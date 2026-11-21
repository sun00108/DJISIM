#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class CallAudioEngine {
    static let shared = CallAudioEngine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var outboundFrames: [Data] = []
    private var pendingMicrophonePCM = Data()
    private var microphoneConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var playbackFormat: AVAudioFormat?
    private var inputTapInstalled = false
    private var stopping = false
    private var changingAudioGraph = false
    private var audioGraphRestartTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var onUnexpectedDisconnect: (@MainActor () -> Void)?
    private var microphoneMuted = false
    private var recording: CallRecordingCapture?
    private var loggedFirstUpstreamFrame = false
    private var loggedFirstDownstreamFrame = false
    private var upstreamLevels = PCMLevelWindow()
    private var downstreamLevels = PCMLevelWindow()
    private var diagnosticTask: Task<Void, Never>?

    private let wireFrameByteCount = 320

    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 8_000,
        channels: 1,
        interleaved: true
    )!

    private init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioEngineConfigurationDidChange()
            }
        }
    }

    var isConnected: Bool { socket != nil }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
    }

    func startRecording(callID: String, phoneNumber: String?) throws {
        guard recording == nil else { return }
        recording = CallRecordingCapture(callID: callID, phoneNumber: phoneNumber)
        AppLog.shared.append("⏺️ 开始通话录音，call_id=\(callID)")
    }

    func takeRecording() -> CallRecordingCapture? {
        defer { recording = nil }
        return recording
    }

    func prepareAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        try audio.setPreferredIOBufferDuration(0.02)
    }

    func connect(
        client: GatewayCallClient,
        callID: String,
        installationID: UUID,
        onUnexpectedDisconnect: @escaping @MainActor () -> Void
    ) async throws {
        stop(notify: false)
        try Task.checkCancellation()
        stopping = false
        self.onUnexpectedDisconnect = onUnexpectedDisconnect
        loggedFirstUpstreamFrame = false
        loggedFirstDownstreamFrame = false
        upstreamLevels.reset()
        downstreamLevels.reset()
        AppLog.shared.append("🎧 请求音频 ticket，call_id=\(callID)")

        let ticket = try await client.audioTicket(callID: callID, installationID: installationID)
        try Task.checkCancellation()
        guard ticket.subprotocolName == "qdc507.audio.v1" else {
            throw GatewayCallClientError.protocolError("未知音频子协议 \(ticket.subprotocolName)")
        }
        AppLog.shared.append("🎫 音频 ticket 已获取，call_id=\(callID)")
        let webSocket = client.session.webSocketTask(
            with: try client.webSocketURL(callID: callID),
            protocols: [ticket.subprotocolName, "ticket.\(ticket.ticket)"]
        )
        socket = webSocket
        webSocket.resume()

        let firstMessage = try await webSocket.receive()
        try Task.checkCancellation()
        guard case let .string(text) = firstMessage,
              let data = text.data(using: .utf8),
              let ready = try? JSONDecoder().decode(AudioReadyMessage.self, from: data),
              ready.type == "ready",
              ready.format.encoding == "pcm_s16le",
              ready.format.sampleRate == 8_000,
              ready.format.channels == 1,
              ready.format.frameBytes == 320 else {
            stop(notify: false)
            throw GatewayCallClientError.protocolError("WebSocket 未返回有效的 ready 消息")
        }

        AppLog.shared.append("🔌 音频 WebSocket ready，call_id=\(callID)")
        try Task.checkCancellation()
        try startAudioGraph()
        try Task.checkCancellation()
        startDiagnosticLogging(callID: callID)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await webSocket.receive()
                    switch message {
                    case let .data(data):
                        try self.playWireAudio(data)
                    case let .string(text):
                        if let data = text.data(using: .utf8),
                           let message = try? JSONDecoder().decode(AudioControlMessage.self, from: data),
                           message.type == "error" {
                            throw GatewayCallClientError.protocolError(message.detail ?? "音频服务错误")
                        }
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                AppLog.shared.append("❌ 通话音频连接中断：\(error.localizedDescription)")
                self.stop(notify: true)
            }
        }
    }

    func stop(notify: Bool = false) {
        guard !stopping else { return }
        stopping = true
        let callback = notify ? onUnexpectedDisconnect : nil
        onUnexpectedDisconnect = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTask?.cancel()
        sendTask = nil
        audioGraphRestartTask?.cancel()
        audioGraphRestartTask = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        outboundFrames.removeAll(keepingCapacity: true)
        pendingMicrophonePCM.removeAll(keepingCapacity: true)
        microphoneMuted = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        player.stop()
        engine.stop()
        engine.reset()
        microphoneConverter = nil
        playbackConverter = nil
        playbackFormat = nil
        stopping = false
        callback?()
    }

    private func startAudioGraph() throws {
        changingAudioGraph = true
        defer { changingAudioGraph = false }
        try configureAndStartAudioGraph()
    }

    private func configureAndStartAudioGraph() throws {
        pendingMicrophonePCM.removeAll(keepingCapacity: true)
        pendingMicrophonePCM.reserveCapacity(wireFrameByteCount * 2)

        let input = engine.inputNode

        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                AppLog.shared.append("⚠️ 系统语音处理不可用：\(error.localizedDescription)")
            }
        }

        // Voice Processing may reconfigure the I/O graph, so read the tap's
        // output format only after enabling it.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw GatewayCallClientError.protocolError("麦克风音频格式不可用")
        }

        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        microphoneConverter = AVAudioConverter(from: inputFormat, to: wireFormat)
        playbackConverter = AVAudioConverter(from: wireFormat, to: outputFormat)
        playbackFormat = outputFormat
        guard microphoneConverter != nil, playbackConverter != nil else {
            throw GatewayCallClientError.protocolError("无法创建音频重采样器")
        }

        input.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
            guard let self, let copy = Self.copyBuffer(buffer) else { return }
            Task { @MainActor [weak self] in
                self?.sendMicrophoneBuffer(copy)
            }
        }
        inputTapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        AppLog.shared.append("✅ 通话音频已启动，线路格式=PCM16/8kHz/mono")
    }

    private func audioEngineConfigurationDidChange() {
        let connected = socket != nil && onUnexpectedDisconnect != nil
        AppLog.shared.append(
            "🔄 AudioEngine 配置变化，engine=\(engine.isRunning)，connected=\(connected)，changing=\(changingAudioGraph)"
        )
        scheduleAudioGraphRestartIfNeeded()
    }

    private func scheduleAudioGraphRestartIfNeeded() {
        let connected = socket != nil && onUnexpectedDisconnect != nil
        guard connected,
              !stopping,
              !changingAudioGraph,
              !engine.isRunning else { return }

        guard audioGraphRestartTask == nil else { return }
        audioGraphRestartTask = Task { [weak self] in
            do {
                // Give AVAudioSession/CallKit a brief moment to finish changing
                // the hardware route before querying the new graph formats.
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            defer { self.audioGraphRestartTask = nil }
            guard !self.stopping,
                  self.socket != nil,
                  self.onUnexpectedDisconnect != nil,
                  !self.engine.isRunning else { return }

            self.changingAudioGraph = true
            defer { self.changingAudioGraph = false }

            do {
                self.resetAudioGraphForRestart()
                try self.configureAndStartAudioGraph()
                AppLog.shared.append("♻️ 通话音频图已恢复")
            } catch {
                AppLog.shared.append("❌ 通话音频图恢复失败：\(error.localizedDescription)")
                self.stop(notify: true)
            }
        }
    }

    private func resetAudioGraphForRestart() {
        sendTask?.cancel()
        sendTask = nil
        outboundFrames.removeAll(keepingCapacity: true)
        pendingMicrophonePCM.removeAll(keepingCapacity: true)
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.reset()
        microphoneConverter = nil
        playbackConverter = nil
        playbackFormat = nil
    }

    private func sendMicrophoneBuffer(_ input: AVAudioPCMBuffer) {
        guard let converter = microphoneConverter, socket != nil else { return }
        let ratio = wireFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, result in
            guard !supplied else {
                result.pointee = .noDataNow
                return nil
            }
            supplied = true
            result.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              let samples = output.int16ChannelData?[0] else { return }
        var bytes = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        guard !bytes.isEmpty else { return }
        if microphoneMuted {
            bytes = Data(repeating: 0, count: bytes.count)
        }
        upstreamLevels.consume(bytes)
        // 录下实际送往 WSS 的上行音频；静音期间因此保持静音。
        recording?.appendMicrophoneAudio(bytes)

        pendingMicrophonePCM.append(bytes)
        while pendingMicrophonePCM.count >= wireFrameByteCount {
            let frame = Data(pendingMicrophonePCM.prefix(wireFrameByteCount))
            pendingMicrophonePCM.removeFirst(wireFrameByteCount)
            enqueueMicrophoneFrame(frame)
        }
    }

    private func enqueueMicrophoneFrame(_ frame: Data) {
        // 控制积压，宁可丢弃最旧的约 20 ms 帧，也不要让通话延迟无限增长。
        if outboundFrames.count >= 50 {
            outboundFrames.removeFirst()
        }
        outboundFrames.append(frame)
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let socket = self.socket, !self.outboundFrames.isEmpty {
                let next = self.outboundFrames.removeFirst()
                do {
                    try await socket.send(.data(next))
                    if !self.loggedFirstUpstreamFrame {
                        self.loggedFirstUpstreamFrame = true
                        AppLog.shared.append("🎙️ 已发送首个上行 PCM 帧，bytes=\(next.count)")
                    }
                } catch is CancellationError {
                    break
                } catch {
                    AppLog.shared.append("❌ 麦克风音频发送失败：\(error.localizedDescription)")
                    self.stop(notify: true)
                    return
                }
            }
            self.sendTask = nil
        }
    }

    private func playWireAudio(_ data: Data) throws {
        guard !data.isEmpty,
              data.count <= wireFrameByteCount * 10,
              data.count.isMultiple(of: wireFrameByteCount) else {
            throw GatewayCallClientError.protocolError("收到无效 PCM 帧，bytes=\(data.count)")
        }
        if !loggedFirstDownstreamFrame {
            loggedFirstDownstreamFrame = true
            AppLog.shared.append("🔈 已收到首个下行 PCM 帧，bytes=\(data.count)")
        }
        downstreamLevels.consume(data)
        // 诊断版本只录制 WSS 收到的对端下行，不包含麦克风，也不做双向混音。
        recording?.appendRemoteAudio(data)
        guard let converter = playbackConverter, let playbackFormat else { return }
        let inputFrames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let input = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: inputFrames),
              let samples = input.int16ChannelData?[0] else { return }
        input.frameLength = inputFrames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: samples,
            count: data.count
        ))

        let ratio = playbackFormat.sampleRate / wireFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrames) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: outputCapacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, result in
            guard !supplied else {
                result.pointee = .noDataNow
                return nil
            }
            supplied = true
            result.pointee = .haveData
            return input
        }
        if status == .error || conversionError != nil {
            throw conversionError ?? GatewayCallClientError.protocolError("下行音频转换失败")
        }
        if output.frameLength > 0 { player.scheduleBuffer(output) }
    }

    private func startDiagnosticLogging(callID: String) {
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak self] in
            guard let self else { return }
            for second in 1...10 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard self.socket != nil else { return }
                let upstream = self.upstreamLevels.takeSnapshot()
                let downstream = self.downstreamLevels.takeSnapshot()
                let route = AVAudioSession.sharedInstance().currentRoute.outputs
                    .map { "\($0.portType.rawValue):\($0.portName)" }
                    .joined(separator: ",")
                AppLog.shared.append(
                    "🩺 音频诊断 \(second)s，call_id=\(callID)，up=\(upstream.description)，down=\(downstream.description)，engine=\(self.engine.isRunning)，player=\(self.player.isPlaying)，routeOut=[\(route)]"
                )
                if !self.engine.isRunning {
                    AppLog.shared.append("⚠️ 音频诊断发现引擎已停止，准备恢复")
                    self.scheduleAudioGraphRestartIfNeeded()
                }
            }
        }
    }

    private nonisolated static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { continue }
            let count = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, count)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }
}

