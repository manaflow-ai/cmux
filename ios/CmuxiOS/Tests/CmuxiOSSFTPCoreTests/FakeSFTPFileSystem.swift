import CmuxiOSSFTPCore
import CmuxMobileSSH
import Foundation

/// An in-memory SFTP tree for the phone-side SFTP tests. `dropAfter` makes
/// the next transfer write that many bytes and then lose the session.
final class FakeSFTPFileSystem: SFTPFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = ["/", "/home", "/home/me"]
    private var links: Set<String> = []
    private var dropAfter: Int?
    private(set) var resumeOffsets: [UInt64] = []

    func put(_ path: String, _ data: Data) { locked { files[path] = data } }
    func file(_ path: String) -> Data? { locked { files[path] } }
    func addDirectory(_ path: String) { locked { _ = directories.insert(path) } }
    func addLink(_ path: String) { locked { _ = links.insert(path) } }
    func isDirectory(_ path: String) -> Bool { locked { directories.contains(path) } }
    func dropNextTransfer(after bytes: Int) { locked { dropAfter = bytes } }
    var offsets: [UInt64] { locked { resumeOffsets } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func realpath(_ path: String) async throws -> String { path == "." ? "/home/me" : path }

    func stat(_ path: String) async throws -> SFTPAttributes {
        try locked {
            if let data = files[path] { return SFTPAttributes(size: UInt64(data.count), permissions: 0o100644) }
            if directories.contains(path) { return SFTPAttributes(size: 0, permissions: 0o040755) }
            throw SFTPError.noSuchFile
        }
    }

    func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        try locked {
            guard directories.contains(path) else { throw SFTPError.noSuchFile }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            func child(_ full: String) -> String? {
                guard full.hasPrefix(prefix), full != path else { return nil }
                let rest = full.dropFirst(prefix.count)
                return rest.contains("/") ? nil : String(rest)
            }
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            var entries: [SFTPEntry] = []
            for (full, data) in files { if let name = child(full) {
                entries.append(SFTPEntry(name: name, attributes: SFTPAttributes(size: UInt64(data.count), permissions: 0o100644, accessTime: when, modificationTime: when)))
            } }
            for full in directories { if let name = child(full) {
                entries.append(SFTPEntry(name: name, attributes: SFTPAttributes(size: 0, permissions: 0o040755, accessTime: when, modificationTime: when)))
            } }
            for full in links { if let name = child(full) {
                entries.append(SFTPEntry(name: name, attributes: SFTPAttributes(size: 0, permissions: 0o120777)))
            } }
            return entries.sorted { $0.name < $1.name }
        }
    }

    func mkdir(_ path: String, permissions: UInt32?) async throws {
        try locked {
            guard !directories.contains(path), files[path] == nil else { throw SFTPError.failure("exists") }
            directories.insert(path)
        }
    }

    func remove(_ path: String) async throws {
        try locked { guard files.removeValue(forKey: path) != nil else { throw SFTPError.noSuchFile } }
    }

    func rmdir(_ path: String) async throws {
        try locked { guard directories.remove(path) != nil else { throw SFTPError.noSuchFile } }
    }

    func rename(_ source: String, to destination: String) async throws {
        try locked {
            guard files[destination] == nil, !directories.contains(destination) else { throw SFTPError.failure("exists") }
            if let data = files.removeValue(forKey: source) { files[destination] = data; return }
            if directories.remove(source) != nil { directories.insert(destination); return }
            throw SFTPError.noSuchFile
        }
    }

    func download(_ remote: String, to localURL: URL, resumeFrom: UInt64,
                  progress: (@Sendable (SFTPTransferProgress) -> Void)?) async throws {
        let (data, drop) = try locked { () -> (Data, Int?) in
            guard let data = files[remote] else { throw SFTPError.noSuchFile }
            resumeOffsets.append(resumeFrom)
            defer { dropAfter = nil }
            return (data, dropAfter)
        }
        var local = resumeFrom > 0 ? ((try? Data(contentsOf: localURL)) ?? Data()).prefix(Int(resumeFrom)) : Data()
        let end = drop.map { min(data.count, local.count + $0) } ?? data.count
        local.append(data.subdata(in: local.count..<end))
        try local.write(to: localURL)
        progress?(SFTPTransferProgress(bytesTransferred: UInt64(local.count), totalBytes: UInt64(data.count)))
        if drop != nil { throw SFTPError.connectionLost }
    }

    func upload(from localURL: URL, to remote: String, resumeFrom: UInt64,
                progress: (@Sendable (SFTPTransferProgress) -> Void)?) async throws {
        let data = try Data(contentsOf: localURL)
        let drop = locked { () -> Int? in
            resumeOffsets.append(resumeFrom)
            defer { dropAfter = nil }
            return dropAfter
        }
        var stored = resumeFrom > 0 ? (locked { files[remote] } ?? Data()).prefix(Int(resumeFrom)) : Data()
        let end = drop.map { min(data.count, stored.count + $0) } ?? data.count
        stored.append(data.subdata(in: stored.count..<end))
        locked { files[remote] = Data(stored) }
        progress?(SFTPTransferProgress(bytesTransferred: UInt64(stored.count), totalBytes: UInt64(data.count)))
        if drop != nil { throw SFTPError.connectionLost }
    }
}

/// Counts opens and resets; hands out the same fake tree.
actor FakeSFTPOpener: SFTPSessionOpening {
    let system: FakeSFTPFileSystem
    private(set) var opens = 0
    private(set) var resets = 0
    private(set) var closed = false

    init(system: FakeSFTPFileSystem) { self.system = system }

    func fileSystem() async throws -> any SFTPFileSystem {
        opens += 1
        return system
    }

    func reset() async { resets += 1 }
    func close() async { closed = true }
}
