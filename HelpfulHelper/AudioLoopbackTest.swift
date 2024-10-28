//
//  AudioLoopbackTest.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/26/24.
//


import Foundation
import AVFoundation

class AudioLoopbackTest {
    private var audioEngine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var playerNode: AVAudioPlayerNode
    private var isRunning = false
    
    init() {
        self.audioEngine = AVAudioEngine()
        self.inputNode = audioEngine.inputNode
        self.playerNode = AVAudioPlayerNode()
        
        setupAudioSession()
        setupAudioEngine()
        
        start()

    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("Audio session setup complete")
            print("Sample rate: \(session.sampleRate)")
            print("IO buffer duration: \(session.ioBufferDuration)")
            print("Input latency: \(session.inputLatency)")
            print("Output latency: \(session.outputLatency)")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        
        // Get the native input format
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("Input format: \(inputFormat)")
        
        // Connect playerNode to main mixer using the same format as input
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: inputFormat)
        
        // Install tap with native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            print("Playing")
            // Schedule the buffer directly without any conversion
            self?.playerNode.scheduleBuffer(buffer, at: nil, options: .interruptsAtLoop, completionHandler: nil)
            
            if !(self?.playerNode.isPlaying ?? false) {
                self?.playerNode.play()
            }
        }
        
        // Prepare and start engine
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            print("Audio engine started successfully")
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func start() {
        isRunning = true
        playerNode.play()
    }
    
    func stop() {
        isRunning = false
        playerNode.stop()
    }
}
