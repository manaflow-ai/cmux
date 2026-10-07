import UIKit

/// A downloaded file ready to show.
public struct LocalFile: Hashable, Sendable {
    public var url: URL
    public var name: String
    public var mime: String?
    /// Where it came from on the Mac.
    public var remotePath: String?

    public init(url: URL, name: String, mime: String? = nil, remotePath: String? = nil) {
        self.url = url
        self.name = name
        self.mime = mime
        self.remotePath = remotePath
    }
}

/// Seam for C13 (viewers): shows a downloaded file. The default is
/// QuickLook; C13 registers its text, Markdown, image and PDF viewer here.
@MainActor
public protocol FileViewerHook: AnyObject {
    func present(_ file: LocalFile, from presenter: UIViewController)
}
