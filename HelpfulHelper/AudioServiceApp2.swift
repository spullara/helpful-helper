//
//  AudioRecordingViewModel2.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/28/24.
//


import SwiftUI
import AVFoundation

// MARK: - Audio Recording View Model
class AudioRecordingViewModel2: ObservableObject {
    private let audioService: AudioServiceProtocol2
    
    @Published var isRecording = false
    @Published var recordedAudios: [String] = []
    @Published var currentlyPlaying: Int?
    @Published var errorMessage: String?
    @Published var showError = false
    
    init(audioService: AudioServiceProtocol2 = AudioService2()) {
        self.audioService = audioService
    }
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        do {
            try audioService.startRecording()
            isRecording = true
        } catch {
            handleError(error)
        }
    }
    
    private func stopRecording() {
        do {
            let audioData = try audioService.stopRecording()
            recordedAudios.append(audioData)
            isRecording = false
        } catch {
            handleError(error)
        }
    }
    
    func playAudio(at index: Int) {
        guard index < recordedAudios.count else { return }
        
        do {
            try audioService.playAudio(base64EncodedString: recordedAudios[index])
            currentlyPlaying = index
            
            // Reset currently playing after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.currentlyPlaying = nil
            }
        } catch {
            handleError(error)
        }
    }
    
    private func handleError(_ error: Error) {
        if let audioError = error as? AudioProcessingError2 {
            switch audioError {
            case .engineNotRunning:
                errorMessage = "Audio engine failed to start"
            case .formatConversionFailed:
                errorMessage = "Failed to convert audio format"
            case .invalidBase64String:
                errorMessage = "Invalid audio data"
            case .audioEngineSetupFailed:
                errorMessage = "Failed to setup audio engine"
            case .recordingInProgress:
                errorMessage = "Recording already in progress"
            case .noRecordingInProgress:
                errorMessage = "No recording in progress"
            }
        } else {
            errorMessage = error.localizedDescription
        }
        showError = true
    }
}

// MARK: - Audio Service Protocol
protocol AudioServiceProtocol2 {
    func startRecording() throws
    func stopRecording() throws -> String
    func playAudio(base64EncodedString: String) throws
}

// MARK: - Audio Processing Errors
enum AudioProcessingError2: Error {
    case engineNotRunning
    case formatConversionFailed
    case invalidBase64String
    case audioEngineSetupFailed
    case recordingInProgress
    case noRecordingInProgress
}

// MARK: - Audio Service Implementation
class AudioService2: AudioServiceProtocol2 {
    private let recorder: AudioRecorder
    private let player: AudioPlayer
    private var isRecording = false
    
    init() {
        self.recorder = AudioRecorder()
        self.player = AudioPlayer()
    }
    
    func startRecording() throws {
        guard !isRecording else {
            throw AudioProcessingError2.recordingInProgress
        }
        
        Task {
            do {
                try await recorder.startRecording()
                DispatchQueue.main.async {
                    self.isRecording = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRecording = false
                }
            }
        }
    }
    
    func stopRecording() throws -> String {
        guard isRecording else {
            throw AudioProcessingError2.noRecordingInProgress
        }
        
        isRecording = false
        return try recorder.stopRecording()
    }
    
    func playAudio(base64EncodedString: String) throws {
        Task {
            do {
                try await player.playAudio(base64EncodedString)
            } catch {
            }
        }
    }
    
    private func handleError(_ error: Error) throws {
        if let audioError = error as? AudioError {
            switch audioError {
            case .noInputAvailable, .formatNotAvailable:
                throw AudioProcessingError2.audioEngineSetupFailed
            case .converterCreationFailed, .converterNotPrepared, .bufferCreationFailed, .conversionFailed:
                throw AudioProcessingError2.formatConversionFailed
            case .invalidBase64String:
                throw AudioProcessingError2.invalidBase64String
            case .invalidBufferData, .noRecordingData:
                throw AudioProcessingError2.engineNotRunning
            case .audioSessionConfigurationFailed:
                throw AudioProcessingError2.audioEngineSetupFailed
            }
        }
        throw error
    }
}

// MARK: - Custom UI Components
struct RecordButton2: View {
    let isRecording: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isRecording ? Color.red : Color.blue)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 30))
                )
        }
    }
}

struct AudioListItem2: View {
    let index: Int
    let isPlaying: Bool
    let onPlay: () -> Void
    
    var body: some View {
        HStack {
            Text("Recording \(index + 1)")
                .font(.headline)
            Spacer()
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(isPlaying ? .red : .blue)
                    .font(.system(size: 20))
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Main View
struct AudioServiceContentView2: View {
    @StateObject private var viewModel = AudioRecordingViewModel2()
    
    var body: some View {
        NavigationView {
            VStack {
                Spacer()
                
                // Recording button
                RecordButton2(
                    isRecording: viewModel.isRecording,
                    action: viewModel.toggleRecording
                )
                .padding(.bottom, 40)
                
                // Recordings list
                if viewModel.recordedAudios.isEmpty {
                    Text("No recordings yet")
                        .foregroundColor(.gray)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.recordedAudios.indices, id: \.self) { index in
                                AudioListItem2(
                                    index: index,
                                    isPlaying: viewModel.currentlyPlaying == index,
                                    onPlay: { viewModel.playAudio(at: index) }
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                Spacer()
            }
            .navigationTitle("Audio Recorder")
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred")
            }
        }
    }
}

// MARK: - Preview Provider
@main
struct AudioServiceApp2: App {
    var body: some Scene {
        WindowGroup {
            AudioServiceContentView2()
        }
    }
}
