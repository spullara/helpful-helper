import SwiftUI
import AVFoundation
import DockKit
import SwiftData

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
//    @Query private var items: [Item]
    @StateObject private var audioCoordinator = AudioStreamCoordinator()
//    @StateObject private var sessionCoordinator = CameraSessionCoordinator()
//    @State private var loopBackTest = AudioLoopbackTest()
    @State private var isRecording = false
    
    var body: some View {
        VStack {
            Text("Manual Tracking Mode")
                .font(.headline)
                .padding(.top)
            
//            // Front camera preview
//            VStack {
//                Text("Front Camera (Face Detection)")
//                    .font(.caption)
//                if let session = sessionCoordinator.getSession(),
//                   let layer = sessionCoordinator.getFrontPreviewLayer() {
//                    CameraPreviewView(session: session, videoLayer: layer)
//                        .frame(height: 300)
//                        .cornerRadius(12)
//                } else {
//                    Text("Front camera unavailable")
//                        .frame(height: 300)
//                        .background(Color.gray.opacity(0.3))
//                        .cornerRadius(12)
//                }
//            }
//            
//            // Back camera preview
//            VStack {
//                Text("Back Camera")
//                    .font(.caption)
//                if let session = sessionCoordinator.getSession(),
//                   let layer = sessionCoordinator.getBackPreviewLayer() {
//                    CameraPreviewView(session: session, videoLayer: layer)
//                        .frame(height: 300)
//                        .cornerRadius(12)
//                } else {
//                    Text("Back camera unavailable")
//                        .frame(height: 300)
//                        .background(Color.gray.opacity(0.3))
//                        .cornerRadius(12)
//                }
//            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
