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
    @State private var isShowingScanner = false

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