private struct PCMLevelWindow {
    private var sampleCount = 0
    private var peak: Int32 = 0
    private var sumSquares: Double = 0

    mutating func consume(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            for sample in rawBuffer.bindMemory(to: Int16.self) {
                let value = Int32(sample)
                peak = max(peak, abs(value))
                let normalized = Double(value) / Double(Int16.max)
                sumSquares += normalized * normalized
                sampleCount += 1
            }
        }
    }

    mutating func takeSnapshot() -> PCMLevelSnapshot {
        defer { reset() }
        guard sampleCount > 0 else {
            return PCMLevelSnapshot(sampleCount: 0, peakDBFS: nil, rmsDBFS: nil)
        }
        let peakValue = Double(peak) / Double(Int16.max)
        let rmsValue = sqrt(sumSquares / Double(sampleCount))
        return PCMLevelSnapshot(
            sampleCount: sampleCount,
            peakDBFS: peakValue > 0 ? 20 * log10(peakValue) : -.infinity,
            rmsDBFS: rmsValue > 0 ? 20 * log10(rmsValue) : -.infinity
        )
    }

    mutating func reset() {
        sampleCount = 0
        peak = 0
        sumSquares = 0
    }
}

private struct PCMLevelSnapshot {
    let sampleCount: Int
    let peakDBFS: Double?
    let rmsDBFS: Double?

