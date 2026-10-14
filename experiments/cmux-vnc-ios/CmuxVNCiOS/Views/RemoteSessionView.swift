import CmuxVNC
import CmuxVNCWebRTC
import SwiftUI

/// A full-screen session: the remote screen plus light chrome that stays
/// out of the way (a top bar to hide, live stats, and state cards).
struct RemoteSessionView: View {
    @Bindable var session: RemoteSession
    let close: () -> Void
    @State private var keyboardVisible = false
    @State private var chromeVisible = true
    @State private var signInUser = ""
    @State private var signInPassword = ""
    @State private var orientation = OrientationLock.saved
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            RemoteScreen(session: session, fitToDisplay: session.preferences.fitToDisplay, keyboardVisible: $keyboardVisible)
                .ignoresSafeArea()
            if chromeVisible {
                VStack(spacing: 6) {
                    topBar
                    if case .connected = session.phase { MacShortcutsBar(session: session) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            stateCard
        }
        .background(.black)
        // Remote screens sit on black: dark chrome keeps the bar and stats legible.
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear { AppDelegate.lock(orientation.mask) }
        .onChange(of: orientation) {
            OrientationLock.saved = orientation
            AppDelegate.lock(orientation.mask)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { session.resumeIfNeeded() }
        }
        .onChange(of: session.preferences.quality) { session.applyQuality() }
        .onDisappear {
            AppDelegate.lock(.all)
            session.close()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Close", systemImage: "xmark") {
                session.close()
                close()
            }
            .labelStyle(.iconOnly)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if session.preferences.showStats, case .connected = session.phase { stats }
            }
            Spacer(minLength: 8)
            Menu {
                Toggle("Fit to Display", systemImage: "rectangle.dashed", isOn: $session.preferences.fitToDisplay)
                Picker("Orientation", systemImage: orientation.symbol, selection: $orientation) {
                    ForEach(OrientationLock.allCases) { lock in Label(lock.title, systemImage: lock.symbol).tag(lock) }
                }
                .pickerStyle(.menu)
                if session.isStream {
                    Picker("Quality", systemImage: "dial.medium", selection: $session.preferences.quality) {
                        ForEach(ScreenQuality.allCases) { quality in Text(quality.title).tag(quality) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Stream stats", isOn: $session.preferences.showStats)
                Section("Send") {
                    Button("Control-Option-Delete", systemImage: "command") { session.tap(.deleteForward, modifiers: [.control, .option]) }
                    Button("Command-Tab", systemImage: "rectangle.stack") { session.tap(.tab, modifiers: [.command]) }
                    Button("Command-Space", systemImage: "magnifyingglass") { session.tap(.space, modifiers: [.command]) }
                    Button("Escape", systemImage: "escape") { session.tap(.escape) }
                }
                Button("Refresh Screen", systemImage: "arrow.clockwise") { session.refresh() }
                Button("Hide Toolbar", systemImage: "chevron.up") { withAnimation { chromeVisible = false } }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            Button("Keyboard", systemImage: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                keyboardVisible.toggle()
            }
            .labelStyle(.iconOnly)
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .overlay(alignment: .bottom) { EmptyView() }
    }

    private var stats: some View {
        let s = session.stats
        let latency = s.latencyMs.map { String(format: "%.0f ms", $0) } ?? "–"
        return Text(session.pathLabel + String(format: " · %.0f fps · %.0f KB/s · ", s.fps, s.kilobytesPerSecond) + latency + " · " + s.encoding)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var stateCard: some View {
        switch session.phase {
        case .connecting:
            card {
                ProgressView()
                Text(session.isReconnecting ? "Reconnecting to \(session.title)…" : "Connecting to \(session.title)…").font(.headline)
            }
        case let .failed(message, needsSignIn):
            card {
                Image(systemName: needsSignIn ? "lock" : "exclamationmark.triangle").font(.largeTitle)
                Text(needsSignIn ? "Sign in to \(session.title)" : "Could not connect").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if needsSignIn {
                    TextField("User name (Mac only)", text: $signInUser)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $signInPassword)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }
                HStack {
                    Button("Close") {
                        session.close()
                        close()
                    }
                    .buttonStyle(.bordered)
                    Button(needsSignIn ? "Sign In" : "Try Again", action: needsSignIn ? signIn : { session.connect() })
                        .buttonStyle(.borderedProminent)
                }
            }
            .onAppear { signInUser = session.credentials.username ?? "" }
        case .ended:
            card {
                Image(systemName: "stop.circle").font(.largeTitle)
                Text("Session ended").font(.headline)
                HStack {
                    Button("Close") { close() }.buttonStyle(.bordered)
                    Button("Reconnect") { session.connect() }.buttonStyle(.borderedProminent)
                }
            }
        case .connected:
            if !chromeVisible {
                Button("Show Toolbar", systemImage: "chevron.down") { withAnimation { chromeVisible = true } }
                    .labelStyle(.iconOnly)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.top, 4)
            }
        }
    }

    private func signIn() {
        session.credentials = VNCCredentials(username: signInUser, password: signInPassword)
        session.connect()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(22)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts `RemoteScreenViewController` in SwiftUI.
struct RemoteScreen: UIViewControllerRepresentable {
    let session: RemoteSession
    let fitToDisplay: Bool
    @Binding var keyboardVisible: Bool

    func makeUIViewController(context: Context) -> RemoteScreenViewController {
        RemoteScreenViewController(session: session)
    }

    func updateUIViewController(_ controller: RemoteScreenViewController, context: Context) {
        controller.fitToDisplay = fitToDisplay
        if controller.isKeyboardVisible != keyboardVisible { controller.isKeyboardVisible = keyboardVisible }
    }
}
