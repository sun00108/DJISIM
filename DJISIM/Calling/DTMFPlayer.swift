#if os(iOS)
import AVFoundation

@MainActor
final class DTMFPlayer {
    static let shared = DTMFPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 48_000.0
    private let toneDuration = 0.12
    private var automaticStopTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var pendingFrequencies: (low: Double, high: Double)?

    private static let frequencies: [Character: (low: Double, high: Double)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477),
    ]

    private init() {
        engine.attach(player)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func playDigit(_ digit: Character) {
        guard let frequencies = Self.frequencies[digit] else { return }
        automaticStopTask?.cancel()
        pendingFrequencies = frequencies

        if engine.isRunning {
            playPendingTone()
            return
        }
        guard activationTask == nil else { return }

        activationTask = Task { [weak self] in
            let activationError = await Task.detached(priority: .userInitiated) {
                do {
                    let session = AVAudioSession.sharedInstance()
                    // Keypad tones follow the silent switch and mix with other media.
                    try session.setCategory(
                        .ambient,
                        mode: .default,
                        options: [.mixWithOthers]
                    )
                    try session.setActive(true)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            self.activationTask = nil
            guard !Task.isCancelled else {
                await self.deactivateAudioSession()
                return
            }
            if let activationError {
                self.pendingFrequencies = nil
                AppLog.shared.append("❌ DTMF 音频会话激活失败：\(activationError)")
                return
            }
            do {
                try self.engine.start()
                self.playPendingTone()
            } catch {
                self.pendingFrequencies = nil
                await self.deactivateAudioSession()
                AppLog.shared.append("❌ DTMF 按键音播放失败：\(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        activationTask?.cancel()
        activationTask = nil
        automaticStopTask?.cancel()
        automaticStopTask = nil
        pendingFrequencies = nil
        player.stop()
        if engine.isRunning { engine.stop() }
        engine.reset()
        await deactivateAudioSession()
    }

    private func playPendingTone() {
        guard let frequencies = pendingFrequencies else { return }
        pendingFrequencies = nil
        player.stop()
        guard let buffer = makeToneBuffer(
            lowFrequency: frequencies.low,
            highFrequency: frequencies.high
        ) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        automaticStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.15))
            } catch {
                return
            }
            await self?.stop()
        }
    }

    private func deactivateAudioSession() async {
        let deactivationError = await Task.detached(priority: .utility) {
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }.value
        if let deactivationError {
            AppLog.shared.append("⚠️ DTMF 音频会话释放失败：\(deactivationError)")
        }
    }

    private func makeToneBuffer(
        lowFrequency: Double,
        highFrequency: Double
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { return nil }

        let frameCount = AVAudioFrameCount(sampleRate * toneDuration)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let fadeFrames = max(1, Int(sampleRate * 0.005))
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let fadeIn = min(1, Double(frame) / Double(fadeFrames))
            let remainingFrames = Int(frameCount) - frame - 1
            let fadeOut = min(1, Double(remainingFrames) / Double(fadeFrames))
            let envelope = min(fadeIn, fadeOut)
            let sample = 0.15 * envelope * (
                sin(2 * .pi * lowFrequency * time)
                    + sin(2 * .pi * highFrequency * time)
            )
            samples[frame] = Float(sample)
        }

        return buffer
    }
}
#endif
