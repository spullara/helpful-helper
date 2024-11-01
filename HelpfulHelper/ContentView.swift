import SwiftUI
import AVFoundation
import DockKit
import SwiftData

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSessionActive = false
    @State private var transcripts: [String] = []
    @State private var lastCapturedImage: UIImage? // Add this state variable
    
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
                        .scaledToFit()
                        .frame(height: 200)
                        .cornerRadius(12)
                        .padding()
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
                let imageData = try await sessionCoordinator.captureImage(from: "front")
                if let image = UIImage(data: imageData) {
                    DispatchQueue.main.async {
                        // Create a new image context with the same size as the captured image
                        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
                        
                        // Draw the original image
                        image.draw(at: .zero)
                        
                        // Get the current graphics context
                        if let context = UIGraphicsGetCurrentContext() {
                            // Draw rectangles for tracked subjects
                            context.setStrokeColor(UIColor.red.cgColor)
                            context.setLineWidth(10.0)
                            
                            for subject in sessionCoordinator.trackedSubjects {
                                if case .person(let person) = subject {
                                    // Calculate original rect in image coordinates
                                    let originalRect = CGRect(
                                        x: person.rect.origin.x * image.size.width,
                                        y: person.rect.origin.y * image.size.height,
                                        width: person.rect.size.width * image.size.width,
                                        height: person.rect.size.height * image.size.height
                                    )
                                    
                                    // Calculate the center point of the original rect
                                    let centerX = originalRect.midX
                                    let centerY = originalRect.midY
                                    
                                    // Create new rect 2x larger, centered on the same point
                                    let newWidth = originalRect.width * 2
                                    let newHeight = originalRect.height * 2
                                    let newRect = CGRect(
                                        x: centerX - (newWidth / 2),
                                        y: centerY - (newHeight / 2),
                                        width: newWidth,
                                        height: newHeight
                                    )
                                    
                                    context.stroke(newRect)
                                }
                            }
                        }
                        
                        // Get the resulting image with rectangles
                        if let newImage = UIGraphicsGetImageFromCurrentImageContext() {
                            self.lastCapturedImage = newImage
                        }
                        
                        // End the image context
                        UIGraphicsEndImageContext()
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
