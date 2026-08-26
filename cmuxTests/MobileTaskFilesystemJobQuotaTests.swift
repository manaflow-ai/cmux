import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileTaskFilesystemJobQuotaTests {
    @Test func capsConcurrentCallersAndReusesReleasedCapacity() async {
        let quota = MobileTaskFilesystemJobQuota(maximumConcurrentJobs: 2)

        let admissions = await withTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    quota.acquire()
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let admittedCount = admissions.count(where: { $0 })
        #expect(admittedCount == 2)
        for _ in 0..<admittedCount {
            quota.release()
        }

        #expect(quota.acquire())
        #expect(quota.acquire())
        #expect(!quota.acquire())
        quota.release()
        quota.release()
    }

    @MainActor
    @Test func saturatedQuotaRejectsListAndSearchHandlersAsBusy() async {
        let quota = MobileTaskFilesystemJobQuota(maximumConcurrentJobs: 1)
        #expect(quota.acquire())
        defer { quota.release() }

        let listResult = await TerminalController.shared.v2MobileDirectoryList(
            params: [
                "path": "/",
                "offset": 0,
                "limit": 1,
            ],
            filesystemJobQuota: quota
        )
        let searchResult = await TerminalController.shared.v2MobileDirectorySearch(
            params: ["query": "cmux"],
            filesystemJobQuota: quota
        )

        #expect(Self.errorCode(from: listResult) == "busy")
        #expect(Self.errorCode(from: searchResult) == "busy")
    }

    @MainActor
    @Test func listHandlerReleasesCapacityAfterFilesystemFailure() async {
        let quota = MobileTaskFilesystemJobQuota(maximumConcurrentJobs: 1)
        let missingPath = "/cmux-directory-quota-missing-\(UUID().uuidString)"

        let result = await TerminalController.shared.v2MobileDirectoryList(
            params: [
                "path": missingPath,
                "offset": 0,
                "limit": 1,
            ],
            filesystemJobQuota: quota
        )

        #expect(Self.errorCode(from: result) == "directory_not_found")
        #expect(quota.acquire())
        quota.release()
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }
}
