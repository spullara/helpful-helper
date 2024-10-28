//
//  AudioRecordingViewModel.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/28/24.
//


import SwiftUI
import AVFoundation

// MARK: - Audio Recording View Model
class AudioRecordingViewModel: ObservableObject {
    private let audioService: AudioServiceProtocol
    
    @Published var isRecording = false
    @Published var recordedAudios: [String] = []
    @Published var currentlyPlaying: Int?
    @Published var errorMessage: String?
    @Published var showError = false
    
    init(audioService: AudioServiceProtocol = AudioService()) {
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
        if let audioError = error as? AudioProcessingError {
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

// MARK: - Custom UI Components
struct RecordButton: View {
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

struct AudioListItem: View {
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
struct AudioServiceContentView: View {
    @StateObject private var viewModel = AudioRecordingViewModel()
    
    var body: some View {
        NavigationView {
            VStack {
                Spacer()
                
                // Recording button
                RecordButton(
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
                                AudioListItem(
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
struct AudioServiceApp: App {
    var body: some Scene {
        WindowGroup {
            AudioServiceContentView()
        }
    }
}
