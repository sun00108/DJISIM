#if os(iOS)
import AVFoundation
import SwiftUI

enum DialingPreferences {
    static let storageKey = "DJISIM.defaultDialingCode"

    static func sanitizedCode(_ value: String) -> String {
        let digits = value.compactMap(\.wholeNumberValue).prefix(3).map(String.init).joined()
        return digits.isEmpty ? "+" : "+\(digits)"
    }

    static func effectiveCode(_ value: String) -> String {
        let code = sanitizedCode(value)
        return code == "+" ? "+1" : code
    }

    static func isValidCountryCallingCode(_ value: String) -> Bool {
        countryCallingCodes.contains(String(sanitizedCode(value).dropFirst()))
    }

    // E.164 国家/地区呼叫代码。这里只用于识别区号边界，不负责各国本地号码格式化。
    static let countryCallingCodes: Set<String> = [
        "1", "7", "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41",
        "43", "44", "45", "46", "47", "48", "49", "51", "52", "53", "54", "55", "56",
        "57", "58", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84", "86",
        "90", "91", "92", "93", "94", "95", "98", "211", "212", "213", "216", "218",
        "220", "221", "222", "223", "224", "225", "226", "227", "228", "229", "230",
        "231", "232", "233", "234", "235", "236", "237", "238", "239", "240", "241",
        "242", "243", "244", "245", "246", "247", "248", "249", "250", "251", "252",
        "253", "254", "255", "256", "257", "258", "260", "261", "262", "263", "264",
        "265", "266", "267", "268", "269", "290", "291", "297", "298", "299", "350",
        "351", "352", "353", "354", "355", "356", "357", "358", "359", "370", "371",
        "372", "373", "374", "375", "376", "377", "378", "379", "380", "381", "382",
        "383", "385", "386", "387", "389", "420", "421", "423", "500", "501", "502",
        "503", "504", "505", "506", "507", "508", "509", "590", "591", "592", "593",
        "594", "595", "596", "597", "598", "599", "670", "672", "673", "674", "675",
        "676", "677", "678", "679", "680", "681", "682", "683", "685", "686", "687",
        "688", "689", "690", "691", "692", "850", "852", "853", "855", "856", "880",
        "886", "960", "961", "962", "963", "964", "965", "966", "967", "968", "970",
        "971", "972", "973", "974", "975", "976", "977", "992", "993", "994", "995",
        "996", "998",
    ]
}

struct CallView: View {
    @ObservedObject private var calls = CallManager.shared
    @ObservedObject private var contacts = ContactsManager.shared
    @AppStorage(DialingPreferences.storageKey) private var storedDialingCode = "+1"
    @State private var temporaryDialingCode: String?
    @State private var subscriberNumber = ""
    @State private var isEditingDialingCode = false
    @State private var showingHistory = false
    @State private var contactDescription = ""
    @State private var showingCallKeypad = false
    @State private var enteredDTMF = ""

