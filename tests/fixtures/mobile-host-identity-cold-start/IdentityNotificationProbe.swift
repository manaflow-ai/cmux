import Darwin
import Foundation

/// Real synchronous main-queue delivery recreates the captured wait cycle:
/// the background writer cannot finish until this reentrant reader returns.
@MainActor
final class IdentityNotificationProbe {
    private let sharedURL: URL
    private let expected: String?
    private var observer: NSObjectProtocol?
    private var notificationValues: [String] = []
    private var wasReady: [Bool] = []

    init(sharedURL: URL, expected: String?) {
        self.sharedURL = sharedURL
        self.expected = expected
    }

    func observe() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      UserDefaults.standard.string(forKey: "mobileHost.deviceID") != nil else { return }
                let ready = MobileHostIdentity.deviceIDIfReady() != nil
                self.wasReady.append(ready)
                IdentityColdStartFixture.emit(["event": "defaults-observer-entered", "snapshot_ready": ready])
                self.notificationValues.append(MobileHostIdentity.deviceID())
                IdentityColdStartFixture.emit(["event": "defaults-observer-returned"])
            }
        }
    }

    func finish(values: [String]) -> Never {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let identity = values.first,
              UUID(uuidString: identity) != nil,
              identity == identity.lowercased(),
              values.count == 16,
              values.allSatisfy({ $0 == identity }),
              !notificationValues.isEmpty,
              notificationValues.allSatisfy({ $0 == identity }),
              wasReady.allSatisfy({ $0 }),
              MobileHostIdentity.deviceIDIfReady() == identity,
              UserDefaults.standard.string(forKey: "mobileHost.deviceID") == identity,
              (try? String(contentsOf: sharedURL, encoding: .utf8).lowercased()) == identity,
              expected == nil || expected == identity else {
            IdentityColdStartFixture.fail("snapshot, reentrant readers, or persisted identity disagreed")
        }
        IdentityColdStartFixture.emit([
            "result": "passed",
            "concurrent_readers": values.count,
            "reentrant_notifications": notificationValues.count,
            "canonical_shared_identity_preserved": true
        ])
        exit(0)
    }
}
