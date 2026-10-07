import CmuxiOSFeatureKit
@testable import CmuxiOSShell
import Foundation
import Testing

@MainActor
struct DirectAddressFormModelTests {
    static let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func invalidDraftShowsIssuesOnlyAfterSaving() async {
        let model = DirectAddressFormModel(store: MockHostsStore())
        #expect(model.visibleIssues.isEmpty)
        #expect(await model.save() == false)
        #expect(model.visibleIssues == [.addressMissing, .hostKeyMissing])
    }

    @Test func validDraftCommitsThroughTheStore() async {
        let store = MockHostsStore()
        let model = DirectAddressFormModel(store: store)
        model.draft = DirectAddressDraft(name: "Studio", address: "100.70.1.2", hostKey: Self.key)
        #expect(await model.save())
        #expect(model.refusal == nil)
        #expect(await store.hub.current.value.contains { $0.name == "Studio" })
    }

    @Test func editingUpdatesTheRecord() async throws {
        let store = MockHostsStore()
        let host = try #require(DirectAddressDraft(name: "Lab", address: "192.168.1.4", hostKey: Self.key).hostDraft())
        _ = try await store.add(host, key: IntentKey())
        let record = try #require(await store.hub.current.value.first { $0.name == "Lab" })
        let model = DirectAddressFormModel(store: store, draft: try #require(DirectAddressDraft(record: record)), editing: record.id)
        model.draft.port = "4199"
        #expect(await model.save())
        let updated = try #require(await store.hub.current.value.first { $0.id == record.id })
        guard case let .direct(endpoint, _) = updated.kind else { Issue.record("not direct"); return }
        #expect(endpoint.port == 4199)
    }

    @Test func refusalIsShown() async {
        let model = DirectAddressFormModel(store: MockHostsStore(), editing: MockFixtures.studio)
        model.draft = DirectAddressDraft(address: "10.0.0.9", hostKey: Self.key)
        #expect(await model.save() == false)
        #expect(model.refusal != nil)
    }
}
