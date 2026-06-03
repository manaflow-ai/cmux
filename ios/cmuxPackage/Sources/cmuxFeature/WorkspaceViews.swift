import Foundation
@preconcurrency import AVFoundation
import CMUXMobileCore
import CmuxMobileAuth
import CmuxMobileDiagnostics
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileWorkspace
import Observation
import OSLog
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceShellView: View {
    @Bindable var store: CMUXMobileShellStore
    let signOut: () -> Void
    @State private var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var usesCompactStack: Bool {
        #if os(iOS)
        MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if usesCompactStack {
                stackLayout
            } else {
                splitLayout
            }
        }
        .onChange(of: usesCompactStack) { _, isCompact in
            guard isCompact, hasPresentedSplitDetail, let selectedWorkspaceID = store.selectedWorkspaceID else {
                return
            }
            compactNavigationPath = [selectedWorkspaceID]
        }
        .accessibilityIdentifier("MobileWorkspaceShell")
        .overlay(alignment: .top) {
            MobileConnectionRecoveryBanner(store: store)
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                navigationStyle: .push,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceInCompactStack,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut
            )
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(for: workspaceID, createWorkspace: createWorkspaceInCompactStack)
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID,
                existingWorkspaceIDs: pendingCompactCreateNavigationWorkspaceIDs
            ) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = createdPath
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            compactNavigationPath = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID
            )
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onChange(of: compactNavigationPath) { _, path in
            guard let selectedWorkspaceID = path.last,
                  store.selectedWorkspaceID != selectedWorkspaceID else {
                return
            }
            store.selectedWorkspaceID = selectedWorkspaceID
        }
        .onChange(of: store.workspaces.map(\.id)) { _, workspaceIDs in
            compactNavigationPath.removeAll { !workspaceIDs.contains($0) }
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onAppear {
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                navigationStyle: .sidebar,
                selectWorkspace: selectWorkspace,
                createWorkspace: store.createWorkspace,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: store.createWorkspace,
                safeAreaContext: splitColumnVisibility == .detailOnly ? .fullWidth : .splitSidebarVisible
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            hasPresentedSplitDetail = true
        }
    }

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        if usesCompactStack, compactNavigationPath.last != id {
            compactNavigationPath = [id]
        }
    }

    private func createWorkspaceInCompactStack() {
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        store.createWorkspace()
        if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        }
    }

    private func autoOpenSelectedWorkspaceForSoakIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE"] == "1",
              compactNavigationPath.isEmpty,
              let selectedWorkspaceID = store.selectedWorkspaceID,
              store.workspaces.contains(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        compactNavigationPath = [selectedWorkspaceID]
        #endif
    }

    @ViewBuilder
    private func workspaceDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        createWorkspace: @escaping () -> Void,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            safeAreaContext: safeAreaContext
        )
    }
}

enum WorkspaceNavigationStyle {
    case push
    case sidebar
}

private struct WorkspaceDetailContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let workspaceID: MobileWorkspacePreview.ID?
    let createWorkspace: () -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
        }
        return store.selectedWorkspace
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                host: store.connectedHostName,
                workspace: workspace,
                store: store,
                selectedTerminalID: Binding(
                    get: { store.selectedTerminalID },
                    set: { store.selectTerminal($0) }
                ),
                createWorkspace: createWorkspace,
                createTerminal: store.createTerminal,
                reportTerminalViewport: store.reportTerminalViewport,
                sendTerminalInput: store.sendTerminalRawInput,
                safeAreaContext: safeAreaContext
            )
            .onAppear {
                if store.selectedWorkspaceID != workspace.id {
                    store.selectedWorkspaceID = workspace.id
                }
            }
            .task(id: workspace.id) {
                await store.openWorkspace(workspace.id)
            }
        } else {
            ContentUnavailableView(
                L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"),
                systemImage: "rectangle.stack"
            )
        }
    }
}

struct WorkspaceListView: View {
    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let host: String
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    /// Optional: when present, the toolbar shows a "settings" menu offering
    /// "Rescan QR" (disconnect + re-pair) and "Sign out". When nil (e.g.
    /// previews), the menu is hidden.
    var rescanQR: (() -> Void)?
    var signOut: (() -> Void)?
    @State private var searchText = ""
    @State private var showingShortcutsSettings = false

