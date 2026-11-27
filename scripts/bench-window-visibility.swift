import AppKit
import ApplicationServices
import Foundation

private struct Sample {
    let dismissMs: Double
    let dismissPressCallMs: Double
    let dismissAfterPressMs: Double
    let restoreMs: Double
    let restoreRequestCallMs: Double
    let restoreActiveMs: Double?
    let restoreCallToActiveMs: Double?
    let restoreVisibleMs: Double
    let restoreCallToVisibleMs: Double
    let restoreFocusedMs: Double
    let restoreCallToFocusedMs: Double
    let restoreActiveToVisibleMs: Double?
    let minimizedAfterDismiss: Bool
    let hiddenAfterDismiss: Bool
}

private struct CmdTabActivationSample {
    let requestCallMs: Double
    let activeMs: Double
    let callToActiveMs: Double
    let visibleMs: Double
    let callToVisibleMs: Double
    let focusedMs: Double
    let callToFocusedMs: Double
}

private func monotonicMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
    return sorted[index]
}

private func summarize(_ label: String, _ values: [Double]) {
    let minValue = values.min() ?? .nan
    let maxValue = values.max() ?? .nan
    let avgValue = values.reduce(0, +) / Double(max(values.count, 1))
    print(
        String(
            format: "%@ min=%.2f p50=%.2f avg=%.2f p95=%.2f max=%.2f count=%d",
            label,
            minValue,
            percentile(values, 0.50),
            avgValue,
            percentile(values, 0.95),
            maxValue,
            values.count
        )
    )
}

private func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.001, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: poll)
    }
    return condition()
}

private func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    (copyAXValue(element, attribute) as? Bool) ?? false
}

private func axWindows(_ appElement: AXUIElement) -> [AXUIElement] {
    guard let values = copyAXValue(appElement, kAXWindowsAttribute) as? [AnyObject] else {
        return []
    }
    return values.compactMap { unsafeBitCast($0, to: AXUIElement?.self) }
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let values = copyAXValue(element, kAXChildrenAttribute) as? [AnyObject] else {
        return []
    }
    return values.compactMap { unsafeBitCast($0, to: AXUIElement?.self) }
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAXValue(element, attribute) as? String
}

private func axSize(_ element: AXUIElement) -> CGSize {
    guard let value = copyAXValue(element, kAXSizeAttribute) else { return .zero }
    var size = CGSize.zero
    AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
    return size
}

private func sameAXElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
}

private func containsAXElement(_ elements: [AXUIElement], _ target: AXUIElement) -> Bool {
    elements.contains { sameAXElement($0, target) }
}

private func preferredBenchmarkWindow(_ appElement: AXUIElement) -> AXUIElement? {
    let candidates = visibleAXWindows(appElement)
        .filter { minimizeButton(for: $0) != nil }
    let standardCandidates = candidates.filter {
        axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }
    return (standardCandidates.isEmpty ? candidates : standardCandidates)
        .max { lhs, rhs in
            let lhsSize = axSize(lhs)
            let rhsSize = axSize(rhs)
            return lhsSize.width * lhsSize.height < rhsSize.width * rhsSize.height
        }
}

private func debugWindowList(_ appElement: AXUIElement) {
    for (index, window) in axWindows(appElement).enumerated() {
        let title = axString(window, kAXTitleAttribute) ?? "<nil>"
        let subrole = axString(window, kAXSubroleAttribute) ?? "<nil>"
        let size = axSize(window)
        let visible = containsAXElement(visibleAXWindows(appElement), window)
        let minimized = axBool(window, kAXMinimizedAttribute)
        fputs(
            String(
                format: "window[%d] title=%@ subrole=%@ visible=%d minimized=%d size=%.0fx%.0f\n",
                index,
                title,
                subrole,
                visible ? 1 : 0,
                minimized ? 1 : 0,
                size.width,
                size.height
            ),
            stderr
        )
    }
}

private func visibleAXWindows(_ appElement: AXUIElement) -> [AXUIElement] {
    axWindows(appElement).filter { !axBool($0, kAXMinimizedAttribute) }
}

private func focusedAXWindow(_ appElement: AXUIElement) -> AXUIElement? {
    guard let value = copyAXValue(appElement, kAXFocusedWindowAttribute) else { return nil }
    return unsafeBitCast(value, to: AXUIElement?.self)
}

