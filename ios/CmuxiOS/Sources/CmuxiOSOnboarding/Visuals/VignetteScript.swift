import QuartzCore

/// The vignette's text and timeline (seconds into one loop). The terminal
/// lines are sample command output, like the shared mock fixtures, so they
/// are not localized; the card's question and buttons are.
struct VignetteScript {
    let prompt = "$ "
    let command = "claude \"fix the flaky login test\""
    let agentLines = [
        "● Reading Tests/LoginTests.swift",
        "● Editing Sources/Auth/Session.swift",
        "● Waiting for approval",
    ]
    let check = "✓"
    let period = OnboardingMotion.vignettePeriod

    let typingStart: CFTimeInterval = 0.8
    var typingEnd: CFTimeInterval { typingStart + CFTimeInterval(command.count) * OnboardingMotion.typePerCharacter }
    let agentLineStarts: [CFTimeInterval] = [2.0, 2.6, 3.2]
    let cardIn: CFTimeInterval = 3.2
    let press: CFTimeInterval = 4.6
    let cardOut: CFTimeInterval = 4.9
    let result: CFTimeInterval = 5.1
    let fadeOut: CFTimeInterval = 7.6
    let fadeOutLength: CFTimeInterval = 0.4
}
