import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Issue #35930: a scrollback checkpoint and a session autosave look up resume
/// approvals once per terminal on the main thread. Each lookup re-parsed the
/// whole `cmux.json`, so a few hundred terminals stalled the app for seconds.
@Suite(.serialized) struct SurfaceResumeApprovalRecordsCacheTests {
    private let secret = Data("issue-35930-approval-secret".utf8)

    @Test func checkpointPassOverManyTerminalsParsesTheStoreOnce() throws {
        let store = try TemporaryApprovalStore()
        let record = try store.approve("claude --resume issue-35930", secret: secret)
        let cache = SurfaceResumeApprovalRecordsCache(observesStoreWrites: false)
        let loads = LoadCounter()

        for _ in 0..<266 {
            let records = cache.validRecords(
                fileURL: store.url,
                dependencies: SurfaceResumeApprovalStore.recordDependencies(for: store.url),
                secret: secret
            ) {
                loads.increment()
                return SurfaceResumeApprovalStore.loadRecords(fileURL: store.url)
            }
            #expect(records.map(\.id) == [record.id])
        }

        #expect(loads.value == 1, "an unchanged store must be parsed once per pass, not once per terminal")
    }

    @Test func editedStoreIsReloaded() throws {
        let store = try TemporaryApprovalStore()
        let first = try store.approve("claude --resume first", secret: secret)
        let cache = SurfaceResumeApprovalRecordsCache(observesStoreWrites: false)
        let lookup = {
            cache.validRecords(
                fileURL: store.url,
                dependencies: SurfaceResumeApprovalStore.recordDependencies(for: store.url),
                secret: secret
            ) {
                SurfaceResumeApprovalStore.loadRecords(fileURL: store.url)
            }.map(\.id)
        }

        #expect(lookup() == [first.id])
        let second = try store.approve("codex resume second", secret: secret)
        #expect(Set(lookup()) == [first.id, second.id])
        try FileManager.default.removeItem(at: store.url)
        #expect(lookup().isEmpty)
    }

    @Test func recordsSignedWithAnotherSecretStayRejected() throws {
        let store = try TemporaryApprovalStore()
        _ = try store.approve("claude --resume signed-elsewhere", secret: secret)
        let cache = SurfaceResumeApprovalRecordsCache(observesStoreWrites: false)
        let dependencies = SurfaceResumeApprovalStore.recordDependencies(for: store.url)

        let trusted = cache.validRecords(fileURL: store.url, dependencies: dependencies, secret: secret) {
            SurfaceResumeApprovalStore.loadRecords(fileURL: store.url)
        }
        let foreign = cache.validRecords(
            fileURL: store.url,
            dependencies: dependencies,
            secret: Data("another-secret".utf8)
        ) {
            SurfaceResumeApprovalStore.loadRecords(fileURL: store.url)
        }

        #expect(trusted.count == 1)
        #expect(foreign.isEmpty)
    }

    @Test func storeWriteInTheSameTimestampTickIsNotServedStale() throws {
        let store = try TemporaryApprovalStore()
        // A stamp that never changes stands in for a write landing within one
        // filesystem timestamp tick; the store's change notification still
        // has to invalidate the cached answer.
        let frozen = SurfaceResumeApprovalRecordsCache.FileStamp(
            device: 1,
            inode: 1,
            size: 1,
            modifiedSeconds: 1,
            modifiedNanoseconds: 1
        )
        let cache = SurfaceResumeApprovalRecordsCache(stamp: { _ in frozen })
        let lookup = {
            cache.validRecords(fileURL: store.url, dependencies: [store.url], secret: secret) {
                SurfaceResumeApprovalStore.loadRecords(fileURL: store.url)
            }.map(\.id)
        }

        #expect(lookup().isEmpty)
        let record = try store.approve("claude --resume same-tick", secret: secret)
        #expect(lookup() == [record.id])
    }

    @Test func sharedStoreLookupReflectsApprovalsAndDeletes() throws {
        let store = try TemporaryApprovalStore()
        let record = try store.approve("claude --resume shared", secret: secret)

        #expect(SurfaceResumeApprovalStore.validRecords(fileURL: store.url, signingSecret: secret).map(\.id) == [record.id])
        #expect(SurfaceResumeApprovalStore.delete(recordId: record.id, fileURL: store.url))
        #expect(SurfaceResumeApprovalStore.validRecords(fileURL: store.url, signingSecret: secret).isEmpty)
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// A `cmux.json` approval store in its own temporary directory.
private final class TemporaryApprovalStore {
    let root: URL
    let url: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-35930-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("cmux.json", isDirectory: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func approve(_ command: String, secret: Data) throws -> SurfaceResumeApprovalRecord {
        try #require(SurfaceResumeApprovalStore.approve(
            binding: SurfaceResumeBindingSnapshot(
                command: command,
                cwd: root.path,
                source: nil,
                environment: ["PATH": "/usr/bin:/bin"]
            ),
            policy: .auto,
            fileURL: url,
            signingSecret: secret
        ))
    }
}
