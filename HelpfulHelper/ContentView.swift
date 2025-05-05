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
    @State private var firstEmbeddingCaptured = false

    // Add a new property for the EmbeddingIndex
    @State private var embeddingIndex = EmbeddingIndex(name: "FaceEmbeddings", dim: 2048)
    @State private var embeddingMatchLog: [(String, Float, UIImage?)] = []

    // Add a new property for the user embedding index
    @State private var userEmbeddingIndex = EmbeddingIndex(name: "UserEmbeddings", dim: 2048)

    // Add a new state variable for the probable user
    @State private var probableUser: String = "Unknown"

    // Add these new properties
    @State private var backCameraFaceTimer: Timer?
    @State private var bestMatchName: String = "No face detected"

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
                            ForEach(transcripts.reversed(), id: \.self) { transcript in
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
                    Text("Face Captured: \(firstEmbeddingCaptured)")
                    Text("Probable User: \(probableUser)")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                // Add this new Text view to display the best match name
                Text("Back Camera Face: \(bestMatchName)")
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

            // Start the back camera face detection timer
            startBackCameraFaceDetection()
        }
        .onDisappear {
            // Stop the timer when the view disappears
            backCameraFaceTimer?.invalidate()
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
        firstEmbeddingCaptured = false
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
                        self.faceEmbeddings.append(embedding.0)
                        
                        // If this is the first embedding captured during this speech session
                        if !self.firstEmbeddingCaptured {
                            self.firstEmbeddingCaptured = true
                            if let matchedUser = self.matchFaceToUser(embedding.0) {
                                self.audioCoordinator.sendProbableUserMessage(matchedUser)
                            } else {
                                self.audioCoordinator.sendProbableUserMessage(nil)
                            }
                        }
                    }
                }
            }
        } catch {
            print("Face capture error: \(error)")
        }
    }

    private func calculateAverageFaceEmbedding() {
        guard !faceEmbeddings.isEmpty else { return }

        averageFaceEmbedding = averageEmbeddings(faceEmbeddings)

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
                            self.probableUser = matchedUser.name
                        }
                    }
                    firstEmbeddingCaptured = false
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
            let search = userEmbeddingIndex.search(vector: floatArray, k: 1)
            print("Found \(search.map(\.1)) for \(user.name)")
        }
        
        print("Updated user embedding index with \(usersWithEmbeddings.count) users")
    }

    // Add a function to match a face to a user name
    private func matchFaceToUser(_ faceEmbedding: MLMultiArray) -> (name: String, similarity: Double)? {
        if let (matchedUser, similarity) = DBHelper.shared.findBestMatchingUser(for: faceEmbedding) {
            print("Matched face to user: \(matchedUser.name), similarity: \(similarity)")
            DispatchQueue.main.async {
                self.probableUser = matchedUser.name
            }
            return (name: matchedUser.name, similarity: similarity)
        }
        DispatchQueue.main.async {
            self.probableUser = "Unknown"
        }
        return nil
    }

    // Add this new function to start the back camera face detection
    private func startBackCameraFaceDetection() {
        backCameraFaceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                await findBackCameraFace()
            }
        }
    }

    // Add this new function to find faces in the back camera image
    private func findBackCameraFace() async {
        do {
            let capturedImage = try await sessionCoordinator.captureImage(from: "back")
            if let image = UIImage(data: capturedImage),
               let embedding = faceIdentifier.findFaces(image: image) {
                if let matchedUser = matchFaceToUser(embedding.0) {
                    DispatchQueue.main.async {
                        self.bestMatchName = matchedUser.name
                    }
                } else {
                    DispatchQueue.main.async {
                        self.bestMatchName = "Unknown face"
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.bestMatchName = "No face detected"
                }
            }
        } catch {
            print("Error capturing back camera image: \(error)")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
