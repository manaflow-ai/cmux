import CmuxBrowser
import Foundation

@MainActor
final class MarkdownFindScriptEvaluatorSpy: BrowserFindScriptEvaluating {
    private var results: [Any?]
    private(set) var evaluatedScripts: [BrowserFindScript] = []

    init(results: [Any?]) {
        self.results = results
    }

    func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        evaluatedScripts.append(script)
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}
