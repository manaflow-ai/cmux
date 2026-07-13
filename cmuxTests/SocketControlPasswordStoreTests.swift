import Foundation
import Testing
import CmuxSettings

@Suite(.serialized)
struct SocketControlPasswordStoreTests {
    private func makeTemporaryDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocketControlPasswordStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test
    func loadsPasswordFromExplicitFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("socket-control-password")
        try "hunter2".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SocketControlPasswordStore(environment: [:], fileURL: fileURL)
        #expect(try store.loadPassword() == "hunter2")
    }

    @Test
    func returnsNilWhenFileMissing() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("missing-file")

        let store = SocketControlPasswordStore(environment: [:], fileURL: fileURL)
        #expect(try store.loadPassword() == nil)
    }

    @Test
    func verifiesPasswordFromEnvironment() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SocketControlPasswordStore(
            environment: ["CMUX_SOCKET_PASSWORD": "swordfish"],
            fileURL: directory.appendingPathComponent("missing-file")
        )
        #expect(store.verify(password: "swordfish"))
    }

    @Test
    func failsVerificationWhenNoPasswordConfigured() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SocketControlPasswordStore(
            environment: [:],
            fileURL: directory.appendingPathComponent("missing-file")
        )
        #expect(!store.verify(password: "swordfish"))
    }
}
