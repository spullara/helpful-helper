import SwiftUI
import AVFoundation
import DockKit
import SwiftData
import Vision
import CoreML
import CoreFoundation
import UIKit

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSessionActive = false
    @State private var transcripts: [String] = []
    @State private var lastCapturedImage: UIImage?
    @State private var faceEmbedding: MLMultiArray?
    private var faceIdentifier = Faces()

    @StateObject private var sessionCoordinator: CameraSessionCoordinator
    @StateObject private var audioCoordinator: AudioStreamCoordinator
    
    // New state variables for face embedding collection
    @State private var faceEmbeddings: [MLMultiArray] = []
    @State private var embeddingTimer: Timer?
    @State private var averageFaceEmbedding: MLMultiArray?
    @State private var totalEmbeddings: Int = 0
    
    // Create DBHelper instance once
    private let dbHelper = DBHelper()
    
    init() {
        let cameraCoordinator = CameraSessionCoordinator()
        _sessionCoordinator = StateObject(wrappedValue: cameraCoordinator)
        _audioCoordinator = StateObject(wrappedValue: AudioStreamCoordinator(cameraCoordinator: cameraCoordinator))
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack {
                HStack {
                    Button(action: toggleSession) {
                        Text(isSessionActive ? "Sleep" : "Wake")
                            .font(.headline)
                            .padding()
                            .background(isSessionActive ? Color.red : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    
                    Button(action: testCapture) {
                        Text("Test Capture")
                            .font(.headline)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                
                if let image = lastCapturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geometry.size.width - 30, maxHeight: 300)
                        .cornerRadius(12)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                }
                
                HStack(spacing: 10) {
                    // Front camera preview
                    VStack {
                        Text("Front Camera (Face Detection)")
                            .font(.caption)
                        if let session = sessionCoordinator.getSession(),
                           let layer = sessionCoordinator.getFrontPreviewLayer() {
                            ZStack {
                                CameraPreviewView(session: session, videoLayer: layer)
                                    .aspectRatio(3/4, contentMode: .fit)
                                    .frame(width: geometry.size.width / 2 - 15)
                                    .cornerRadius(12)
                                RectangleOverlayView(trackedSubjects: sessionCoordinator.trackedSubjects)
                                    .aspectRatio(3/4, contentMode: .fit)
                                    .frame(width: geometry.size.width / 2 - 15)
                            }
                        } else {
                            Text("Front camera unavailable")
                                .frame(width: geometry.size.width / 2 - 15, height: (geometry.size.width / 2 - 15) * 4/3)
                                .background(Color.gray.opacity(0.3))
                                .cornerRadius(12)
                        }
                    }

                    // Back camera preview
                    VStack {
                        Text("Back Camera")
                            .font(.caption)
                        if let session = sessionCoordinator.getSession(),
                           let layer = sessionCoordinator.getBackPreviewLayer() {
                            CameraPreviewView(session: session, videoLayer: layer)
                                .aspectRatio(3/4, contentMode: .fit)
                                .frame(width: geometry.size.width / 2 - 15)
                                .cornerRadius(12)
                        } else {
                            Text("Back camera unavailable")
                                .frame(width: geometry.size.width / 2 - 15, height: (geometry.size.width / 2 - 15) * 4/3)
                                .background(Color.gray.opacity(0.3))
                                .cornerRadius(12)
                        }
                    }
                }

                // Transcription Log
                VStack {
                    Text("Transcription Log")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(transcripts, id: \.self) { transcript in
                                Text(transcript)
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(height: 150)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()

                VStack {
                    Text("Speaking: \(audioCoordinator.averageSpeakingConfidence, specifier: "%.2f")")
                    Text("Looking: \(audioCoordinator.averageLookingAtCameraConfidence, specifier: "%.2f")")
                    Text("Total Embeddings: \(totalEmbeddings)")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
            .padding()

        }
        .onReceive(audioCoordinator.$latestTranscript) { newTranscript in
            if !newTranscript.isEmpty {
                transcripts.append(newTranscript)
                if transcripts.count > 10 {
                    transcripts.removeFirst()
                }
            }
        }
        .onReceive(audioCoordinator.$isSpeechActive) { isSpeechActive in
            if isSpeechActive {
                startCollectingEmbeddings()
            } else {
                stopCollectingEmbeddings()
            }
        }
    }

    private func toggleSession() {
        if isSessionActive {
            audioCoordinator.endSession()
        } else {
            audioCoordinator.startSession()
        }
        isSessionActive.toggle()
    }

    private func testCapture() {
        Task {
            do {
                let capturedImage = try await sessionCoordinator.captureFace()
                DispatchQueue.main.async {
                    self.lastCapturedImage = capturedImage
                    
                    let startTime = CFAbsoluteTimeGetCurrent()
                    if let embedding = self.faceIdentifier.getFaceEmbedding(for: capturedImage) {
                        let endTime = CFAbsoluteTimeGetCurrent()
                        let elapsedTime = endTime - startTime
                        
                        self.faceEmbedding = embedding
                        print("Face Embedding Time: \(elapsedTime) seconds")
                    } else {
                        print("Failed to generate face embedding")
                    }
                }
            } catch {
                print("Capture error: \(error)")
            }
        }
    }
    private func startCollectingEmbeddings() {
        faceEmbeddings = []
        embeddingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task {
                await collectFaceEmbedding()
            }
        }
        print("Started collecting face embeddings.")
    }

    private func stopCollectingEmbeddings() {
        embeddingTimer?.invalidate()
        embeddingTimer = nil
        calculateAverageFaceEmbedding()
        print("Stopped collecting face embeddings.")
    }

    private func collectFaceEmbedding() async {
        do {
            let capturedImage = try await sessionCoordinator.captureFace()
            
            // Check if there's a tracked person with looking confidence > 0.8
            if let trackedPerson = sessionCoordinator.trackedSubjects.first(where: { subject in
                if case .person(let person) = subject,
                   let lookingConfidence = person.lookingAtCameraConfidence,
                   lookingConfidence > 0.8 {
                    return true
                }
                return false
            }) {
                if let embedding = faceIdentifier.getFaceEmbedding(for: capturedImage) {
                    DispatchQueue.main.async {
                        self.faceEmbeddings.append(embedding)
                        self.totalEmbeddings = self.faceEmbeddings.count
                    }
                }
            }
        } catch {
            print("Face capture error: \(error)")
        }
    }

    private func calculateAverageFaceEmbedding() {
        guard !faceEmbeddings.isEmpty else { return }

        let embeddingSize = faceEmbeddings[0].count
        var averageEmbedding = [Double](repeating: 0, count: embeddingSize)

        for embedding in faceEmbeddings {
            for i in 0..<embeddingSize {
                averageEmbedding[i] += embedding[i].doubleValue
            }
        }

        for i in 0..<embeddingSize {
            averageEmbedding[i] /= Double(faceEmbeddings.count)
        }

        averageFaceEmbedding = try? MLMultiArray(shape: [embeddingSize as NSNumber], dataType: .double)
        for i in 0..<embeddingSize {
            averageFaceEmbedding?[i] = NSNumber(value: averageEmbedding[i])
        }

        // Save the last frame as an image
        if let lastFrame = sessionCoordinator.getLatestFrame(camera: .front) {
            let image = UIImage(ciImage: CIImage(cvPixelBuffer: lastFrame))
            if let fileName = dbHelper.saveFrameAsImage(image),
               let averageEmbedding = averageFaceEmbedding {
                // Store the average embedding and filename in the database
                let embeddingId = dbHelper.storeFaceEmbedding(averageEmbedding, filename: fileName)
                print("Stored average face embedding with ID: \(embeddingId ?? -1)")
            }
        }

        print("Average Face Embedding calculated and stored. Total embeddings: \(faceEmbeddings.count)")
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
