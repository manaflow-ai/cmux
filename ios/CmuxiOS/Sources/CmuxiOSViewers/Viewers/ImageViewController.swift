import UIKit

/// An image with pinch and double-tap zoom, fitted to the screen.
@MainActor
final class ImageViewController: UIViewController, UIScrollViewDelegate {
    private let url: URL
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = url.lastPathComponent
        imageView.accessibilityIdentifier = "viewers.image"
        scrollView.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let url = url
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            self?.show(image)
        }
    }

    private func show(_ image: UIImage?) {
        guard let image else {
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "photo")
            content.text = ViewersText.errorTitle(.failed(""))
            contentUnavailableConfiguration = content
            return
        }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        fit()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fit()
    }

    private func fit() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, scrollView.bounds.width > 0 else { return }
        let scale = min(scrollView.bounds.width / size.width, scrollView.bounds.height / size.height, 1)
        scrollView.minimumZoomScale = scale
        scrollView.maximumZoomScale = max(scale * 8, 4)
        if scrollView.zoomScale < scale || scrollView.zoomScale == 1 { scrollView.zoomScale = scale }
        center()
    }

    private func center() {
        let x = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
        let y = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 3)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                            animated: animated)
        }
    }
}
