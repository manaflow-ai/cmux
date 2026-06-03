import Foundation
@preconcurrency import AVFoundation
import CMUXMobileCore
import CmuxMobileAuth
import CmuxMobileTerminal
import Observation
import OSLog
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

#if DEBUG
private let mobileShellUILog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell-ui"
)
#endif

@MainActor
public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore

    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        CMUXMobileRootView(store: store)
    }
}

struct CMUXMobileRootView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager = AuthManager.shared
    @State private var pendingAttachURL: String?
    @State private var didConsumeUITestAttachURL = false
    @State private var didAuthenticateWithAttachTicket = false
    @State private var isShowingAddDeviceSheet = true
    #if os(iOS)
    @State private var addDeviceSheetDetent: PresentationDetent = .large
    #endif

    private var shouldShowTerminalLayoutPreview: Bool {
        #if os(iOS)
        return UITestConfig.terminalLayoutPreviewEnabled
        #else
        return false
        #endif
    }

    @ViewBuilder private var terminalLayoutPreview: some View {
        #if os(iOS)
        TerminalLayoutPreviewView()
        #else
        EmptyView()
        #endif
    }

    var body: some View {
        Group {
            if shouldShowTerminalLayoutPreview {
                terminalLayoutPreview
            } else if shouldShowRestoringSession {
                RestoringSessionView()
            } else if !isAuthenticated {
                SignInView()
            } else if store.connectionState != .connected {
                DisconnectedWorkspaceShellView(
                    showAddDevice: showAddDevice,
                    signOut: signOut
                )
                .sheet(isPresented: $isShowingAddDeviceSheet) {
                    PairingView(
                        pairingCode: $store.pairingCode,
                        connectionError: store.connectionError,
                        connectPairingCode: {
                            await store.connectPairingInput()
                        },
                        connectManualHost: { name, host, port in
                            await store.connectManualHost(name: name, host: host, port: port)
                        },
                        cancelPairing: store.cancelPairing,
                        cancel: { isShowingAddDeviceSheet = false }
                    )
                    #if os(iOS)
                    .presentationDetents([.medium, .large], selection: $addDeviceSheetDetent)
                    .presentationDragIndicator(.visible)
                    #endif
                }
                .onAppear {
                    showAddDevice()
                }
            } else {
                WorkspaceShellView(store: store, signOut: signOut)
            }
        }
        .animation(.snappy(duration: 0.18), value: isAuthenticated)
        .animation(.snappy(duration: 0.18), value: store.phase)
        .onAppear {
            syncShellAuthentication(isAuthenticated)
            store.resumeForegroundRefresh()
            connectUITestAttachURLIfNeeded()
            #if os(iOS)
            MobilePushCoordinator.shared.bind(store: store)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.resumeForegroundRefresh()
        }
        .onOpenURL { url in
            let rawURL = url.absoluteString
            if MobileRootAuthGate.isAttachURL(url) {
                connectAttachURL(rawURL)
                return
            }

            guard isAuthenticated else {
                pendingAttachURL = rawURL
                return
            }
            Task {
                await store.connectPairingURL(rawURL)
            }
        }
        .onChange(of: isAuthenticated) { _, isAuthenticated in
            syncShellAuthentication(isAuthenticated)
            guard isAuthenticated else {
                return
            }
            if let rawURL = pendingAttachURL {
                pendingAttachURL = nil
                Task {
                    await store.connectPairingURL(rawURL)
                }
                return
            }
            let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
            if !startedUITestAttachURL,
               MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                connectionState: store.connectionState
            ) {
                let stackUserID = authManager.currentUser?.id
                Task {
                    await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
                }
            }
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
        }
        .onChange(of: store.connectionState) { _, connectionState in
            if connectionState == .connected {
                isShowingAddDeviceSheet = false
            } else {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
        .onChange(of: store.hasActiveUnexpiredAttachTicket) { _, hasActiveUnexpiredAttachTicket in
            if !hasActiveUnexpiredAttachTicket {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
    }

    private var isAuthenticated: Bool {
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication
        )
    }

    private var shouldShowRestoringSession: Bool {
        MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
            isRestoringSession: authManager.isRestoringSession
        )
    }

    private var hasActiveAttachTicketAuthentication: Bool {
        didAuthenticateWithAttachTicket && store.hasActiveUnexpiredAttachTicket
    }

    private func syncShellAuthentication(
        _ isAuthenticated: Bool,
        isRestoringSession: Bool? = nil
    ) {
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: isAuthenticated,
            isRestoringSession: isRestoringSession ?? authManager.isRestoringSession,
            store: store
        )
    }

    private func showAddDevice() {
        #if os(iOS)
        addDeviceSheetDetent = .large
        #endif
        isShowingAddDeviceSheet = true
    }

    private func connectAttachURL(_ rawURL: String) {
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication(true)
        Task {
            let result = await store.connectPairingURLResult(rawURL)
            guard MobileRootAuthGate.shouldClearAttachTicketAuthentication(
                pairingResult: result,
                connectionState: store.connectionState,
                hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
            ) else { return }
            didAuthenticateWithAttachTicket = false
            syncShellAuthentication(authManager.isAuthenticated)
        }
    }

    private func clearAttachTicketAuthenticationIfNeeded() {
        guard didAuthenticateWithAttachTicket,
              store.connectionState != .connected || !store.hasActiveUnexpiredAttachTicket else {
            return
        }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication(authManager.isAuthenticated)
    }

    private func signOut() {
        Task {
            await authManager.signOut()
            didAuthenticateWithAttachTicket = false
            store.signOut()
        }
    }

    @discardableResult
    private func connectUITestAttachURLIfNeeded() -> Bool {
        #if DEBUG
        // Auto-pair when CMUX_UITEST_ATTACH_URL is supplied at launch. Originally
        // gated on mock data (the XCUITest harness), but the dev-launch tooling
        // (scripts/mobile-dev-launch.sh) signs in for real (CMUX_UITEST_STACK_*
        // with CMUX_UITEST_MOCK_DATA=0) and still wants to auto-attach, so this
        // fires for any authenticated session once the attach URL is present.
        // No-op unless that env var is set, so normal launches are unaffected.
        guard !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.attachURL else {
            return false
        }
        didConsumeUITestAttachURL = true
        Task {
            await store.connectPairingURL(attachURL)
        }
        return true
        #else
        return false
        #endif
    }
}

