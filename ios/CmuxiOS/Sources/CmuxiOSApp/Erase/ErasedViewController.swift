import CmuxiOSDesign
import CmuxiOSSettingsCore
import UIKit

/// Shown after Erase All Data. Stores already in memory must not write the
/// erased data back, so the app stays here until the user closes it; the
/// next launch starts fresh. Items that could not be removed are counted.
@MainActor
final class ErasedViewController: UIViewController {
    private let report: EraseReport

    init(report: EraseReport) {
        self.report = report
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        view.accessibilityIdentifier = "erase.done"
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: report.isComplete ? "checkmark.circle" : "exclamationmark.circle")
        content.imageProperties.tintColor = .secondaryLabel
        content.text = String(localized: "erase.done.title", defaultValue: "All Data Erased", bundle: .module)
        var body = String(localized: "erase.done.body",
                          defaultValue: "Close cmux from the app switcher to finish. The next launch starts fresh.", bundle: .module)
        if !report.isComplete {
            body += "\n\n" + String(format: String(localized: "erase.done.failures",
                                                   defaultValue: "%lld items could not be removed. Delete the app to remove them.",
                                                   bundle: .module), report.failures.count)
        }
        content.secondaryText = body
        contentUnavailableConfiguration = content
    }
}