    private let keys: [[DialPadKey]] = [
        [.init("1", ""), .init("2", "ABC"), .init("3", "DEF")],
        [.init("4", "GHI"), .init("5", "JKL"), .init("6", "MNO")],
        [.init("7", "PQRS"), .init("8", "TUV"), .init("9", "WXYZ")],
        [.init("*", ""), .init("0", "+"), .init("#", "")],
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let call = calls.currentCall {
                    activeCallView(call)
                } else {
                    dialPad
                }
            }
            .navigationTitle("拨号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(calls.currentCall == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar(calls.currentCall == nil ? .visible : .hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock")
                    }
                    .accessibilityLabel("最近通话与通话设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CallRecordingsView()
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .accessibilityLabel("所有录音")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = calls.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
            .sheet(isPresented: $showingHistory) {
                NavigationStack { CallHistoryView() }
            }
        }
    }

    private var dialPad: some View {
        GeometryReader { proxy in
            let diameter = min(max((proxy.size.width - 96) / 3, 72), 92)
            VStack(spacing: 0) {
                Spacer(minLength: 18)

                VStack(spacing: 7) {
                    Text(formattedNumber)
                        .font(.system(size: 38, weight: .regular, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .contentTransition(.numericText())
                        .onTapGesture {
                            if subscriberNumber.isEmpty { isEditingDialingCode.toggle() }
                        }

                    Text(isEditingDialingCode ? "正在编辑拨出区号" : contactDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 20)

                VStack(spacing: 14) {
                    ForEach(keys.indices, id: \.self) { row in
                        HStack(spacing: 20) {
                            ForEach(keys[row]) { key in
                                DialPadButton(key: key, diameter: diameter) {
                                    append(key.digit)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 20)

                HStack {
                    Color.clear.frame(width: diameter, height: diameter)
                    Spacer()
                    DialCallButton(diameter: diameter, isEnabled: canCall) {
                        let number = outgoingNumber
                        Task {
                            await DTMFPlayer.shared.stop()
                            await calls.startOutgoing(number: number)
                        }
                    }
                    .accessibilityLabel("拨打 \(formattedNumber)")
                    Spacer()
                    Button(action: deleteBackward) {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.primary)
                            .frame(width: diameter, height: diameter)
                    }
                    .buttonStyle(.plain)
                    .opacity(canDelete ? 1 : 0)
                    .disabled(!canDelete)
                    .accessibilityLabel("退格")
                }
                .padding(.horizontal, max(28, (proxy.size.width - diameter * 3 - 40) / 2))

                Spacer(minLength: 12)
            }
            .task(id: contactLookupNumber) {
                contactDescription = ""
                let number = contactLookupNumber
                guard contacts.hasContactAccess, !number.isEmpty else { return }
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                } catch {
                    return
                }
                let name = await contacts.displayNameAsync(for: number)
                guard !Task.isCancelled, number == contactLookupNumber else { return }
                contactDescription = name == number ? "" : name
            }
        }
    }

    private func activeCallView(_ call: GatewayCallRecord) -> some View {
        GeometryReader { proxy in
            let controlDiameter = min(max((proxy.size.width - 112) / 3, 76), 92)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.48, blue: 0.66),
                        Color(red: 0.06, green: 0.17, blue: 0.43),
                        Color(red: 0.12, green: 0.12, blue: 0.29),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 30)

                    if showingCallKeypad {
                        Text(enteredDTMF.isEmpty ? " " : enteredDTMF)
                            .font(.system(size: 42, weight: .regular, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: 52)
                    } else {
                        Text(calls.statusText)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        Text(call.cellularNumber ?? "未知号码")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .padding(.top, 6)
                    }

                    Spacer(minLength: showingCallKeypad ? 20 : 80)

                    if showingCallKeypad {
                        activeDTMFPad(diameter: controlDiameter)
                    } else {
                        activeCallControls(call: call, diameter: controlDiameter)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
            }
        }
        .onDisappear {
            showingCallKeypad = false
            enteredDTMF = ""
        }
    }

    private func activeCallControls(call: GatewayCallRecord, diameter: CGFloat) -> some View {
        let isActive = call.state == .active
        return VStack(spacing: 26) {
            HStack(alignment: .top, spacing: 24) {
                CallControlButton(
                    title: "音频",
                    systemImage: "speaker.wave.3.fill",
                    diameter: diameter,
                    isSelected: calls.isSpeakerEnabled,
                    isEnabled: isActive,
                    action: calls.toggleSpeaker
                )
                Color.clear
                    .frame(width: diameter + 16, height: diameter + 32)
                    .accessibilityHidden(true)
                CallControlButton(
                    title: "静音",
                    systemImage: calls.isMuted ? "mic.slash.fill" : "mic.fill",
                    diameter: diameter,
                    isSelected: calls.isMuted,
                    isEnabled: isActive,
                    action: calls.toggleMute
                )
            }

            HStack(alignment: .top, spacing: 24) {
                CallControlButton(
                    title: calls.isRecording ? "停止录音" : "录音",
                    systemImage: calls.isRecording ? "stop.fill" : "record.circle",
                    diameter: diameter,
                    isSelected: calls.isRecording,
                    selectedColor: Color(uiColor: .systemRed),
                    isEnabled: isActive,
                    action: calls.toggleRecording
                )
                CallControlButton(
                    title: "结束",
                    systemImage: "phone.down.fill",
                    diameter: diameter,
                    normalColor: Color(uiColor: .systemRed),
                    action: { Task { await calls.endCurrentCall() } }
                )
                CallControlButton(
                    title: "拨号键盘",
                    systemImage: "circle.grid.3x3.fill",
                    diameter: diameter,
                    isEnabled: isActive
                ) {
                    enteredDTMF = ""
                    showingCallKeypad = true
                }
            }
        }
    }

    private func activeDTMFPad(diameter: CGFloat) -> some View {
        VStack(spacing: 14) {
            ForEach(keys.indices, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(keys[row]) { key in
                        InCallDialPadButton(
                            key: key,
                            diameter: diameter,
                            isEnabled: !calls.isSendingDTMF
                        ) {
                            guard enteredDTMF.count < 32 else { return }
                            enteredDTMF.append(key.digit)
                            calls.sendDTMF(key.digit)
                        }
                    }
                }
            }

            HStack {
                Color.clear.frame(width: diameter, height: diameter)
                Spacer()
                CallControlButton(
                    title: "结束",
                    systemImage: "phone.down.fill",
                    diameter: diameter,
                    normalColor: Color(uiColor: .systemRed),
                    action: { Task { await calls.endCurrentCall() } }
                )
                Spacer()
                Button("隐藏拨号键盘") {
                    showingCallKeypad = false
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: diameter)
            }
            .padding(.top, 18)
        }
    }

    private var dialingCode: String {
        DialingPreferences.sanitizedCode(temporaryDialingCode ?? storedDialingCode)
    }

    private var outgoingNumber: String {
        DialingPreferences.effectiveCode(dialingCode)
            + subscriberNumber.filter(\.isNumber)
    }

    private var formattedNumber: String {
        let code = dialingCode
        guard !subscriberNumber.isEmpty else { return code }
        return "\(code) \(grouped(subscriberNumber))"
    }

    private var contactLookupNumber: String {
        subscriberNumber.isEmpty ? "" : outgoingNumber
    }

    private var canCall: Bool {
        !subscriberNumber.isEmpty
            && subscriberNumber.allSatisfy(\.isNumber)
            && DialingPreferences.isValidCountryCallingCode(dialingCode)
            && !AppConfiguration.token.isEmpty
    }

    private var canDelete: Bool {
        !subscriberNumber.isEmpty || dialingCode.count > 1
    }

    private func append(_ character: Character) {
        if isEditingDialingCode {
            guard character.isNumber else { return }
            let digits = String(dialingCode.dropFirst()) + String(character)
            guard digits.count <= 3 else { return }
            DTMFPlayer.shared.playDigit(character)
            temporaryDialingCode = "+\(digits)"
            if DialingPreferences.countryCallingCodes.contains(digits) {
                isEditingDialingCode = false
            }
            return
        }
        guard subscriberNumber.count < 24 else { return }
        DTMFPlayer.shared.playDigit(character)
        subscriberNumber.append(character)
    }

    private func deleteBackward() {
        if !subscriberNumber.isEmpty {
            subscriberNumber.removeLast()
            return
        }
        guard dialingCode.count > 1 else { return }
        temporaryDialingCode = String(dialingCode.dropLast())
        isEditingDialingCode = true
    }

    private func grouped(_ value: String) -> String {
        guard value.count > 4 else { return value }
        let suffix = String(value.suffix(4))
        var prefix = String(value.dropLast(4))
        var groups: [String] = []
        while !prefix.isEmpty {
            let length = min(3, prefix.count)
            groups.append(String(prefix.prefix(length)))
            prefix.removeFirst(length)
        }
        groups.append(suffix)
        return groups.joined(separator: " ")
    }
}

private struct DialCallButton: View {
    let diameter: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.green, in: Circle())
        }
        .buttonStyle(DialButtonPressStyle(shadowColor: .green))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct DialButtonPressStyle: PrimitiveButtonStyle {
    var shadowColor: Color = .black

    func makeBody(configuration: Configuration) -> some View {
        DialButtonPressStyleBody(
            configuration: configuration,
            shadowColor: shadowColor
        )
    }
}

private struct DialButtonPressStyleBody: View {
    let configuration: PrimitiveButtonStyle.Configuration
    let shadowColor: Color

    @Environment(\.isEnabled) private var isEnabled
    @State private var pressStartDate: Date?
    /// 松手后展示用的缩放值：松手瞬间保底跳到至少 popScale，再用弹簧动画收回 1。
    @State private var releaseScale: CGFloat = 1
    @GestureState private var gestureState = DialButtonGestureState()

    /// 第一阶段：按下后 0~popDuration 秒内快速弹出到 popScale，快按也能立刻看到放大。
    private let popDuration: TimeInterval = 0.01
    private let popScale: CGFloat = 1.2
    /// 第二阶段：popDuration~popDuration+growDuration 秒内持续放大到 maxScale，
    /// 长按或拖动越久放大越明显。
    private let growDuration: TimeInterval = 0.05
    private let maxScale: CGFloat = 1.3

    /// 纯粹按“已按住时长”算出的缩放值，不看是否还在按——用于松手那一刻回溯峰值。
    private func rawScale(heldFor duration: TimeInterval) -> CGFloat {
        let popPortion = min(duration / popDuration, 1)
        let popEased = 1 - pow(1 - popPortion, 3)
        let currentPopScale = 1 + (popScale - 1) * popEased
        guard duration > popDuration else { return currentPopScale }

        let growPortion = min((duration - popDuration) / growDuration, 1)
        let growEased = 1 - pow(1 - growPortion, 2)
        return currentPopScale + (maxScale - currentPopScale) * growEased
    }

    private func isHolding(heldFor duration: TimeInterval) -> Bool {
        gestureState.isPressed && duration > popDuration
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: pressStartDate == nil)) { context in
            let held = pressStartDate.map { context.date.timeIntervalSince($0) } ?? 0
            let holding = isHolding(heldFor: held)
            let liveScale = gestureState.isPressed ? rawScale(heldFor: held) : releaseScale

            configuration.label
                .offset(limitedOffset(gestureState.translation, maximumDistance: 11))
                .brightness(gestureState.isPressed ? -0.025 : 0)
                .shadow(
                    color: shadowColor.opacity(gestureState.isPressed ? 0.22 : 0),
                    radius: holding ? 14 : 7,
                    y: holding ? 7 : 3
                )
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: gestureState.isPressed)
                .animation(
                    .interactiveSpring(response: 0.18, dampingFraction: 0.78),
                    value: gestureState.translation
                )
                // 放在两个 .animation 之后：缩放动画完全交给下面手动的 withAnimation 控制，
                // 不会被上面这两个隐式动画抢先接管。
                .scaleEffect(liveScale)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gestureState) { value, state, _ in
                    guard isEnabled else { return }
                    state.isPressed = true
                    state.translation = value.translation
                }
                .onEnded { value in
                    guard isEnabled else { return }
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance <= 70 {
                        configuration.trigger()
                    }
                }
        )
        .onChange(of: gestureState.isPressed) { _, pressed in
            if pressed {
                pressStartDate = .now
                return
            }
            let heldDuration = pressStartDate.map { Date.now.timeIntervalSince($0) } ?? 0
            pressStartDate = nil
            // 保底：哪怕触摸时长几乎为 0（还没来得及渲染出放大的那一帧），
            // 松手瞬间也强制跳到至少 popScale，再弹簧收回 1，保证一定能看到动画。
            releaseScale = max(rawScale(heldFor: heldDuration), popScale)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) {
                releaseScale = 1
            }
        }
    }

    private func limitedOffset(_ translation: CGSize, maximumDistance: CGFloat) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > maximumDistance, distance > 0 else { return translation }
        let scale = maximumDistance / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}

