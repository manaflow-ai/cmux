#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

private struct Options {
    let bundleIdentifier: String
    let timeoutSeconds: Double

    init(arguments: ArraySlice<String>) throws {
        guard let bundleIdentifier = arguments.first, !bundleIdentifier.isEmpty else {
            throw NSError(domain: "TerminateBundleApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "usage: terminate-bundle-app.swift <bundle-id> [timeout-seconds]"
            ])
        }
        let timeout = arguments.dropFirst().first.flatMap(Double.init) ?? 5
        guard timeout.isFinite, timeout > 0 else {
            throw NSError(domain: "TerminateBundleApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "timeout-seconds must be a positive number"
            ])
        }
        self.bundleIdentifier = bundleIdentifier
        self.timeoutSeconds = timeout
    }
}

/// Tracks termination notifications without polling process state. The lock
/// protects the small set because NSWorkspace may deliver notifications off
/// the main thread while the command waits on the semaphore.
private final class TerminationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<pid_t>
    private var didSignal = false
    private let completion = DispatchSemaphore(value: 0)

    init(processIdentifiers: Set<pid_t>) {
        self.remaining = processIdentifiers
        if processIdentifiers.isEmpty {
            didSignal = true
            completion.signal()
        }
    }

    func markTerminated(_ processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard remaining.remove(processIdentifier) != nil else { return }
        guard remaining.isEmpty, !didSignal else { return }
        didSignal = true
        completion.signal()
    }

    func isComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty
    }

    func wait(until deadline: DispatchTime) -> Bool {
        if isComplete() { return true }
        _ = completion.wait(timeout: deadline)
        return isComplete()
    }
}

private func runningTargetProcesses(bundleIdentifier: String, processIdentifiers: Set<pid_t>) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { processIdentifiers.contains($0.processIdentifier) && !$0.isTerminated }
}

private func markProcessesMissingFromWorkspace(
    bundleIdentifier: String,
    processIdentifiers: Set<pid_t>,
    tracker: TerminationTracker
) {
    let running = Set(
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    )
    for processIdentifier in processIdentifiers where !running.contains(processIdentifier) {
        tracker.markTerminated(processIdentifier)
    }
}

do {
    let options = try Options(arguments: CommandLine.arguments.dropFirst())
    let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: options.bundleIdentifier
    )
    guard !applications.isEmpty else { exit(EXIT_SUCCESS) }

    let processIdentifiers = Set(applications.map(\.processIdentifier))
    let tracker = TerminationTracker(processIdentifiers: processIdentifiers)
    let notificationCenter = NSWorkspace.shared.notificationCenter
    let observer = notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: nil
    ) { notification in
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            processIdentifiers.contains(application.processIdentifier) else {
            return
        }
        tracker.markTerminated(application.processIdentifier)
    }
    defer { notificationCenter.removeObserver(observer) }

    for application in applications {
        if application.isTerminated {
            tracker.markTerminated(application.processIdentifier)
        } else if !application.terminate() {
            // The process is still scoped by the exact bundle identifier. A
            // force termination is safer than falling through and relaunching
            // against a stale process with the prior auth environment.
            _ = application.forceTerminate()
        }
    }

    markProcessesMissingFromWorkspace(
        bundleIdentifier: options.bundleIdentifier,
        processIdentifiers: processIdentifiers,
        tracker: tracker
    )
    let gracefulDeadline = DispatchTime.now() + options.timeoutSeconds
    _ = tracker.wait(until: gracefulDeadline)

    if !tracker.isComplete() {
        for application in runningTargetProcesses(
            bundleIdentifier: options.bundleIdentifier,
            processIdentifiers: processIdentifiers
        ) {
            _ = application.forceTerminate()
        }
        markProcessesMissingFromWorkspace(
            bundleIdentifier: options.bundleIdentifier,
            processIdentifiers: processIdentifiers,
            tracker: tracker
        )
        let forceDeadline = DispatchTime.now() + options.timeoutSeconds
        _ = tracker.wait(until: forceDeadline)
    }

    markProcessesMissingFromWorkspace(
        bundleIdentifier: options.bundleIdentifier,
        processIdentifiers: processIdentifiers,
        tracker: tracker
    )
    guard tracker.isComplete() else {
        fputs(
            "error: application bundle '\(options.bundleIdentifier)' did not terminate before the deadline\n",
            stderr
        )
        exit(EXIT_FAILURE)
    }
    exit(EXIT_SUCCESS)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
