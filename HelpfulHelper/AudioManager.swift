//
//  AudioManager.swift
//  audioexperiments
//
//  Created by Sam Pullara on 10/29/24.
//

import AVFAudio

class AudioManager {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let mixerNode: AVAudioMixerNode
    private let converterNode: AVAudioMixerNode
    private let inputNode: AVAudioInputNode
    
    // Processing format: 24kHz, mono, Int16
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true)!
    
    private var isRecording = false
    private var isPlaying = false
    
    // Activity logging
    @Published var activityLog: [(timestamp: Date, message: String)] = []
    
    // Callback for processing recorded audio
    typealias AudioProcessingCallback = ([Int16]) -> Void
    private let processingCallback: AudioProcessingCallback
    
    init(processingCallback: @escaping AudioProcessingCallback) {
        self.processingCallback = processingCallback
        
        // Initialize audio engine and nodes
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        mixerNode = AVAudioMixerNode()
        converterNode = AVAudioMixerNode()
        inputNode = engine.inputNode
        
        // Add nodes to engine
        engine.attach(playerNode)
        engine.attach(mixerNode)
        engine.attach(converterNode)
        
        // Set volume for format conversion nodes
        mixerNode.volume = 1.0
        converterNode.volume = 1.0
        
        // Set up the audio session
        setupAudioSession()
        
        // Register for route change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        logActivity("Audio Manager initialized")
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                  mode: .default,
                                  options: [.allowBluetoothA2DP, .allowBluetooth, .allowAirPlay])
            try session.setPreferredSampleRate(24000)
            try session.setPreferredInputNumberOfChannels(1)
            try session.setActive(true)
            
            logActivity("Audio Session Configuration:")
            logActivity("Sample Rate: \(session.sampleRate)")
            logActivity("IO Buffer Duration: \(session.ioBufferDuration)")
            logActivity("Input Channels: \(session.inputNumberOfChannels)")
            logActivity("Output Channels: \(session.outputNumberOfChannels)")
            
            // Log current audio route
            let currentRoute = session.currentRoute
            var routeDescription = "Current audio route:"
            for port in currentRoute.inputs {
                routeDescription += "\nInput: \(port.portName)"
            }
            for port in currentRoute.outputs {
                routeDescription += "\nOutput: \(port.portName)"
            }
            logActivity(routeDescription)
            
        } catch {
            logActivity("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func connectNodes() throws {
        print("Connecting nodes...")
        // Disconnect any existing connections
        engine.disconnectNodeInput(mixerNode)
        engine.disconnectNodeInput(converterNode)
        engine.disconnectNodeInput(engine.mainMixerNode)
        
        // Get the hardware formats
        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        let hardwareOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        
        logActivity("Hardware Input Format: \(formatDescription(hardwareInputFormat))")
        logActivity("Hardware Output Format: \(formatDescription(hardwareOutputFormat))")
        logActivity("Processing Format: \(formatDescription(processingFormat))")
        
        // RECORDING PATH:
        engine.connect(inputNode, to: converterNode, format: hardwareInputFormat)

        // PLAYBACK PATH:
        engine.connect(playerNode, to: mixerNode, format: hardwareInputFormat)

        // FINAL OUTPUT:
        engine.connect(playerNode, to: engine.mainMixerNode, format: hardwareOutputFormat)
        
        logActivity("Audio nodes connected")
    }
    
    func startRecording() throws {
        guard !isRecording else { return }
        
        logActivity("Starting recording...")
        
        try connectNodes()

        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)

        converterNode.installTap(onBus: 0, bufferSize: 8192, format: hardwareInputFormat) { [weak self] buffer, time in
            let inputToProcessingConverter = AVAudioConverter(from: hardwareInputFormat, to: self!.processingFormat)!
            guard let self = self else { return }
            
            let frameCount = AVAudioFrameCount(buffer.frameLength)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.processingFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let status = inputToProcessingConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            if status == .error || error != nil {
                print("Conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            
            guard let int16ChannelData = convertedBuffer.int16ChannelData else { return }
            let numFrames = Int(convertedBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: int16ChannelData[0], count: numFrames))
            self.processingCallback(samples)
        }
        
        try engine.start()
        isRecording = true
        logActivity("Recording started")
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        logActivity("Stopping recording...")
        converterNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        logActivity("Recording stopped")
    }
    
    func play(buffers: [[Int16]]) throws {
        guard !isPlaying else { return }
        
        logActivity("Starting playback...")
        
        try connectNodes()

        let hardwareOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        let processingToOutputConverter = AVAudioConverter(from: processingFormat, to: hardwareOutputFormat)!
        
        for (index, samples) in buffers.enumerated() {
            guard let buffer = createBuffer(from: samples) else {
                logActivity("Failed to create buffer from samples")
                continue
            }
            
            let frameCount = AVAudioFrameCount(buffer.frameLength)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: hardwareOutputFormat, frameCapacity: frameCount) else { continue }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let status = processingToOutputConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            if status == .error || error != nil {
                logActivity("Conversion failed: \(error?.localizedDescription ?? "unknown error")")
                continue
            }
            
            if index == buffers.count - 1 {
                playerNode.scheduleBuffer(convertedBuffer) { [weak self] in
                    DispatchQueue.main.async {
                        self?.stopPlayback()
                        self?.logActivity("Playback completed")
                    }
                }
            } else {
                playerNode.scheduleBuffer(convertedBuffer)
            }
        }        
        try engine.start()
        playerNode.play()
        isPlaying = true
        
        logActivity("Playback started")
    }
    
    private func createBuffer(from samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        
        buffer.frameLength = buffer.frameCapacity
        
        let channelData = buffer.int16ChannelData!
        samples.withUnsafeBufferPointer { samplesPtr in
            channelData[0].initialize(from: samplesPtr.baseAddress!, count: samples.count)
        }
        
        return buffer
    }

    func stopPlayback() {
        guard isPlaying else { return }
        
        logActivity("Stopping playback...")
        playerNode.stop()
        engine.stop()
        isPlaying = false
        logActivity("Playback stopped")
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        logActivity("Audio route changed: \(routeChangeReason(reason))")
        
        // Log new route
        DispatchQueue.main.async { [weak self] in
            self?.updateRouteInfo()
        }
        
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override:
            if isRecording {
                restartRecordingWithNewRoute()
            }
            if isPlaying {
                restartPlaybackWithNewRoute()
            }
        default:
            break
        }
    }
    
    private func updateRouteInfo() {
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        var routeDescription = "Current audio route:"
        
        for port in currentRoute.inputs {
            routeDescription += "\nInput: \(port.portName) (Port Type: \(port.portType.rawValue))"
        }
        for port in currentRoute.outputs {
            routeDescription += "\nOutput: \(port.portName) (Port Type: \(port.portType.rawValue))"
        }
        
        logActivity(routeDescription)
        
    }
    
    private func restartRecordingWithNewRoute() {
        logActivity("Restarting recording due to route change")
        stopRecording()
        try? startRecording()
    }
    
    private func restartPlaybackWithNewRoute() {
        logActivity("Restarting playback due to route change")
        stopPlayback()
    }
    
    private func logActivity(_ message: String) {
        let logEntry = (timestamp: Date(), message: message)
        activityLog.insert(logEntry, at: 0)
    }
    
    private func formatDescription(_ format: AVAudioFormat) -> String {
        return "[\(format.sampleRate)Hz, \(format.channelCount)ch, \(format.commonFormat.description)]"
    }
    
    private func routeChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "Unknown"
        case .newDeviceAvailable: return "New Device Available"
        case .oldDeviceUnavailable: return "Old Device Unavailable"
        case .categoryChange: return "Category Change"
        case .override: return "Override"
        case .wakeFromSleep: return "Wake From Sleep"
        case .noSuitableRouteForCategory: return "No Suitable Route"
        case .routeConfigurationChange: return "Configuration Change"
        @unknown default: return "Unknown"
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        logActivity("Audio Manager deinitialized")
    }
}

// Extension to provide description for common formats
extension AVAudioCommonFormat {
    var description: String {
        switch self {
        case .pcmFormatFloat32: return "Float32"
        case .pcmFormatFloat64: return "Float64"
        case .pcmFormatInt16: return "Int16"
        case .pcmFormatInt32: return "Int32"
        case .otherFormat: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}