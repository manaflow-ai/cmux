import Darwin
import Foundation

extension CLISSHPTYResizeInputTests {
    /// Waits for output forwarded after the CLI installs its terminal input mode.
    /// A server-side ready write is too early: the CLI's TCSAFLUSH can still
    /// discard test input queued before the actual forwarding boundary.
    func waitForForwardingOutput(_ masterFD: Int32) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        let marker = Data("input-resize-ready".utf8)
        while output.count < 4096 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: masterFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { return false }
            let count = Darwin.read(masterFD, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            output.append(contentsOf: bytes.prefix(count))
            if output.range(of: marker) != nil { return true }
        }
        return false
    }
}