private func visibleCGWindows(processIdentifier: pid_t) -> [[String: Any]] {
    guard let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    return windowInfo.filter { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier else {
            return false
        }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer == 0 else { return false }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { return false }
        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else {
            return true
        }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else {
            return true
        }
        return bounds.width > 1 && bounds.height > 1
    }
}

private func hasVisibleCGWindow(processIdentifier: pid_t) -> Bool {
    !visibleCGWindows(processIdentifier: processIdentifier).isEmpty
}

private func resolvedBundleIdentifier(appURL: URL, requestedBundleIdentifier: String) -> String {
    guard let actualBundleIdentifier = Bundle(url: appURL)?.bundleIdentifier,
          !actualBundleIdentifier.isEmpty else {
        return requestedBundleIdentifier
    }
    if actualBundleIdentifier != requestedBundleIdentifier {
        fputs(
            "Using app bundle identifier \(actualBundleIdentifier) instead of requested \(requestedBundleIdentifier).\n",
            stderr
        )
    }
    return actualBundleIdentifier
}

private let directLaunchEnvironmentKeysToRemove = [
    "CMUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_SOCKET_MODE",
    "CMUX_TAB_ID",
    "CMUX_PANEL_ID",
    "CMUX_SURFACE_ID",
    "CMUX_WORKSPACE_ID",
    "CMUXD_UNIX_PATH",
    "CMUX_TAG",
    "CMUX_PORT",
    "CMUX_PORT_END",
    "CMUX_PORT_RANGE",
    "CMUX_DEBUG_LOG",
    "CMUX_BUNDLE_ID",
    "CMUX_BUNDLED_CLI_PATH",
    "CMUX_DISABLE_SESSION_RESTORE",
    "CMUX_SHELL_INTEGRATION",
    "CMUX_SHELL_INTEGRATION_DIR",
    "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION",
    "GHOSTTY_BIN_DIR",
    "GHOSTTY_RESOURCES_DIR",
    "GHOSTTY_SHELL_FEATURES",
    "GIT_PAGER",
    "GH_PAGER",
    "TERMINFO",
    "XDG_DATA_DIRS",
]

private func directLaunchEnvironment(appURL: URL, bundleIdentifier: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in directLaunchEnvironmentKeysToRemove {
        environment.removeValue(forKey: key)
    }

    if let bundle = Bundle(url: appURL),
       let launchEnvironment = bundle.infoDictionary?["LSEnvironment"] as? [String: String] {
        environment.merge(launchEnvironment) { _, newValue in newValue }
    }
    environment["CMUX_BUNDLE_ID"] = environment["CMUX_BUNDLE_ID"] ?? bundleIdentifier
    return environment
}

private func waitForRunningApplication(bundleIdentifier: String, timeout: TimeInterval) -> NSRunningApplication? {
    var runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    guard runningApp == nil else { return runningApp }

    _ = waitUntil(timeout: timeout) {
        runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        return runningApp != nil
    }
    return runningApp
}

private func directLaunchLogURL(bundleIdentifier: String) -> URL {
    let safeIdentifier = bundleIdentifier
        .map { character in character.isLetter || character.isNumber ? character : "-" }
        .reduce(into: "") { $0.append($1) }
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cmux-window-visibility-\(safeIdentifier).log")
}

private func launchApplicationProcess(appURL: URL, bundleIdentifier: String) -> NSRunningApplication? {
    guard let bundle = Bundle(url: appURL),
          let executableURL = bundle.executableURL else {
        fputs("direct launch: unable to resolve executable for bundle at \(appURL.path)\n", stderr)
        return nil
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        fputs("direct launch executable missing: \(executableURL.path)\n", stderr)
        return nil
    }

    let process = Process()
    process.executableURL = executableURL
    process.environment = directLaunchEnvironment(appURL: appURL, bundleIdentifier: bundleIdentifier)
    let logURL = directLaunchLogURL(bundleIdentifier: bundleIdentifier)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    if let logHandle = try? FileHandle(forWritingTo: logURL) {
        process.standardOutput = logHandle
        process.standardError = logHandle
        fputs("direct launch log: \(logURL.path)\n", stderr)
    }
    do {
        try process.run()
    } catch {
        fputs("direct launch error: \(error)\n", stderr)
        return waitForRunningApplication(bundleIdentifier: bundleIdentifier, timeout: 1)
    }
    return waitForRunningApplication(bundleIdentifier: bundleIdentifier, timeout: 10)
}

