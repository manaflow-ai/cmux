import Darwin
import Foundation

private struct SnapshotPayload: Encodable {
    let path: String
    let displayPaths: [String]
    let contents: String
    let isEditable: Bool
}

private struct Payload: Encodable {
    let cmux: SnapshotPayload
    let ghostty: SnapshotPayload
    let synced: SnapshotPayload
}

@main
private struct ConfigSourceProbe {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: config_source_probe <home-directory>\n", stderr)
            Darwin.exit(64)
        }

        let homeDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let previewDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("cmux-config-probe", isDirectory: true)
        let environment = ConfigSourceEnvironment(
            homeDirectoryURL: homeDirectoryURL,
            previewDirectoryURL: previewDirectoryURL
        )

        let payload = Payload(
            cmux: encodedSnapshot(for: .cmux, environment: environment),
            ghostty: encodedSnapshot(for: .ghostty, environment: environment),
            synced: encodedSnapshot(for: .synced, environment: environment)
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
