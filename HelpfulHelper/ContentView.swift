import SwiftUI
import AVFoundation
import DockKit
import SwiftData
import Vision
import CoreML

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSessionActive = false
    @State private var transcripts: [String] = []
    @State private var lastCapturedImage: UIImage? // Add this state variable
    @State private var faceEmbedding: MLMultiArray?
    private var faceIdentifier = Faces()

    @StateObject private var sessionCoordinator: CameraSessionCoordinator
    @StateObject private var audioCoordinator: AudioStreamCoordinator
    
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
                    Text("Avg Speaking Confidence: \(audioCoordinator.averageSpeakingConfidence, specifier: "%.2f")")
                    Text("Avg Looking at Camera Confidence: \(audioCoordinator.averageLookingAtCameraConfidence, specifier: "%.2f")")
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
                    if let embedding = self.faceIdentifier.getFaceEmbedding(for: capturedImage) {
                        self.faceEmbedding = embedding
                        print("Face Embedding: \(embedding)")
                    } else {
                        print("Failed to generate face embedding")
                    }
                }
            } catch {
                print("Capture error: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
