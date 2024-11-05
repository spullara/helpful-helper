import SwiftUI
import AVFoundation
import DockKit
import SwiftData
import Vision
import CoreML
import CoreFoundation
import UIKit

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var userEmbeddingIndex: EmbeddingIndex?

    init() {
        _userEmbeddingIndex = State(initialValue: EmbeddingIndex(name: "UserEmbeddings", dim: 512))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MainView()
                .tabItem {
                    Image(systemName: "house")
                    Text("Main")
                }
                .tag(0)

            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(1)
        }
    }
}

struct MainView: View {
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

    // Add a new property for the EmbeddingIndex
    @State private var embeddingIndex = EmbeddingIndex(name: "FaceEmbeddings", dim: 2048)
    @State private var embeddingMatchLog: [(String, Float, UIImage?)] = []

    // Add a new property for the user embedding index
    @State private var userEmbeddingIndex = EmbeddingIndex(name: "UserEmbeddings", dim: 2048)

    // Add a new state variable for the probable user
    @State private var probableUser: String = "Unknown"

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

                    Button(action: resetDatabase) {
                        Text("Reset")
                            .font(.headline)
                            .padding()
                            .background(Color.orange)
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
                    Text("Probable User: \(probableUser)")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
            .padding()

        }
        .padding()
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
        .onAppear {
            loadFaceEmbeddings()
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

    private func resetDatabase() {
        // Clear the database
        DBHelper.shared.clearDatabase()

        // Reset state variables
        faceEmbeddings = []
        averageFaceEmbedding = nil
        totalEmbeddings = 0
        embeddingMatchLog = []

        // Reinitialize the embedding index
        embeddingIndex = EmbeddingIndex(name: "FaceEmbeddings", dim: 2048)

        print("Database reset completed")
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
            if let _ = sessionCoordinator.trackedSubjects.first(where: { subject in
                if case .person(let person) = subject,
                   let lookingConfidence = person.lookingAtCameraConfidence,
                   lookingConfidence > 0.8 {
                    return true
                }
                return false
            }) {
                if let embedding = faceIdentifier.findFaces(image: capturedImage) {
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

        // Use captureFace instead of getLatestFrame
        Task {
            do {
                let capturedFaceImage = try await sessionCoordinator.captureFace()
                if let fileName = DBHelper.shared.saveFrameAsImage(capturedFaceImage),
                   let averageEmbedding = averageFaceEmbedding {
                    let floatArray = convertToArray(averageEmbedding)

                    // Store the average embedding and filename in the database
                    if let embeddingId = DBHelper.shared.storeFaceEmbedding(averageEmbedding, filename: fileName) {
                        print("Stored average face embedding with ID: \(embeddingId)")

                        // Add the new embedding to the EmbeddingIndex
                        embeddingIndex.add(vector: floatArray, localIdentifier: fileName)
                        print("Added new embedding to the index")
                    }

                    // Match the face to a user
                    if let matchedUser = matchFaceToUser(averageEmbedding) {
                        DispatchQueue.main.async {
                            self.probableUser = matchedUser
                        }
                    }
                }
            } catch {
                print("Error capturing face image: \(error)")
            }
        }

        print("Average Face Embedding calculated and stored. Total embeddings: \(faceEmbeddings.count)")
    }

    private func loadImage(for identifier: String) -> UIImage? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent(identifier)
        return UIImage(contentsOfFile: fileURL.path)
    }

    // Helper function to convert MLMultiArray to [Float]
    private func convertToArray(_ mlMultiArray: MLMultiArray) -> [Float] {
        let length = mlMultiArray.count
        var array = [Float](repeating: 0.0, count: length)
        for i in 0...length - 1 {
            array[i] = Float(truncating: mlMultiArray[i])
        }
        return array
    }

    private func loadFaceEmbeddings() {
        // Initialize the EmbeddingIndex
        embeddingIndex = EmbeddingIndex(name: "FaceEmbeddings", dim: 512) // Assuming 512-dimensional embeddings

        // Load existing embeddings from the database
        let embeddings = DBHelper.shared.getAllFaceEmbeddings()
        for (embedding, identifier) in embeddings {
            let floatArray = convertToArray(embedding)
            embeddingIndex.add(vector: floatArray, localIdentifier: identifier)
        }

        print("Loaded \(embeddings.count) face embeddings into the index")
    }

    // Add a new function to update the user embedding index
    private func updateUserEmbeddingIndex() {
        // Clear the existing index
        userEmbeddingIndex.clear()

        // Get all users with their average embeddings
        let usersWithEmbeddings = DBHelper.shared.getUsersWithAverageEmbeddings()

        // Add each user's average embedding to the index
        for (user, averageEmbedding) in usersWithEmbeddings {
            let floatArray = convertToArray(averageEmbedding)
            userEmbeddingIndex.add(vector: floatArray, localIdentifier: user.name)
        }

        print("Updated user embedding index with \(usersWithEmbeddings.count) users")
    }

    // Add a function to match a face to a user name
    private func matchFaceToUser(_ faceEmbedding: MLMultiArray) -> String? {
        updateUserEmbeddingIndex()
        print("Searching for a match...")
        let floatArray = convertToArray(faceEmbedding)
        let searchResults = userEmbeddingIndex.search(vector: floatArray, k: 10)
        print("Found \(searchResults.map(\.1))")
        if let topMatch = searchResults.first {
            let userName = userEmbeddingIndex.getLocalIdentifier(topMatch.0)
            let similarity = topMatch.1
            print("Matched face to user: \(userName), similarity: \(similarity)")
            return userName
        }
        return nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
