import Cocoa
import CEFWrapper
import os.log

nonisolated(unsafe) let cefLogger = Logger(subsystem: "co.sstools.CEFWebView", category: "CEFApplication")

// MARK: - CEF Application Lifecycle Manager

/// Manages CEF initialization and shutdown on the main thread.
@MainActor
public final class CEFApplication {
    public static let shared = CEFApplication()

    private var isInitialized = false
    weak var activeBrowserHost: CEFBrowserHost?

    /// Tracks helper processes that spawned before a `CEFBrowserHost` exists (GPU/network/storage
    /// typically spawn during `CefInitialize`, before SwiftUI creates the browser).
    private var helperSpawnedGPU = false
    private var helperSpawnedNetwork = false
    private var helperSpawnedStorage = false
    private var helperSpawnedRenderer = false

    /// Tracks helper failures (renderer can fail even if it spawned)
    private var helperFailedGPU = false
    private var helperFailedNetwork = false
    private var helperFailedStorage = false
    private var helperFailedRenderer = false

    /// Main-frame load error details (from `OnLoadError`), buffered until `CEFBrowserHost` exists.
    private var lastMainFrameLoadErrorCode: Int?
    private var lastMainFrameLoadErrorText: String?

    nonisolated(unsafe) private var spawnedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failedObserver: NSObjectProtocol?

    private init() {
        cefLogger.info("🔔 CEFApplication.init() - registering notification observers")

        // Observe helper spawning notifications from CEFWrapper (C/Objective-C side)
        spawnedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CEFHelperSpawned"),
            object: nil,
            queue: .main
        ) { notification in
            cefLogger.info("🟢 CEFHelperSpawned notification RECEIVED on main queue")
            cefLogger.debug("Notification object: \(String(describing: notification.object))")
            if let userInfo = notification.userInfo as? [String: String] {
                cefLogger.debug("✅ userInfo parsed successfully: \(userInfo)")
                if let helperType = userInfo["type"] {
                    cefLogger.info("🟢 Found helperType in userInfo: \(helperType)")
                    Task { @MainActor in
                        cefLogger.info("📋 Calling recordHelperSpawned(\(helperType))")
                        CEFApplication.shared.recordHelperSpawned(helperType)
                    }
                } else {
                    cefLogger.warning("❌ userInfo has keys but missing 'type' key: \(userInfo.keys)")
                }
            } else {
                cefLogger.warning("❌ CEFHelperSpawned userInfo not [String: String]. Raw userInfo: \(String(describing: notification.userInfo))")
            }
        }

