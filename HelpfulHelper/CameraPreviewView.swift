//
//  CameraPreviewView.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/24/24.
//

import SwiftUI
import AVFoundation

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