    var description: String {
        guard let peakDBFS, let rmsDBFS else { return "none" }
        return "samples=\(sampleCount),peak=\(format(peakDBFS))dBFS,rms=\(format(rmsDBFS))dBFS"
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "-inf"
    }
}

struct CallRecordingCapture: Sendable {
    let callID: String
    let phoneNumber: String?
    let startedAt: Date
    private let startedUptime: TimeInterval
    private var microphoneSamples: [Int16] = []
    private var remoteSamples: [Int16] = []
    private var microphoneStarted = false
    private var remoteStarted = false

    init(callID: String, phoneNumber: String?) {
        self.callID = callID
        self.phoneNumber = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        startedAt = Date()
        startedUptime = ProcessInfo.processInfo.systemUptime
    }

    mutating func appendMicrophoneAudio(_ data: Data) {
        guard let incoming = Self.decodePCM16(data) else { return }
        if !microphoneStarted {
            microphoneStarted = true
            microphoneSamples.append(contentsOf: repeatElement(0, count: initialOffset))
        }
        microphoneSamples.append(contentsOf: incoming)
    }

    mutating func appendRemoteAudio(_ data: Data) {
        guard let incoming = Self.decodePCM16(data) else { return }
        if !remoteStarted {
            remoteStarted = true
            remoteSamples.append(contentsOf: repeatElement(0, count: initialOffset))
        }
        // WebSocket frames may arrive in bursts. Preserve their stream order
        // instead of positioning them by wall-clock arrival time, which would
        // otherwise overlap burst frames and insert silence between batches.
        remoteSamples.append(contentsOf: incoming)
    }

