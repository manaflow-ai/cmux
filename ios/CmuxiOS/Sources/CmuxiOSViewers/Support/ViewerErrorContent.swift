import CmuxiOSViewersCore
import UIKit

/// The empty state for a failed read, with Try Again.
@MainActor
struct ViewerErrorContent {
    static func configuration(_ error: ViewerSourceError, retry: (() -> Void)?) -> UIContentUnavailableConfiguration {
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: symbol(error))
        content.text = ViewersText.errorTitle(error)
        content.secondaryText = ViewersText.errorBody(error)
        if let retry {
            var button = UIButton.Configuration.borderedTinted()
            button.title = ViewersText.retry
            button.baseForegroundColor = .label
            button.baseBackgroundColor = .tertiarySystemFill
            content.button = button
            content.buttonProperties.primaryAction = UIAction { _ in retry() }
        }
        return content
    }

    static func symbol(_ error: ViewerSourceError) -> String {
        switch error {
        case .noConnection, .needsDirectConnection: "wifi.slash"
        case .noWorkspaceFolder, .notFound: "folder.badge.questionmark"
        case .notARepository: "arrow.triangle.branch"
        case .forbidden: "lock"
        case .tooLarge: "externaldrive.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}
