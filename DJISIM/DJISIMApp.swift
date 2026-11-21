///* Copyright Yahagi Networks and Contributors */

import SwiftUI
import SwiftData

@main
struct DJISIMApp: App {

    private let smsContainer = SMSPersistence.shared.container
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(smsContainer)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SMSAcknowledgementManager.shared.retryPending()
                #if os(iOS)
                CallManager.shared.applicationBecameActive()
                #endif
            }
        }
    }
}
