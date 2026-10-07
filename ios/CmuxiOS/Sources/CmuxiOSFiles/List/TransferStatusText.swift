import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import Foundation

/// The status line of a transfer row, localized.
struct TransferStatusText {
    let item: TransferItem

    var text: String {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let done = bytes.string(fromByteCount: item.progress.completedBytes)
        let total = item.progress.totalBytes.map { bytes.string(fromByteCount: $0) }
        switch item.progress.state {
        case .running:
            let amount = total.map {
                String(localized: "files.status.ofTotal", defaultValue: "\(done) of \($0)", bundle: .module)
            } ?? done
            guard let rate = item.bytesPerSecond, rate > 0 else { return amount }
            let speed = bytes.string(fromByteCount: Int64(rate))
            return String(localized: "files.status.speed", defaultValue: "\(amount), \(speed)/s", bundle: .module)
        case .paused:
            return String(localized: "files.status.paused", defaultValue: "Paused at \(done). Tap to resume.", bundle: .module)
        case .finished:
            if let path = item.progress.remotePath {
                return String(localized: "files.status.savedAt", defaultValue: "Saved on the Mac at \(path)", bundle: .module)
            }
            return String(localized: "files.status.finished", defaultValue: "Done", bundle: .module)
        case .cancelled:
            return String(localized: "files.status.cancelled", defaultValue: "Cancelled", bundle: .module)
        case .failed(let reason):
            return Self.failure(reason)
        }
    }

    static func failure(_ code: String) -> String {
        switch code {
        case "files.forbidden":
            String(localized: "files.error.forbidden", defaultValue: "The Mac does not share this location.", bundle: .module)
        case "files.not_found":
            String(localized: "files.error.notFound", defaultValue: "The file is no longer there.", bundle: .module)
        case "files.too_large":
            String(localized: "files.error.tooLarge", defaultValue: "The file is too large for the Mac to accept.", bundle: .module)
        case "files.digest_mismatch":
            String(localized: "files.error.digest", defaultValue: "The file changed in transit. Try again.", bundle: .module)
        case "files.dest_invalid":
            String(localized: "files.error.dest", defaultValue: "The destination folder is not available.", bundle: .module)
        case "link.unsupportedOnPath":
            String(localized: "files.error.relay", defaultValue: "File transfer needs a direct connection to the Mac.", bundle: .module)
        default:
            String(localized: "files.error.generic", defaultValue: "The transfer stopped.", bundle: .module)
        }
    }
}
