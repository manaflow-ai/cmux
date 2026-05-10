import Foundation
@preconcurrency import AVFoundation
import CMUXMobileSyncCore
import Observation
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#endif

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
    @State private var email = ""
    @State private var code = ""
    @State private var isShowingCodeEntry = false
    @State private var error: String?
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    authCard {
                        if isShowingCodeEntry {
                            codeEntryView
                        } else {
                            emailEntryView
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var emailEntryView: some View {
        VStack(spacing: 20) {
            brandHeader

            Button(action: providerSignIn) {
                Label(L10n.string("mobile.signIn.apple", defaultValue: "Sign in with Apple"), systemImage: "apple.logo")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("MobileSignInButton")

            Button(action: providerSignIn) {
                HStack(spacing: 8) {
                    Image("GoogleLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(L10n.string("mobile.signIn.google", defaultValue: "Sign in with Google"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("signin.google")

            DividerLabel(text: L10n.string("mobile.signIn.emailDivider", defaultValue: "or continue with email"))

            VStack(spacing: 12) {
                MobileAuthInputPill(height: 50, alignment: .leading) {
                    TextField(
                        L10n.string("mobile.signIn.emailPlaceholder", defaultValue: "Email address"),
                        text: $email
                    )
                    .textFieldStyle(.plain)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFocused)
                    .accessibilityIdentifier("Email")
                } onTap: {
                    emailFocused = true
                }

                Button(action: continueWithEmail) {
                    Text(L10n.string("mobile.signIn.emailCode", defaultValue: "Email me a code"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule())
                }
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("signin.emailCode")
            }

            if let error {
                errorText(error)
            }
        }
    }

    private var codeEntryView: some View {
        VStack(spacing: 18) {
            brandHeader

            VStack(spacing: 6) {
                Text(L10n.string("mobile.signIn.checkEmail", defaultValue: "Check your email"))
                    .font(.headline)

                Text(String(format: L10n.string("mobile.signIn.sentCodeFormat", defaultValue: "We sent a code to %@"), email))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            MobileAuthInputPill(height: 60, alignment: .center) {
                TextField(L10n.string("mobile.signIn.codePlaceholder", defaultValue: "000000"), text: $code)
                    .textFieldStyle(.plain)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .focused($codeFocused)
                    .onChange(of: code) { _, newValue in
                        if newValue.count > 6 {
                            code = String(newValue.prefix(6))
                        }
                        if newValue.count == 6 {
                            verifyCode()
                        }
                    }
                    .accessibilityIdentifier("signin.code")
            } onTap: {
                codeFocused = true
            }
            .onAppear {
                codeFocused = true
            }

            if let error {
                errorText(error)
            }

            Button(action: verifyCode) {
                Text(L10n.string("mobile.signIn.verifyCode", defaultValue: "Verify code"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule())
            }
            .disabled(code.count != 6)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("signin.verifyCode")

            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isShowingCodeEntry = false
                    code = ""
                    error = nil
                }
            } label: {
                Text(L10n.string("mobile.signIn.useDifferentEmail", defaultValue: "Use a different email"))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func providerSignIn() {
        error = nil
        signIn()
    }

    private func continueWithEmail() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") else {
            error = L10n.string("mobile.signIn.emailError", defaultValue: "Please enter a valid email address.")
            return
        }

        email = trimmedEmail
        error = nil
        withAnimation(.snappy(duration: 0.18)) {
            isShowingCodeEntry = true
        }
    }

    private func verifyCode() {
        guard code.count == 6 else {
            error = L10n.string("mobile.signIn.codeError", defaultValue: "Enter the 6-digit code from your email.")
            return
        }

        error = nil
        signIn()
    }

    private func authCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 24)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            )
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("CmuxLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(L10n.string("mobile.signIn.title", defaultValue: "cmux"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct DividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            dividerLine
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .layoutPriority(1)
            dividerLine
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.4))
            .frame(height: 1)
    }
}

private struct GameOfLifeHeader: View {
    private let columns = 36
    private let rows = 52
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameOfLifeGrid(columns: columns, rows: rows)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)

                LinearGradient(
                    colors: [
                        Color(.systemBackground).opacity(0),
                        Color(.systemBackground).opacity(colorScheme == .dark ? 0.82 : 0.70),
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }
}

private struct GameOfLifeGrid: View {
    let columns: Int
    let rows: Int

    @State private var cells: [Bool] = []
    @State private var stepCount = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tick = Int(time / 0.08)

            GeometryReader { _ in
                Canvas { context, size in
                    let cellWidth = size.width / CGFloat(columns)
                    let cellHeight = size.height / CGFloat(rows)
                    let cellSize = min(cellWidth, cellHeight) * 0.52
                    let yOffset = (cellHeight - cellSize) * 0.5
                    let xOffset = (cellWidth - cellSize) * 0.5
                    let scale = max(1, displayScale)

                    func snapToPixel(_ value: CGFloat) -> CGFloat {
                        (value * scale).rounded(.toNearestOrAwayFromZero) / scale
                    }

                    for row in 0..<rows {
                        for col in 0..<columns where isAlive(row: row, col: col) {
                            let baseOpacity = colorScheme == .dark ? 0.10 : 0.16
                            let flicker = baseOpacity + 0.10 * sin(time * 2.0 + Double(row * 3 + col) * 0.22)
                            let rect = CGRect(
                                x: snapToPixel(CGFloat(col) * cellWidth + xOffset),
                                y: snapToPixel(CGFloat(row) * cellHeight + yOffset),
                                width: snapToPixel(cellSize),
                                height: snapToPixel(cellSize)
                            )
                            let base = Color(colorScheme == .dark ? UIColor.systemGray4 : UIColor.systemGray2)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: rect.width * 0.5),
                                with: .color(base.opacity(max(0, flicker)))
                            )
                        }
                    }
                }
            }
            .onChange(of: tick) { _, _ in
                step()
            }
            .onAppear {
                if cells.isEmpty {
                    seed()
                }
            }
        }
    }

    private func index(row: Int, col: Int) -> Int {
        row * columns + col
    }

    private func isAlive(row: Int, col: Int) -> Bool {
        let wrappedRow = (row + rows) % rows
        let wrappedCol = (col + columns) % columns
        let idx = index(row: wrappedRow, col: wrappedCol)
        if idx < cells.count {
            return cells[idx]
        }
        return false
    }

    private func seed() {
        var rng = SystemRandomNumberGenerator()
        cells = (0..<(rows * columns)).map { _ in
            Double.random(in: 0...1, using: &rng) < 0.22
        }
        stepCount = 0
    }

    private func step() {
        guard !cells.isEmpty else {
            seed()
            return
        }

        var next = cells
        var aliveCount = 0

        for row in 0..<rows {
            for col in 0..<columns {
                let idx = index(row: row, col: col)
                let neighbors = neighborCount(row: row, col: col)
                let alive = cells[idx]
                let nextAlive = (alive && (neighbors == 2 || neighbors == 3)) || (!alive && neighbors == 3)
                next[idx] = nextAlive
                if nextAlive {
                    aliveCount += 1
                }
            }
        }

        stepCount += 1

        if aliveCount < max(6, (rows * columns) / 22) || stepCount > 120 {
            seed()
            return
        }

        cells = next
    }

    private func neighborCount(row: Int, col: Int) -> Int {
        var count = 0
        for dr in -1...1 {
            for dc in -1...1 {
                if dr == 0 && dc == 0 {
                    continue
                }
                if isAlive(row: row + dr, col: col + dc) {
                    count += 1
                }
            }
        }
        return count
    }
}

