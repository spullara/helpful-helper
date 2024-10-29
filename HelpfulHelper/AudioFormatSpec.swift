//
//  AudioFormatSpec.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/28/24.
//


import AVFoundation
import Foundation

// MARK: - Audio Format Specification
struct AudioFormatSpec {
    static let target = AudioFormatSpec(
        sampleRate: 24000,
        channelCount: 1,
        format: .pcmFormatInt16
    )
    
    let sampleRate: Double
    let channelCount: UInt32
    let format: AVAudioCommonFormat
    
    var asAudioFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: format,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        )
    }
}

// MARK: - Audio Engine Manager
class AudioEngineManager {
    let engine = AVAudioEngine()
    private var hardwareFormat: AVAudioFormat?
    private let audioSession = AVAudioSession.sharedInstance()
        
    var isRunning: Bool {
        engine.isRunning
    }
    
    func setup() async throws {
        try await configureAudioSession()
        // Wait for hardware to be ready
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        let inputNode = engine.inputNode
        
        hardwareFormat = inputNode.inputFormat(forBus: 0)
        try engine.start()
    }
    
    private func configureAudioSession() async throws {
            do {
                try await audioSession.setCategory(.playAndRecord,
                                                mode: .default,
                                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
                try await audioSession.setActive(true)
            } catch {
                throw AudioError.audioSessionConfigurationFailed(error)
            }
        }
    
    func getHardwareFormat() throws -> AVAudioFormat {
        guard let format = hardwareFormat else {
            throw AudioError.formatNotAvailable
        }
        return format
    }
    
    var inputNode: AVAudioInputNode? {
        engine.inputNode
    }
    
    var mainMixerNode: AVAudioMixerNode {
        engine.mainMixerNode
    }
}

// MARK: - Format Converter
class AudioFormatConverter {
    private var converter: AVAudioConverter?
    
    func prepare(from: AVAudioFormat, to: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: from, to: to) else {
            throw AudioError.converterCreationFailed
        }
        self.converter = converter
    }
    
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter = converter else {
            throw AudioError.converterNotPrepared
        }
        
        let targetFormat = converter.outputFormat
              
        guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
                )
              ) else {
            throw AudioError.bufferCreationFailed
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if let error = error {
            throw AudioError.conversionFailed(error)
        }
        
        return outputBuffer
    }
}

// MARK: - Audio Recorder
class AudioRecorder {
    private let engineManager: AudioEngineManager
    private let converter: AudioFormatConverter
    private var recordingBuffers: [AVAudioPCMBuffer] = []
    private var targetFormat: AVAudioFormat?
    
    init(engineManager: AudioEngineManager = AudioEngineManager(),
         converter: AudioFormatConverter = AudioFormatConverter()) {
        self.engineManager = engineManager
        self.converter = converter
    }
    
    func startRecording() async throws {
        try await engineManager.setup()
        
        guard let hardwareFormat = try? engineManager.getHardwareFormat(),
              let targetFormat = AudioFormatSpec.target.asAudioFormat else {
            throw AudioError.formatNotAvailable
        }
        
        self.targetFormat = targetFormat
        try converter.prepare(from: hardwareFormat, to: targetFormat)
        
        let inputNode = engineManager.inputNode!
        let bufferSize = AVAudioFrameCount(targetFormat.sampleRate * 0.5) // 500ms buffer
        
        recordingBuffers.removeAll()
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            do {
                let convertedBuffer = try self.converter.convert(buffer)
                self.recordingBuffers.append(convertedBuffer)
            } catch {
                print("Recording error: \(error)")
            }
        }
    }
    
    func stopRecording() throws -> String {
        defer {
            engineManager.inputNode?.removeTap(onBus: 0)
            recordingBuffers.removeAll()
        }
        
        guard !recordingBuffers.isEmpty,
              let targetFormat = self.targetFormat else {
            throw AudioError.noRecordingData
        }
        
        // Calculate total frame count
        let totalFrames = recordingBuffers.reduce(0) { $0 + $1.frameLength }
        
        // Create a single buffer to hold all the data
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: totalFrames) else {
            throw AudioError.bufferCreationFailed
        }
        
        // Copy data from all buffers
        var offset: AVAudioFrameCount = 0
        for buffer in recordingBuffers {
            guard let channelData = finalBuffer.int16ChannelData,
                  let sourceData = buffer.int16ChannelData else {
                throw AudioError.invalidBufferData
            }
            
            // Copy frame by frame
            for channel in 0..<Int(targetFormat.channelCount) {
                for frame in 0..<buffer.frameLength {
                    channelData[channel][Int(offset + frame)] = sourceData[channel][Int(frame)]
                }
            }
            offset += buffer.frameLength
        }
        finalBuffer.frameLength = totalFrames
        
        return try Base64AudioConverter.toBase64(finalBuffer)
    }
}

