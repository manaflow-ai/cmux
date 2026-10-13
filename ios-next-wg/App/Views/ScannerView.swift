@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR scanner: a rounded camera viewport with corner guides.
struct ScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    if denied {
                        VStack(spacing: 10) {
                            Image(systemName: "camera.fill").font(.title)
                            Text("Allow camera access in Settings to scan the code.")
                                .multilineTextAlignment(.center)
                                .font(.subheadline)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        .foregroundStyle(.secondary)
                        .padding(30)
                    } else {
                        CameraPreview(onCode: onCode, onDenied: { denied = true })
                    }
                    CornerGuides()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .padding(28)
                }
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.white.opacity(0.06)))
                Text("Scan the code on your Mac")
                    .font(.title3.weight(.semibold))
                Text("In cmux on your Mac, open the command palette and choose Open Mobile Pairing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
                Button {
                    if let text = UIPasteboard.general.string { onCode(text) }
                } label: {
                    Text("Paste link instead")
                        .font(.headline)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            VStack {
                HStack {
                    GlassCircleButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                    Spacer()
                }
                .padding(.horizontal, 20)
                Spacer()
            }
        }
    }
}

/// Four corner brackets inside a rect.
struct CornerGuides: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 34
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// The camera feed; reports the first QR code it reads.
struct CameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        let coordinator = context.coordinator
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted else { return onDenied() }
                coordinator.start(on: view)
            }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let onCode: (String) -> Void
        private let queue = DispatchQueue(label: "cmux.next.scanner")
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        @MainActor func start(on view: PreviewView) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            view.previewLayer.session = session
            let session = session
            queue.async { session.startRunning() }
        }

        func stop() {
            let session = session
            queue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered, let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue,
                  code.hasPrefix("cmux-next://") else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stop()
            onCode(code)
        }
    }
}
