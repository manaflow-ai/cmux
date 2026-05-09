import Foundation
import CMUXMobileSyncCore
import Observation
import SwiftUI

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

    var body: some View {
        Group {
            if !store.isSignedIn {
                SignInView(signIn: store.signIn)
            } else if store.connectionState != .connected {
                PairingView(
                    pairingCode: $store.pairingCode,
                    connect: store.connectPreviewHost,
                    signOut: store.signOut
                )
            } else {
                WorkspaceShellView(store: store)
            }
        }
        .animation(.snappy(duration: 0.18), value: store.phase)
    }
}

struct SignInView: View {
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text(L10n.string("mobile.signIn.title", defaultValue: "cmux"))
                    .font(.largeTitle.bold())

                Text(L10n.string("mobile.signIn.subtitle", defaultValue: "Sign in to connect to your Mac workspaces."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button(action: signIn) {
                Label(L10n.string("mobile.signIn.button", defaultValue: "Sign In"), systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("MobileSignInButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct PairingView: View {
    @Binding var pairingCode: String
    let connect: () -> Void
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("mobile.pairing.title", defaultValue: "Pair with Mac"))
                                .font(.headline)
                            Text(L10n.string("mobile.pairing.subtitle", defaultValue: "Scan the QR from `cmux ios`, or enter a debug pairing code in Simulator."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button {
                    } label: {
                        Label(L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code"), systemImage: "camera.viewfinder")
                    }
                    .disabled(true)
                    .accessibilityIdentifier("MobileScanQRCodeButton")

                    TextField(
                        L10n.string("mobile.pairing.codePlaceholder", defaultValue: "Pairing code"),
                        text: $pairingCode
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("MobilePairingCodeField")

                    Button(action: connect) {
                        Label(L10n.string("mobile.pairing.connect", defaultValue: "Connect"), systemImage: "link")
                    }
                    .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("MobileConnectButton")
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.navigationTitle", defaultValue: "Pairing"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: signOut) {
                        Text(L10n.string("mobile.signOut", defaultValue: "Sign Out"))
                    }
                    .accessibilityIdentifier("MobileSignOutButton")
                }
            }
        }
    }
}

struct WorkspaceShellView: View {
    @Bindable var store: CMUXMobileShellStore

    var body: some View {
        NavigationSplitView {
            WorkspaceListView(
                workspaces: store.workspaces,
                selection: $store.selectedWorkspaceID,
                createWorkspace: store.createWorkspace
            )
        } detail: {
            if let workspace = store.selectedWorkspace {
                WorkspaceDetailView(
                    host: store.connectedHostName,
                    workspace: workspace,
                    selectedTerminalID: Binding(
                        get: { store.selectedTerminalID },
                        set: { store.selectTerminal($0) }
                    ),
                    createWorkspace: store.createWorkspace,
                    createTerminal: store.createTerminal
                )
            } else {
                ContentUnavailableView(
                    L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"),
                    systemImage: "rectangle.stack"
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("MobileWorkspaceShell")
    }
}

struct WorkspaceListView: View {
    let workspaces: [MobileWorkspacePreview]
    @Binding var selection: MobileWorkspacePreview.ID?
    let createWorkspace: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(workspaces) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .tag(workspace.id)
                }
            }
        }
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: createWorkspace) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
                .accessibilityIdentifier("MobileNewWorkspaceButton")
            }
        }
        .accessibilityIdentifier("MobileWorkspaceList")
    }
}

struct WorkspaceRow: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workspace.name)
                .font(.headline)
            Text(L10n.terminalCount(workspace.terminals.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
    }
}

struct WorkspaceDetailView: View {
    let host: String
    let workspace: MobileWorkspacePreview
    @Binding var selectedTerminalID: MobileTerminalPreview.ID?
    let createWorkspace: () -> Void
    let createTerminal: () -> Void

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == selectedTerminalID } ?? workspace.terminals.first
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(
                host: host,
                workspace: workspace,
                selectedTerminalID: selectedTerminal?.id,
                selectTerminal: { selectedTerminalID = $0 },
                createWorkspace: createWorkspace,
                createTerminal: createTerminal
            )

            Divider()

            TerminalPreviewSurface(terminal: selectedTerminal, workspace: workspace)
        }
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkspaceToolbar: View {
    let host: String
    let workspace: MobileWorkspacePreview
    let selectedTerminalID: MobileTerminalPreview.ID?
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(host)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(workspace.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: createWorkspace) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
            .accessibilityIdentifier("MobileNewWorkspaceButton")

            Menu {
                ForEach(workspace.terminals) { terminal in
                    Button {
                        selectTerminal(terminal.id)
                    } label: {
                        Label(terminal.name, systemImage: terminal.id == selectedTerminalID ? "checkmark.circle.fill" : "terminal")
                    }
                    .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
                }

                Divider()

                Button(action: createTerminal) {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileNewTerminalMenuItem")
            } label: {
                Label(
                    workspace.terminals.first { $0.id == selectedTerminalID }?.name
                        ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                    systemImage: "terminal"
                )
                .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileTerminalDropdown")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct TerminalPreviewSurface: View {
    let terminal: MobileTerminalPreview?
    let workspace: MobileWorkspacePreview

    private var snapshot: MobileTerminalGhosttySnapshot? {
        terminal?.snapshot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach((snapshot?.renderedVisibleLines ?? []).indices, id: \.self) { index in
                    Text(snapshot?.renderedVisibleLines[index] ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(index == 0 ? .green : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("MobileTerminalRow-\(index)")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .accessibilityIdentifier("MobileTerminalSurface")
    }
}

enum L10n {
    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .main)
    }

    static func terminalCount(_ count: Int) -> String {
        String(format: string("mobile.workspace.terminalCountFormat", defaultValue: "%d terminals"), count)
    }

    static func workspaceName(index: Int) -> String {
        String(format: string("mobile.preview.workspaceNameFormat", defaultValue: "Workspace %d"), index)
    }

    static func terminalName(index: Int) -> String {
        String(format: string("mobile.preview.terminalNameFormat", defaultValue: "Terminal %d"), index)
    }

}
