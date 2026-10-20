#!/usr/bin/env swift

import AppKit
import Darwin
import Dispatch
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

/// Owns termination state on an actor. Completion is delivered through an
/// async stream, so the command waits for the workspace's lifecycle event
/// rather than polling process state or blocking a thread with a semaphore.
private actor TerminationTracker {
    private var remaining: Set<pid_t>
    private var completion: AsyncStream<Void>.Continuation?

    init(processIdentifiers: Set<pid_t>) {
        self.remaining = processIdentifiers
    }

    func install(_ completion: AsyncStream<Void>.Continuation) {
        self.completion = completion
        if remaining.isEmpty {
            completion.finish()
        }
    }

    func markTerminated(_ processIdentifier: pid_t) {
        guard remaining.remove(processIdentifier) != nil else { return }
        guard remaining.isEmpty else { return }
        completion?.yield(())
        completion?.finish()
    }

    func isComplete() -> Bool {
        remaining.isEmpty
    }
}

private func runningTargetProcesses(
    bundleIdentifier: String,
    processIdentifiers: Set<pid_t>
) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { processIdentifiers.contains($0.processIdentifier) && !$0.isTerminated }
}

private func markProcessesMissingFromWorkspace(
    bundleIdentifier: String,
    processIdentifiers: Set<pid_t>,
    tracker: TerminationTracker
) async {
    let running = Set(
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    )
    for processIdentifier in processIdentifiers where !running.contains(processIdentifier) {
        await tracker.markTerminated(processIdentifier)
    }
}

/// Waits for either the tracked lifecycle event or a cancellation-aware
/// deadline. The timeout is a bounded failure deadline, not a synchronization
/// delay, and the losing task is cancelled as soon as the other task wins.
private func waitForCompletion(
    tracker: TerminationTracker,
    stream: AsyncStream<Void>,
    until deadline: ContinuousClock.Instant
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream {
                return true
            }
            return await tracker.isComplete()
        }
        group.addTask {
            do {
                try await ContinuousClock().sleep(until: deadline)
                return false
            } catch {
                // The completion task won and cancelled this deadline task.
                return true
            }
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func run() async throws {
    let options = try Options(arguments: CommandLine.arguments.dropFirst())
    let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: options.bundleIdentifier
    )
    guard !applications.isEmpty else { exit(EXIT_SUCCESS) }

    let processIdentifiers = Set(applications.map(\.processIdentifier))
    let tracker = TerminationTracker(processIdentifiers: processIdentifiers)
    let completionStream = AsyncStream<Void> { continuation in
        Task { await tracker.install(continuation) }
    }
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
        Task { await tracker.markTerminated(application.processIdentifier) }
    }
    defer { notificationCenter.removeObserver(observer) }

    for application in applications {
        if application.isTerminated {
            await tracker.markTerminated(application.processIdentifier)
        } else if !application.terminate() {
            // The process is still scoped by the exact bundle identifier.
            // Force termination is safer than relaunching with stale auth.
            _ = application.forceTerminate()
        }
    }

    await markProcessesMissingFromWorkspace(
        bundleIdentifier: options.bundleIdentifier,
        processIdentifiers: processIdentifiers,
        tracker: tracker
    )
    let clock = ContinuousClock()
    let gracefulDeadline = clock.now.advanced(by: .seconds(options.timeoutSeconds))
    _ = await waitForCompletion(
        tracker: tracker,
        stream: completionStream,
        until: gracefulDeadline
    )

    if !(await tracker.isComplete()) {
        for application in runningTargetProcesses(
            bundleIdentifier: options.bundleIdentifier,
            processIdentifiers: processIdentifiers
        ) {
            _ = application.forceTerminate()
        }
        await markProcessesMissingFromWorkspace(
            bundleIdentifier: options.bundleIdentifier,
            processIdentifiers: processIdentifiers,
            tracker: tracker
        )
        let forceDeadline = clock.now.advanced(by: .seconds(options.timeoutSeconds))
        _ = await waitForCompletion(
            tracker: tracker,
            stream: completionStream,
            until: forceDeadline
        )
    }

    await markProcessesMissingFromWorkspace(
        bundleIdentifier: options.bundleIdentifier,
        processIdentifiers: processIdentifiers,
        tracker: tracker
    )
    guard await tracker.isComplete() else {
        fputs(
            "error: application bundle '\(options.bundleIdentifier)' did not terminate before the deadline\n",
            stderr
        )
        exit(EXIT_FAILURE)
    }
    exit(EXIT_SUCCESS)
}

Task {
    do {
        try await run()
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
