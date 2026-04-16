import SwiftUI

// MARK: - Helper Process Status

public struct HelperStatus {
    public let name: String
    public var isSpawned: Bool = false
    public var timestamp: Date?
}

// MARK: - Observable State

@MainActor
@Observable
public final class CEFWebViewState {
    public var isLoading: Bool = false
    public var estimatedProgress: Double = 0.0
    public var title: String?
    public var currentURL: URL?
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    /// Error message if CEF initialization or browser creation failed. Non-nil indicates a critical failure.
    public var initializationError: String?

    /// Helper process status tracking
    public var gpuHelperSpawned: Bool = false
    public var networkHelperSpawned: Bool = false
    public var storageHelperSpawned: Bool = false
    public var rendererHelperSpawned: Bool = false

    /// Helper failure tracking
    public var gpuHelperFailed: Bool = false
    public var networkHelperFailed: Bool = false
    public var storageHelperFailed: Bool = false
    public var rendererHelperFailed: Bool = false

    /// Main-frame load error from CEF `OnLoadError` (when renderer failure is due to navigation error).
    public var lastMainFrameLoadErrorCode: Int?
    public var lastMainFrameLoadErrorText: String?

    /// Single line for the status bar when `rendererHelperFailed` is true.
    public var rendererFailureStatusLine: String {
        if let code = lastMainFrameLoadErrorCode {
            let detail = lastMainFrameLoadErrorText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.isEmpty {
                return "Load failed (error \(code))"
            }
            return "Load failed: \(detail) (error \(code))"
        }
        if let t = lastMainFrameLoadErrorText, !t.isEmpty {
            return "Load failed: \(t)"
        }
        return "Renderer process failed"
    }

    private weak var browserHost: CEFBrowserHost?

    public init() {}

    internal func setBrowserHost(_ host: CEFBrowserHost) {
        self.browserHost = host
    }

    public func reload() {
        browserHost?.reload()
    }

    public func goBack() {
        browserHost?.goBack()
    }

    public func goForward() {
        browserHost?.goForward()
    }
}
