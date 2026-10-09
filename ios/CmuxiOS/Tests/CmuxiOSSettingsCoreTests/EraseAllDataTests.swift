@testable import CmuxiOSSettingsCore
import Foundation
import Testing

struct EraseAllDataTests {
    private func sandbox(in root: URL) -> EraseAllDataPlan.Sandbox {
        EraseAllDataPlan.Sandbox(
            applicationSupport: root.appendingPathComponent("Library/Application Support", isDirectory: true),
            caches: root.appendingPathComponent("Library/Caches", isDirectory: true),
            documents: root.appendingPathComponent("Documents", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    // MARK: The plan

    @Test func planListsEveryKeychainClassSandboxDirectoryAndTheDefaultsDomain() throws {
        let root = URL(fileURLWithPath: "/sandbox", isDirectory: true)
        let plan = EraseAllDataPlan.standard(bundleID: "dev.cmux.ios.nxe5", sandbox: sandbox(in: root), groups: [])
        #expect(plan.items == [
            .keychain(.genericPassword), .keychain(.internetPassword), .keychain(.key), .keychain(.certificate), .keychain(.identity),
            .directoryContents(URL(fileURLWithPath: "/sandbox/Library/Application Support", isDirectory: true)),
            .directoryContents(URL(fileURLWithPath: "/sandbox/Library/Caches", isDirectory: true)),
            .directoryContents(URL(fileURLWithPath: "/sandbox/Documents", isDirectory: true)),
            .directoryContents(URL(fileURLWithPath: "/sandbox/tmp", isDirectory: true)),
            .defaultsDomain("dev.cmux.ios.nxe5"),
        ])
    }

    @Test func sharedGroupsLoseOnlyThisBuildsFolderAndKeys() {
        let group = AppGroupContainer(id: "group.dev.cmux.ios", url: URL(fileURLWithPath: "/groups/cmux", isDirectory: true))
        let plan = EraseAllDataPlan.standard(bundleID: "dev.cmux.ios.nxe5",
                                             sandbox: EraseAllDataPlan.Sandbox(applicationSupport: nil, caches: nil, documents: nil, temporary: nil),
                                             groups: [group])
        let shared = plan.items.filter {
            switch $0 {
            case .folder, .defaultsKeys: true
            default: false
            }
        }
        #expect(shared == [
            .folder(URL(fileURLWithPath: "/groups/cmux/dev.cmux.ios.nxe5", isDirectory: true)),
            .defaultsKeys(suite: "group.dev.cmux.ios", prefix: "dev.cmux.ios.nxe5."),
        ])
        #expect(!plan.items.contains(.directoryContents(URL(fileURLWithPath: "/groups/cmux", isDirectory: true))))
        #expect(!plan.items.contains(.folder(URL(fileURLWithPath: "/groups/cmux", isDirectory: true))))
    }

    @Test(arguments: ["", "..", ".", "a/b", "../escape"])
    func namespaceRefusesIdsThatEscapeTheContainer(_ bundleID: String) {
        let group = AppGroupContainer(id: "g", url: URL(fileURLWithPath: "/groups/cmux", isDirectory: true))
        #expect(EraseAllDataPlan.namespace(of: group, bundleID: bundleID) == nil)
    }

    @Test func missingGroupContainerListsOnlyItsKeys() {
        let plan = EraseAllDataPlan.standard(bundleID: "b", sandbox: EraseAllDataPlan.Sandbox(applicationSupport: nil, caches: nil, documents: nil,
                                                                                              temporary: nil),
                                             groups: [AppGroupContainer(id: "g", url: nil)])
        #expect(plan.items.last == .defaultsKeys(suite: "g", prefix: "b."))
        #expect(!plan.items.contains { if case .folder = $0 { true } else { false } })
    }

    // MARK: The executor

    @Test func executorEmptiesTheSandboxAndLeavesSiblingsAlone() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = sandbox(in: root.appendingPathComponent("app", isDirectory: true))
        try write(box.applicationSupport!.appendingPathComponent("ssh/hosts.json"))
        try write(box.applicationSupport!.appendingPathComponent("cmux-next/transfers.json"))
        try write(box.caches!.appendingPathComponent("cmux-viewers/a/b.txt"))
        try write(box.temporary!.appendingPathComponent("composer-attachments/p.png"))
        let other = root.appendingPathComponent("other-app/Library/Application Support/keep.json")
        try write(other)
        let groupRoot = root.appendingPathComponent("group", isDirectory: true)
        try write(groupRoot.appendingPathComponent("dev.cmux.ios.nxe5/state.json"))
        try write(groupRoot.appendingPathComponent("dev.cmux.ios.other/state.json"))
        let keychain = RecordingKeychain()
        let defaults = RecordingDefaults()
        let plan = EraseAllDataPlan.standard(bundleID: "dev.cmux.ios.nxe5", sandbox: box,
                                             groups: [AppGroupContainer(id: "group.dev.cmux.ios", url: groupRoot)])
        let report = EraseAllDataExecutor(keychain: keychain, files: FileManagerWiper(), defaults: defaults).run(plan)
        #expect(report.isComplete)
        for directory in [box.applicationSupport!, box.caches!, box.temporary!] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: box.applicationSupport!.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(!FileManager.default.fileExists(atPath: groupRoot.appendingPathComponent("dev.cmux.ios.nxe5").path))
        #expect(FileManager.default.fileExists(atPath: groupRoot.appendingPathComponent("dev.cmux.ios.other/state.json").path))
        #expect(keychain.deleted == KeychainItemClass.allCases)
        #expect(defaults.domains == ["dev.cmux.ios.nxe5"])
        #expect(defaults.prefixes == ["group.dev.cmux.ios": "dev.cmux.ios.nxe5."])
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = sandbox(in: root)
        try write(box.caches!.appendingPathComponent("c"))
        let keychain = RecordingKeychain(failing: [.key])
        let report = EraseAllDataExecutor(keychain: keychain, files: FileManagerWiper(), defaults: RecordingDefaults())
            .run(.standard(bundleID: "b", sandbox: box, groups: []))
        #expect(report.failures == [EraseReport.Failure(item: .keychain(.key), reason: "keychain -25308")])
        #expect(keychain.deleted == KeychainItemClass.allCases.filter { $0 != .key })
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.caches!.path).isEmpty)
    }

    @Test func userDefaultsWiperRemovesOnlyPrefixedKeysOfTheSuite() throws {
        let suite = "erase-suite-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "dev.cmux.ios.nxe5.token")
        defaults.set(2, forKey: "dev.cmux.ios.other.token")
        UserDefaultsWiper().removeKeys(suite: suite, prefix: "dev.cmux.ios.nxe5.")
        #expect(defaults.object(forKey: "dev.cmux.ios.nxe5.token") == nil)
        #expect(defaults.integer(forKey: "dev.cmux.ios.other.token") == 2)
    }

    // MARK: Confirmation

    @Test func confirmationIgnoresCaseWidthAndSpaces() {
        let rule = EraseConfirmationRule(word: "Erase")
        #expect(rule.matches("erase"))
        #expect(rule.matches("  ERASE \n"))
        #expect(rule.matches("ｅｒａｓｅ"))
        #expect(!rule.matches("eras"))
        #expect(!rule.matches(""))
        #expect(EraseConfirmationRule(word: "消去").matches("消去"))
        #expect(!EraseConfirmationRule(word: "").matches(""))
    }

    @Test @MainActor func modelErasesOnlyAfterTheWordAndOnce() async {
        var runs = 0
        let model = EraseAllDataModel(rule: EraseConfirmationRule(word: "Erase")) {
            runs += 1
            return EraseReport()
        }
        await model.erase()
        #expect(runs == 0)
        model.typed = "erase"
        #expect(model.canErase)
        await model.erase()
        await model.erase()
        #expect(runs == 1)
        #expect(model.phase == .finished(EraseReport()))
    }
}

final class RecordingKeychain: KeychainWiping, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [KeychainItemClass] = []
    let failing: Set<KeychainItemClass>

    init(failing: Set<KeychainItemClass> = []) { self.failing = failing }

    var deleted: [KeychainItemClass] { lock.withLock { log } }

    func deleteAll(_ itemClass: KeychainItemClass) throws {
        if failing.contains(itemClass) { throw SecurityKeychainWiper.Failure(status: -25308) }
        lock.withLock { log.append(itemClass) }
    }
}

final class RecordingDefaults: DefaultsWiping, @unchecked Sendable {
    private let lock = NSLock()
    private var removedDomains: [String] = []
    private var removedPrefixes: [String: String] = [:]

    var domains: [String] { lock.withLock { removedDomains } }
    var prefixes: [String: String] { lock.withLock { removedPrefixes } }

    func removeDomain(_ name: String) { lock.withLock { removedDomains.append(name) } }
    func removeKeys(suite: String, prefix: String) { lock.withLock { removedPrefixes[suite] = prefix } }
}
