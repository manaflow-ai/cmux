import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the global font magnification for this test process only.
///
/// Writing `GlobalFontMagnification.percentKey` to `UserDefaults.standard`
/// persists through cfprefsd to every process that shares the app-host
/// defaults domain, including the app hosts of other shards on the same
/// runner. An app host that launches while such a write is in place applies
/// that magnification to its terminals for its whole life. The argument domain
/// is volatile and outranks the persistent domain, so a pin there is seen by
/// every reader in this process, `@AppStorage` included, and by no other
/// process.
@MainActor
struct ProcessLocalGlobalFontMagnification {
    private let originalArgumentDomain: [String: Any]

    /// Pins `percent` until ``restore()``.
    init(percent: Int) {
        originalArgumentDomain = UserDefaults.standard.volatileDomain(
            forName: UserDefaults.argumentDomain
        )
        set(percent)
    }

    /// Replaces the pinned percent.
    func set(_ percent: Int) {
        var pinned = originalArgumentDomain
        pinned[GlobalFontMagnification.percentKey] = percent
        UserDefaults.standard.setVolatileDomain(
            pinned,
            forName: UserDefaults.argumentDomain
        )
    }

    /// Restores the argument domain captured when the pin began.
    func restore() {
        UserDefaults.standard.setVolatileDomain(
            originalArgumentDomain,
            forName: UserDefaults.argumentDomain
        )
    }

    /// Runs `body` with `percent` pinned.
    static func with<T>(
        _ percent: Int,
        _ body: () throws -> T
    ) rethrows -> T {
        let pin = Self(percent: percent)
        defer { pin.restore() }
        return try body()
    }
}

/// Runs a suite with Ghostty's applied global font magnification at a fixed
/// percent.
///
/// Terminal font lineage stores unmagnified base points, and a workspace zoom
/// step moves each terminal by whole runtime points, so one step changes the
/// base by `1 / scale`. The app host applies whatever magnification its
/// defaults held at launch, so a suite whose expectations are written in base
/// points pins the scale here. The pin goes through a real configuration
/// reload, the only path that changes the applied magnification. Suites that
/// run in parallel share one lease, and the last one out reapplies the
/// previous magnification.
struct AppliedGlobalFontMagnificationTrait: SuiteTrait, TestScoping {
    let percent: Int

    var isRecursive: Bool { false }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await AppliedGlobalFontMagnificationLease.withLease(
            percent: percent,
            function
        )
    }
}

extension Trait where Self == AppliedGlobalFontMagnificationTrait {
    /// Runs the suite with Ghostty's applied magnification at `percent`.
    static func appliedGlobalFontMagnification(_ percent: Int) -> Self {
        Self(percent: percent)
    }
}

@MainActor
private final class AppliedGlobalFontMagnificationLease {
    private static var current: AppliedGlobalFontMagnificationLease?

    private let percent: Int
    private let pin: ProcessLocalGlobalFontMagnification
    /// Whether taking the lease reloaded configuration.
    private let applied: Task<Bool, any Error>
    private var holders = 1

    private init(percent: Int) {
        self.percent = percent
        pin = ProcessLocalGlobalFontMagnification(percent: percent)
        applied = Task { @MainActor in
            try await Self.applyStoredMagnification(expected: percent)
        }
    }

    static func withLease(
        percent: Int,
        _ function: @Sendable () async throws -> Void
    ) async throws {
        let lease: AppliedGlobalFontMagnificationLease
        if let current {
            try #require(
                current.percent == percent,
                "Parallel suites must pin the same magnification"
            )
            current.holders += 1
            lease = current
        } else {
            lease = AppliedGlobalFontMagnificationLease(percent: percent)
            current = lease
        }
        let result: Result<Void, any Error>
        do {
            _ = try await lease.applied.value
            try await function()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        try await lease.release()
        try result.get()
    }

    private func release() async throws {
        holders -= 1
        guard holders == 0 else { return }
        if Self.current === self {
            Self.current = nil
        }
        pin.restore()
        if (try? await applied.value) == true {
            _ = try await Self.applyStoredMagnification(expected: nil)
        }
    }

    /// Reloads configuration when the applied magnification differs from the
    /// stored one, and reports whether it reloaded.
    private static func applyStoredMagnification(
        expected: Int?
    ) async throws -> Bool {
        let app = GhosttyApp.shared
        let stored = GlobalFontMagnification.storedPercent
        guard app.appliedGlobalFontMagnificationPercent != stored else {
            return false
        }
        let committed: Bool = await withCheckedContinuation { continuation in
            let enqueued = app.reloadConfiguration(
                source: "test.appliedGlobalFontMagnification",
                reloadSettingsFromFile: false,
                commitCompletion: { committed in
                    continuation.resume(returning: committed)
                }
            )
            if !enqueued {
                continuation.resume(returning: false)
            }
        }
        try #require(committed, "The magnification reload must commit")
        if let expected {
            try #require(
                app.appliedGlobalFontMagnificationPercent == expected,
                "The reload must apply the pinned magnification"
            )
        }
        return true
    }
}
