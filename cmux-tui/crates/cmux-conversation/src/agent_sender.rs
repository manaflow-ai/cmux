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
    /// Who the chat shows it is from, as `APP` or `APP › PERSONA` ("Grok bot ›
    /// Ada", "Claude Code › 3fa9c1d2@mini-7"; u20190): the label's words, never
    /// read back from the id. None shows [`AgentSender::name`].
    pub display: Option<String>,
}

/// The separator between a sender's app and its persona in a label.
pub const PERSONA_SEPARATOR: &str = " › ";
/// The longest app or persona kept in a label.
pub const MAX_DISPLAY_PART: usize = 48;

/// One display part: one line, no brackets, at most [`MAX_DISPLAY_PART`] characters.
fn display_part(text: &str) -> Option<String> {
    let part: String = text
        .trim()
        .chars()
        .map(|c| if c.is_control() || matches!(c, '[' | ']' | '›') { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_DISPLAY_PART)
        .collect();
    (!part.is_empty()).then_some(part)
}

/// `APP › PERSONA` from `text`: its parts split at `›` or `>` (`Grok bot > Ada`);
/// None when nothing is left.
pub fn display_of(text: &str) -> Option<(String, Option<String>)> {
    let (app, persona) = match text.split_once(['›', '>']) {
        Some((app, persona)) => (app, Some(persona)),
        None => (text, None),
    };
    let app = display_part(app)?;
    Some((app, persona.and_then(display_part)))
}

/// The label words for `app` and its optional `persona`.
pub fn display_label(app: &str, persona: Option<&str>) -> Option<String> {
    let app = display_part(app)?;
    Some(match persona.and_then(display_part) {
        Some(persona) => format!("{app}{PERSONA_SEPARATOR}{persona}"),
        None => app,
    })
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
        Some(AgentSender { name, class, thread, display: None })
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

    /// This sender shown as `app` (and `persona`): `[from APP › PERSONA]`.
    pub fn with_display(mut self, app: &str, persona: Option<&str>) -> AgentSender {
        self.display = display_label(app, persona);
        self
    }

    /// The words the label names: [`AgentSender::display`], else the name.
    pub fn shown(&self) -> &str {
        self.display.as_deref().unwrap_or(&self.name)
    }

    /// The text the conversation shows: `[from <shown>] <text>`.
    pub fn labelled(&self, text: &str) -> String {
        format!("[from {}] {text}", self.shown())
    }

    /// `text` without the `[from <shown>] ` label this sender put on it.
    pub fn unlabelled<'a>(&self, text: &'a str) -> &'a str {
        text.strip_prefix(&format!("[from {}] ", self.shown())).unwrap_or(text)
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
mod tests;
