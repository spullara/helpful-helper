//
//  CameraSessionCoordinator.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/24/24.
//

import AVFoundation
import DockKit
import CoreImage
import UIKit

// MARK: - Camera Session Coordinator
class CameraSessionCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    private var multiCamSession: AVCaptureMultiCamSession?
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var currentDockAccessory: DockAccessory?
    private var lastProcessedTime: TimeInterval = 0
    private let minimumProcessingInterval: TimeInterval = 0.1 // 10Hz maximum processing rate
    private var frontCameraConnection: AVCaptureConnection?
    
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    
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
        
        // Setup front camera
        if let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let frontInput = try? AVCaptureDeviceInput(device: frontCamera),
           session.canAddInput(frontInput) {
            session.addInput(frontInput)
            setupCameraPreview(for: .front, input: frontInput, in: session)
            print("Front camera setup successful")
        } else {
            print("Failed to setup front camera")
        }
        
        // Setup back camera
        if let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let backInput = try? AVCaptureDeviceInput(device: backCamera),
           session.canAddInput(backInput) {
            session.addInput(backInput)
            setupCameraPreview(for: .back, input: backInput, in: session)
            print("Back camera setup successful")
        } else {
            print("Failed to setup back camera")
        }
        
        session.commitConfiguration()
        self.multiCamSession = session
        
        // Start the session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        
        print("Camera session setup completed")
    }
    
    private func setupCameraPreview(for position: AVCaptureDevice.Position, input: AVCaptureDeviceInput, in session: AVCaptureMultiCamSession) {
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        guard session.canAddOutput(output) else {
            print("Cannot add video data output for \(position) camera")
            return
        }
        session.addOutput(output)
        
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            print("No video port found for \(position) camera")
            return
        }
        
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else {
            print("Cannot add connection for \(position) camera")
            return
        }
        session.addConnection(connection)
        
        if position == .front {
            self.frontPreviewLayer = layer
            self.frontVideoOutput = output
        } else {
            self.backPreviewLayer = layer
            self.backVideoOutput = output
        }
        
        print("Preview setup completed for \(position) camera")
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
    
    var lastFaces = 0
    
    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Ensure we don't process frames too frequently
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessedTime >= minimumProcessingInterval else { return }
        lastProcessedTime = currentTime
        
        guard let accessory = currentDockAccessory else {
            return
        }
        
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
                if lastFaces != metadataObjects.count {
                    print("Tracked faces: \(metadataObjects.count)")
                    lastFaces = metadataObjects.count
                }
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

    private var captureCompletion: ((Result<Data, CameraSessionError>) -> Void)?
    private var captureTimer: Timer?
    private var isCapturing = false
    
    func captureImage(from camera: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let videoOutput: AVCaptureVideoDataOutput?
            if camera == "front" {
                videoOutput = frontVideoOutput
            } else if camera == "back" {
                videoOutput = backVideoOutput
            } else {
                continuation.resume(throwing: CameraSessionError.invalidCamera)
                return
            }
            
            guard let output = videoOutput else {
                continuation.resume(throwing: CameraSessionError.outputUnavailable)
                return
            }
            
            self.isCapturing = true
            
            self.captureCompletion = { [weak self] result in
                // Only process if we're still capturing
                guard let self = self, self.isCapturing else { return }
                
                // Reset capture state
                self.isCapturing = false
                self.captureTimer?.invalidate()
                self.captureTimer = nil
                self.captureCompletion = nil
                
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Set up a timeout to cancel the capture after a short duration
            self.captureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self, self.isCapturing else { return }
                self.isCapturing = false
                self.captureCompletion?(.failure(.captureTimeout))
            }
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Only process if we're actively capturing and have a completion handler
        guard isCapturing, let captureCompletion = self.captureCompletion else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            captureCompletion(.failure(.captureFailed))
            return
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            captureCompletion(.failure(.captureFailed))
            return
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
            captureCompletion(.failure(.captureFailed))
            return
        }
        
        captureCompletion(.success(jpegData))
    }
}

enum CameraSessionError: Error {
    case invalidCamera
    case outputUnavailable
    case captureFailed
    case captureTimeout
}