private struct DialButtonGestureState {
    var isPressed = false
    var translation: CGSize = .zero
}

private struct DialPadKey: Identifiable {
    let digit: Character
    let letters: String
    var id: Character { digit }

    init(_ digit: Character, _ letters: String) {
        self.digit = digit
        self.letters = letters
    }
}

private struct DialPadButton: View {
    let key: DialPadKey
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: -2) {
                Text(String(key.digit))
                    .font(.system(size: 36, weight: .regular, design: .rounded))
                Text(key.letters)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .frame(height: 14)
            }
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(DialButtonPressStyle())
        .accessibilityLabel(String(key.digit))
    }
}

private struct InCallDialPadButton: View {
    let key: DialPadKey
    let diameter: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: -2) {
                Text(String(key.digit))
                    .font(.system(size: 36, weight: .regular, design: .rounded))
                Text(key.letters)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .frame(height: 14)
            }
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(.white.opacity(0.14), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(DialButtonPressStyle(shadowColor: .white))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(String(key.digit))
    }
}

private struct CallControlButton: View {
    let title: String
    let systemImage: String
    let diameter: CGFloat
    var isSelected = false
    var normalColor: Color = .white.opacity(0.14)
    var selectedColor: Color = .white
    var selectedForegroundColor: Color = .black
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(isSelected ? selectedForegroundColor : .white)
                    .frame(width: diameter, height: diameter)
                    .background(isSelected ? selectedColor : normalColor, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(DialButtonPressStyle(shadowColor: isSelected ? selectedColor : .white))
            .disabled(!isEnabled)

            Text(title)
                .font(.callout)
                .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: diameter + 16)
        }
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

