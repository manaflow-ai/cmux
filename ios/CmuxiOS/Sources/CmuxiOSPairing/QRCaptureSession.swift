@preconcurrency import AVFoundation
import Foundation

/// Owns the capture session; start and stop run on its own serial queue
/// (AVFoundation blocks the caller while the camera spins up).
final class QRCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.cmux.ios.pairing.qr-capture")
    private var configured = false

    /// Adds the back camera and a QR metadata output. False when no camera is available.
    func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        guard !configured else { return true }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return false }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        session.commitConfiguration()
        configured = true
        return true
    }

    func start() {
        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}