enum MobileRootAuthGate {
    static func isAuthenticated(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false
    ) -> Bool {
        stackAuthenticated || attachTicketAuthenticated
    }

    static func shouldShowRestoringSession(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false,
        isRestoringSession: Bool
    ) -> Bool {
        isRestoringSession && !isAuthenticated(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated
        )
    }

    static func isAttachURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("cmux-ios") == .orderedSame else {
            return false
        }
        return url.host?.caseInsensitiveCompare("attach") == .orderedSame
    }

    static func shouldClearAttachTicketAuthentication(
        pairingResult: MobilePairingURLConnectionResult,
        connectionState: MobileConnectionState,
        hasActiveUnexpiredTicket: Bool
    ) -> Bool {
        switch pairingResult {
        case .connected:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        case .failed:
            return true
        case .superseded:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        }
    }

    static func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        stackAuthenticated && !attachTicketAuthenticated && connectionState != .connected
    }

    @MainActor
    static func syncShellAuthentication(
        stackAuthenticated: Bool,
        isRestoringSession: Bool = false,
        store: CMUXMobileShellStore
    ) {
        if stackAuthenticated {
            store.signIn()
        } else if !isRestoringSession {
            store.signOut()
        }
    }
}

private struct DisconnectedWorkspaceShellView: View {
    let showAddDevice: () -> Void
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices"),
                    systemImage: "desktopcomputer.and.iphone"
                )
            } description: {
                Text(L10n.string("mobile.devices.emptyDescription", defaultValue: "Add a Mac to start syncing terminal workspaces."))
            } actions: {
                Button(action: showAddDevice) {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
            }
            .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    signOutButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addDeviceToolbarButton
                }
                #else
                ToolbarItem {
                    signOutButton
                }
                ToolbarItem {
                    addDeviceToolbarButton
                }
                #endif
            }
            .accessibilityIdentifier("MobileDisconnectedWorkspaceShell")
        }
    }

    private var signOutButton: some View {
        Button(action: signOut) {
            Text(L10n.string("mobile.signOut", defaultValue: "Sign Out"))
        }
        .accessibilityIdentifier("MobileSignOutButton")
    }

    private var addDeviceToolbarButton: some View {
        Button(action: showAddDevice) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}
