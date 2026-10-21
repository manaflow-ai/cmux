//! A prompt that only checks the agent answers ("Reply with only: OK", "ping").
//!
//! Agents smoke-test a harness or a route by hand with `acpmux new`, `acpmux run` or
//! `cmux acp run` and such a prompt (2026-10-20). That chat then read "Reply with only: OK"
//! in Leo's list, the chats it started read "Subagent of · Reply with only: OK", and it
//! folded under the agent that ran the check. A probe titles no chat (`hub/titles.rs`: the
//! first real message does) and makes no chat a subagent of its caller (`client.rs`).

/// The longest prompt that can still be a probe.
const MAX_CHARS: usize = 80;
/// One-word checks, whole.
const WORDS: &[&str] = &["ping", "ok", "test", "hi", "hello"];
/// Openers of the "answer with this one word" checks.
const OPENERS: &[&str] = &[
    "reply with",
    "respond with",
    "answer with",
    "reply only",
    "respond only",
    "say only",
    "just say",
    "just reply",
    "say ok",
    "say pong",
];

/// Whether `text` is a probe: one short line asking for a fixed reply.
pub fn is_probe(text: &str) -> bool {
    let text = text.trim();
    if text.is_empty() || text.chars().count() > MAX_CHARS || text.contains('\n') {
        return false;
    }
    let lower = text.to_lowercase();
    let bare = lower.trim_end_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());
    WORDS.contains(&bare) || OPENERS.iter().any(|opener| starts_with_words(bare, opener))
}

/// `text` starts with `words`, ending at a word boundary.
fn starts_with_words(text: &str, words: &str) -> bool {
    text.strip_prefix(words)
        .is_some_and(|rest| rest.chars().next().is_none_or(|c| !c.is_alphanumeric()))
}

#[cfg(test)]
mod tests {
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
        ] {
            assert!(!is_probe(text), "{text:?}");
        }
    }
}
