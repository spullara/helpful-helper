import SwiftUI
import AVFoundation
import DockKit
import SwiftData

// MARK: - Camera Preview View
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

// MARK: - Camera Session Coordinator
class CameraSessionCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, ObservableObject {
    private var multiCamSession: AVCaptureMultiCamSession?
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var currentDockAccessory: DockAccessory?
    private var lastProcessedTime: TimeInterval = 0
    private let minimumProcessingInterval: TimeInterval = 0.1 // 10Hz maximum processing rate
    private var frontCameraConnection: AVCaptureConnection?
    
    override init() {
        super.init()
        setupSession()
        monitorDockAccessories()
    }
    
    private func setupSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam not supported")
            return
        }
        
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        
        // Setup front camera with face detection first
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let frontInput = try? AVCaptureDeviceInput(device: frontCamera) else {
            print("Failed to setup front camera")
            return
        }
        
        if session.canAddInput(frontInput) {
            session.addInput(frontInput)
            
            // Setup metadata output for face detection
            let metadata = AVCaptureMetadataOutput()
            if session.canAddOutput(metadata) {
                session.addOutput(metadata)
                
                // Important: Set the metadata output connection and orientation
                if let connection = metadata.connection(with: .metadata) {
                    connection.isEnabled = true
                    frontCameraConnection = connection
                }
                
                metadata.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                
                // Set metadata object types after adding the output to the session
                if metadata.availableMetadataObjectTypes.contains(.face) {
                    metadata.metadataObjectTypes = [.face]
                }
                
                self.metadataOutput = metadata
            }
            
            // Setup front camera preview
            let frontOutput = AVCaptureVideoDataOutput()
            if session.canAddOutput(frontOutput) {
                session.addOutput(frontOutput)
                
                let frontLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
                frontLayer.videoGravity = .resizeAspectFill
                
                let frontConnection = AVCaptureConnection(inputPort: frontInput.ports[0], videoPreviewLayer: frontLayer)
                frontConnection.videoOrientation = .portrait
                session.addConnection(frontConnection)
                self.frontPreviewLayer = frontLayer
            }
        }
        
        // Setup back camera
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let backInput = try? AVCaptureDeviceInput(device: backCamera) else {
            print("Failed to setup back camera")
            return
        }
        
        if session.canAddInput(backInput) {
            session.addInput(backInput)
            
            let backOutput = AVCaptureVideoDataOutput()
            if session.canAddOutput(backOutput) {
                session.addOutput(backOutput)
                
                let backLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
                backLayer.videoGravity = .resizeAspectFill
                
                let backConnection = AVCaptureConnection(inputPort: backInput.ports[0], videoPreviewLayer: backLayer)
                backConnection.videoOrientation = .portrait
                session.addConnection(backConnection)
                self.backPreviewLayer = backLayer
            }
        }
        
        session.commitConfiguration()
        self.multiCamSession = session
        
        // Start the session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        
        print("Camera session setup completed")
    }
    
    private func monitorDockAccessories() {
        Task {
            do {
                // Disable system tracking since we're doing manual tracking
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
                print("System tracking disabled")
                
                for await stateChange in try DockAccessoryManager.shared.accessoryStateChanges {
                    if let accessory = stateChange.accessory, stateChange.state == .docked {
                        self.currentDockAccessory = accessory
                        print("Dock accessory connected: \(accessory.identifier)")
                        
                        // Set framing mode to center when accessory connects
                        try await accessory.setFramingMode(.center)
                    } else {
                        self.currentDockAccessory = nil
                        print("Dock accessory disconnected")
                    }
                }
            } catch {
                print("Error monitoring accessories: \(error)")
            }
        }
    }
    
    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Ensure we don't process frames too frequently
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessedTime >= minimumProcessingInterval else { return }
        lastProcessedTime = currentTime
        
        guard let accessory = currentDockAccessory else {
            print("No dock accessory connected")
            return
        }
        
        print("Received metadata objects: \(metadataObjects.count)")
        
        // Only process if we have face metadata objects
        guard !metadataObjects.isEmpty else { return }
        
        Task {
            do {
                // Create camera information for tracking
                let cameraInfo = DockAccessory.CameraInformation(
                    captureDevice: .builtInWideAngleCamera,
                    cameraPosition: .front,
                    orientation: .portrait,
                    cameraIntrinsics: nil,
                    referenceDimensions: CGSize(width: 1920, height: 1080)
                )
                
                // Track the faces
                try await accessory.track(metadataObjects, cameraInformation: cameraInfo)
                print("Tracked faces: \(metadataObjects.count)")
            } catch {
                print("Error tracking faces: \(error)")
            }
        }
    }
    
    // Public accessors
    func getFrontPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return frontPreviewLayer
    }
    
    func getBackPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return backPreviewLayer
    }
    
    func getSession() -> AVCaptureMultiCamSession? {
        return multiCamSession
    }
}

// MARK: - Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @StateObject private var sessionCoordinator = CameraSessionCoordinator()
    
    var body: some View {
        VStack {
            Text("Manual Tracking Mode")
                .font(.headline)
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
