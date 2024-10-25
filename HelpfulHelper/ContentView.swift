import SwiftUI
import AVFoundation
import DockKit
import SwiftData

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
        
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.frame = uiView.bounds
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @State private var dockAccessoryManager = DockAccessoryManager.shared
    @State private var frontCaptureSession: AVCaptureSession?
    @State private var backCaptureSession: AVCaptureSession?
    @State private var frontMetadataOutput: AVCaptureMetadataOutput?
    
    func setupCamera(position: AVCaptureDevice.Position) -> (AVCaptureSession?, AVCaptureMetadataOutput?) {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        var metadataOutput: AVCaptureMetadataOutput?
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: position) else {
            print("\(position) camera not available")
            return (nil, nil)
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            let videoOutput = AVCaptureVideoDataOutput()
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            
            // Create and configure metadata output
            let metadata = AVCaptureMetadataOutput()
            if session.canAddOutput(metadata) {
                session.addOutput(metadata)
                metadata.metadataObjectTypes = [.face]
                metadataOutput = metadata
            }
            
            return (session, metadataOutput)
        } catch {
            print("Error setting up capture session for \(position) camera: \(error)")
            return (nil, nil)
        }
    }
    
    func test() {
        Task {
            // Set up front camera
            let (frontSession, frontMetadata) = setupCamera(position: .front)
            if let frontSession = frontSession {
                self.frontMetadataOutput = frontMetadata
                DispatchQueue.global(qos: .userInitiated).async {
                    frontSession.startRunning()
                    DispatchQueue.main.async {
                        self.frontCaptureSession = frontSession
                    }
                }
            }
            
            // Set up back camera
            let (backSession, _) = setupCamera(position: .back)
            if let backSession = backSession {
                DispatchQueue.global(qos: .userInitiated).async {
                    backSession.startRunning()
                    DispatchQueue.main.async {
                        self.backCaptureSession = backSession
                    }
                }
            }
            
            do {
                // Monitor for dock accessories
                print("Getting accessories...")
                for await accessoryStateChange in try DockAccessoryManager.shared.accessoryStateChanges {
                    guard let accessory = accessoryStateChange.accessory,
                          accessoryStateChange.state == .docked else {
                        continue
                    }
                    
                    print("Dock accessory connected: \(accessory.identifier)")
                    
                    // Configure accessory to use front camera
                    if let frontSession = frontCaptureSession {
                        // Get the front camera device
                        guard let frontCamera = (frontSession.inputs.first as? AVCaptureDeviceInput)?.device else {
                            continue
                        }
                        
                        // Create camera information for the front camera
                        let cameraInfo = DockAccessory.CameraInformation(
                            captureDevice: frontCamera.deviceType,
                            cameraPosition: .front,  // Explicitly specify front camera
                            orientation: .portrait,
                            cameraIntrinsics: nil,
                            referenceDimensions: CGSize(width: 1920, height: 1080)
                        )
                        
                        // Monitor tracking states
                        for await state in try accessory.trackingStates {
                            print("Tracking state updated: \(state.description)")
                            print("Tracked subjects: \(state.trackedSubjects.count)")
                        }
                    }
                }
            } catch {
                print("Error monitoring accessories: \(error)")
            }
        }
    }
    
    var body: some View {
        VStack {
            if DockAccessoryManager.shared.isSystemTrackingEnabled {
                Text("System Tracking Enabled")
                    .onAppear(perform: test)
            }
        
            // Front camera preview
            VStack {
                Text("Front Camera")
                    .font(.caption)
                if let session = frontCaptureSession {
                    CameraPreviewView(session: session)
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
                if let session = backCaptureSession {
                    CameraPreviewView(session: session)
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
