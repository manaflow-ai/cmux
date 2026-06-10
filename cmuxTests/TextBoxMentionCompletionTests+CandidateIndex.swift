import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Mention candidate index prefiltering
extension TextBoxMentionCompletionTests {
    @Test
    func testTextBoxMentionCandidateIndexDoesNotReturnUnvalidatedNucleoRows() {
        let skillNames = [
            "agent-browser",
            "agent-cli-integration",
            "algorithmic-complexity-audit",
            "auto-issue",
            "cleanup-dev-builds",
            "close-issues",
            "pi-agent-rust",
            "xcodebuildmcp-cli"
        ] + (0..<40).map { String(format: "zzz-distractor-%02d", $0) }
        let candidates = skillNames.map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate-pr",
            limit: 500
        )

        #expect(matches.isEmpty)
    }

    @Test
    func testTextBoxMentionCandidateIndexFiltersWeakPartialFuzzyRows() {
        let candidates = [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ].map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate",
            limit: 500
        )

        #expect(matches.map(\.title) == ["/iterate-pr"])
    }

    @Test
    func testTextBoxMentionCandidateIndexStopsPrefilterWhenCancelled() {
        let candidates = [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ].map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }
        var cancellationChecks = 0

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate",
            limit: 500
        ) {
            cancellationChecks += 1
            return cancellationChecks > 1
        }

        #expect(matches.isEmpty)
        #expect(cancellationChecks > 1)
    }

}
