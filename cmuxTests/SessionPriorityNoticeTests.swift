import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The notification for a session priority restart whose resume was not typed says what
/// happened, the way an account switch's does: a Claude still running must quit before the
/// resume, or it would run in two places; a closed terminal is not "this terminal". It names
/// the effort and the model the restart was for, and only those.
///
/// The test host may run in any language, so texts are compared with the catalog's lookups.
struct SessionPriorityNoticeTests {
    private let command = "cd -- '/tmp/p' && CLAUDE_CODE_EFFORT_LEVEL=high claude --resume s1"

    private func manual(_ reason: ClaudeAccountSwitchManualResume.Reason) -> ClaudeAccountSwitchManualResume {
        ClaudeAccountSwitchManualResume(command: command, typedInput: command + "\n", reason: reason)
    }

    private func notice(
        _ reason: ClaudeAccountSwitchManualResume.Reason,
        target: SessionPriorityTarget = SessionPriorityTarget(effort: .high)
    ) -> SessionPriorityNotice {
        SessionPriorityNotice.notRestarted(target: target, manual: manual(reason))
    }

    private var effortPhrase: String {
        String(format: String(localized: "notification.sessionPriority.target.effort", defaultValue: "Claude effort %@"), locale: .current, "high")
    }

    @Test
    func eachReasonSaysWhatHappened() {
        let bodies = [
            notice(.notTyped).body,
            notice(.paneReplaced).body,
            notice(.previousClaudeStillRunning(processIDs: [4242, 4243])).body,
        ]

        #expect(Set(bodies).count == 3)
        for body in bodies {
            #expect(body.hasSuffix(command))
            #expect(body.contains(effortPhrase))
        }
        #expect(bodies[2].contains("4242, 4243"))
    }

    @Test
    func modelOnlyTargetNamesTheModelNotTheEffort() {
        let target = SessionPriorityTarget(model: "opus")
        let modelPhrase = String(
            format: String(localized: "notification.sessionPriority.target.model", defaultValue: "Claude model %@"),
            locale: .current,
            "opus"
        )
        let effortOpus = String(
            format: String(localized: "notification.sessionPriority.target.effort", defaultValue: "Claude effort %@"),
            locale: .current,
            "opus"
        )

        let shown = notice(.notTyped, target: target)

        #expect(shown.body.contains(modelPhrase))
        #expect(!shown.body.contains(effortOpus))
        #expect(shown.title == String(localized: "notification.sessionPriority.title.model", defaultValue: "Claude model not changed"))
        #expect(shown.title != notice(.notTyped).title)
    }

    @Test
    func effortAndModelTargetNamesBoth() {
        let both = String(
            format: String(
                localized: "notification.sessionPriority.target.effortAndModel",
                defaultValue: "Claude effort %1$@ and model %2$@"
            ),
            locale: .current,
            "xhigh",
            "opus"
        )

        let shown = notice(.paneReplaced, target: SessionPriorityTarget(effort: .xhigh, model: "opus"))

        #expect(shown.body.contains(both))
    }

    /// The English wording mirrors the account switch's (`ClaudeAccountSwitchNotice`): wait for
    /// the old Claude before resuming, and never "restarted this terminal" for a closed one.
    /// Every new key carries all nine app locales.
    @Test
    func catalogTextsMirrorTheAccountSwitchWording() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        func value(_ key: String, _ locale: String) throws -> String {
            let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "no localizations \(key)")
            let unit = try #require((localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any], "no \(locale) for \(key)")
            return try #require(unit["value"] as? String)
        }
        let keys = [
            "notTyped", "paneReplaced", "previousClaudeStillRunning",
            "target.effort", "target.model", "target.effortAndModel", "title", "title.model",
        ].map { "notification.sessionPriority.\($0)" }
        for key in keys {
            for locale in ["en", "ar", "de", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant"] {
                let text = try value(key, locale)
                #expect(!text.isEmpty, "\(key) \(locale)")
            }
        }
        let stillRunning = try value("notification.sessionPriority.previousClaudeStillRunning", "en")
        #expect(stillRunning.contains("Once that Claude has quit"))
        #expect(!stillRunning.contains("Run:"))
        let replaced = try value("notification.sessionPriority.paneReplaced", "en")
        #expect(!replaced.contains("restarted this terminal"))
        #expect(replaced.contains("closed"))
        #expect(strings["notification.sessionPriority.notRestarted"] == nil)
    }
}
