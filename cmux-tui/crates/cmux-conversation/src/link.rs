//! Permalinks of conversations and messages (`conversation-tree-v1`):
//! `<scheme>://conversation/<conv_id>` and
//! `<scheme>://conversation/<conv_id>/message/<msg_id>`, where the scheme is
//! the build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`). Every UI
//! (the Messages Home, the Channels page, the CLI) formats and parses links
//! with this one grammar, so a link copied in one opens in the other.

/// Longest link accepted, in bytes.
pub const MAX_LINK_BYTES: usize = 512;

/// A parsed permalink: the conversation and, optionally, one message in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationLink {
    /// The link scheme as written (`cmux`, `cmux-dev`, `cmux-dev-<tag>`).
    pub scheme: String,
    pub conversation: String,
    pub message: Option<String>,
}

impl ConversationLink {
    /// The canonical text of the link.
    pub fn url(&self) -> String {
        format_link(&self.scheme, &self.conversation, self.message.as_deref())
    }
}

/// The link of `conversation` (and `message`) in `scheme`.
pub fn format_link(scheme: &str, conversation: &str, message: Option<&str>) -> String {
    match message {
        Some(message) => format!("{scheme}://conversation/{conversation}/message/{message}"),
        None => format!("{scheme}://conversation/{conversation}"),
    }
}

/// Parses a permalink. A query (`?machine=...`) or fragment is ignored, so a
/// link never carries a command. Returns `None` for any other URL.
pub fn parse_link(url: &str) -> Option<ConversationLink> {
    if url.len() > MAX_LINK_BYTES {
        return None;
    }
    let (scheme, rest) = url.split_once("://")?;
    if !valid_scheme(scheme) {
        return None;
    }
    let path = rest.split(['?', '#']).next().unwrap_or_default();
    let path = path.strip_suffix('/').unwrap_or(path);
    let mut segments = path.split('/');
    if segments.next()? != "conversation" {
        return None;
    }
    let conversation = segments.next().filter(|id| valid_id(id, "conv_"))?;
    let message = match (segments.next(), segments.next()) {
        (None, _) => None,
        (Some("message"), Some(id)) if valid_id(id, "msg_") => Some(id.to_string()),
        _ => return None,
    };
    if segments.next().is_some() {
        return None;
    }
    Some(ConversationLink {
        scheme: scheme.to_ascii_lowercase(),
        conversation: conversation.to_string(),
        message,
    })
}

/// `cmux` or `cmux-<tail>`, any case, where the tail is 1-64 letters, digits
/// and single `-` between them (`cmux-dev`, `cmux-dev-mytag`). Any cmux build's
/// scheme is accepted: a link copied in another build resolves against this
/// owner (an id it does not have is `unknown_conversation`).
fn valid_scheme(scheme: &str) -> bool {
    let lower = scheme.to_ascii_lowercase();
    lower == "cmux"
        || lower.strip_prefix("cmux-").is_some_and(|tail| {
            tail.len() <= 64
                && tail.split('-').all(|word| {
                    !word.is_empty() && word.bytes().all(|byte| byte.is_ascii_alphanumeric())
                })
        })
}

/// An owner id: `prefix` and 1-64 ASCII letters, digits or `_` (local ids
/// are 26 Crockford digits; cloud ids keep their own length).
fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix).is_some_and(|tail| {
        !tail.is_empty()
            && tail.len() <= 64
            && tail.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    })
}
