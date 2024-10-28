import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private var audioConverter: AVAudioConverter!
    private var isRecording = false
    private var recordedData = Data()

    init() throws {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000.0, channels: 1, interleaved: true)!
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if audioConverter == nil {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }
        isRecording = true

        audioEngine.prepare()
        try audioEngine.start()

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, _) in
            guard let self = self else { return }
            var error: NSError?
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self.audioConverter.outputFormat, frameCapacity: AVAudioFrameCount(buffer.frameLength))!

            self.audioConverter.convert(to: pcmBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error = error {
                print("Conversion error: \(error)")
                return
            }

            let channelData = pcmBuffer.int16ChannelData![0]
            let channelDataArray = Array(UnsafeBufferPointer(start: channelData, count: Int(pcmBuffer.frameLength)))
            self.recordedData.append(Data(buffer: UnsafeBufferPointer(start: channelData, count: channelDataArray.count)))
        }
    }

    func stopRecording() throws -> String? {
        guard isRecording else { return nil }
        isRecording = false
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let base64String = recordedData.base64EncodedString()
        recordedData = Data()
        return base64String
    }
}

class AudioPlayer {
    private var audioEngine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
    private var audioConverter: AVAudioConverter!

    init() throws {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)

        let outputFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000.0, channels: 1, interleaved: true)!
        audioConverter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        if audioConverter == nil {
            throw NSError(domain: "AudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)
    }

    func play(_ base64String: String) throws {
        guard let data = Data(base64Encoded: base64String) else {
            throw NSError(domain: "AudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 string"])
        }

        let frameLength = data.count / MemoryLayout<Int16>.size
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioConverter.inputFormat, frameCapacity: AVAudioFrameCount(frameLength))!

        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        let channelData = pcmBuffer.int16ChannelData![0]
        data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            let unsafePointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress!
            channelData.update(from: unsafePointer, count: frameLength)
        }

        audioEngine.prepare()
        try audioEngine.start()

        playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
        playerNode.play()
    }
}
