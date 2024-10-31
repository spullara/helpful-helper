import SwiftUI
import AVFoundation
import DockKit
import SwiftData

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isRecording = false
    @State private var isSessionActive = false
    @State private var isTestingAnthropic = false
    @State private var anthropicResult: String = ""
    
    @StateObject private var sessionCoordinator: CameraSessionCoordinator
    @StateObject private var audioCoordinator: AudioStreamCoordinator
    
    init() {
        let cameraCoordinator = CameraSessionCoordinator()
        _sessionCoordinator = StateObject(wrappedValue: cameraCoordinator)
        _audioCoordinator = StateObject(wrappedValue: AudioStreamCoordinator(cameraCoordinator: cameraCoordinator))
    }
    
    var body: some View {
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
                
                Button(action: testAnthropic) {
                    Text("Test Anthropic")
                        .font(.headline)
                        .padding()
                        .background(isTestingAnthropic ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(isTestingAnthropic)
            }
            
            if !anthropicResult.isEmpty {
                Text("Anthropic Result:")
                    .font(.headline)
                Text(anthropicResult)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }
            
            // Front camera preview
            VStack {
                Text("Front Camera (Face Detection)")
                    .font(.caption)
                if let session = sessionCoordinator.getSession(),
                   let layer = sessionCoordinator.getFrontPreviewLayer() {
                    ZStack {
                        CameraPreviewView(session: session, videoLayer: layer)
                            .frame(height: 300)
                            .cornerRadius(12)
                        RectangleOverlayView(rects: sessionCoordinator.trackedRects)
                            .frame(height: 300)
                    }
                } else {
                    Text("Front camera unavailable")
                        .frame(height: 300)
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
                        .frame(height: 300)
                        .cornerRadius(12)
                } else {
                    Text("Back camera unavailable")
                        .frame(height: 300)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
            }
        }
        .padding()
    }

    private func toggleSession() {
        if isSessionActive {
            audioCoordinator.endSession()
        } else {
            audioCoordinator.startSession()
        }
        isSessionActive.toggle()
    }
    
    private func testAnthropic() {
        isTestingAnthropic = true
        anthropicResult = ""
        
        Task {
            do {
                let imageData = try await sessionCoordinator.captureImage(from: "front")
                let result = try await audioCoordinator.callAnthropicAPI(imageData: imageData, query: "What is in the image?")
                DispatchQueue.main.async {
                    self.anthropicResult = result
                    self.isTestingAnthropic = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.anthropicResult = "Error: \(error.localizedDescription)"
                    self.isTestingAnthropic = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
