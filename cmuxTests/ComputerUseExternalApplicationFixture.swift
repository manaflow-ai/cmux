import AppKit
import Foundation

/// Owns a real external application instance for AppKit computer-use tests.
@MainActor
final class ComputerUseExternalApplicationFixture {
    private enum LaunchError: Error {
        case noApplicationBundle(URL)
        case failedToLaunch(underlying: Error?)
        case reusedApplication
        case incompleteIdentity
    }

    let application: NSRunningApplication

    /// Launches a hidden, non-activating instance through LaunchServices.
    ///
    /// The instance is intentionally real rather than a fabricated
    /// ``NSRunningApplication``: the watcher validates the PID, bundle ID,
    /// launch date, and localized name through AppKit before it can activate
    /// an application.
    init(applicationURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw LaunchError.noApplicationBundle(applicationURL)
        }
        let existingProcessIdentifiers = Set(
            NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.hidesOthers = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]

        let application = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                guard let application else {
                    continuation.resume(throwing: LaunchError.failedToLaunch(
                        underlying: error
                    ))
                    return
                }
                continuation.resume(returning: application)
            }
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !existingProcessIdentifiers.contains(application.processIdentifier) else {
            // A reused application belongs to someone else; never terminate it.
            throw LaunchError.reusedApplication
        }
        guard !application.isTerminated,
              application.launchDate != nil,
              application.bundleIdentifier?.isEmpty == false,
              application.localizedName?.isEmpty == false else {
            _ = application.forceTerminate()
            throw LaunchError.incompleteIdentity
        }
        self.application = application
    }

    /// Terminates the exact process this fixture launched.
    func terminate() {
        guard !application.isTerminated else { return }
        _ = application.forceTerminate()
    }
}
