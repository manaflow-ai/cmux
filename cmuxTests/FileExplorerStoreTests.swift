import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock Provider

final class MockFileExplorerProvider: FileExplorerProvider {
    var homePath: String
    var isAvailable: Bool
    var listings: [String: Result<[FileExplorerEntry], Error>] = [:]
    var listCallCount = 0
    var listCallPaths: [String] = []
    /// Optional delay (seconds) before returning results
    var delay: TimeInterval = 0

    init(homePath: String = "/home/user", isAvailable: Bool = true) {
        self.homePath = homePath
        self.isAvailable = isAvailable
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallCount += 1
        listCallPaths.append(path)

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }

        if let result = listings[path] {
            return try result.get()
        }
        return []
    }
}

final class MockSSHFileExplorerTransport: SSHFileExplorerTransport {
    var homePath: Result<String, Error>
    var listings: [String: Result<[FileExplorerEntry], Error>] = [:]
    var downloads: [String: Result<Data, Error>] = [:]
    private(set) var resolvedHomeConnections: [SSHFileExplorerConnection] = []
    private(set) var listedPaths: [String] = []
    private(set) var downloadedPaths: [String] = []

    init(homePath: Result<String, Error> = .success("/home/dev")) {
        self.homePath = homePath
    }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        resolvedHomeConnections.append(connection)
        return try homePath.get()
    }

    func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        listedPaths.append(path)
        if let result = listings[path] {
            return try result.get()
        }
        return []
    }

    func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        downloadedPaths.append(path)
        let data = try downloads[path, default: .success(Data())].get()
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL)
    }
}

final class DeferredListFileExplorerProvider: FileExplorerProvider {
    var homePath = "/home/dev"
    var isAvailable = true
    private(set) var listCallPaths: [String] = []
    private var continuation: CheckedContinuation<[FileExplorerEntry], Error>?

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallPaths.append(path)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeListing(returning entries: [FileExplorerEntry]) {
        continuation?.resume(returning: entries)
        continuation = nil
    }
}

// MARK: - Store Tests

/// The store's `@Published` state is driven by unstructured `Task { ... }` calls that
/// hop to `@MainActor`. Pinning the test class to `@MainActor` keeps observations on
/// the same actor as the mutations, so reads see a consistent snapshot.
@MainActor
final class FileExplorerStoreTests: XCTestCase {

    struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Poll until `condition` holds or `timeout` elapses.
    /// The timeout runs off the main actor so a wedged main-actor load fails the
    /// specific test instead of consuming the whole CI job timeout.
    nonisolated func waitFor(
        _ description: String,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @escaping @Sendable () -> Bool
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        if await MainActor.run(body: condition) {
                            return
                        }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw WaitTimeout(description: description)
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await MainActor.run {
                XCTFail("Timed out waiting for: \(description)", file: file, line: line)
            }
            throw error
        }
    }

    // MARK: - Basic loading

}

