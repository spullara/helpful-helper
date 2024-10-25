import SwiftUI
import AVFoundation
import DockKit
import SwiftData

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let videoLayer: AVCaptureVideoPreviewLayer
    
    init(session: AVCaptureSession, videoLayer: AVCaptureVideoPreviewLayer) {
        self.session = session
        self.videoLayer = videoLayer
    }
    
    class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer
        
        init(layer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = layer
            super.init(frame: .zero)
            setupLayer()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupLayer() {
            layer.addSublayer(previewLayer)
            backgroundColor = .black
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(layer: videoLayer)
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
    @State private var multiCamSession: AVCaptureMultiCamSession?
    @State private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    @State private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    @State private var frontMetadataOutput: AVCaptureMetadataOutput?
    
    func setupMultiCamSession() -> (AVCaptureMultiCamSession?, AVCaptureVideoPreviewLayer?, AVCaptureVideoPreviewLayer?, AVCaptureMetadataOutput?) {
        // Check if device supports multi cam
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam not supported on this device")
            return (nil, nil, nil, nil)
        }
        
        let session = AVCaptureMultiCamSession()
        
        // Start configuration
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        var frontPreviewLayer: AVCaptureVideoPreviewLayer?
        var backPreviewLayer: AVCaptureVideoPreviewLayer?
        var metadataOutput: AVCaptureMetadataOutput?
        
        // Setup back camera
        guard let backCamera = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back),
              let backDeviceInput = try? AVCaptureDeviceInput(device: backCamera) else {
            print("Unable to initialize back camera")
            return (nil, nil, nil, nil)
        }
        
        guard session.canAddInput(backDeviceInput) else {
            print("Unable to add back camera input")
            return (nil, nil, nil, nil)
        }
        session.addInput(backDeviceInput)
        
        let backOutput = AVCaptureVideoDataOutput()
        guard session.canAddOutput(backOutput) else {
            print("Unable to add back camera output")
            return (nil, nil, nil, nil)
        }
        session.addOutput(backOutput)
        
        // Setup back preview layer
        let backLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        backLayer.videoGravity = .resizeAspectFill
        
        // Create back camera preview layer connection
        let backConnection = AVCaptureConnection(inputPort: backDeviceInput.ports[0], videoPreviewLayer: backLayer)
        backConnection.videoOrientation = .portrait
        session.addConnection(backConnection)
        backPreviewLayer = backLayer
        
        // Setup front camera
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let frontDeviceInput = try? AVCaptureDeviceInput(device: frontCamera) else {
            print("Unable to initialize front camera")
            return (session, nil, backPreviewLayer, nil)
        }
        
        guard session.canAddInput(frontDeviceInput) else {
            print("Unable to add front camera input")
            return (session, nil, backPreviewLayer, nil)
        }
        session.addInput(frontDeviceInput)
        
        let frontOutput = AVCaptureVideoDataOutput()
        guard session.canAddOutput(frontOutput) else {
            print("Unable to add front camera output")
            return (session, nil, backPreviewLayer, nil)
        }
        session.addOutput(frontOutput)
        
        // Setup front preview layer
        let frontLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontLayer.videoGravity = .resizeAspectFill
        
        // Create front camera preview layer connection
        let frontConnection = AVCaptureConnection(inputPort: frontDeviceInput.ports[0], videoPreviewLayer: frontLayer)
        frontConnection.videoOrientation = .portrait
        session.addConnection(frontConnection)
        frontPreviewLayer = frontLayer
        
        // Setup metadata output for face detection
        let metadata = AVCaptureMetadataOutput()
        if session.canAddOutput(metadata) {
            session.addOutput(metadata)
            metadata.metadataObjectTypes = [.face]
            metadataOutput = metadata
        }
        
        print("MultiCam session setup completed")
        return (session, frontPreviewLayer, backPreviewLayer, metadataOutput)
    }
    
    func test() {
        Task {
            let (session, frontLayer, backLayer, frontMetadata) = setupMultiCamSession()
            
            if let session = session {
                DispatchQueue.main.async {
                    self.multiCamSession = session
                    self.frontPreviewLayer = frontLayer
                    self.backPreviewLayer = backLayer
                    self.frontMetadataOutput = frontMetadata
                }
                
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
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
                    
                    // Monitor tracking states
                    for await state in try accessory.trackingStates {
                        print("Tracking state updated: \(state.description)")
                        print("Tracked subjects: \(state.trackedSubjects.count)")
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
                if let session = multiCamSession,
                   let layer = frontPreviewLayer {
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
                if let session = multiCamSession,
                   let layer = backPreviewLayer {
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