private func minimizeButton(for window: AXUIElement) -> AXUIElement? {
    if let value = copyAXValue(window, kAXMinimizeButtonAttribute),
       let button = unsafeBitCast(value, to: AXUIElement?.self) {
        return button
    }

    var stack = axChildren(window)
    var visited = 0
    while let element = stack.popLast(), visited < 256 {
        visited += 1
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let title = axString(element, kAXTitleAttribute)?.lowercased()
        let description = axString(element, kAXDescriptionAttribute)?.lowercased()
        if role == kAXButtonRole,
           subrole == kAXMinimizeButtonSubrole || title == "minimize" || description == "minimize" {
            return element
        }
        stack.append(contentsOf: axChildren(element))
    }

    return nil
}

private func debugAXTree(root: AXUIElement, maxNodes: Int = 80) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var emitted = 0
    while let (element, depth) = stack.popLast(), emitted < maxNodes {
        emitted += 1
        let indent = String(repeating: "  ", count: depth)
        let role = axString(element, kAXRoleAttribute) ?? "<nil>"
        let subrole = axString(element, kAXSubroleAttribute) ?? "<nil>"
        let title = axString(element, kAXTitleAttribute) ?? "<nil>"
        let description = axString(element, kAXDescriptionAttribute) ?? "<nil>"
        fputs("\(indent)role=\(role) subrole=\(subrole) title=\(title) description=\(description)\n", stderr)
        for child in axChildren(element).reversed() {
            stack.append((child, depth + 1))
        }
    }
}

private func openApplication(appURL: URL, bundleIdentifier: String) -> NSRunningApplication? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    let semaphore = DispatchSemaphore(value: 0)
    var openedApp: NSRunningApplication?
    var openedError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        openedApp = app
        openedError = error
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    if let openedError {
        fputs("openApplication error: \(openedError)\n", stderr)
    }
    if let app = openedApp ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        return app
    }

    fputs("Falling back to direct app executable launch.\n", stderr)
    return launchApplicationProcess(appURL: appURL, bundleIdentifier: bundleIdentifier)
}

@discardableResult
private func openBundleIdentifier(_ bundleIdentifier: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleIdentifier]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
}

private func activateFinder(except app: NSRunningApplication) {
    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        finder.activate(options: [])
    } else {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: finderURL, configuration: configuration) { _, _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
    _ = waitUntil(timeout: 0.5) { !app.isActive }
}

private func terminateExisting(bundleIdentifier: String) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
        app.terminate()
    }
    _ = waitUntil(timeout: 5) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
        app.forceTerminate()
    }
    _ = waitUntil(timeout: 5) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

