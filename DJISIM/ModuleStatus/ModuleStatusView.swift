///* Copyright Yahagi Networks and Contributors */

import SwiftUI

struct ModuleStatusView: View {
    @ObservedObject var model: SMSViewModel
    let showSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasConfiguration {
                    ContentUnavailableView {
                        Label("尚未配置网关", systemImage: "server.rack")
                    } description: {
                        Text("请先在“短信”页面输入服务器地址和 Token。")
                    } actions: {
                        Button("打开设置", action: showSettings)
                    }
                } else if let status = model.moduleStatus {
                    Form {
                        ModuleAPISummarySection(status: status)

                        if let warnings = status.warnings, !warnings.isEmpty {
                            Section("模块警告") {
                                ForEach(warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .refreshable { await model.refreshModuleStatus() }
                } else if model.isLoadingModule {
                    ProgressView("正在获取模块状态…")
                } else {
                    ContentUnavailableView(
                        "暂无模块状态",
                        systemImage: "simcard",
                        description: Text("点击刷新以调用 GET /api/v1/module。")
                    )
                }
            }
            .navigationTitle("模块状态")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.refreshModuleStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!model.hasConfiguration || model.isLoadingModule)

                    Button(action: showSettings) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                        .padding()
                }
            }
        }
        .task {
            guard model.hasConfiguration, model.moduleStatus == nil else { return }
            await model.refreshModuleStatus()
        }
    }
}

private struct ModuleAPISummarySection: View {
    let status: ModuleStatus

    var body: some View {
        Section {
            LabeledContent("连接状态") {
                Label(status.connected ? "已连接" : "未连接", systemImage: status.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.connected ? .green : .secondary)
            }
            LabeledContent("模块标识", value: status.identity ?? "—")
            LabeledContent("本机号码", value: status.phoneNumber ?? "SIM 未提供")
            LabeledContent("运营商", value: operatorDescription)
            LabeledContent("信号") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(signalDescription)
                    if let bars = status.signal?.bars {
                        ProgressView(value: Double(max(0, min(bars, 5))), total: 5)
                            .frame(width: 90)
                    }
                }
            }
            if let bus = status.bus, let address = status.address {
                LabeledContent("USB", value: "Bus \(bus) · Address \(address)")
            }
            if let measuredAt = status.networkMeasuredAt {
                LabeledContent("网络采样时间", value: measuredAt)
            }
            if let error = status.error {
                LabeledContent("错误", value: error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("模块概览")
        } footer: {
            Text("数据来自 GET /api/v1/module；下拉可刷新。")
        }
    }

    private var operatorDescription: String {
        let name = status.operator?.name ?? "未知"
        guard let radio = status.operator?.radio, !radio.isEmpty else { return name }
        return "\(name) · \(radio)"
    }

    private var signalDescription: String {
        guard let signal = status.signal else { return "未采样" }
        if let dbm = signal.dbm, let bars = signal.bars {
            return "\(dbm) dBm · \(bars)/5"
        }
        return signal.error == nil ? "未知" : "暂不可用"
    }
}
