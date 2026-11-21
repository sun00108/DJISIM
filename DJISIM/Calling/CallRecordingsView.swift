#if os(iOS)
import AVFoundation
import Combine
import SwiftUI

private struct CallRecordingItem: Identifiable, Hashable {
    let url: URL
    let recordedAt: Date
    let duration: TimeInterval
    let phoneNumber: String?

    var id: URL { url }

    var title: String {
        phoneNumber ?? "通话录音"
    }
}

@MainActor
private final class CallRecordingsLibrary: ObservableObject {
    @Published private(set) var recordings: [CallRecordingItem] = []
    @Published private(set) var errorMessage: String?

    func reload() async {
        do {
            let directory = try Self.recordingsDirectory(create: true)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            var loaded: [CallRecordingItem] = []
            for url in urls where url.pathExtension.lowercased() == "m4a" {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile != false else { continue }
                let asset = AVURLAsset(url: url)
                let time = try? await asset.load(.duration)
                let seconds = time.map(CMTimeGetSeconds) ?? 0
                loaded.append(CallRecordingItem(
                    url: url,
                    recordedAt: Self.dateFromFilename(url)
                        ?? values?.creationDate
                        ?? values?.contentModificationDate
                        ?? .distantPast,
                    duration: seconds.isFinite ? max(0, seconds) : 0,
                    phoneNumber: Self.phoneNumberFromFilename(url)
                ))
            }
            recordings = loaded.sorted { $0.recordedAt > $1.recordedAt }
            errorMessage = nil
        } catch {
            recordings = []
            errorMessage = "无法读取通话录音：\(error.localizedDescription)"
        }
    }

    func delete(_ recording: CallRecordingItem) throws {
        try FileManager.default.removeItem(at: recording.url)
        recordings.removeAll { $0.id == recording.id }
    }

    private static func recordingsDirectory(create: Bool) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let directory = documents.appendingPathComponent("Call Recordings", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func dateFromFilename(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("call-") else { return nil }
        let value = String(name.dropFirst("call-".count))
        let timestamp = String(value.prefix(17))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: timestamp)
    }

    private static func phoneNumberFromFilename(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let separator = name.range(of: "--", options: .backwards) else { return nil }
        let number = String(name[separator.upperBound...])
        return number.isEmpty ? nil : number
    }
}

@MainActor
private final class CallRecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var selectedURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func select(_ recording: CallRecordingItem) {
        guard selectedURL != recording.url else { return }
        stop(clearSelection: false)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            selectedURL = recording.url
            currentTime = 0
            duration = player.duration
            errorMessage = nil
        } catch {
            selectedURL = recording.url
            errorMessage = "无法播放录音：\(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            progressTask?.cancel()
            progressTask = nil
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else {
                errorMessage = "无法开始播放录音。"
                return
            }
            isPlaying = true
            startProgressUpdates()
        }
        currentTime = player.currentTime
    }

    func seek(by offset: TimeInterval) {
        seek(to: currentTime + offset)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stopIfPlaying(_ url: URL) {
        guard selectedURL == url else { return }
        stop(clearSelection: true)
    }

    func stop(clearSelection: Bool = true) {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if clearSelection { selectedURL = nil }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.currentTime = player.duration
            self?.progressTask?.cancel()
            self?.progressTask = nil
        }
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

struct CallRecordingsView: View {
    @StateObject private var library = CallRecordingsLibrary()
    @StateObject private var player = CallRecordingPlayer()

    var body: some View {
        Group {
            if library.recordings.isEmpty, library.errorMessage == nil {
                ContentUnavailableView(
                    "暂无通话录音",
                    systemImage: "waveform",
                    description: Text("通话中点击“录音”，保存后的文件会显示在这里。")
                )
            } else {
                List {
                    ForEach(library.recordings) { recording in
                        recordingSection(recording)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(recording)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("所有录音")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .task { await library.reload() }
        .onDisappear { player.stop() }
        .safeAreaInset(edge: .bottom) {
            if let message = library.errorMessage ?? player.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func recordingSection(_ recording: CallRecordingItem) -> some View {
        VStack(spacing: 0) {
            Button {
                player.select(recording)
            } label: {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(recording.recordedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatDuration(recording.duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if player.selectedURL == recording.url {
                expandedPlayer(recording)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: player.selectedURL)
    }

    private func expandedPlayer(_ recording: CallRecordingItem) -> some View {
        VStack(spacing: 14) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .tint(.secondary)

            HStack {
                Text(formatDuration(player.currentTime))
                Spacer()
                Text("−\(formatDuration(max(0, player.duration - player.currentTime)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                ShareLink(item: recording.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享录音")

                Spacer()
                Button { player.seek(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                }
                Spacer()
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .frame(width: 46, height: 46)
                }
                Spacer()
                Button { player.seek(by: 15) } label: {
                    Image(systemName: "goforward.15")
                }
                Spacer()
                Button(role: .destructive) {
                    delete(recording)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除录音")
            }
            .font(.title2)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.bottom, 8)
        }
    }

    private func delete(_ recording: CallRecordingItem) {
        player.stopIfPlaying(recording.url)
        do {
            try library.delete(recording)
        } catch {
            AppLog.shared.append("❌ 删除通话录音失败：\(error.localizedDescription)")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0 else { return "0:00" }
        let total = Int(duration.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