private func runCmdTabActivationBenchmark(
    appURL: URL,
    bundleIdentifier: String,
    app: NSRunningApplication,
    appElement: AXUIElement,
    sampleCount: Int,
    useCGVisibility: Bool,
    activateAllWindows: Bool
) {
    func hasVisibleBenchmarkWindow(_ runningApp: NSRunningApplication? = nil) -> Bool {
        if useCGVisibility {
            guard let processIdentifier = (runningApp ?? runningApplication(bundleIdentifier: bundleIdentifier))?.processIdentifier else {
                return false
            }
            return hasVisibleCGWindow(processIdentifier: processIdentifier)
        }
        return !visibleAXWindows(appElement).isEmpty
    }

    var samples: [CmdTabActivationSample] = []
    var failuresByReason: [String: Int] = [:]

    func recordFailure(_ reason: String) {
        failuresByReason[reason, default: 0] += 1
    }

    for _ in 0..<sampleCount {
        if !hasVisibleBenchmarkWindow(app) {
            _ = openApplication(appURL: appURL, bundleIdentifier: bundleIdentifier)
        }
        guard waitUntil(timeout: 5, { hasVisibleBenchmarkWindow(app) }) else {
            recordFailure("initial_visible_timeout")
            continue
        }
        if !useCGVisibility, let window = preferredBenchmarkWindow(appElement) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        activateFinder(except: app)
        guard waitUntil(timeout: 2, {
            runningApplication(bundleIdentifier: bundleIdentifier)?.isActive == false
        }) else {
            recordFailure("deactivate_timeout")
            continue
        }
        guard let running = runningApplication(bundleIdentifier: bundleIdentifier) else {
            recordFailure("missing_running_app")
            continue
        }

        let requestStart = monotonicMs()
        let options: NSApplication.ActivationOptions = activateAllWindows ? [.activateAllWindows] : []
        let activated = running.activate(options: options)
        let requestEnd = monotonicMs()
        guard activated else {
            recordFailure("activate_returned_false")
            continue
        }

        guard waitUntil(timeout: 5, {
            running.isActive || runningApplication(bundleIdentifier: bundleIdentifier)?.isActive == true
        }) else {
            recordFailure("active_timeout")
            continue
        }
        let activeEnd = monotonicMs()

        guard waitUntil(timeout: 5, {
            running.isHidden == false && (
                useCGVisibility
                    ? hasVisibleCGWindow(processIdentifier: running.processIdentifier)
                    : preferredBenchmarkWindow(appElement) != nil
            )
        }) else {
            recordFailure("visible_timeout")
            continue
        }
        let visibleEnd = monotonicMs()

        let focusedEnd: Double
        if useCGVisibility {
            focusedEnd = visibleEnd
        } else {
            guard waitUntil(timeout: 5, { focusedAXWindow(appElement) != nil }) else {
                recordFailure("focused_timeout")
                continue
            }
            focusedEnd = monotonicMs()
        }

        samples.append(
            CmdTabActivationSample(
                requestCallMs: requestEnd - requestStart,
                activeMs: activeEnd - requestStart,
                callToActiveMs: activeEnd - requestEnd,
                visibleMs: visibleEnd - requestStart,
                callToVisibleMs: visibleEnd - requestEnd,
                focusedMs: focusedEnd - requestStart,
                callToFocusedMs: focusedEnd - requestEnd
            )
        )
    }

    summarize("cmdtab_activate_request_call", samples.map(\.requestCallMs))
    summarize("cmdtab_activate_active", samples.map(\.activeMs))
    summarize("cmdtab_activate_call_to_active", samples.map(\.callToActiveMs))
    summarize("cmdtab_activate_visible", samples.map(\.visibleMs))
    summarize("cmdtab_activate_call_to_visible", samples.map(\.callToVisibleMs))
    summarize("cmdtab_activate_focused", samples.map(\.focusedMs))
    summarize("cmdtab_activate_call_to_focused", samples.map(\.callToFocusedMs))
    let failureSummary = failuresByReason
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
    print("failures=\(failuresByReason.values.reduce(0, +)) \(failureSummary)")
}

private func requireTrustedAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        fputs("Accessibility trust is required for this benchmark.\n", stderr)
        exit(2)
    }
}

