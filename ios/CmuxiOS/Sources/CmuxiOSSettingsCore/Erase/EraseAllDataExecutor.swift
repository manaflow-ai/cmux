import Foundation

/// Runs an `EraseAllDataPlan`: each item independently, so one failure
/// never stops the rest; failures are collected for the final screen.
/// Directory items remove only direct children of the listed directory.
public struct EraseAllDataExecutor: Sendable {
    let keychain: any KeychainWiping
    let files: any FileWiping
    let defaults: any DefaultsWiping

    public init(keychain: any KeychainWiping, files: any FileWiping, defaults: any DefaultsWiping) {
        self.keychain = keychain
        self.files = files
        self.defaults = defaults
    }

    public func run(_ plan: EraseAllDataPlan) -> EraseReport {
        var report = EraseReport()
        for item in plan.items {
            do {
                try erase(item)
            } catch {
                report.failures.append(EraseReport.Failure(item: item, reason: Self.reason(error)))
            }
        }
        return report
    }

    private func erase(_ item: EraseItem) throws {
        switch item {
        case .keychain(let itemClass):
            try keychain.deleteAll(itemClass)
        case .directoryContents(let directory):
            guard files.exists(directory) else { return }
            var firstError: (any Error)?
            for child in try files.children(of: directory) {
                do { try files.remove(child) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        case .folder(let folder):
            guard files.exists(folder) else { return }
            try files.remove(folder)
        case .defaultsDomain(let name):
            defaults.removeDomain(name)
        case .defaultsKeys(let suite, let prefix):
            defaults.removeKeys(suite: suite, prefix: prefix)
        }
    }

    static func reason(_ error: any Error) -> String {
        if let keychain = error as? SecurityKeychainWiper.Failure { return "keychain \(keychain.status)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
