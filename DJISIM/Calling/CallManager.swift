#if os(iOS)
import AVFoundation
import CallKit
import Combine
import Foundation
import PushKit

@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published private(set) var currentCall: GatewayCallRecord?
    @Published private(set) var statusText = "无通话"
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentCalls: [GatewayCallRecord] = []
    @Published private(set) var microphonePermission = AVAudioApplication.shared.recordPermission
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = false
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var isSendingDTMF = false

    private let provider: CXProvider
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?
    private var sessions: [UUID: LocalCallSession] = [:]
    private var eventTask: Task<Void, Never>?
    private var monitoredCallID: String?
    private var eventStreamConnected = false
    private var eventConnectionSignals: [AsyncStream<Void>.Continuation] = []
    private var dtmfTask: Task<Void, Never>?
    private var callKitAudioActive = false
    private var audioConnectionTask: Task<Void, Never>?
    private var audioConnectionAttemptID: UUID?
    private var configured = false

    override private init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func configure() {
        guard !configured else { return }
        configured = true
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
        AppLog.shared.append("PushKit 与 CallKit 已配置")
        Task {
            await reconcileCurrentCall()
            await refreshRecentCalls()
        }
    }

    func configurationDidChange() {
        stopEventMonitoring()
        Task {
            await reconcileCurrentCall()
            await refreshRecentCalls()
        }
    }

    func applicationBecameActive() {
        microphonePermission = AVAudioApplication.shared.recordPermission
        Task { await reconcileCurrentCall() }
    }

    func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { _ in
            Task { @MainActor in
                CallManager.shared.microphonePermission = AVAudioApplication.shared.recordPermission
            }
        }
    }

    func startOutgoing(number: String) async {
        let normalized = number
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalized.range(of: #"^\+?[0-9]{1,20}$"#, options: .regularExpression) != nil else {
            errorMessage = "电话号码格式无效。"
            return
        }
        guard sessions.isEmpty else {
            errorMessage = "当前已有一条通话。"
            return
        }
        let uuid = UUID()
        sessions[uuid] = LocalCallSession(
            callKitUUID: uuid,
            serverCallID: "",
            caller: normalized,
            direction: .outboundCellular,
            callKitReported: true
        )
        let handle = CXHandle(type: .phoneNumber, value: normalized)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        do {
            try await callController.request(CXTransaction(action: action))
            errorMessage = nil
        } catch {
            sessions.removeValue(forKey: uuid)
            errorMessage = "无法开始系统通话：\(error.localizedDescription)"
        }
    }

    func endCurrentCall() async {
        guard let uuid = sessions.keys.first else { return }
        do {
            try await callController.request(CXTransaction(action: CXEndCallAction(call: uuid)))
        } catch {
            errorMessage = "无法请求挂断：\(error.localizedDescription)"
        }
    }

    func toggleMute() {
        guard currentCall != nil else { return }
        isMuted.toggle()
        CallAudioEngine.shared.setMicrophoneMuted(isMuted)
    }

    func toggleSpeaker() {
        guard currentCall != nil else { return }
        let nextValue = !isSpeakerEnabled
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(
                nextValue ? .speaker : .none
            )
            isSpeakerEnabled = nextValue
        } catch {
            errorMessage = "无法切换音频输出：\(error.localizedDescription)"
        }
    }

    func sendDTMF(_ digit: Character) {
        let validDigits = "0123456789*#ABCD"
        guard validDigits.contains(digit),
              let call = currentCall,
              call.state == .active,
              !isSendingDTMF else { return }
        isSendingDTMF = true
        dtmfTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSendingDTMF = false
                self.dtmfTask = nil
            }
            do {
                _ = try await self.makeClient().sendDTMF(
                    callID: call.id,
                    digit: digit,
                    installationID: PushNotificationManager.shared.installationID
                )
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = "发送通话按键失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleRecording() {
        guard let call = currentCall,
              call.state == .active,
              CallAudioEngine.shared.isConnected else { return }
        if isRecording {
            finishRecording()
        } else {
            do {
                let phoneNumber = call.cellularNumber
                    ?? sessions.values.first(where: { $0.serverCallID == call.id })?.caller
                try CallAudioEngine.shared.startRecording(
                    callID: call.id,
                    phoneNumber: phoneNumber
                )
                isRecording = true
                lastRecordingURL = nil
            } catch {
                errorMessage = "无法开始通话录音：\(error.localizedDescription)"
            }
        }
    }

    func refreshRecentCalls() async {
        do { recentCalls = try await makeClient().calls() }
        catch { AppLog.shared.append("⚠️ 获取通话历史失败：\(error.localizedDescription)") }
    }

    private func makeClient() throws -> GatewayCallClient {
        try GatewayCallClient()
    }

    private func reportIncoming(_ invitation: IncomingCallPush, completion: @escaping () -> Void) {
        guard let uuid = UUID(uuidString: invitation.callID) else {
            completion()
            return
        }
        if sessions[uuid] != nil {
            completion()
            return
        }
        let isExpired = invitation.expiresAt.map { $0 <= Date() } ?? false

        sessions[uuid] = LocalCallSession(
            callKitUUID: uuid,
            serverCallID: invitation.callID,
            caller: invitation.caller,
            direction: .inboundCellular
        )
        let readiness = AsyncStream<Void>.makeStream()
        startEventMonitoring(
            callID: invitation.callID,
            connectionSignal: readiness.continuation
        )
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(
            type: .phoneNumber,
            value: invitation.caller ?? "未知号码"
        )
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else {
                    readiness.continuation.finish()
                    completion()
                    return
                }
                if let error {
                    self.sessions.removeValue(forKey: uuid)
                    if self.sessions.isEmpty {
                        self.stopEventMonitoring()
                    }
                    self.errorMessage = "CallKit 拒绝显示来电：\(error.localizedDescription)"
                    readiness.continuation.finish()
                    completion()
                    return
                }
                guard var local = self.sessions[uuid] else {
                    readiness.continuation.finish()
                    completion()
                    return
                }
                local.callKitReported = true
                self.sessions[uuid] = local
                if isExpired {
                    self.finish(uuid: uuid, reason: .unanswered)
                    readiness.continuation.finish()
                    completion()
                    return
                }
                if let pendingRecord = local.record {
                    self.apply(pendingRecord, to: uuid)
                    if self.sessions[uuid] == nil {
                        readiness.continuation.finish()
                        completion()
                        return
                    }
                }
                self.statusText = "来电：\(invitation.caller ?? "未知号码")"
                Task { await self.reconcile(callID: invitation.callID) }
                await self.waitForInitialSignaling(readiness.stream)
                readiness.continuation.finish()
                // 已完成 CallKit 上报，并已建立 SSE，或最多等待 1.5 秒。
                completion()
                await self.updateCallerName(for: uuid, number: invitation.caller)
            }
        }
    }

    private func reportMalformedIncomingPush(completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "无效来电")
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            completion()
            Task { @MainActor in
                CallManager.shared.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            }
        }
    }

    private func updateCallerName(for uuid: UUID, number: String?) async {
        guard let number, sessions[uuid] != nil else { return }
        let name = ContactsManager.shared.displayName(for: number)
        guard name != number else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = name
        update.hasVideo = false
        provider.reportCall(with: uuid, updated: update)
    }

    private func reconcileCurrentCall() async {
        do {
            guard let record = try await makeClient().currentCall(), record.frontend == "app" else {
                if let uuid = sessions.keys.first {
                    finish(uuid: uuid, reason: .remoteEnded)
                }
                return
            }
            if let uuid = sessions.first(where: { $0.value.serverCallID == record.id })?.key {
                receiveRecord(record, for: uuid)
                startEventMonitoring(callID: record.id)
                return
            }
            guard record.direction == .inboundCellular,
                  record.state == .ringingCellular,
                  record.ownerInstallationID == nil,
                  let uuid = record.callUUID else { return }
            reportIncoming(
                IncomingCallPush.recovered(from: record),
                completion: {}
            )
            receiveRecord(record, for: uuid)
        } catch {
            AppLog.shared.append("⚠️ 恢复通话状态失败：\(error.localizedDescription)")
        }
    }

    private func reconcile(callID: String) async {
        do {
            let record = try await makeClient().call(id: callID)
            guard let uuid = sessions.first(where: { $0.value.serverCallID == callID })?.key else { return }
            AppLog.shared.append(
                "🔄 REST 通话对账，state=\(record.state.rawValue)，call_id=\(record.id)"
            )
            receiveRecord(record, for: uuid)
        } catch {
            if let clientError = error as? GatewayCallClientError,
               case let .server(status, _) = clientError, status == 404,
               let uuid = sessions.first(where: { $0.value.serverCallID == callID })?.key {
                finish(uuid: uuid, reason: .failed)
            }
        }
    }

    private func startEventMonitoring(
        callID: String,
        connectionSignal: AsyncStream<Void>.Continuation? = nil
    ) {
        if monitoredCallID == callID, eventTask != nil {
            if let connectionSignal {
                if eventStreamConnected {
                    connectionSignal.yield(())
                } else {
                    eventConnectionSignals.append(connectionSignal)
                }
            }
            return
        }

        stopEventMonitoring()
        monitoredCallID = callID
        eventStreamConnected = false
        if let connectionSignal { eventConnectionSignals.append(connectionSignal) }
        eventTask = Task { [weak self] in
            var retrySeconds: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let client = try self.makeClient()
                    try await client.streamCallEvents(onConnected: {
                        await CallManager.shared.eventStreamDidConnect(callID: callID)
                        // SSE 不重放断线窗口中的事件，所以每次连接成功后都立即 REST 对账。
                        await CallManager.shared.reconcile(callID: callID)
                    }) { record in
                        await CallManager.shared.receiveEvent(record)
                    }
                    retrySeconds = 1
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        return
                    }
                    self.eventStreamConnected = false
                    AppLog.shared.append(
                        "⚠️ 通话 SSE 中断，准备 REST 对账：\(error.localizedDescription)"
                    )
                    await self.reconcile(callID: callID)
                    if self.sessions.values.allSatisfy({ $0.serverCallID != callID }) { return }
                    try? await Task.sleep(for: .seconds(retrySeconds))
                    retrySeconds = min(retrySeconds * 2, 15)
                }
            }
        }
    }

    private func eventStreamDidConnect(callID: String) {
        guard monitoredCallID == callID else { return }
        eventStreamConnected = true
        let signals = eventConnectionSignals
        eventConnectionSignals.removeAll(keepingCapacity: true)
        for signal in signals { signal.yield(()) }
        AppLog.shared.append("✅ 通话 SSE 已连接，call_id=\(callID)")
    }

    private func stopEventMonitoring() {
        eventTask?.cancel()
        eventTask = nil
        monitoredCallID = nil
        eventStreamConnected = false
        let signals = eventConnectionSignals
        eventConnectionSignals.removeAll(keepingCapacity: true)
        for signal in signals { signal.finish() }
    }

    private func receiveEvent(_ record: GatewayCallRecord) {
        guard let uuid = sessions.first(where: {
            $0.value.serverCallID == record.id
        })?.key else { return }
        AppLog.shared.append("📞 收到 call.state，state=\(record.state.rawValue)，call_id=\(record.id)")
        receiveRecord(record, for: uuid)
    }

    private func receiveRecord(_ record: GatewayCallRecord, for uuid: UUID) {
        guard var local = sessions[uuid] else { return }
        if !local.callKitReported {
            // CallKit 尚未确认来电上报时只缓存状态；否则抢先到达的 ended
            // 会先结束一个系统尚不知道的 UUID，随后来电报告反而继续响铃。
            local.record = record
            sessions[uuid] = local
            return
        }
        apply(record, to: uuid)
    }

    private func waitForInitialSignaling(_ stream: AsyncStream<Void>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func apply(_ record: GatewayCallRecord, to uuid: UUID) {
        guard var local = sessions[uuid] else { return }
        local.record = record
        sessions[uuid] = local
        currentCall = record
        statusText = description(for: record)

        let localID = PushNotificationManager.shared.installationID.uuidString.lowercased()
        if let owner = record.ownerInstallationID?.lowercased(), owner != localID {
            finish(uuid: uuid, reason: .answeredElsewhere)
            return
        }
        if record.state == .active, record.direction == .outboundCellular {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        } else if record.state.isTerminal {
            finish(uuid: uuid, reason: record.state == .failed ? .failed : .remoteEnded)
        }
    }

    private func finish(uuid: UUID, reason: CXCallEndedReason) {
        guard sessions.removeValue(forKey: uuid) != nil else { return }
        callKitAudioActive = false
        cancelAudioConnectionAttempt()
        resetCallControls()
        CallAudioEngine.shared.stop(notify: false)
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentCall = nil
        statusText = "无通话"
        if sessions.isEmpty {
            stopEventMonitoring()
        }
        Task { await refreshRecentCalls() }
    }

    private func audioDisconnected(uuid: UUID) {
        guard let session = sessions[uuid] else { return }
        finish(uuid: uuid, reason: .failed)
        Task {
            try? await makeClient().hangup(
                callID: session.serverCallID,
                installationID: PushNotificationManager.shared.installationID
            )
        }
    }

    private func finishRecording() {
        guard let capture = CallAudioEngine.shared.takeRecording() else {
            isRecording = false
            return
        }
        isRecording = false
        Task { [weak self] in
            do {
                let url = try await Task.detached(priority: .utility) {
                    try capture.writeToDocuments()
                }.value
                guard let self else { return }
                self.lastRecordingURL = url
                AppLog.shared.append("✅ 通话录音已保存：\(url.path)")
            } catch {
                guard let self else { return }
                self.errorMessage = "保存通话录音失败：\(error.localizedDescription)"
                AppLog.shared.append("❌ 保存通话录音失败：\(error.localizedDescription)")
            }
        }
    }

    private func resetCallControls() {
        if isRecording { finishRecording() }
        isMuted = false
        CallAudioEngine.shared.setMicrophoneMuted(false)
        if isSpeakerEnabled {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        }
        isSpeakerEnabled = false
        dtmfTask?.cancel()
        dtmfTask = nil
        isSendingDTMF = false
    }

    private func cancelAudioConnectionAttempt() {
        audioConnectionAttemptID = nil
        audioConnectionTask?.cancel()
        audioConnectionTask = nil
    }

    private func connectCallAudioIfReady(trigger: String) {
        guard callKitAudioActive,
              audioConnectionTask == nil,
              !CallAudioEngine.shared.isConnected,
              let (uuid, local) = sessions.first,
              !local.serverCallID.isEmpty else { return }

        let callID = local.serverCallID
        let attemptID = UUID()
        audioConnectionAttemptID = attemptID
        AppLog.shared.append(
            "🎧 准备通话音频连接，trigger=\(trigger)，call_id=\(callID)，attempt=\(attemptID.uuidString.prefix(8))"
        )
        audioConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.audioConnectionAttemptID == attemptID {
                    self.audioConnectionAttemptID = nil
                    self.audioConnectionTask = nil
                }
            }
            do {
                try await CallAudioEngine.shared.connect(
                    client: self.makeClient(),
                    callID: callID,
                    installationID: PushNotificationManager.shared.installationID
                ) { [weak self] in
                    self?.audioDisconnected(uuid: uuid)
                }
                try Task.checkCancellation()
                guard self.callKitAudioActive,
                      self.audioConnectionAttemptID == attemptID,
                      self.sessions[uuid]?.serverCallID == callID else {
                    if self.audioConnectionAttemptID == attemptID {
                        CallAudioEngine.shared.stop(notify: false)
                    }
                    return
                }
                AppLog.shared.append(
                    "✅ 通话音频连接就绪，call_id=\(callID)，attempt=\(attemptID.uuidString.prefix(8))"
                )
            } catch is CancellationError {
                AppLog.shared.append(
                    "⏹️ 通话音频连接已取消，call_id=\(callID)，attempt=\(attemptID.uuidString.prefix(8))"
                )
                if self.audioConnectionAttemptID == attemptID {
                    CallAudioEngine.shared.stop(notify: false)
                }
            } catch {
                guard self.callKitAudioActive,
                      self.audioConnectionAttemptID == attemptID,
                      self.sessions[uuid]?.serverCallID == callID else { return }
                self.errorMessage = "无法建立通话音频：\(error.localizedDescription)"
                AppLog.shared.append(
                    "❌ 通话音频连接失败，call_id=\(callID)：\(error.localizedDescription)"
                )
                self.audioDisconnected(uuid: uuid)
            }
        }
    }

    private func description(for record: GatewayCallRecord) -> String {
        switch record.state {
        case .ringingCellular: "正在响铃"
        case .waitingClient: "正在准备音频"
        case .waitingCellular: "正在等待对方接听"
        case .active: "通话中"
        case .hangingUp: "正在挂断"
        case .failed: "通话失败"
        case .ended: "通话已结束"
        default: record.state.rawValue
        }
    }
}

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor in
            PushNotificationManager.shared.didRegister(voIPToken: pushCredentials.token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in PushNotificationManager.shared.didInvalidateVoIPToken() }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        let invitation = IncomingCallPush(dictionary: payload.dictionaryPayload)
        Task { @MainActor in
            if let invitation {
                self.reportIncoming(invitation, completion: completion)
            } else {
                self.reportMalformedIncomingPush(completion: completion)
            }
        }
    }
}

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            let active = Array(sessions.values)
            sessions.removeAll()
            stopEventMonitoring()
            callKitAudioActive = false
            cancelAudioConnectionAttempt()
            resetCallControls()
            CallAudioEngine.shared.stop(notify: false)
            currentCall = nil
            statusText = "无通话"
            for call in active where !call.serverCallID.isEmpty {
                _ = try? await makeClient().hangup(
                    callID: call.serverCallID,
                    installationID: PushNotificationManager.shared.installationID
                )
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard var local = sessions[action.callUUID] else {
                action.fail()
                return
            }
            do {
                try CallAudioEngine.shared.prepareAudioSession()
                let record = try await makeClient().start(
                    number: action.handle.value,
                    installationID: PushNotificationManager.shared.installationID
                )
                local.serverCallID = record.id
                local.record = record
                sessions[action.callUUID] = local
                currentCall = record
                statusText = description(for: record)
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                startEventMonitoring(callID: record.id)
                action.fulfill()
                connectCallAudioIfReady(trigger: "CXStartCallAction")
            } catch {
                sessions.removeValue(forKey: action.callUUID)
                errorMessage = error.localizedDescription
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard var local = sessions[action.callUUID], !local.serverCallID.isEmpty else {
                action.fail()
                return
            }
            do {
                try CallAudioEngine.shared.prepareAudioSession()
                let record = try await makeClient().answer(
                    callID: local.serverCallID,
                    installationID: PushNotificationManager.shared.installationID
                )
                local.record = record
                sessions[action.callUUID] = local
                apply(record, to: action.callUUID)
                action.fulfill()
                connectCallAudioIfReady(trigger: "CXAnswerCallAction")
            } catch {
                await reconcile(callID: local.serverCallID)
                if let recovered = sessions[action.callUUID]?.record,
                   recovered.ownerInstallationID?.lowercased()
                    == PushNotificationManager.shared.installationID.uuidString.lowercased(),
                   recovered.state == .waitingClient || recovered.state == .active {
                    action.fulfill()
                    connectCallAudioIfReady(trigger: "CXAnswerCallAction recovery")
                    return
                }
                if sessions[action.callUUID] != nil {
                    errorMessage = error.localizedDescription
                    finish(uuid: action.callUUID, reason: .failed)
                }
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let local = sessions.removeValue(forKey: action.callUUID)
            callKitAudioActive = false
            cancelAudioConnectionAttempt()
            resetCallControls()
            CallAudioEngine.shared.stop(notify: false)
            currentCall = nil
            statusText = "无通话"
            stopEventMonitoring()
            action.fulfill()
            guard let local, !local.serverCallID.isEmpty else { return }
            do {
                _ = try await makeClient().hangup(
                    callID: local.serverCallID,
                    installationID: PushNotificationManager.shared.installationID
                )
            } catch {
                AppLog.shared.append("⚠️ 网关挂断请求失败：\(error.localizedDescription)")
            }
            await refreshRecentCalls()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            callKitAudioActive = true
            let inputs = audioSession.currentRoute.inputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            let outputs = audioSession.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            AppLog.shared.append(
                "🔊 CallKit didActivate，rate=\(audioSession.sampleRate)，ioBuffer=\(audioSession.ioBufferDuration)，routeIn=[\(inputs)]，routeOut=[\(outputs)]"
            )
            connectCallAudioIfReady(trigger: "CallKit didActivate")
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            AppLog.shared.append("🔇 CallKit didDeactivate")
            callKitAudioActive = false
            cancelAudioConnectionAttempt()
            CallAudioEngine.shared.stop(notify: false)
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Task { @MainActor in
            if let call = action as? CXCallAction {
                finish(uuid: call.callUUID, reason: .failed)
            }
        }
    }
}

private extension IncomingCallPush {
    static func recovered(from record: GatewayCallRecord) -> IncomingCallPush {
        IncomingCallPush(
            callID: record.id,
            caller: record.cellularNumber,
            expiresAt: nil
        )
    }

    init(callID: String, caller: String?, expiresAt: Date?) {
        self.callID = callID
        self.caller = caller
        self.expiresAt = expiresAt
    }
}
#endif