private func main() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        fputs("usage: bench-window-visibility <app-path> <bundle-id> [samples]\n", stderr)
        exit(64)
    }

    let appURL = URL(fileURLWithPath: arguments[1])
    let bundleIdentifier = resolvedBundleIdentifier(
        appURL: appURL,
        requestedBundleIdentifier: arguments[2]
    )
    let verbose = arguments.contains("--verbose")
    let activateRestore = arguments.contains("--activate-restore")
    let cmdTabActivation = arguments.contains("--cmd-tab-activation")
    let cmdTabActivateAllWindows = arguments.contains("--cmd-tab-activate-all-windows")
    let reuseRunning = arguments.contains("--reuse-running")
    let useCGVisibility = arguments.contains("--cg-visibility")
    let sampleCount = arguments.dropFirst(3).first(where: { Int($0) != nil }).flatMap(Int.init) ?? 15
    if !cmdTabActivation || !useCGVisibility || verbose {
        requireTrustedAccessibility()
    }

    if !reuseRunning {
        terminateExisting(bundleIdentifier: bundleIdentifier)
    }

    let app = reuseRunning
        ? runningApplication(bundleIdentifier: bundleIdentifier)
        : openApplication(appURL: appURL, bundleIdentifier: bundleIdentifier)
    guard let app else {
        fputs("Unable to launch app.\n", stderr)
        exit(1)
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    func hasVisibleBenchmarkWindow(_ runningApp: NSRunningApplication? = nil) -> Bool {
        if useCGVisibility {
            guard let processIdentifier = (runningApp ?? runningApplication(bundleIdentifier: bundleIdentifier))?.processIdentifier else {
                return false
            }
            return hasVisibleCGWindow(processIdentifier: processIdentifier)
        }
        return !visibleAXWindows(appElement).isEmpty
    }

    guard waitUntil(timeout: 20, { hasVisibleBenchmarkWindow(app) }) else {
        fputs("Timed out waiting for initial visible window.\n", stderr)
        exit(1)
    }
    if verbose {
        debugWindowList(appElement)
    }

    if cmdTabActivation {
        runCmdTabActivationBenchmark(
            appURL: appURL,
            bundleIdentifier: bundleIdentifier,
            app: app,
            appElement: appElement,
            sampleCount: sampleCount,
            useCGVisibility: useCGVisibility,
            activateAllWindows: cmdTabActivateAllWindows
        )
        return
    }

    var samples: [Sample] = []
    var failuresByReason: [String: Int] = [:]
    var phaseMissesByReason: [String: Int] = [:]

    func recordFailure(_ reason: String) {
        failuresByReason[reason, default: 0] += 1
    }

    func recordPhaseMiss(_ reason: String) {
        phaseMissesByReason[reason, default: 0] += 1
    }

    for _ in 0..<sampleCount {
        if !hasVisibleBenchmarkWindow() {
            _ = openApplication(appURL: appURL, bundleIdentifier: bundleIdentifier)
        }
        guard waitUntil(timeout: 5, { hasVisibleBenchmarkWindow() }) else {
            recordFailure("initial_visible_timeout")
            continue
        }

        guard let window = preferredBenchmarkWindow(appElement) else {
            recordFailure("missing_benchmark_window")
            continue
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        guard let button = minimizeButton(for: window) else {
            debugAXTree(root: window)
            fputs("Unable to find AX minimize button.\n", stderr)
            exit(1)
        }

        let dismissStart = monotonicMs()
        let pressResult = AXUIElementPerformAction(button, kAXPressAction as CFString)
        let dismissPressEnd = monotonicMs()
        guard pressResult == .success else {
            recordFailure("press_failed_\(pressResult.rawValue)")
            continue
        }
        guard waitUntil(timeout: 3, {
            runningApplication(bundleIdentifier: bundleIdentifier)?.isHidden == true ||
            (useCGVisibility
                ? runningApplication(bundleIdentifier: bundleIdentifier).map { !hasVisibleCGWindow(processIdentifier: $0.processIdentifier) } ?? false
                : !containsAXElement(visibleAXWindows(appElement), window)) ||
                (!useCGVisibility && axBool(window, kAXMinimizedAttribute))
        }) else {
            let visibleCount = useCGVisibility
                ? runningApplication(bundleIdentifier: bundleIdentifier)
                    .map { visibleCGWindows(processIdentifier: $0.processIdentifier).count } ?? 0
                : visibleAXWindows(appElement).count
            let minimizedCount = useCGVisibility
                ? 0
                : axWindows(appElement).filter { axBool($0, kAXMinimizedAttribute) }.count
            recordFailure("dismiss_timeout_visible_\(visibleCount)_minimized_\(minimizedCount)")
            continue
        }
        let dismissEnd = monotonicMs()
        let minimizedAfterDismiss = useCGVisibility
            ? false
            : axWindows(appElement).contains { axBool($0, kAXMinimizedAttribute) }
        let hiddenAfterDismiss = runningApplication(bundleIdentifier: bundleIdentifier)?.isHidden == true

        let restoreStart: Double
        let restoreRequestEnd: Double
        let restoringApp: NSRunningApplication?
        if activateRestore, let running = runningApplication(bundleIdentifier: bundleIdentifier) {
            activateFinder(except: running)
            restoreStart = monotonicMs()
            if running.isHidden {
                _ = openBundleIdentifier(bundleIdentifier)
                restoringApp = runningApplication(bundleIdentifier: bundleIdentifier)
            } else {
                running.activate(options: [.activateAllWindows])
                restoringApp = running
            }
            restoreRequestEnd = monotonicMs()
        } else {
            restoreStart = monotonicMs()
            restoringApp = openApplication(appURL: appURL, bundleIdentifier: bundleIdentifier)
            restoreRequestEnd = monotonicMs()
        }
        guard let restoringApp else {
            recordFailure("restore_missing_running_app")
            continue
        }
        let activeEnd = waitUntil(timeout: 5, {
            restoringApp.isActive || runningApplication(bundleIdentifier: bundleIdentifier)?.isActive == true
        }) ? monotonicMs() : nil
        if activeEnd == nil {
            recordPhaseMiss("restore_active_timeout")
        }
        guard waitUntil(timeout: 5, {
            restoringApp.isHidden == false && (
                useCGVisibility
                    ? hasVisibleCGWindow(processIdentifier: restoringApp.processIdentifier)
                    : preferredBenchmarkWindow(appElement) != nil
            )
        }) else {
            let hiddenValue = restoringApp.isHidden ? 1 : 0
            let visibleCount = useCGVisibility
                ? visibleCGWindows(processIdentifier: restoringApp.processIdentifier).count
                : visibleAXWindows(appElement).count
            let allWindowCount = useCGVisibility ? visibleCount : axWindows(appElement).count
            recordFailure("restore_visible_timeout_hidden_\(hiddenValue)_visible_\(visibleCount)_windows_\(allWindowCount)")
            continue
        }
        let visibleEnd = monotonicMs()
        let focusedEnd: Double
        if useCGVisibility {
            focusedEnd = visibleEnd
        } else {
            guard waitUntil(timeout: 5, {
                focusedAXWindow(appElement) != nil
            }) else {
                recordFailure("restore_focused_timeout")
                continue
            }
            focusedEnd = monotonicMs()
        }

        samples.append(
            Sample(
                dismissMs: dismissEnd - dismissStart,
                dismissPressCallMs: dismissPressEnd - dismissStart,
                dismissAfterPressMs: dismissEnd - dismissPressEnd,
                restoreMs: focusedEnd - restoreStart,
                restoreRequestCallMs: restoreRequestEnd - restoreStart,
                restoreActiveMs: activeEnd.map { $0 - restoreStart },
                restoreCallToActiveMs: activeEnd.map { $0 - restoreRequestEnd },
                restoreVisibleMs: visibleEnd - restoreStart,
                restoreCallToVisibleMs: visibleEnd - restoreRequestEnd,
                restoreFocusedMs: focusedEnd - restoreStart,
                restoreCallToFocusedMs: focusedEnd - restoreRequestEnd,
                restoreActiveToVisibleMs: activeEnd.map { visibleEnd - $0 },
                minimizedAfterDismiss: minimizedAfterDismiss,
                hiddenAfterDismiss: hiddenAfterDismiss
            )
        )
    }

    summarize("titlebar_dismiss_wall", samples.map(\.dismissMs))
    summarize("titlebar_dismiss_press_call", samples.map(\.dismissPressCallMs))
    summarize("titlebar_dismiss_after_press", samples.map(\.dismissAfterPressMs))
    summarize("titlebar_restore_wall", samples.map(\.restoreMs))
    summarize("titlebar_restore_request_call", samples.map(\.restoreRequestCallMs))
    summarize("titlebar_restore_active", samples.compactMap(\.restoreActiveMs))
    summarize("titlebar_restore_call_to_active", samples.compactMap(\.restoreCallToActiveMs))
    summarize("titlebar_restore_visible", samples.map(\.restoreVisibleMs))
    summarize("titlebar_restore_call_to_visible", samples.map(\.restoreCallToVisibleMs))
    summarize("titlebar_restore_focused", samples.map(\.restoreFocusedMs))
    summarize("titlebar_restore_call_to_focused", samples.map(\.restoreCallToFocusedMs))
    summarize("titlebar_restore_active_to_visible", samples.compactMap(\.restoreActiveToVisibleMs))
    let minimizedCount = samples.filter(\.minimizedAfterDismiss).count
    print("titlebar_dismiss_minimized_after count=\(minimizedCount) total=\(samples.count)")
    let hiddenCount = samples.filter(\.hiddenAfterDismiss).count
    print("titlebar_dismiss_hidden_after count=\(hiddenCount) total=\(samples.count)")
    let failureSummary = failuresByReason
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
    print("failures=\(failuresByReason.values.reduce(0, +)) \(failureSummary)")
    let phaseMissSummary = phaseMissesByReason
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
    print("phase_misses=\(phaseMissesByReason.values.reduce(0, +)) \(phaseMissSummary)")
}

main()
