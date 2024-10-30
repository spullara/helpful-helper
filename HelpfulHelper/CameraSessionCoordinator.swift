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
        } else {
            self.backPreviewLayer = layer
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
    
}
