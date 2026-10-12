import Foundation

/// Credentials saved by `cmux-native-host register`.
public struct HostConfig: Codable, Equatable, Sendable {
    public var api: URL
    public var hostID: String
    public var hostSecret: String
    public var name: String

    public init(api: URL, hostID: String, hostSecret: String, name: String) {
        self.api = api
        self.hostID = hostID
        self.hostSecret = hostSecret
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case api, name
        case hostID = "host_id"
        case hostSecret = "host_secret"
    }
}

/// Reads and writes `~/Library/Application Support/cmux-native-host/host.json`
/// (file mode 600, directory 700).
public struct HostConfigStore: Sendable {
    public var url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-native-host/host.json")
    }

    public func load() throws -> HostConfig {
        try JSONDecoder().decode(HostConfig.self, from: Data(contentsOf: url))
    }

    public func save(_ config: HostConfig) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        // Create with 600 before any secret bytes land on disk.
        let tmp = dir.appending(path: ".host.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.write(contentsOf: data)
        try handle.close()
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
