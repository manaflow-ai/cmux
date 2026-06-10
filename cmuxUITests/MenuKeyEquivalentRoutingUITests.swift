import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin

extension MenuKeyEquivalentRoutingUITests {
    func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

extension SplitCloseRightBlankRegressionUITests {
    func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

final class MenuKeyEquivalentRoutingUITests: XCTestCase {
    var gotoSplitPath = ""
    var keyequivPath = ""
    var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        gotoSplitPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        keyequivPath = "/tmp/cmux-ui-test-keyequiv-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"

        try? FileManager.default.removeItem(atPath: gotoSplitPath)
        try? FileManager.default.removeItem(atPath: keyequivPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

}

final class SplitCloseRightBlankRegressionUITests: XCTestCase {
    var dataPath = ""
    var socketPath = ""
    var diagnosticsPath = ""
    var screenshotDir = ""
    var socketClient: ControlSocketClient?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        dataPath = "/tmp/cmux-ui-test-split-close-right-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-diagnostics-\(UUID().uuidString).json"
        // Prefer a globally accessible dir so we can pull screenshots from the VM for debugging.
        // If sandbox rules prevent this, fall back to the runner's container temp dir.
        let leaf = "cmux-ui-test-split-close-right-shots-\(UUID().uuidString)"
        let preferredURL = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(leaf)
        let fallbackURL = FileManager.default.temporaryDirectory.appendingPathComponent(leaf)
        // Attempt to create the preferred dir; if it fails, use fallback.
        if (try? FileManager.default.createDirectory(at: preferredURL, withIntermediateDirectories: true)) != nil {
            screenshotDir = preferredURL.path
        } else {
            screenshotDir = fallbackURL.path
        }
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: screenshotDir)
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
    }

    final class ControlSocketClient {
        private let path: String

        init(path: String) {
            self.path = path
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var addr = sockaddr_un()
            // Zero-init is important because we compute a variable sockaddr length and
            // the kernel may validate `sun_len` on some macOS versions.
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString) // includes null terminator
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            // Darwin expects a sockaddr length that includes only the fields up to the pathname.
            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            // `sun_len` exists on Darwin/BSD.
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard ok == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
