import Foundation

/// Carries the original folder loader and scope into one lazily pushed child route.
struct ChatArtifactFolderRoute: Sendable {
    let path: String
    let scope: ChatArtifactViewerScope
    let loader: ChatArtifactLoader

    init(
        parentPath: String,
        childName: String,
        scope: ChatArtifactViewerScope,
        loader: ChatArtifactLoader
    ) {
        path = (parentPath as NSString).appendingPathComponent(childName)
        self.scope = scope
        self.loader = loader
    }
}