    nonisolated func writeToDocuments() throws -> URL {
        let fileManager = FileManager.default
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("Call Recordings", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: startedAt)
        let safeNumber = phoneNumber?
            .filter { $0.isNumber || $0 == "+" }
        let filename = if let safeNumber, !safeNumber.isEmpty {
            "call-\(timestamp)--\(safeNumber).m4a"
        } else {
            "call-\(timestamp).m4a"
        }
        let url = directory.appendingPathComponent(filename)

        let count = max(microphoneSamples.count, remoteSamples.count)
        guard count > 0 else {
            throw GatewayCallClientError.protocolError("录音中没有音频数据")
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 8_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // AVAudioFile.write requires the buffer format to exactly match the
        // file's processingFormat. AAC files normally use non-interleaved
        // Float32 here, even though the captured wire audio is PCM16.
        let processingFormat = file.processingFormat
        guard let output = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(count)
        ), let destination = output.floatChannelData?[0] else {
            try? fileManager.removeItem(at: url)
            throw GatewayCallClientError.protocolError("无法创建录音缓冲区")
        }
        output.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let microphone = index < microphoneSamples.count ? Float(microphoneSamples[index]) / 32_768 : 0
            let remote = index < remoteSamples.count ? Float(remoteSamples[index]) / 32_768 : 0
            // Keep the remote side prominent while adding the local microphone.
            // Hard limiting protects the AAC encoder from summed peaks.
            destination[index] = min(max(remote * 0.9 + microphone * 0.5, -1), 1)
        }

        do {
            try file.write(from: output)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return url
    }

    private var initialOffset: Int {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedUptime)
        return Int((elapsed * 8_000).rounded())
    }

    private static func decodePCM16(_ data: Data) -> [Int16]? {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }
    }

}

private struct AudioReadyMessage: Decodable {
    struct Format: Decodable {
        let encoding: String
        let sampleRate: Int
        let channels: Int
        let frameBytes: Int

        enum CodingKeys: String, CodingKey {
            case encoding, channels
            case sampleRate = "sample_rate"
            case frameBytes = "frame_bytes"
        }
    }

    let type: String
    let format: Format
}

private struct AudioControlMessage: Decodable {
    let type: String
    let detail: String?
}
#endif
