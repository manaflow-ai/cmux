//! Who sent a message an agent wrote to a Chief (`cmux chief -p --from`,
//! `cmux chief acp` under acpmux): the sending acpmux session's name, the
//! message's class and its thread, carried in the message's `client_msg_id`
//! (`agent~<name>~<class>~<thread>~<nonce>`).
//!
//! The marker only ever lowers trust. Any writer that can post as the owner
//! may set it, and a Chief reads a marked message as another agent's words,
//! never the owner's: it is labelled with the sender and its turn runs under
//! the ask floor (no local effects). An unmarked message is read as before, so
//! nothing here can make a message count as the owner's.
//!
//! The visible text starts with `[from <name>] `, so the conversation shows
//! the message as that agent's, not as the owner's own words.

/// The `client_msg_id` prefix of a marked message.
pub const MARK: &str = "agent~";
/// The longest sender name kept (acpmux names are at most 64 characters).
pub const MAX_NAME: usize = 64;
/// The longest thread kept.
pub const MAX_THREAD: usize = 24;
/// The classes an acpmux send takes (`acpmux send --class`); anything else
/// is read as `result`, the acpmux default.
pub const CLASSES: [&str; 6] = ["block", "question", "result", "fyi", "blocker", "action"];

/// The sender of a marked message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentSender {
    /// The acpmux session name of the sender.
    pub name: String,
    /// What it asks of the receiver (one of [`CLASSES`]).
    pub class: String,
    /// Its thread, when it named one.
    pub thread: Option<String>,
}

/// A name or thread character kept as is; every other one becomes `-`.
fn keep(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':' | '/' | '@')
}

fn clean(text: &str, max: usize) -> String {
    text.trim().chars().map(|c| if keep(c) { c } else { '-' }).take(max).collect()
}

impl AgentSender {
    /// A sender named `name` (cleaned to [`MAX_NAME`] characters of
    /// `[A-Za-z0-9_.:/@-]`); None when nothing is left.
    pub fn new(name: &str, class: Option<&str>, thread: Option<&str>) -> Option<AgentSender> {
        let name = clean(name, MAX_NAME);
        if name.trim_matches('-').is_empty() {
            return None;
        }
        let class =
            class.map(str::trim).filter(|c| CLASSES.contains(c)).unwrap_or("result").to_owned();
        let thread =
            thread.map(|t| clean(t, MAX_THREAD)).filter(|t| !t.trim_matches('-').is_empty());
        Some(AgentSender { name, class, thread })
    }

    /// The `client_msg_id` for one message of this sender; `nonce` makes it
    /// unique (at most 16 characters are kept). Always a valid token of at
    /// most 128 printable ASCII characters.
    pub fn client_msg_id(&self, nonce: &str) -> String {
        let nonce: String = nonce.chars().filter(char::is_ascii_alphanumeric).take(16).collect();
        format!(
            "{MARK}{}~{}~{}~{nonce}",
            self.name,
            self.class,
            self.thread.as_deref().unwrap_or("")
        )
    }

    /// The text the conversation shows: `[from <name>] <text>`.
    pub fn labelled(&self, text: &str) -> String {
        format!("[from {}] {text}", self.name)
    }

    /// `text` without the `[from <name>] ` label this sender put on it.
    pub fn unlabelled<'a>(&self, text: &'a str) -> &'a str {
        text.strip_prefix(&format!("[from {}] ", self.name)).unwrap_or(text)
    }
}

/// The sender a message's `client_msg_id` names; None for an unmarked one
/// (the owner's own words, read as before).
pub fn of_client_msg_id(id: &str) -> Option<AgentSender> {
    let rest = id.strip_prefix(MARK)?;
    let mut fields = rest.split('~');
    let name = fields.next()?;
    let class = fields.next();
    let thread = fields.next().filter(|t| !t.is_empty());
    AgentSender::new(name, class, thread)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_marked_id_names_its_sender_class_and_thread() {
        let sender =
            AgentSender::new("claude-sr2-coord", Some("question"), Some("pr:123")).unwrap();
        let id = sender.client_msg_id("0123456789abcdef0123");
        assert_eq!(id, "agent~claude-sr2-coord~question~pr:123~0123456789abcdef");
        assert!(crate::valid_token(&id));
        assert_eq!(of_client_msg_id(&id), Some(sender));
    }

    #[test]
    fn an_unmarked_id_is_no_agent() {
        assert_eq!(of_client_msg_id("cli-0123"), None);
        assert_eq!(of_client_msg_id("send-1"), None);
        assert_eq!(of_client_msg_id("agent~~result~~x"), None);
    }

    #[test]
    fn names_and_threads_are_cleaned_and_the_class_defaults_to_result() {
        let long = "x".repeat(200);
        let sender =
            AgentSender::new(&format!(" lane a~{long}"), Some("urgent"), Some("t 1")).unwrap();
        assert_eq!(sender.name.len(), MAX_NAME);
        assert!(sender.name.starts_with("lane-a-"));
        assert_eq!(sender.class, "result");
        assert_eq!(sender.thread.as_deref(), Some("t-1"));
        let id = sender.client_msg_id(&"f".repeat(64));
        assert!(id.len() <= 128 && crate::valid_token(&id), "{id}");
        assert_eq!(of_client_msg_id(&id), Some(sender));
    }

    #[test]
    fn the_label_round_trips() {
        let sender = AgentSender::new("lane-a", None, None).unwrap();
        let shown = sender.labelled("rebase when free");
        assert_eq!(shown, "[from lane-a] rebase when free");
        assert_eq!(sender.unlabelled(&shown), "rebase when free");
        assert_eq!(sender.unlabelled("plain"), "plain");
    }
}
