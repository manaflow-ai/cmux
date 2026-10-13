import PDFKit
import QuickLook
import SafariServices
import SwiftUI
import UIKit
import WebKit

// MARK: - Image

/// Pinch to zoom, pan, and double-tap to toggle 1x/2.5x at the tap point.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        if view.imageView.image !== image { view.setImage(image) }
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "Image")
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBoundsSize, let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            center()
            return
        }
        lastBoundsSize = bounds.size
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = 1
        maximumZoomScale = max(4, 1 / max(fit, 0.01))
        center()
    }

    private func center() {
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        let insetY = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

// MARK: - PDF

struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

// MARK: - Web

/// Renders HTML (Markdown, SVG, HTML files) in a non-persistent web view.
/// Script is off: previews are documents, not apps. Link taps go to `openURL`.
struct WebPreview: UIViewRepresentable {
    enum Source: Equatable {
        case html(String, baseURL: URL?)
        case file(URL)
    }

    let source: Source
    var openURL: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        applyBackground(to: view)
        view.navigationDelegate = context.coordinator
        context.coordinator.openURL = openURL
        load(source, into: view)
        context.coordinator.loaded = source
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.openURL = openURL
        guard context.coordinator.loaded != source else { return }
        context.coordinator.loaded = source
        applyBackground(to: view)
        load(source, into: view)
    }

    /// An HTML or SVG file is drawn on white, as Safari and Quick Look do:
    /// a page without its own colors has black text, which vanished on the
    /// clear (dark) background. Rendered markdown brings its own colors.
    private func applyBackground(to view: WKWebView) {
        let pageColors: Bool
        if case .file = source { pageColors = true } else { pageColors = false }
        view.isOpaque = pageColors
        view.backgroundColor = pageColors ? .white : .clear
        view.scrollView.backgroundColor = pageColors ? .white : .clear
    }

    private func load(_ source: Source, into view: WKWebView) {
        switch source {
        case .html(let html, let baseURL): view.loadHTMLString(html, baseURL: baseURL)
        case .file(let url): view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var openURL: ((URL) -> Void)?
        var loaded: Source?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            if url.fragment != nil, url.scheme == webView.url?.scheme, url.path == webView.url?.path { return .allow }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { openURL?(url) }
            return .cancel
        }
    }
}

// MARK: - QuickLook

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Safari and export

/// In-app browser for references of kind `url`.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// "Save to Files": exports a copy of a temp file through the document picker.
struct FileExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// An identifiable URL for `.sheet(item:)`.
struct PresentedURL: Identifiable, Hashable {
    var url: URL
    var id: String { url.absoluteString }
}
