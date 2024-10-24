//
//  ContentView.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/24/24.
//

import SwiftUI
import SwiftData
import DockKit
import AVFoundation

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @State private var dockAccessoryManager = DockAccessoryManager.shared
    @State private var captureSession: AVCaptureSession?

    func test() {
        Task {
            do {
                // Set up and start AVCaptureSession
                let session = AVCaptureSession()
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                                     for: .video,
                                                                     position: .front) else {
                                print("Front camera not available")
                                return
                            }
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    if session.canAddInput(input) {
                        session.addInput(input)
                    }
                    
                    // Add video data output
                    let videoOutput = AVCaptureVideoDataOutput()
                    if session.canAddOutput(videoOutput) {
                        session.addOutput(videoOutput)
                    }
                    
                    // Add metadata output for face detection
                    let metadataOutput = AVCaptureMetadataOutput()
                    if session.canAddOutput(metadataOutput) {
                        session.addOutput(metadataOutput)
                        // Configure metadata output to detect faces
                        metadataOutput.metadataObjectTypes = [.face]
                    }
                    
                    // Store the session
                    self.captureSession = session
                    
                    // Get reference dimensions from the video connection
                    let videoConnection = videoOutput.connection(with: .video)
                    let referenceDimensions = CGSize(
                        width: videoConnection?.videoMaxScaleAndCropFactor ?? 1920,
                        height: videoConnection?.videoMaxScaleAndCropFactor ?? 1080
                    )
                    
                    // Start the session on a background queue
                    DispatchQueue.global(qos: .userInitiated).async {
                        session.startRunning()
                    }
                    
                    // Monitor for dock accessories
                    for await accessoryStateChange in try DockAccessoryManager.shared.accessoryStateChanges {
                        guard let accessory = accessoryStateChange.accessory,
                              accessoryStateChange.state == .docked else {
                            continue
                        }
                        
                        print("Dock accessory connected: \(accessory.identifier)")
                        
                        // Create camera information for tracking
                        let cameraInfo = DockAccessory.CameraInformation(
                            captureDevice: camera.deviceType,
                            cameraPosition: camera.position,
                            orientation: .portrait,  // Adjust based on actual orientation
                            cameraIntrinsics: nil,
                            referenceDimensions: referenceDimensions
                        )
                        
                        // System tracking will automatically start when a device is docked
                        // You can observe tracking states if needed:
                        for await state in try accessory.trackingStates {
                            print("Tracking state updated: \(state.description)")
                            print("Tracked subjects: \(state.trackedSubjects.count)")
                        }
                    }
                    
                } catch {
                    print("Error setting up capture session: \(error)")
                }
            }
        }
    }
        
    var body: some View {
        NavigationSplitView {
            List {
                if DockAccessoryManager.shared.isSystemTrackingEnabled {
                    Text("System Tracking Enabled")
                        .onAppear(perform: test)
                }
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
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
