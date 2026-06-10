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


// MARK: - Skill mention suggestions
extension TextBoxMentionCompletionTests {
    @Test
    func testTextBoxMentionSkillSuggestionsUseTypedDollarTrigger() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sample-dollar-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: sample-dollar-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 20),
                query: "sample-dollar",
                trigger: "$"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.first?.title == "$sample-dollar-skill")
        #expect(suggestions.first?.systemImageName == "sparkle.magnifyingglass")
        // The $ trigger inserts the bare skill reference (not a markdown link),
        // unlike the / and @ triggers.
        #expect(suggestions.first?.insertionText == "$sample-dollar-skill")
    }

    @Test
    func testTextBoxMentionSkillSuggestionsUseTypedSlashTriggerForEmptyQuery() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-slash-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sample-slash-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: sample-slash-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        // An empty query returns the whole skill corpus, which also includes the
        // machine's global skill roots (~/.codex/skills, etc.), so the temp skill
        // is not guaranteed to sort first. Assert it is present with the typed
        // trigger rather than asserting its position.
        let slashSkill = suggestions.first { $0.title == "/sample-slash-skill" }
        #expect(slashSkill != nil)
        #expect(slashSkill?.insertionText.hasPrefix("[/sample-slash-skill](") == true)
    }

    @Test
    func testTextBoxMentionEmptySkillSuggestionsKeepNearestProjectSkillsBeforeCap() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-local-skill-priority-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let ancestorSkillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let projectSkillsDirectory = projectDirectory.appendingPathComponent("skills", isDirectory: true)
        let localSkillDirectory = projectSkillsDirectory.appendingPathComponent("zz-local-skill", isDirectory: true)
        try fileManager.createDirectory(at: localSkillDirectory, withIntermediateDirectories: true)
        try "name: zz-local-skill\n".write(
            to: localSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        for index in 0..<520 {
            let skillName = String(format: "aaa-global-%03d", index)
            let skillDirectory = ancestorSkillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "/"
            ),
            rootDirectory: projectDirectory.path
        )

        let localSkillIndex = suggestions.firstIndex { $0.title == "/zz-local-skill" }
        let ancestorSkillIndex = suggestions.firstIndex { $0.title.hasPrefix("/aaa-global-") }
        #expect(localSkillIndex != nil)
        #expect(ancestorSkillIndex != nil)
        #expect((localSkillIndex ?? Int.max) < (ancestorSkillIndex ?? Int.max))
    }

    @Test
    func testTextBoxMentionSkillSuggestionsFindNestedSkillPacks() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-nested-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("team", isDirectory: true)
            .appendingPathComponent("nested-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: nested-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 13),
                query: "nested-skill",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        let nestedSkill = suggestions.first { $0.title == "/nested-skill" }
        #expect(nestedSkill != nil)
        #expect(nestedSkill?.insertionText.hasPrefix("[/nested-skill](") == true)
    }

    @Test
    func testTextBoxMentionSkillSuggestionsPreferExactNameOverPathOnlyFuzzyMatches() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skill-fuzzy-filter-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        let skillNames = [
            "agent-browser",
            "agent-cli-integration",
            "algorithmic-complexity-audit",
            "auto-issue",
            "cleanup-dev-builds",
            "close-issues",
            "pi-agent-rust",
            "xcodebuildmcp-cli",
            "iterate-pr"
        ] + (0..<40).map { String(format: "zzz-distractor-%02d", $0) }
        for skillName in skillNames {
            let skillDirectory = skillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        for trigger in ["/", "$"] as [Character] {
            let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
                for: TextBoxMentionQuery(
                    kind: .skill,
                    range: NSRange(location: 0, length: 11),
                    query: "iterate-pr",
                    trigger: trigger
                ),
                rootDirectory: root.path
            )

            #expect(suggestions.first?.title == "\(trigger)iterate-pr")
            #expect(!suggestions.contains { $0.title == "\(trigger)pi-agent-rust" })
            #expect(!suggestions.contains { $0.title == "\(trigger)agent-browser" })
        }
    }

    @Test
    func testTextBoxMentionSkillSuggestionsFilterWeakPartialFuzzyMatches() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skill-partial-fuzzy-filter-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        for skillName in [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ] {
            let skillDirectory = skillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 8),
                query: "iterate",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.first?.title == "/iterate-pr")
        #expect(!suggestions.contains { $0.title == "/agent-browser" })
        #expect(!suggestions.contains { $0.title == "/pi-agent-rust" })
    }

}
