use super::is_probe;

#[test]
fn route_checks_are_probes() {
    for text in [
        "Reply with only: OK",
        "reply with exactly OK",
        "Respond with only the word pong.",
        "Say OK",
        "ping",
        "  Hello!  ",
        "Just reply OK and nothing else",
    ] {
        assert!(is_probe(text), "{text:?}");
    }
}

#[test]
fn real_messages_are_not_probes() {
    for text in [
        "Reply with a summary of the failing tests in cmux-tui",
        "",
        "Fix the title of a chat whose first prompt was a route check",
        "Okay, now open the PR",
        "pinging the daemon fails after a restart, why?",
        "Reply with only: OK\nthen read COMMON.md and start on the brief",
        "Replying to the review: the second finding is right, fix it and push",
        "Reply with only the files that changed in the last commit",
        "Respond with just the list of failing tests",
        "Reply with exactly what the error said",
        "Answer with a haiku about autumn",
        "Reply with a joke",
        "Respond with a plan",
        "Just reply to Bob's email",
        "Reply only in French",
        "Say hello to the new teammate in the channel",
        "say hi to the team",
        "Reply with a test",
        "Print the test",
        "reply yes or no: is the build green?",
        "yes",
        "done",
    ] {
        assert!(!is_probe(text), "{text:?}");
    }
}
