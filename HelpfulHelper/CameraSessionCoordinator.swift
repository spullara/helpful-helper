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
import SwiftUI

// MARK: - Camera Session Coordinator
class CameraSessionCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    // Add properties to store latest frames
    private var latestFrontFrame: CVPixelBuffer?
    private var latestBackFrame: CVPixelBuffer?
    private let frameBufferLock = NSLock()
    
    private var multiCamSession: AVCaptureMultiCamSession?
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var currentDockAccessory: DockAccessory?
    private var lastProcessedTime: TimeInterval = 0
    private let minimumProcessingInterval: TimeInterval = 0.1 // 10Hz maximum processing rate
    private var frontCameraConnection: AVCaptureConnection?
    private let systemTracking = true
    private let debugTracking = false
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    @Published var trackedSubjects: [DockAccessory.TrackedSubjectType] = []
    
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
            if !systemTracking {
                setupMetadataOutput(for: frontInput, in: session)
            }
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

    private func setupMetadataOutput(for input: AVCaptureDeviceInput, in session: AVCaptureMultiCamSession) {
        let metadataOutput = AVCaptureMetadataOutput()
        
        guard session.canAddOutput(metadataOutput) else {
            print("Cannot add metadata output")
            return
        }
        
        session.addOutput(metadataOutput)
        
        // Configure metadata output
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        
        if metadataOutput.availableMetadataObjectTypes.contains(.face) {
            metadataOutput.metadataObjectTypes = [.face]
        }
        
        // Ensure the connection is set up correctly
        if let connection = metadataOutput.connection(with: .metadata) {
            connection.isEnabled = true
        }
        
        self.metadataOutput = metadataOutput
        print("Metadata output setup completed")
    }

    private func monitorDockAccessories() {
        Task {
            do {
                // Disable system tracking since we're doing manual tracking
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(systemTracking)
                print("System tracking \(systemTracking ? "enabled" : "disabled")")
                
                for await stateChange in try DockAccessoryManager.shared.accessoryStateChanges {
                    if let accessory = stateChange.accessory, stateChange.state == .docked {
                        self.currentDockAccessory = accessory
                        print("Dock accessory connected: \(accessory.identifier)")
                        
                        // Set framing mode to center when accessory connects
                        if !systemTracking {
                            try await accessory.setFramingMode(.center)
                        }
                        
                        if systemTracking {
                            subscribeToTrackingUpdates(accessory: accessory)
                        }
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
    
    private func subscribeToTrackingUpdates(accessory: DockAccessory) {
        Task {
            do {
                for try await trackingState in try accessory.trackingStates {
                    // Process the tracking state
                    processTrackingState(trackingState)
                }
            } catch {
                print("Error subscribing to tracking updates: \(error)")
            }
        }
    }

    private func processTrackingState(_ trackingState: DockAccessory.TrackingState) {
        DispatchQueue.main.async {
            self.trackedSubjects = trackingState.trackedSubjects
        }
    }
    
    var lastFaces = -1
    
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
                
                // Get the tracking state
                for try await trackingState in try accessory.trackingStates {
                    for subject in trackingState.trackedSubjects {
                        if case .person(let trackedPerson) = subject {
                            if let speakingConfidence = trackedPerson.speakingConfidence {
                                if debugTracking {
                                    print("****************")
                                    print("identifier: \(trackedPerson.identifier)")
                                    print("saliencyRank: \(trackedPerson.speakingConfidence)")
                                    print("lookingAtCameraConfidence: \(trackedPerson.lookingAtCameraConfidence)")
                                    print("speakingConfidence: \(trackedPerson.speakingConfidence)")
                                    print("rect: \(trackedPerson.rect)")
                                    print("****************")
                                }
                            }
                        }
                    }
                    break  // We only need the first state, so we break after processing it
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
    private var capturingCamera: AVCaptureDevice.Position?
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Store latest frame based on camera position
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameBufferLock.lock()
            if connection.inputPorts.first?.sourceDevicePosition == .front {
                latestFrontFrame = imageBuffer
            } else {
                latestBackFrame = imageBuffer
            }
            frameBufferLock.unlock()
        }
        
        // Only process capture request if we're explicitly capturing
        guard isCapturing, 
              let captureCompletion = self.captureCompletion,
              let capturingCamera = self.capturingCamera,
              connection.inputPorts.first?.sourceDevicePosition == capturingCamera else { return }
        
        print("Converting frame to JPEG for camera: \(connection.inputPorts.first?.sourceDevicePosition == .front ? "front" : "back")")
        
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let jpegData = convertFrameToJPEG(imageBuffer)
            if let data = jpegData {
                captureCompletion(.success(data))
            } else {
                captureCompletion(.failure(.captureFailed))
            }
        } else {
            captureCompletion(.failure(.captureFailed))
        }
    }
    
    // Helper function to convert CVPixelBuffer to JPEG
    private func convertFrameToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        // Create UIImage and rotate if needed
        let uiImage = UIImage(cgImage: cgImage)
        let rotatedImage: UIImage
        
        // Check if we need to rotate (device is in portrait)
        if UIDevice.current.orientation == .portrait {
            // Rotate 90 degrees clockwise
            rotatedImage = UIImage(cgImage: cgImage, scale: uiImage.scale, orientation: .right)
        } else {
            rotatedImage = uiImage
        }
        
        return rotatedImage.jpegData(compressionQuality: 0.8)
    }
    
    // Modified capture function to use cached frame
    func captureImage(from camera: String) async throws -> Data {
        print("Attempting to capture image from \(camera) camera")
        return try await withCheckedThrowingContinuation { continuation in
            frameBufferLock.lock()
            defer { frameBufferLock.unlock() }
            
            let frame: CVPixelBuffer?
            if camera == "front" {
                frame = latestFrontFrame
            } else if camera == "back" {
                frame = latestBackFrame
            } else {
                continuation.resume(throwing: CameraSessionError.invalidCamera)
                return
            }
            
            guard let pixelBuffer = frame else {
                continuation.resume(throwing: CameraSessionError.outputUnavailable)
                return
            }
            
            if let jpegData = convertFrameToJPEG(pixelBuffer) {
                continuation.resume(returning: jpegData)
            } else {
                continuation.resume(throwing: CameraSessionError.captureFailed)
            }
        }
    }
    
    // Add function to access latest frames for ML processing
    func getLatestFrame(camera: AVCaptureDevice.Position) -> CVPixelBuffer? {
        frameBufferLock.lock()
        defer { frameBufferLock.unlock() }
        return camera == .front ? latestFrontFrame : latestBackFrame
    }

}

enum CameraSessionError: Error {
    case invalidCamera
    case outputUnavailable
    case captureFailed
    case captureTimeout
}