private struct MobileAuthInputPill<Content: View>: View {
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    let onTap: () -> Void

    init(
        height: CGFloat,
        alignment: Alignment,
        @ViewBuilder content: () -> Content,
        onTap: @escaping () -> Void
    ) {
        self.height = height
        self.alignment = alignment
        self.content = content()
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct PairingView: View {
    @Binding var pairingCode: String
    let connect: () -> Void
    let signOut: () -> Void
    @State private var isShowingScanner = false
    @FocusState private var isPairingCodeFocused: Bool

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
                        isShowingScanner = true
                    } label: {
                        Label(L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code"), systemImage: "camera.viewfinder")
                    }
                    .accessibilityIdentifier("MobileScanQRCodeButton")

                    TextField(
                        L10n.string("mobile.pairing.codePlaceholder", defaultValue: "Pairing code"),
                        text: $pairingCode
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isPairingCodeFocused)
                    .onTapGesture {
                        isPairingCodeFocused = true
                    }
                    .accessibilityIdentifier("MobilePairingCodeField")

                    Button(action: connect) {
                        Label(L10n.string("mobile.pairing.connect", defaultValue: "Connect"), systemImage: "link")
                    }
                    .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("MobileConnectButton")
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.navigationTitle", defaultValue: "Pairing"))
            .sheet(isPresented: $isShowingScanner) {
                MobilePairingScannerSheet { scannedCode in
                    pairingCode = scannedCode
                    isShowingScanner = false
                    connect()
                }
            }
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

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    QRCodeScannerView { code in
                        onCode(code)
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .notDetermined:
                    ProgressView()
                        .task {
                            await requestCameraAccess()
                        }
                case .denied, .restricted:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                        systemImage: "camera.fill"
                    )
                @unknown default:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                        systemImage: "camera.fill"
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"))
                    }
                    .accessibilityIdentifier("MobileScannerCancelButton")
                }
            }
        }
    }

    @MainActor
    private func requestCameraAccess() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        authorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private var didScan = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  metadata.type == .qr,
                  let value = metadata.stringValue,
                  value.hasPrefix("cmux-ios://") else {
                return
            }
            didScan = true
            onCode(value)
        }
    }
}

final class QRCodeScannerViewController: UIViewController {
    private let coordinator: QRCodeScannerView.Coordinator
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.cmux.mobile.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    init(coordinator: QRCodeScannerView.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            showUnavailable()
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(coordinator, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true
    }

    private func startSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func stopSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable")
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
#else
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void

    var body: some View {
        ContentUnavailableView(
            L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
            systemImage: "camera.fill"
        )
    }
}
#endif

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
                    terminalInputText: $store.terminalInputText,
                    createWorkspace: store.createWorkspace,
                    createTerminal: store.createTerminal,
                    sendTerminalInput: store.sendTerminalInput
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
    @Binding var terminalInputText: String
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let sendTerminalInput: () -> Void

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

            Divider()

            TerminalInputBar(
                text: $terminalInputText,
                send: sendTerminalInput
            )
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

struct TerminalInputBar: View {
    @Binding var text: String
    let send: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField(
                L10n.string("mobile.terminal.inputPlaceholder", defaultValue: "Send to terminal"),
                text: $text
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .onSubmit(send)
            .focused($isInputFocused)
            .onTapGesture {
                isInputFocused = true
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("MobileTerminalInputField")

            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(L10n.string("mobile.terminal.send", defaultValue: "Send"))
            .accessibilityIdentifier("MobileTerminalSendButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct TerminalPreviewSurface: View {
    let terminal: MobileTerminalPreview?
    let workspace: MobileWorkspacePreview

    private var renderedLines: [String] {
        terminal?.lines ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(renderedLines.indices, id: \.self) { index in
                    Text(renderedLines[index])
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
