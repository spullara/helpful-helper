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
    
    func setupCamera(position: AVCaptureDevice.Position) -> AVCaptureSession? {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: position) else {
            print("\(position) camera not available")
            return nil
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
            
            let metadataOutput = AVCaptureMetadataOutput()
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.metadataObjectTypes = [.face]
            }
            
            return session
        } catch {
            print("Error setting up capture session for \(position) camera: \(error)")
            return nil
        }
    }
    
    func test() {
        Task {
            // Set up front camera
            if let frontSession = setupCamera(position: .front) {
                DispatchQueue.global(qos: .userInitiated).async {
                    frontSession.startRunning()
                    DispatchQueue.main.async {
                        self.frontCaptureSession = frontSession
                    }
                }
            }
            
            // Set up back camera
            if let backSession = setupCamera(position: .back) {
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
                    
                    // Use front camera for tracking (you can modify this based on your needs)
                    if let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                          for: .video,
                                                          position: .front) {
                        let videoOutput = AVCaptureVideoDataOutput()
                        let videoConnection = videoOutput.connection(with: .video)
                        let referenceDimensions = CGSize(
                            width: videoConnection?.videoMaxScaleAndCropFactor ?? 1920,
                            height: videoConnection?.videoMaxScaleAndCropFactor ?? 1080
                        )
                        
                        let cameraInfo = DockAccessory.CameraInformation(
                            captureDevice: camera.deviceType,
                            cameraPosition: camera.position,
                            orientation: .portrait,
                            cameraIntrinsics: nil,
                            referenceDimensions: referenceDimensions
                        )
                        
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
    
    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date(), label: "New Item")
            modelContext.insert(newItem)
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