private struct CallHistoryView: View {
    @ObservedObject private var calls = CallManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("通话权限") {
                LabeledContent("麦克风", value: microphonePermissionText)
                if calls.microphonePermission == .undetermined {
                    Button("允许麦克风访问") { calls.requestMicrophonePermission() }
                } else if calls.microphonePermission == .denied {
                    Text("请在系统设置中允许 DJI SIM 使用麦克风，否则接听后无法传输语音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("最近通话") {
                if calls.recentCalls.isEmpty {
                    Text("暂无通话记录").foregroundStyle(.secondary)
                } else {
                    ForEach(calls.recentCalls.prefix(25)) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: call.direction == .inboundCellular
                                      ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                Text(call.cellularNumber ?? "未知号码")
                                Spacer()
                                Text(call.state == .failed ? "失败" : call.state == .ended ? "已结束" : call.state.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(call.state == .failed ? .red : .secondary)
                            }
                            if let startedAt = call.startedAt {
                                Text(startedAt)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("最近通话")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .refreshable { await calls.refreshRecentCalls() }
    }

    private var microphonePermissionText: String {
        switch calls.microphonePermission {
        case .undetermined: "尚未申请"
        case .denied: "已拒绝"
        case .granted: "已允许"
        @unknown default: "未知"
        }
    }
}
#endif
