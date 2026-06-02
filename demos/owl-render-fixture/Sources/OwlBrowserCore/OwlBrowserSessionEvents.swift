import Foundation
import OwlMojoBindingsGenerated

public struct OwlBrowserSessionEventSnapshot: Codable {
    public let ready: Bool
    public let disconnected: Bool
    public let contextID: UInt32
    public let contextGeneration: UInt64
    public let hostPID: Int32
    public let loading: Bool
    public let url: String
    public let title: String
    public let surfaceTree: OwlFreshSurfaceTree?
    public let logs: [String]
}

private struct OwlFreshEvent {
    let kind: Int32
    let contextID: UInt32
    let hostPID: Int32
    let loading: Bool
    let url: UnsafePointer<CChar>?
    let title: UnsafePointer<CChar>?
    let message: UnsafePointer<CChar>?
}

public typealias OwlFreshEventCallback = @convention(c) (
    UnsafeRawPointer?,
    UnsafeMutableRawPointer?
) -> Void

public final class OwlBrowserSessionEvents {
    private let lock = NSLock()
    private var ready = false
    private var disconnected = false
    private var contextID: UInt32 = 0
    private var contextGeneration: UInt64 = 0
    private var hostPID: Int32 = -1
    private var loading = true
    private var url = ""
    private var title = ""
    private var surfaceTree: OwlFreshSurfaceTree?
    private var logs: [String] = []

    public init() {}

    fileprivate func record(_ event: OwlFreshEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event.kind {
        case 1:
            if let message = event.message {
                logs.append(String(cString: message))
                if logs.count > 30 {
                    logs.removeFirst(logs.count - 30)
                }
            }
        case 2:
            ready = true
            hostPID = event.hostPID
            updateContextID(event.contextID)
        case 3:
            updateContextID(event.contextID)
        case 4:
            loading = event.loading
            if let eventURL = event.url {
                url = String(cString: eventURL)
            }
            if let eventTitle = event.title {
                title = String(cString: eventTitle)
            }
        case 5:
            disconnected = true
        case 6:
            if let message = event.message,
               let data = String(cString: message).data(using: .utf8),
               let tree = try? JSONDecoder().decode(OwlFreshSurfaceTree.self, from: data) {
                surfaceTree = tree
            }
        default:
            break
        }
    }

    public func snapshot() -> OwlBrowserSessionEventSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return OwlBrowserSessionEventSnapshot(
            ready: ready,
            disconnected: disconnected,
            contextID: contextID,
            contextGeneration: contextGeneration,
            hostPID: hostPID,
            loading: loading,
            url: url,
            title: title,
            surfaceTree: surfaceTree,
            logs: logs
        )
    }

    private func updateContextID(_ id: UInt32) {
        guard id != 0 else {
            return
        }
        contextID = id
        contextGeneration += 1
    }
}

let owlFreshEventCallback: OwlFreshEventCallback = { eventPointer, userData in
    guard let eventPointer, let userData else {
        return
    }
    let events = Unmanaged<OwlBrowserSessionEvents>.fromOpaque(userData).takeUnretainedValue()
    events.record(eventPointer.assumingMemoryBound(to: OwlFreshEvent.self).pointee)
}
