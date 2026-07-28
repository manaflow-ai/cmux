#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileSearchAutomationSearchControllerSpy: FileSearchControlling {
    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
    var searchRequests: [String] = []

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
        searchRequests.append(rawQuery)
    }

    func cancel(clear: Bool) {}
}
