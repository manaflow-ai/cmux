//! A prompt that only checks the agent answers ("Reply with only: OK", "ping").
//!
//! Agents smoke-test a harness or a route by hand with `acpmux new`, `acpmux run` or
//! `cmux acp run` and such a prompt (2026-10-20). That chat then read "Reply with only: OK"
//! in Leo's list, the chats it started read "Subagent of · Reply with only: OK", and it
//! folded under the agent that ran the check. A probe titles no chat (`hub/titles.rs`: the
//! first real message does), and a one-shot probe from an agent's shell runs ephemeral: its
//! chat goes after the reply, never kept as the agent's subagent (`cli/run/standard.rs`).

/// The longest prompt that can still be a probe.
const MAX_CHARS: usize = 80;
/// The fixed replies a check asks for ("Reply with only: ready").
const REPLIES: &[&str] = &["ok", "pong", "ping", "yes", "done", "ack", "ready", "hi"];
/// The one-word checks. Not "yes" or "done": a person may open a chat with those.
const ONE_WORD: &[&str] = &["ok", "ping", "pong", "hi", "hello", "test"];
/// Openers of the "answer with this one word" checks.
const OPENERS: &[&str] = &[
    "reply with",
    "respond with",
    "answer with",
    "reply",
    "respond",
    "say",
    "print",
    "just say",
    "just reply",
];
/// Words that may stand between an opener and the fixed reply, or after it.
const FILLER: &[&str] =
    &["only", "exactly", "just", "the", "word", "a", "single", "and", "nothing", "else"];

/// Whether `text` is a probe: one short line asking for a fixed reply ("Reply with only: OK",
/// "Say pong", "ping"), never a task that opens the same way ("Reply with only the files that
/// changed", "Answer with a haiku").
pub fn is_probe(text: &str) -> bool {
    let text = text.trim();
    if text.is_empty() || text.chars().count() > MAX_CHARS || text.contains('\n') {
        return false;
    }
    let lower = text.to_lowercase();
    let words: Vec<&str> =
        lower.split(|c: char| !c.is_alphanumeric()).filter(|word| !word.is_empty()).collect();
    if let [word] = words.as_slice() {
        return ONE_WORD.contains(word);
    }
    let rest = OPENERS.iter().find_map(|opener| {
        let opener: Vec<&str> = opener.split(' ').collect();
        words.strip_prefix(opener.as_slice())
    });
    let Some(rest) = rest else { return false };
    let replies = rest.iter().filter(|word| REPLIES.contains(word)).count();
    replies == 1 && rest.iter().all(|word| REPLIES.contains(word) || FILLER.contains(word))
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
}
