import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A session priority restart carries its model on a `--model` argument, never `ANTHROPIC_MODEL`.
/// The recorded launch may already name a model in either spelling, so every recorded form is
/// replaced, and the executable in `argv[0]` is never read as an option.
struct SessionPriorityLaunchArgumentsTests {
    @Test
    func readsSpaceAndEqualsForms() {
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["claude", "--model", "opus"]) == "opus")
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["claude", "--model=sonnet"]) == "sonnet")
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--effort", in: ["claude", "--verbose", "--effort", "low"]) == "low")
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["claude", "--fallback-model", "haiku"]) == nil)
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["claude", "--model"]) == nil)
    }

    @Test
    func replacingRemovesEveryExistingForm() {
        let replaced = SessionPriorityLaunchArguments.replacing(
            option: "--model",
            with: "opus",
            in: ["claude", "--model", "sonnet", "--verbose", "--model=haiku", "--fallback-model", "haiku"]
        )

        #expect(replaced == ["claude", "--verbose", "--fallback-model", "haiku", "--model", "opus"])
    }

    @Test
    func replacingKeepsTheOptionBeforeAnOptionTerminator() {
        // Everything after `--` is a prompt the resume drops, so an option appended there is lost.
        let replaced = SessionPriorityLaunchArguments.replacing(
            option: "--model",
            with: "opus",
            in: ["claude", "--model", "sonnet", "--", "--model fix"]
        )

        #expect(replaced == ["claude", "--model", "opus", "--", "--model fix"])
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["claude", "--", "--model", "x"]) == nil)
    }

    @Test
    func ignoresArgvZero() {
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["--model=opus"]) == nil)
        #expect(SessionPriorityLaunchArguments.value(ofOption: "--model", in: ["--model", "opus"]) == nil)
        #expect(
            SessionPriorityLaunchArguments.replacing(option: "--model", with: "opus", in: ["--model=sonnet"])
                == ["--model=sonnet", "--model", "opus"]
        )
    }
}
