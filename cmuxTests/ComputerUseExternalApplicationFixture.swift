import AppKit
import Foundation

/// Owns a real external application instance for AppKit computer-use tests.
@MainActor
final class ComputerUseExternalApplicationFixture {
    private enum LaunchError: Error {
        case noApplicationBundle
        case failedToLaunch(underlying: Error?)
        case missingLaunchDate
    }

    let application: NSRunningApplication

    /// Launches a hidden, non-activating instance through LaunchServices.
    ///
    /// The instance is intentionally real rather than a fabricated
    /// ``NSRunningApplication``: the watcher validates the PID, bundle ID,
    /// launch date, and localized name through AppKit before it can activate
    /// an application.
    init() async throws {
        let applicationURL = try Self.applicationURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.hidesOthers = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false

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
        guard application.launchDate != nil else {
            _ = application.forceTerminate()
            throw LaunchError.missingLaunchDate
        }
        self.application = application
    }

    /// Terminates the exact process this fixture launched.
    func terminate() {
        guard !application.isTerminated else { return }
        _ = application.forceTerminate()
    }

    private static func applicationURL() throws -> URL {
        let candidates = [
            "/System/Applications/TextEdit.app",
            "/System/Applications/Calculator.app",
            "/System/Library/CoreServices/Finder.app",
        ]
        guard let path = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            throw LaunchError.noApplicationBundle
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
