import AppKit
import CEFWrapper
import SwiftUI
import os.log

private let logger = Logger(subsystem: "co.sstools.CEFWebView", category: "CEFWebView")

/// Hosting view that tells CEF when SwiftUI/AppKit changes its size (required for SetAsChild / windowed embedding).
private final class CEFBrowserContainerView: NSView {
    /// Match top-left origin with Chromium’s SetAsChild expectations (default NSView is bottom-left).
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        // No intrinsic size - let SwiftUI frame dictate the size
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        logger.debug("📐 CEFBrowserContainerView.layout() called, bounds: \(NSStringFromRect(self.bounds))")
        CEFWrapper.notifyBrowserViewGeometryChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        logger.debug("📏 CEFBrowserContainerView.setFrameSize(\(NSStringFromSize(newSize))) called")
        super.setFrameSize(newSize)
        logger.debug("📏 After setFrameSize, bounds: \(NSStringFromRect(self.bounds))")
        CEFWrapper.notifyBrowserViewGeometryChanged()
    }
}

// MARK: - NSViewRepresentable Wrapper

public struct CEFWebView: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var state: CEFWebViewState

    public init(url: Binding<URL?>, state: Binding<CEFWebViewState>) {
        self._url = url
        self._state = state
    }

    public func makeNSView(context: Context) -> NSView {
        logger.info("🔍 [1/3 CRITICAL PATH] CEFWebView.makeNSView ENTRY")

        // Create container view — will be sized by SwiftUI layout system
        let container = CEFBrowserContainerView(frame: .zero)
        logger.debug("📦 Created CEFBrowserContainerView with frame: \(NSStringFromRect(container.frame))")
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.autoresizesSubviews = true

        // Store container for later use
        context.coordinator.container = container
        logger.debug("✅ Stored container in coordinator")

        // Initialize CEF on first use (only once, safe to call repeatedly)
        do {
            logger.debug("🔧 Attempting CEF initialization...")
            try CEFApplication.shared.initialize()
            logger.debug("✅ CEFApplication.shared.initialize() succeeded")
        } catch let error as NSError {
            let errorDesc = "CEF Initialization Failed: \(error.localizedDescription)"
            logger.error("❌ CEF initialization failed: \(errorDesc, privacy: .public)")
            state.initializationError = errorDesc
            return container
        } catch {
            let errorDesc = "CEF Initialization Failed: \(error)"
            logger.error("❌ CEF initialization failed: \(errorDesc, privacy: .public)")
            state.initializationError = errorDesc
            return container
        }

        // DON'T create browser here — we have zero bounds. Wait for updateNSView when view is properly sized.
        context.coordinator.lastNavigationKeyFromBinding = nil
        logger.debug("📝 Set lastNavigationKeyFromBinding = nil, waiting for updateNSView...")

        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = context.coordinator.container else {
            logger.error("❌ updateNSView: container is nil!")
            return
        }

        logger.info("📍 updateNSView called (browserHost: \(context.coordinator.browserHost != nil ? "EXISTS" : "nil"))")
        logger.info("   - nsView.bounds: \(NSStringFromRect(nsView.bounds))")
        logger.info("   - nsView.frame: \(NSStringFromRect(nsView.frame))")
        logger.info("   - container.bounds: \(NSStringFromRect(container.bounds))")
        logger.info("   - container.frame: \(NSStringFromRect(container.frame))")
        logger.info("   - browserHost present: \(context.coordinator.browserHost != nil)")

        // Update container frame to match parent bounds
        if !nsView.bounds.isEmpty {
            if container.frame != nsView.bounds {
                logger.debug("📐 updateNSView: Updating container from \(NSStringFromRect(container.frame)) to \(NSStringFromRect(nsView.bounds))")
                container.frame = nsView.bounds
                CEFWrapper.notifyBrowserViewGeometryChanged()
            }
        } else {
            // SwiftUI not sizing the view - use a sensible default so CEF can render
            let defaultSize = NSSize(width: 800, height: 600)
            if container.frame.size != defaultSize {
                logger.warning("⚠️ nsView.bounds is EMPTY, setting default container size: \(NSStringFromSize(defaultSize))")
                container.frame = NSRect(origin: .zero, size: defaultSize)
                CEFWrapper.notifyBrowserViewGeometryChanged()
            }
        }

        // Create browser on first updateNSView call (bounds may still be zero, but we need to try)
        logger.debug("🔍 Checking browser creation: browserHost=\(context.coordinator.browserHost != nil)")
        if context.coordinator.browserHost == nil {
            logger.info("🔍 [2/3 CRITICAL PATH] First updateNSView - creating browser")
            let initialURL = url ?? URL(string: "about:blank")!
            logger.debug("📋 Initial URL: \(initialURL.absoluteString)")
            logger.debug("📐 Container bounds: \(NSStringFromRect(container.bounds))")
            logger.debug("📐 NSView bounds: \(NSStringFromRect(nsView.bounds))")

            do {
                logger.debug("🔧 Calling CEFBrowserHost.init()...")
                let host = try CEFBrowserHost(parentView: container, url: initialURL, state: state)
                logger.debug("✅ CEFBrowserHost created successfully")

                context.coordinator.browserHost = host
                logger.debug("✅ Stored browserHost in coordinator")

                CEFApplication.shared.activeBrowserHost = host
                logger.debug("✅ Set activeBrowserHost on CEFApplication")

                state.setBrowserHost(host)
                logger.debug("✅ Set browserHost on state")

                state.currentURL = url
                context.coordinator.lastNavigationKeyFromBinding = url.map(Self.stableNavigationKey)

                // Load the initial URL immediately after browser creation
                // (updateNSView may not be called again after this, so do it now)
                if let urlToLoad = url {
                    logger.info("🔍 Loading initial URL immediately: \(urlToLoad.absoluteString)")
                    host.loadURL(urlToLoad)
                }

                logger.info("✅ [2/3 CRITICAL PATH] CEFBrowserHost initialized successfully")
            } catch let error as CEFError {
                logger.error("❌ [2/3 CRITICAL PATH] Browser creation failed: \(error.localizedDescription, privacy: .public)")
                state.initializationError = error.localizedDescription
                return
            } catch {
                logger.error("❌ [2/3 CRITICAL PATH] Browser creation failed: \(String(describing: error), privacy: .public)")
                state.initializationError = "Browser Creation Failed: \(error)"
                return
            }
        }

        // Now handle URL binding changes
        guard let host = context.coordinator.browserHost else {
            logger.debug("⚠️ No browserHost yet")
            return
        }

        let key = url.map(Self.stableNavigationKey)
        logger.debug("URL binding check: key=\(key?.prefix(50) ?? "nil"), lastKey=\(context.coordinator.lastNavigationKeyFromBinding?.prefix(50) ?? "nil")")

        if key != context.coordinator.lastNavigationKeyFromBinding {
            context.coordinator.lastNavigationKeyFromBinding = key
            if let url {
                logger.info("🔍 [3/3 CRITICAL PATH] Binding URL changed, calling loadURL: \(url.absoluteString)")
                host.loadURL(url)
                state.currentURL = url
            } else {
                logger.info("URL is nil, not loading")
            }
        } else {
            logger.debug("URL key unchanged, skipping loadURL")
        }
    }

    /// Normalized key for “same navigation” so trailing slashes / percent-encoding don’t double-load.
    private static func stableNavigationKey(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.browserHost?.close()
        CEFApplication.shared.activeBrowserHost = nil
    }

    public class Coordinator {
        var browserHost: CEFBrowserHost?
        var container: NSView?
        /// Stable string form of last applied `$url` (see `stableNavigationKey`).
        var lastNavigationKeyFromBinding: String?
    }

}

#Preview {
    @Previewable @State var url: URL? = URL(string: "https://google.com")
    @Previewable @State var state = CEFWebViewState()

    VStack {
        HStack {
            Button(action: { state.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!state.canGoBack)

            Button(action: { state.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!state.canGoForward)

            Button(action: { state.reload() }) {
                Image(systemName: "arrow.clockwise")
            }

            TextField("URL", value: $url, format: .url)
                .textFieldStyle(.roundedBorder)
        }
        .padding()

        CEFWebView(url: $url, state: $state)
    }
}
