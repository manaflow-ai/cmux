import Foundation
import Testing
@testable import cmuxFeature

@Suite
struct MobileIrxRuntimeLifecycleTests {
    @Test
    func endpointReadyPublishesRuntimeChanges() async {
        let composition = makeComposition()

        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let updates = await composition.changes()
                var iterator = updates.makeAsyncIterator()
                _ = await iterator.next()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
            await composition.recordEndpointReady(cached: false)
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(observed)
    }

    private func makeComposition() -> MobileIrxRuntimeComposition {
        MobileIrxRuntimeComposition(
            configuration: MobileIrohV2Configuration(
                baseURL: URL(string: "https://example.test")!,
                environment: "test",
                projectID: "test-project",
                appNamespace: "dev.cmux.tests",
                buildTag: "test",
                appVersion: "1.0",
                displayName: "Test",
                stateDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-iroh-runtime-tests-\(UUID().uuidString)")
            )
        )
    }
}
