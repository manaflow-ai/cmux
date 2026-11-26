//! acpmux's chat keys, `<harness>:<session id>`: all a running chat is found
//! by, and what an older daemon's chat-open plan falls back to.

use serde::Serialize;

/// A key's parts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Key {
    /// The harness as the index names it (`claude-code`, `codex`).
    pub harness: Option<String>,
    pub session: Option<String>,
}

/// Swift's `split(separator: ":", maxSplits: 1)`: empty pieces are dropped
/// and do not count as the split.
fn split_once_nonempty(key: &str) -> Vec<&str> {
    let mut parts = Vec::with_capacity(2);
    let mut rest = key;
    while parts.is_empty() {
        match rest.split_once(':') {
            Some((head, tail)) => {
                if !head.is_empty() {
                    parts.push(head);
                }
                rest = tail;
            }
            None => break,
        }
    }
    if !rest.is_empty() {
        parts.push(rest);
    }
    parts
}

/// The harness and session id a key names; the session only when the key
/// has both parts.
pub fn parse(key: &str) -> Key {
    let parts = split_once_nonempty(key);
    Key {
        harness: parts.first().map(|part| (*part).to_owned()),
        session: (parts.len() == 2).then(|| parts[1].to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(harness: Option<&str>, session: Option<&str>) -> Key {
        Key { harness: harness.map(Into::into), session: session.map(Into::into) }
    }

    #[test]
    fn a_key_names_its_harness_and_session() {
        assert_eq!(parse("codex:019a-b"), key(Some("codex"), Some("019a-b")));
        assert_eq!(
            parse("claude-code:s:with:colons"),
            key(Some("claude-code"), Some("s:with:colons"))
        );
    }

    #[test]
    fn a_key_without_a_session_names_only_its_harness() {
        assert_eq!(parse("codex"), key(Some("codex"), None));
        assert_eq!(parse("codex:"), key(Some("codex"), None));
        assert_eq!(parse(""), key(None, None));
        assert_eq!(parse(":"), key(None, None));
    }

    #[test]
    fn empty_pieces_drop_as_swift_split_does() {
        // ":abc" is one piece; "::a:b" drops both empty heads and splits once.
        assert_eq!(parse(":abc"), key(Some("abc"), None));
        assert_eq!(parse("::a:b"), key(Some("a"), Some("b")));
        assert_eq!(parse("a::b"), key(Some("a"), Some(":b")));
    }
}
