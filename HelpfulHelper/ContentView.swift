import SwiftUI
import AVFoundation
import DockKit
import SwiftData

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isRecording = false
    @State private var isSessionActive = false
    
    @StateObject private var sessionCoordinator: CameraSessionCoordinator
    @StateObject private var audioCoordinator: AudioStreamCoordinator
    
    init() {
        let cameraCoordinator = CameraSessionCoordinator()
        _sessionCoordinator = StateObject(wrappedValue: cameraCoordinator)
        _audioCoordinator = StateObject(wrappedValue: AudioStreamCoordinator(cameraCoordinator: cameraCoordinator))
    }
    
    var body: some View {
        VStack {
            Button(action: toggleSession) {
                Text(isSessionActive ? "Sleep" : "Wake")
                    .font(.headline)
                    .padding()
                    .background(isSessionActive ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top)
            
            // Front camera preview
            VStack {
                Text("Front Camera (Face Detection)")
                    .font(.caption)
                if let session = sessionCoordinator.getSession(),
                   let layer = sessionCoordinator.getFrontPreviewLayer() {
                    CameraPreviewView(session: session, videoLayer: layer)
                        .frame(height: 300)
                        .cornerRadius(12)
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