    private var filteredWorkspaces: [MobileWorkspacePreview] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return workspaces
        }
        return workspaces.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(query)
                || workspace.previewLine.localizedCaseInsensitiveContains(query)
                || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredWorkspaces) { workspace in
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        host: host,
                        isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
                        navigationStyle: navigationStyle,
                        selectWorkspace: selectWorkspace
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                settingsMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                newWorkspaceButton
            }
            #else
            ToolbarItem {
                newWorkspaceButton
            }
            #endif
        }
        .accessibilityIdentifier("MobileWorkspaceList")
        #if os(iOS)
        .sheet(isPresented: $showingShortcutsSettings) {
            TerminalShortcutsSettingsView()
        }
        #endif
    }

    private var newWorkspaceButton: some View {
        Button(action: createWorkspace) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                showingShortcutsSettings = true
            } label: {
                Label(
                    L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceTerminalShortcutsMenuItem")
            #if os(iOS)
            Button {
                Task {
                    if MobilePushCoordinator.shared.isEnabled {
                        await MobilePushCoordinator.shared.disable()
                    } else {
                        _ = await MobilePushCoordinator.shared.enable()
                    }
                }
            } label: {
                Label(
                    MobilePushCoordinator.shared.isEnabled
                        ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications")
                        : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me About Agents"),
                    systemImage: MobilePushCoordinator.shared.isEnabled ? "bell.slash" : "bell"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceNotificationsMenuItem")
            #endif
            if let rescanQR {
                Button {
                    rescanQR()
                } label: {
                    Label(
                        L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceRescanQRMenuItem")
            }
            if let signOut {
                Button(role: .destructive) {
                    signOut()
                } label: {
                    Label(
                        L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceSignOutMenuItem")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
    }
}

private struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(workspace: workspace, host: host, isSelected: false)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    selectWorkspace(workspace.id)
                })
            case .sidebar:
                Button {
                    selectWorkspace(workspace.id)
                } label: {
                    WorkspaceRow(workspace: workspace, host: host, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.accessibilitySummary(host: host))
    }
}

struct WorkspaceRow: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceAvatar(workspace: workspace)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(host: host))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.statusColor)
                        .frame(width: 7, height: 7)

                    Text(workspace.detailLine(host: host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }
}

private struct WorkspaceAvatar: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        ZStack {
            Circle()
                .fill(workspace.avatarGradient)
                .frame(width: 48, height: 48)

            Image(systemName: workspace.avatarSymbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }
}

private extension MobileWorkspacePreview {
    var previewLine: String {
        terminals.first?.name ?? name
    }

    var statusColor: Color {
        terminals.isEmpty ? .orange : .green
    }

    var avatarSymbolName: String {
        terminals.count > 1 ? "rectangle.stack.fill" : "terminal.fill"
    }

    var avatarGradient: LinearGradient {
        let palettes: [[Color]] = [
            [Color.blue, Color.cyan],
            [Color.green, Color.teal],
            [Color.orange, Color.yellow],
            [Color.gray, Color.blue],
        ]
        let colors = palettes[abs(stableAvatarSeed) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func timestampOrStatus(host: String) -> String {
        let date = latestActivityDate
        guard date.timeIntervalSince1970 > 1 else {
            return host.isEmpty ? (terminals.first?.name ?? "") : host
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    func detailLine(host: String) -> String {
        let count = L10n.terminalCount(terminals.count)
        guard !host.isEmpty else {
            return count
        }
        return "\(host), \(count)"
    }

    func accessibilitySummary(host: String) -> String {
        "\(previewLine), \(detailLine(host: host))"
    }

    private var latestActivityDate: Date { .distantPast }

private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}

struct WorkspaceDetailView: View {
    let host: String
    let workspace: MobileWorkspacePreview
    @Bindable var store: CMUXMobileShellStore
    @Binding var selectedTerminalID: MobileTerminalPreview.ID?
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    @State private var isTerminalPickerPresented = false

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == selectedTerminalID } ?? workspace.terminals.first
    }

    var body: some View {
        detailContent()
    }

    private func detailContent() -> some View {
        // libghostty owns the bottom input accessory bar: it ships with
        // `GhosttySurfaceView`'s `inputAccessoryView` (see
        // `TerminalInputAccessoryAction`). The SwiftUI bar that used to
        // live here has been removed so the two stacked toolbars from
        // dogfood iosfin no longer fight for the same screen edge.
        Group {
            #if os(iOS)
            if let terminalID = selectedTerminal?.id.rawValue {
                GhosttySurfaceRepresentable(
                    surfaceID: terminalID,
                    store: store,
                    fontSize: MobileTerminalFontPreference.defaultSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TerminalPalette.background)
            } else {
                TerminalPalette.background
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            #else
            TerminalPalette.background
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: true
        )
        .background {
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        #else
        .background(TerminalPalette.background)
        #endif
        .navigationTitle(workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
            #else
            ToolbarItem {
                terminalToolbarButtons
            }
        #endif
        }
    }

    private func dismissKeyboard() {
        #if os(iOS)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
        terminalPickerToolbarButton
    }

    private var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    private var terminalPickerToolbarButton: some View {
        Button {
            dismissTerminalKeyboardForChrome()
            isTerminalPickerPresented = true
        } label: {
            Label(
                selectedTerminal?.name ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "terminal"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(host)
        .popover(isPresented: $isTerminalPickerPresented, arrowEdge: .top) {
            terminalPickerContent
        }
    }

    private var terminalPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(workspace.terminals) { terminal in
                Button {
                    selectTerminalFromPicker(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedTerminal?.id ? "checkmark.circle.fill" : "terminal"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }

            Divider()
                .padding(.vertical, 4)

            Button(action: createWorkspaceFromTerminalPicker) {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: createTerminalFromToolbar) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewTerminalMenuItem")

            #if DEBUG && canImport(UIKit)
            Button(action: copyDebugLogsFromMenu) {
                // DEV-only debug tooling; not shipped, so not localized.
                Label("Copy Debug Logs", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif
        }
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    #if DEBUG && canImport(UIKit)
    private func copyDebugLogsFromMenu() {
        isTerminalPickerPresented = false
        // Include "what the user sees" (the visible terminal text) above the
        // debug log so a pasted bug report shows the on-screen content too.
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        Task { @MainActor in
            let count = await MobileDebugLog.shared.copyToPasteboard(prepending: terminalText)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NSLog("cmux.terminal copied %d debug log lines + visible terminal to pasteboard", count)
        }
    }
    #endif

    private func createWorkspaceFromToolbar() {
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    private func createWorkspaceFromTerminalPicker() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createWorkspace()
    }

    private func createTerminalFromToolbar() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createTerminal()
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        selectedTerminalID = terminalID
    }

    private func dismissTerminalKeyboardForChrome() {
        dismissKeyboard()
    }
}