// MARK: - Base64 Audio Converter
class Base64AudioConverter {
    static func toBase64(_ buffer: AVAudioPCMBuffer) throws -> String {
        guard let channelData = buffer.int16ChannelData else {
            throw AudioError.invalidBufferData
        }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let totalBytes = frameLength * channelCount * 2 // 2 bytes per Int16 sample
        
        var data = Data(capacity: totalBytes)
        
        // Interleave channels if needed
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = channelData[channel][frame]
                withUnsafeBytes(of: sample) { sampleBytes in
                    data.append(contentsOf: sampleBytes)
                }
            }
        }
        
        return data.base64EncodedString()
    }
    
    static func fromBase64(_ base64String: String, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let data = Data(base64Encoded: base64String) else {
            throw AudioError.invalidBase64String
        }
        
        let bytesPerFrame = 2 * format.channelCount // 2 bytes per Int16 sample * number of channels
        let frameLength = AVAudioFrameCount(data.count / Int(bytesPerFrame))
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw AudioError.bufferCreationFailed
        }
        
        buffer.frameLength = frameLength
        
        guard let channelData = buffer.int16ChannelData else {
            throw AudioError.invalidBufferData
        }
        
        // De-interleave the data into the buffer
        let channelCount = Int(format.channelCount)
        data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> Void in
            let int16Buffer = rawBufferPointer.bindMemory(to: Int16.self)
            for frame in 0..<Int(frameLength) {
                for channel in 0..<channelCount {
                    let index = frame * channelCount + channel
                    channelData[channel][frame] = int16Buffer[index]
                }
            }
        }
        
        return buffer
    }
}

// MARK: - Audio Player
class AudioPlayer {
    private let engineManager: AudioEngineManager
    private let converter: AudioFormatConverter
    
    init(engineManager: AudioEngineManager = AudioEngineManager(),
         converter: AudioFormatConverter = AudioFormatConverter()) {
        self.engineManager = engineManager
        self.converter = converter
    }
    
    func playAudio(_ base64String: String) async throws {
        try await engineManager.setup()
        
        guard let targetFormat = AudioFormatSpec.target.asAudioFormat else {
            throw AudioError.formatNotAvailable
        }
        
        let buffer = try Base64AudioConverter.fromBase64(base64String, format: targetFormat)
        
        let playerNode = AVAudioPlayerNode()
        engineManager.engine.attach(playerNode)
        engineManager.engine.connect(playerNode, to: engineManager.mainMixerNode, format: targetFormat)
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            DispatchQueue.main.async {
                playerNode.stop()
                self.engineManager.engine.detach(playerNode)
            }
        }
        
        playerNode.play()
    }
}

// MARK: - Errors
enum AudioError: Error {
    case noInputAvailable
    case formatNotAvailable
    case converterCreationFailed
    case converterNotPrepared
    case bufferCreationFailed
    case conversionFailed(Error)
    case invalidBufferData
    case invalidBase64String
    case noRecordingData
    case audioSessionConfigurationFailed(Error)
}

