//
//  AudioFormatConstants.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/28/24.
//


import AVFoundation

// MARK: - Audio Format Constants
enum AudioFormatConstants {
    static let targetSampleRate: Double = 24000.0
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitDepth: UInt32 = 16
}

// MARK: - Audio Processing Errors
enum AudioProcessingError: Error {
    case engineNotRunning
    case formatConversionFailed
    case invalidBase64String
    case audioEngineSetupFailed
    case recordingInProgress
    case noRecordingInProgress
}

// MARK: - Audio Buffer Protocol
protocol AudioBufferProvider {
    func appendBuffer(_ buffer: AVAudioPCMBuffer)
    func clearBuffer()
    func getAccumulatedData() -> Data?
}

// MARK: - Audio Buffer Implementation
class PCMBufferAccumulator: AudioBufferProvider {
    private var accumulatedData = Data()
    
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        let stride = buffer.stride
        let frameLength = Int(buffer.frameLength)
        let bufferData = Data(bytes: channelData[0], count: frameLength * stride)
        accumulatedData.append(bufferData)
    }
    
    func clearBuffer() {
        accumulatedData = Data()
    }
    
    func getAccumulatedData() -> Data? {
        return accumulatedData.isEmpty ? nil : accumulatedData
    }
}

// MARK: - Audio Service Protocol
protocol AudioServiceProtocol {
    func startRecording() throws
    func stopRecording() throws -> String
    func playAudio(base64EncodedString: String) throws
}

// MARK: - Main Audio Service Implementation
class AudioService: AudioServiceProtocol {
    private let engine = AVAudioEngine()
    private let bufferAccumulator: AudioBufferProvider
    private var audioConverter: AVAudioConverter?
    private var isRecording = false
    
    init(bufferAccumulator: AudioBufferProvider = PCMBufferAccumulator()) {
        self.bufferAccumulator = bufferAccumulator
    }
    
    // MARK: - Setup Methods
    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
    }
    
    private func setupAudioEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormatConstants.targetSampleRate,
            channels: AudioFormatConstants.targetChannels,
            interleaved: true
        )!
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioProcessingError.formatConversionFailed
        }
        
        audioConverter = converter
        
        let bufferSize = AVAudioFrameCount(AudioFormatConstants.targetSampleRate * 0.1) // 100ms buffer
        
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            
            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * (targetFormat.sampleRate / inputFormat.sampleRate)
                )
            )!
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            if error == nil {
                self.bufferAccumulator.appendBuffer(convertedBuffer)
            }
        }
    }
    
    // MARK: - Public Interface
    func startRecording() throws {
        guard !isRecording else {
            throw AudioProcessingError.recordingInProgress
        }
        
        try setupAudioSession()
        try setupAudioEngine()
        
        bufferAccumulator.clearBuffer()
        isRecording = true
        
        if !engine.isRunning {
            try engine.start()
        }
    }
    
    func stopRecording() throws -> String {
        guard isRecording else {
            throw AudioProcessingError.noRecordingInProgress
        }
        
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        
        guard let audioData = bufferAccumulator.getAccumulatedData() else {
            return ""
        }
        
        return audioData.base64EncodedString()
    }
    
    func playAudio(base64EncodedString: String) throws {
        guard let audioData = Data(base64Encoded: base64EncodedString) else {
            throw AudioProcessingError.invalidBase64String
        }
        
        // First create a buffer in our source format (24k PCM Int16)
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormatConstants.targetSampleRate,
            channels: AudioFormatConstants.targetChannels,
            interleaved: true
        )!
        
        // Get the hardware output format
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        
        // Create converter from our format to hardware format
        guard let converter = AVAudioConverter(from: sourceFormat, to: hardwareFormat) else {
            throw AudioProcessingError.formatConversionFailed
        }
        
        // Create source buffer
        let bytesPerFrame = 2 * AudioFormatConstants.targetChannels // 2 bytes per Int16 sample
        let frameCount = UInt32(audioData.count) / UInt32(bytesPerFrame)
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)!
        sourceBuffer.frameLength = frameCount
        
        // Fill source buffer
        audioData.withUnsafeBytes { rawBufferPointer in
            if let int16BufferPointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress {
                sourceBuffer.int16ChannelData?.pointee.update(from: int16BufferPointer, count: Int(frameCount))
            }
        }
        
        // Calculate the correct output frame capacity based on sample rate conversion
        let sampleRateRatio = hardwareFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * sampleRateRatio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: hardwareFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw AudioProcessingError.formatConversionFailed
        }
        
        // Convert the audio
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            throw AudioProcessingError.formatConversionFailed
        }
        
        // Play the converted audio
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: hardwareFormat)
        
        if !engine.isRunning {
            try engine.start()
        }
        
        player.scheduleBuffer(outputBuffer, at: nil, options: .interrupts) { [weak self] in
            DispatchQueue.main.async {
                self?.engine.detach(player)
            }
        }
        player.play()
    }
}

// MARK: - Testing Support Extensions
extension AudioService {
    func getAudioConverter() -> AVAudioConverter? {
        return audioConverter
    }
    
    var isEngineRunning: Bool {
        return engine.isRunning
    }
}