        // Observe helper failure notifications from CEFWrapper (C/Objective-C side)
        failedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CEFHelperFailed"),
            object: nil,
            queue: .main
        ) { notification in
            cefLogger.info("CEFHelperFailed notification received")
            guard let userInfo = notification.userInfo,
                  let helperType = userInfo["type"] as? String
            else {
                cefLogger.warning("CEFHelperFailed missing userInfo or type: \(String(describing: notification.userInfo))")
                return
            }
            let errorCode = (userInfo["errorCode"] as? NSNumber).map { $0.intValue }
            let errorText = userInfo["errorText"] as? String
            Task { @MainActor in
                CEFApplication.shared.recordHelperFailed(
                    helperType,
                    mainFrameLoadErrorCode: errorCode,
                    mainFrameLoadErrorText: errorText
                )
            }
        }

        cefLogger.info("✅ Notification observers registered successfully")
    }

    deinit {
        if let observer = spawnedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = failedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Handle CEF subprocess roles at the very start of the app, before any other initialization.
    /// If this process is a CEF subprocess (renderer, GPU, utility, network), this method will
    /// call exit() — it does not return. If this is the main browser process, returns normally.
    /// Must be called from the main thread before SwiftUI initializes.
    public nonisolated static func handleSubprocessIfNeeded() {
        cefLogger.debug("handleSubprocessIfNeeded called")

        let exitCode = CEFWrapper.executeSubprocess(withArgc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        cefLogger.debug("CefExecuteProcess returned exitCode=\(exitCode)")

        if exitCode >= 0 {
            // This is a subprocess; exit with the exit code returned by CefExecuteProcess
            cefLogger.debug("This is a subprocess, exiting with code \(exitCode)")
            exit(exitCode)
        }
        // exitCode < 0 means main browser process — continue with normal app startup
        cefLogger.debug("This is the main browser process, continuing startup")
    }

    /// Initialize CEF framework. Call once at app startup.
    public func initialize() throws {
        guard !isInitialized else {
            cefLogger.debug("CEF already initialized, skipping")
            return
        }

        // Swift bridges initializeCEFWithError: as a throwing method
        do {
            try CEFWrapper.initializeCEF()
        } catch let error as NSError {
            let errorDesc = error.localizedDescription
            cefLogger.error("CEF INITIALIZATION FAILED: \(errorDesc, privacy: .public) (code: \(error.code))")
            throw CEFError.initializationFailed(reason: errorDesc)
        } catch {
            cefLogger.error("CEF initialization failed with unknown error: \(String(describing: error), privacy: .public)")
            throw CEFError.initializationFailed(reason: error.localizedDescription)
        }

        cefLogger.info("CEF Initialized Successfully")
        isInitialized = true
    }

    /// Records a helper spawn from `CEFHelperSpawned` notifications (may arrive before `CEFBrowserHost` exists).
    func recordHelperSpawned(_ type: String) {
        cefLogger.info("🟢 recordHelperSpawned called with type: \(type)")
        let lowerType = type.lowercased()
        cefLogger.debug("Type lowercased: \(lowerType)")

        switch lowerType {
        case "gpu":
            cefLogger.debug("Setting helperSpawnedGPU = true")
            helperSpawnedGPU = true
        case "network":
            cefLogger.debug("Setting helperSpawnedNetwork = true")
            helperSpawnedNetwork = true
        case "storage":
            cefLogger.debug("Setting helperSpawnedStorage = true")
            helperSpawnedStorage = true
        case "renderer":
            cefLogger.debug("Setting helperSpawnedRenderer = true")
            helperSpawnedRenderer = true
        default:
            cefLogger.warning("⚠️ Unknown helper type from CEF: \(type)")
            return
        }

        cefLogger.info("✅ Recorded helper spawn (accumulated): \(type)")

        if let state = activeBrowserHost?.state {
            cefLogger.info("🟢 Broadcasting state change to CEFWebViewState")
            applyAccumulatedHelperFlags(to: state)
        } else {
            cefLogger.info("ℹ️ No activeBrowserHost.state available yet - flags will be applied when browser attaches")
        }
    }

    /// Records a helper failure from `CEFHelperFailed` notifications.
    /// `mainFrameLoadErrorCode` / `mainFrameLoadErrorText` are set when the failure comes from CEF `OnLoadError` (main frame).
    func recordHelperFailed(
        _ type: String,
        mainFrameLoadErrorCode: Int? = nil,
        mainFrameLoadErrorText: String? = nil
    ) {
        cefLogger.info("recordHelperFailed type=\(type) loadErrorCode=\(String(describing: mainFrameLoadErrorCode))")
        let lowerType = type.lowercased()

        switch lowerType {
        case "gpu":
            helperFailedGPU = true
            helperSpawnedGPU = false
        case "network":
            helperFailedNetwork = true
            helperSpawnedNetwork = false
        case "storage":
            helperFailedStorage = true
            helperSpawnedStorage = false
        case "renderer":
            helperFailedRenderer = true
            helperSpawnedRenderer = false
            if let code = mainFrameLoadErrorCode {
                lastMainFrameLoadErrorCode = code
                lastMainFrameLoadErrorText = mainFrameLoadErrorText
            } else {
                lastMainFrameLoadErrorCode = nil
                lastMainFrameLoadErrorText = nil
            }
        default:
            cefLogger.warning("Unknown helper type from CEF: \(type)")
            return
        }

        if let state = activeBrowserHost?.state {
            applyAccumulatedHelperFlags(to: state)
            if lowerType == "renderer" {
                state.isLoading = false
            }
        } else {
            cefLogger.debug("No activeBrowserHost.state yet; failure flags buffered for attach")
        }
    }

    /// Clears renderer failure state when starting a new navigation (user or programmatic load).
    func clearRendererFailureStateForNewNavigation() {
        helperFailedRenderer = false
        lastMainFrameLoadErrorCode = nil
        lastMainFrameLoadErrorText = nil
    }

    /// Copies accumulated flags into `CEFWebViewState` (call when the browser host attaches state).
    fileprivate func applyAccumulatedHelperFlags(to state: CEFWebViewState) {
        cefLogger.info("🔄 applyAccumulatedHelperFlags: applying spawn flags")

        if helperSpawnedGPU {
            cefLogger.debug("  → Setting state.gpuHelperSpawned = true")
            state.gpuHelperSpawned = true
        }
        if helperSpawnedNetwork {
            cefLogger.debug("  → Setting state.networkHelperSpawned = true")
            state.networkHelperSpawned = true
        }
        if helperSpawnedStorage {
            cefLogger.debug("  → Setting state.storageHelperSpawned = true")
            state.storageHelperSpawned = true
        }
        if helperSpawnedRenderer {
            cefLogger.debug("  → Setting state.rendererHelperSpawned = true")
            state.rendererHelperSpawned = true
        }

        cefLogger.info("🔄 applyAccumulatedHelperFlags: applying failure flags")

        if helperFailedGPU {
            cefLogger.error("  → 🔴 Setting state.gpuHelperFailed = true")
            state.gpuHelperFailed = true
        }
        if helperFailedNetwork {
            cefLogger.error("  → 🔴 Setting state.networkHelperFailed = true")
            state.networkHelperFailed = true
        }
        if helperFailedStorage {
            cefLogger.error("  → 🔴 Setting state.storageHelperFailed = true")
            state.storageHelperFailed = true
        }
        if helperFailedRenderer {
            state.rendererHelperFailed = true
            state.lastMainFrameLoadErrorCode = lastMainFrameLoadErrorCode
            state.lastMainFrameLoadErrorText = lastMainFrameLoadErrorText
        }

        cefLogger.debug("applyAccumulatedHelperFlags complete")
    }

    /// Shutdown CEF gracefully. Should be called on app termination.
    public func shutdown() {
        CEFWrapper.shutdown()
        isInitialized = false
    }
}

// MARK: - CEF Browser Host Wrapper

/// Wraps a CEF browser instance on the main thread.
@MainActor
public final class CEFBrowserHost {
    private var isAlive = true
    /// Observable SwiftUI state; internal so `CEFApplication` can merge accumulated helper-spawn flags.
    internal weak var state: CEFWebViewState?

    /// The native macOS view for CEF rendering.
    public let nativeView: NSView?

    /// Create a browser instance with an initial URL.
    public init(parentView: NSView, url: URL, state: CEFWebViewState? = nil) throws {
        cefLogger.debug("CEFBrowserHost.init() - parentView: \(NSStringFromRect(parentView.frame)), url: \(url.absoluteString)")

        guard let browserView = CEFWrapper.createBrowser(in: parentView, url: url.absoluteString) else {
            let errorMsg = "CEFWrapper.createBrowser returned nil. This indicates the browser subprocess failed to initialize. " +
                          "Likely causes: helper executable crash, dyld library loading failure, JIT entitlements missing, " +
                          "or invalid code signatures. Check system logs and CEF debug log at ~/Library/Caches/com.chromium.webview/debug.log"
            cefLogger.error("BROWSER CREATION FAILED: \(errorMsg, privacy: .public)")
            throw CEFError.browserCreationFailed(reason: errorMsg)
        }

        cefLogger.info("CEF Browser View Created Successfully: \(String(describing: browserView))")
        self.nativeView = browserView
        self.state = state
        if let state {
            CEFApplication.shared.applyAccumulatedHelperFlags(to: state)
        }
    }

    /// Load a URL in the browser.
    func loadURL(_ url: URL) {
        guard isAlive else {
            cefLogger.warning("loadURL called but browserHost is dead")
            return
        }
        CEFApplication.shared.clearRendererFailureStateForNewNavigation()
        state?.rendererHelperFailed = false
        state?.lastMainFrameLoadErrorCode = nil
        state?.lastMainFrameLoadErrorText = nil

        cefLogger.info("loadURL: \(url.absoluteString)")
        CEFWrapper.loadURL(url.absoluteString)
        updateState()
    }

    func reload() {
        guard isAlive else { return }
        CEFWrapper.reloadBrowser()
    }

    func goBack() {
        guard isAlive else { return }
        CEFWrapper.goBack()
        updateState()
    }

    func goForward() {
        guard isAlive else { return }
        CEFWrapper.goForward()
        updateState()
    }

    /// Update state from CEF's current values.
    func updateState() {
        state?.isLoading = CEFWrapper.isLoading()
        state?.canGoBack = CEFWrapper.canGoBack()
        state?.canGoForward = CEFWrapper.canGoForward()
        state?.title = CEFWrapper.currentTitle()
        if let urlString = CEFWrapper.currentURL(),
           let url = URL(string: urlString) {
            state?.currentURL = url
        }
    }

    func close() {
        guard isAlive else { return }
        isAlive = false
        CEFWrapper.closeBrowser()
    }
}

// MARK: - Error Types

enum CEFError: Error {
    case resourcesNotFound
    case initializationFailed(reason: String)
    case browserCreationFailed(reason: String)

    var localizedDescription: String {
        switch self {
        case .resourcesNotFound:
            return "CEF resources not found"
        case .initializationFailed(let reason):
            return "CEF initialization failed: \(reason)"
        case .browserCreationFailed(let reason):
            return "Browser creation failed: \(reason)"
        }
    }
}
