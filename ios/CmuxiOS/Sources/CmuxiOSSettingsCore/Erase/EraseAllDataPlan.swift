public import Foundation

/// What Erase All Data removes on this device (e5-extras.md section 3):
/// every Keychain class in the app's own access group, the contents of the
/// app sandbox's data directories, the app's defaults domain, and in each
/// App Group only the folder and suite keys named by this bundle id, because
/// the group id is shared by every build of the team. Nothing outside those
/// roots is listed, so other apps' data is never touched.
public struct EraseAllDataPlan: Hashable, Sendable {
    public var items: [EraseItem]

    public init(items: [EraseItem]) {
        self.items = items
    }

    /// The sandbox directories whose contents go.
    public struct Sandbox: Hashable, Sendable {
        public var applicationSupport: URL?
        public var caches: URL?
        public var documents: URL?
        public var temporary: URL?

        public init(applicationSupport: URL?, caches: URL?, documents: URL?, temporary: URL?) {
            self.applicationSupport = applicationSupport
            self.caches = caches
            self.documents = documents
            self.temporary = temporary
        }

        /// This process's directories.
        public static var current: Sandbox {
            let manager = FileManager.default
            return Sandbox(
                applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                caches: manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
                documents: manager.urls(for: .documentDirectory, in: .userDomainMask).first,
                temporary: manager.temporaryDirectory)
        }
    }

    public static func standard(bundleID: String, sandbox: Sandbox, groups: [AppGroupContainer]) -> EraseAllDataPlan {
        var items = KeychainItemClass.allCases.map(EraseItem.keychain)
        for directory in [sandbox.applicationSupport, sandbox.caches, sandbox.documents, sandbox.temporary].compactMap({ $0 }) {
            items.append(.directoryContents(directory))
        }
        if !bundleID.isEmpty {
            items.append(.defaultsDomain(bundleID))
            for group in groups {
                if let folder = namespace(of: group, bundleID: bundleID) { items.append(.folder(folder)) }
                items.append(.defaultsKeys(suite: group.id, prefix: bundleID + "."))
            }
        }
        return EraseAllDataPlan(items: items)
    }

    /// `<container>/<bundle id>`: this build's folder in a shared group.
    /// Nil when the id could escape the container (empty, `/`, `..`).
    static func namespace(of group: AppGroupContainer, bundleID: String) -> URL? {
        guard let container = group.url, !bundleID.isEmpty, !bundleID.contains("/"), bundleID != ".", bundleID != ".." else {
            return nil
        }
        let folder = container.appendingPathComponent(bundleID, isDirectory: true)
        // Belt and braces: the folder must be a direct child of the container.
        guard folder.standardizedFileURL.deletingLastPathComponent().path == container.standardizedFileURL.path else { return nil }
        return folder
    }
}
