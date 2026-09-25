import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor
struct ReviewPaneModelTests {
    @Test func presentsOnlyTheCLIsSurfacedFindings() async {
        let commands = ReviewPaneCommands()
        let model = ReviewPaneModel(commands: commands, cliPath: "/fixture/cmux")
        await model.load(directory: "/fixture/repo", selection: "latest", includeAll: false)
        #expect(model.error == nil)
        #expect(model.runs.map(\.id) == ["receipt"])
        #expect(model.findings.map(\.id) == ["F-1"])
        #expect(model.intent == "Fix the caller")
        #expect(model.source == "recorded-tree")
        #expect(model.findings.first?.isVerified == false)

        await model.load(directory: "/fixture/repo", selection: "receipt", includeAll: true)
        #expect(model.findings.map(\.id) == ["F-1", "F-2"])
        #expect(await commands.findingsArguments() == [
            ["review", "findings", "receipt", "--repo", "/fixture/repo", "--json"],
            ["review", "findings", "receipt", "--all", "--repo", "/fixture/repo", "--json"]
        ])
    }

    @Test func unavailableDirectoryClearsPriorReceipt() async {
        let model = ReviewPaneModel(commands: ReviewPaneCommands(), cliPath: "/fixture/cmux")
        await model.load(directory: "/fixture/repo", selection: "latest", includeAll: false)
        #expect(!model.findings.isEmpty)
        await model.load(directory: nil, selection: "latest", includeAll: false)
        #expect(model.findings.isEmpty)
        #expect(model.runs.isEmpty)
        #expect(model.source.isEmpty)
        #expect(!model.isLoading)
    }
}

