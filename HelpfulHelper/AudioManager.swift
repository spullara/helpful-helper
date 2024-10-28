//
//  AudioManager.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/28/24.
//


import SwiftUI
import AVFoundation

class AudioManager: ObservableObject {
    private var player: AudioPlayer?
    private var recorder: AudioRecorder?
    @Published var isRecording = false
    private var recordedAudio: String?
    
    init() {
        do {
            player = try AudioPlayer()
            recorder = try AudioRecorder()
        } catch {
            print("Failed to initialize recorder: \(error)")
        }
    }
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            guard allowed else {
                print("Microphone permission denied")
                return
            }
            
            DispatchQueue.main.async {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playAndRecord)
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self?.recorder?.startRecording()
                    self?.isRecording = true
                } catch {
                    print("Failed to start recording: \(error)")
                }
            }
        }
    }
    
    private func stopRecording() {
        do {
            guard let audioData = try recorder?.stopRecording() else {
                return
            }
            recordedAudio = audioData
            isRecording = false
            
            // Play back immediately
            try player!.play(audioData)
        } catch {
            print("Failed to stop recording: \(error)")
            isRecording = false
        }
    }
}

struct AudioManagerContentView: View {
    @StateObject private var audioManager = AudioManager()
    
    var body: some View {
        VStack {
            Button(action: {
                audioManager.toggleRecording()
            }) {
                Image(systemName: audioManager.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(audioManager.isRecording ? .red : .blue)
            }
            
            Text(audioManager.isRecording ? "Recording..." : "Tap to Record")
                .font(.headline)
                .padding()
        }
    }
}

//@main
struct AudioRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            AudioManagerContentView()
        }
    }
}
