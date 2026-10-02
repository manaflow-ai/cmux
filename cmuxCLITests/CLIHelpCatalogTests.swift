import Foundation
import Testing

/// Task help is a view of the command catalog. Keep every advertised
/// top-level verb resolvable by the same catalog used for dispatch and
/// suggestions.
struct CLIHelpCatalogTests {
    @Test func everyTaskHelpCommandResolvesFromTheCatalog() {
        let usage = CMUXCLI(args: [], initialSIGPIPEInspectionPayload: nil).usage()
        var listed: Set<String> = []
        var unresolved: Set<String> = []
        for line in usage.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasSuffix(":"), !text.hasPrefix("cmux ") else { continue }
            let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            guard let token, token.first?.isLetter == true else { continue }
            for name in token.split(separator: "|") {
                let command = String(name)
                if CLITopLevelCommands.names.contains(command) {
                    listed.insert(command)
                } else {
                    unresolved.insert(command)
                }
            }
        }
        #expect(!listed.isEmpty)
        #expect(unresolved.isEmpty, "help lists commands outside the catalog: \(unresolved.sorted())")
        #expect(!usage.contains("resize-window"))
        #expect(!usage.contains("browser url|get-url"))
    }
}
