///* Copyright Yahagi Networks and Contributors */

import SwiftUI

struct ContentView: View {
    @StateObject private var model = SMSViewModel()
    @State private var showingSettings = false
    @State private var showingComposer = false
    @State private var composeTransitionSource = "push-messages-compose"
    @Namespace private var composeTransitionNamespace

    var body: some View {
        TabView {
            #if os(iOS)
            CallView()
                .tabItem {
                    Label("拨号", systemImage: "circle.grid.3x3.fill")
                }
            #endif

            PushMessagesView(
                model: model,
                composeTransitionNamespace: composeTransitionNamespace,
                composeTransitionID: "push-messages-compose"
            ) {
                composeTransitionSource = "push-messages-compose"
                showingComposer = true
            }
            .tabItem {
                Label("短信", systemImage: "bubble.left.and.bubble.right")
            }

            ModuleStatusView(model: model) {
                showingSettings = true
            }
            .tabItem {
                Label("模块状态", systemImage: "simcard")
            }
        }
        .sheet(isPresented: $showingComposer) {
            ComposeMessageView(model: model)
                #if os(iOS)
                .navigationTransition(
                    .zoom(
                        sourceID: composeTransitionSource,
                        in: composeTransitionNamespace
                    )
                )
                #endif
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView(model: model) }
        }
        .task {
            guard model.hasConfiguration else { return }
            await model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveDJISIMRemoteNotification)) { _ in
            guard model.hasConfiguration else { return }
            Task { await model.refresh() }
        }
    }
}
