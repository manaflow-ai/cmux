import Darwin
import Foundation

private struct SnapshotPayload: Encodable {
    let path: String
    let displayPaths: [String]
    let contents: String
    let isEditable: Bool
}

private struct Payload: Encodable {
    let sources: [String]
    let cmux: SnapshotPayload
    let synced: SnapshotPayload
    let loadPaths: [String]
}

@main
private struct ConfigSourceProbe {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: config_source_probe <home-directory> [bundle-identifier]\n", stderr)
            Darwin.exit(64)
        }

        let homeDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let bundleIdentifier: String
        if CommandLine.arguments.count >= 3 {
            bundleIdentifier = CommandLine.arguments[2]
        } else {
            bundleIdentifier = "com.cmuxterm.app"
        }
        let previewDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("cmux-config-probe", isDirectory: true)
        let appSupportDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let environment = ConfigSourceEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            currentBundleIdentifier: bundleIdentifier,
            previewDirectoryURL: previewDirectoryURL
        )

        let payload = Payload(
            sources: ConfigSource.allCases.map(\.rawValue),
            cmux: encodedSnapshot(for: .cmux, environment: environment),
            synced: encodedSnapshot(for: .synced, environment: environment),
            loadPaths: CmuxGhosttyConfigPathResolver.loadConfigURLs(
                currentBundleIdentifier: bundleIdentifier,
                appSupportDirectory: appSupportDirectoryURL
            )
            .map(\.path)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
    }

    private static func encodedSnapshot(
        for source: ConfigSource,
        environment: ConfigSourceEnvironment
    ) -> SnapshotPayload {
        let snapshot = source.snapshot(environment: environment)
        return SnapshotPayload(
            path: snapshot.primaryURL.path,
            displayPaths: snapshot.displayPaths,
            contents: snapshot.contents,
            isEditable: snapshot.isEditable
        )
    }
}
