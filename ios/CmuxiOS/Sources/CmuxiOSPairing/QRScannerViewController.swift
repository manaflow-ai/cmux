@preconcurrency import AVFoundation
import CmuxPairing
import CmuxiOSDesign
import UIKit

/// Camera preview that reports the first cmux pairing link it sees (B6;
/// replaces C10's placeholder viewfinder). Codes that are not cmux links are
/// ignored; a link with an unknown version is still reported so the caller
/// can ask for an app update.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onLink: ((URL) -> Void)?
    var onUnavailable: (() -> Void)?

    private let capture = QRCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let frameView = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = PairingScannerText.viewfinderLabel
        view.accessibilityTraits = .image
        guard capture.configure(delegate: self) else {
            onUnavailable?()
            return
        }
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        frameView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 24
        frameView.layer.cornerCurve = .continuous
        frameView.isUserInteractionEnabled = false
        view.addSubview(frameView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        let side = min(view.bounds.width, view.bounds.height) * 0.62
        frameView.frame = CGRect(x: (view.bounds.width - side) / 2, y: (view.bounds.height - side) / 2, width: side, height: side)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delivered = false
        capture.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        capture.stop()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated { self.consider(texts) }
    }

    private func consider(_ texts: [String]) {
        guard !delivered else { return }
        for text in texts {
            guard let url = URL(string: text), Self.isPairingLink(url) else { continue }
            delivered = true
            capture.stop()
            Haptics().play(.success)
            onLink?(url)
            return
        }
    }

    /// A cmux `pair`/`attach` link of any version (unknown versions get an update message later).
    static func isPairingLink(_ url: URL) -> Bool {
        do {
            _ = try PairingLink(url: url)
            return true
        } catch PairingLinkError.notPairingLink {
            return false
        } catch {
            return true
        }
    }
}
