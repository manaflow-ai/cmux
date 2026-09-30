import XCTest
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A main-frame navigation's policy decision waits for the local-file encoding
/// probe. On loaded fleet Macs that probe, a utility-priority task on the Swift
/// cooperative pool, did not run for 9-17 s while WebKit and the main actor
/// stayed responsive, so first file navigations never committed (#15488). This
/// holds that condition deterministically: the pool admits no work at any
/// priority while a fresh panel opens a local file.
///
/// This is an XCTest case because its body runs on the main thread; a Swift
/// Testing body would need the very pool it fills.
@MainActor
final class BrowserLocalFileNavigationSchedulingTests: XCTestCase {
    func testFirstLocalFileNavigationCommitsWhileTheCooperativePoolIsFull() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-probe-scheduling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.md")
        try Data("# 산책의 즐거움".utf8).write(to: fileURL)

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        let saturation = CooperativePoolSaturation()
        defer { saturation.release() }
        let admitting = saturation.fill(blockers: ProcessInfo.processInfo.activeProcessorCount * 2)
        XCTAssertTrue(admitting.isEmpty, "the cooperative pool still admitted work at \(admitting)")

        panel.navigate(to: fileURL)

        // WebKit state only: the panel's own loading flag settles through a
        // clock sleep, which is not what this test measures.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if panel.webView.url?.absoluteString == fileURL.absoluteString,
               panel.webView.backForwardList.currentItem?.url.absoluteString == fileURL.absoluteString,
               !panel.webView.isLoading {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTFail(
            "A local-file navigation must not wait for the cooperative pool to commit. "
                + "Live=\(panel.webView.url?.absoluteString ?? "nil") "
                + "Committed=\(panel.webView.backForwardList.currentItem?.url.absoluteString ?? "nil") "
                + "webViewLoading=\(panel.webView.isLoading)"
        )
    }
}

/// Parks tasks at every priority on the Swift cooperative pool until `release()`.
private final class CooperativePoolSaturation {
    private static let priorities: [TaskPriority] = [
        TaskPriority(rawValue: 0x21), .userInitiated, .medium, .utility, .background,
    ]
    private let gate = DispatchSemaphore(value: 0)

    /// Parks `blockers` tasks at each priority, then returns the priorities at
    /// which a later task still started. Empty means the pool admits nothing.
    func fill(blockers: Int) -> [TaskPriority] {
        let gate = gate
        for priority in Self.priorities {
            for _ in 0..<blockers {
                Task.detached(priority: priority) { holdCooperativeThread(until: gate) }
            }
        }
        let canaries = Self.priorities.map { priority -> (TaskPriority, DispatchSemaphore) in
            let started = DispatchSemaphore(value: 0)
            Task.detached(priority: priority) { started.signal() }
            return (priority, started)
        }
        let deadline = DispatchTime.now() + .milliseconds(500)
        return canaries.filter { $0.1.wait(timeout: deadline) == .success }.map { $0.0 }
    }

    /// Lets every parked and queued task finish; each one wakes the next.
    func release() {
        gate.signal()
    }
}

/// Holds one cooperative thread until `gate` opens, then passes the gate on.
private func holdCooperativeThread(until gate: DispatchSemaphore) {
    gate.wait()
    gate.signal()
}
