//! The event schema: what a usage file may hold.
//!
//! Every field is a number, a boolean, a closed enum or a [`Token`] (an identifier such as an
//! action id or a model name, checked against a narrow character set). An object id the app or
//! acpmux hands in (a tab, an agent session, a machine) is an [`Id`]: it is hashed with this
//! install's salt before it is written, so a file never holds the id itself. Unknown fields are
//! refused, so no caller can add a free-text field by sending one. There is no field for message
//! text, a file path, a URL or a title.

use serde::{Deserialize, Serialize};

/// The longest [`Token`] kept; a longer one is written as [`Token::OTHER`].
pub const TOKEN_MAX: usize = 64;
/// The longest raw [`Id`] accepted before hashing.
pub const ID_MAX: usize = 256;

/// An identifier from a fixed vocabulary (an action id, a harness, a model, a channel):
/// `[A-Za-z0-9._:\[\]-]{1,64}`. Anything else (a space, a slash, a longer text) becomes
/// [`Token::OTHER`], so a person's own text never lands in the file through a token.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct Token(String);

impl Token {
    /// What an unacceptable token is written as.
    pub const OTHER: &'static str = "other";

    /// `raw` when it is a plain identifier, else [`Token::OTHER`].
    pub fn new(raw: &str) -> Self {
        let plain = !raw.is_empty()
            && raw.len() <= TOKEN_MAX
            && raw.bytes().all(|b| {
                b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-' | b'[' | b']')
            });
        Self(if plain { raw.to_owned() } else { Self::OTHER.to_owned() })
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for Token {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Ok(Self::new(&raw))
    }
}

/// An object id (a tab, an agent session, a machine). Callers hand in the raw id;
/// [`crate::Recorder`] replaces it with a 12-byte salted SHA-256 (24 hex characters) before
/// writing, so files from two installs never share an id and no id is readable back.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Id(String);

impl Id {
    pub fn new(raw: impl Into<String>) -> Self {
        Self(raw.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn hash_with(&mut self, salt: &[u8]) {
        use sha2::{Digest, Sha256};
        let mut raw = std::mem::take(&mut self.0);
        // At most ID_MAX bytes, cut at a character boundary (`truncate` panics inside one).
        let cut = (0..=ID_MAX.min(raw.len())).rev().find(|&i| raw.is_char_boundary(i)).unwrap_or(0);
        raw.truncate(cut);
        let mut digest = Sha256::new();
        digest.update(salt);
        digest.update(raw.as_bytes());
        self.0 = hex::encode(&digest.finalize()[..12]);
    }
}

/// What the person's keyboard is in, as the app's focus model resolves it
/// (`FocusState.Resolved.kind`, folded to what a report needs).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Surface {
    Terminal,
    /// A web page, its address bar, find bar or DevTools.
    Browser,
    /// An agent chat tab.
    Chat,
    /// An internal page tab (Markdown, diff, files, Settings as a tab).
    Page,
    /// A Home conversation.
    Conversation,
    /// The sidebar or its search field.
    Sidebar,
    /// The command palette.
    Palette,
    /// Another overlay (a sheet, rename, a menu).
    Overlay,
    /// A pane with nothing to type into, a text field, or nothing.
    Other,
}

/// How an action run started (`ActionEntrypoint`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Entry {
    /// A key press: a shortcut, a menu key equivalent, the palette's Return.
    Key,
    /// A click or a drop.
    Pointer,
    /// The person's run with no input event being dispatched.
    Unattributed,
    Cli,
    Mcp,
    Script,
    Remote,
    Page,
}

/// One thing that happened. The variants are the whole vocabulary of a usage file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case", deny_unknown_fields)]
pub enum Event {
    /// The app started. `prev` is how the previous run ended: `clean`, `crash`, `hang` or `unknown`.
    Launch { channel: Token, build: Token, prev: Token },
    /// The app became active (`on`) or stopped being active.
    Active { on: bool },
    /// The keyboard moved to `surface`, in content tab `tab` when there is one.
    Focus {
        surface: Surface,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tab: Option<Id>,
    },
    /// An action ran: its catalog id (cmux.json commands are `custom`, anything else bound outside
    /// the catalog `extension`), how it started, and its perform-to-commit time.
    Action { id: Token, via: Entry, ms: f32 },
    /// A latency the app or a page measured, by name (`first_frame`, `chat_first_paint`,
    /// `chat_switch`, ...).
    Latency { what: Token, ms: f32 },
    /// How much is open now.
    Counts {
        windows: u32,
        workspaces: u32,
        screens: u32,
        panes: u32,
        tabs: u32,
        terminals: u32,
        browsers: u32,
        chats: u32,
        /// The widest pane count of one screen (a split layout's size).
        #[serde(default)]
        max_panes_per_screen: u32,
        /// The sidebar's width in points, 0 when hidden.
        #[serde(default)]
        sidebar_width: u32,
    },
    /// An agent chat was shown (`on`) or hidden in every pane that had it.
    View { session: Id, on: bool },
    /// An agent session started on `machine` (hashed host name; `local` for this one).
    Session { session: Id, harness: Token, machine: Id },
    /// An agent turn ended, with what its harness reported.
    Turn {
        session: Id,
        harness: Token,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<Token>,
        ms: u64,
        #[serde(default)]
        input_tokens: u64,
        #[serde(default)]
        output_tokens: u64,
        #[serde(default)]
        cache_read_tokens: u64,
        #[serde(default)]
        cache_write_tokens: u64,
        #[serde(default)]
        tool_calls: u32,
        #[serde(default)]
        subagents: u32,
    },
    /// A counted interaction inside a page: `what` is `scroll`, `fold`, `unfold`, `search`,
    /// `copy`, ... and `n` how many since the last such event.
    Interaction { what: Token, n: u32 },
    /// A connection count now: `what` is `peers`, `remote_control`, `share_links`, `machines`.
    Connections { what: Token, n: u32 },
}

impl Event {
    /// Hashes every [`Id`] in place.
    pub(crate) fn hash_ids(&mut self, salt: &[u8]) {
        match self {
            Self::Focus { tab: Some(tab), .. } => tab.hash_with(salt),
            Self::View { session, .. } | Self::Turn { session, .. } => session.hash_with(salt),
            Self::Session { session, machine, .. } => {
                session.hash_with(salt);
                if machine.as_str() != "local" {
                    machine.hash_with(salt);
                }
            }
            _ => {}
        }
    }
}

/// Which process wrote a record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    App,
    Daemon,
    Acpmux,
}

/// One line of a usage file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    /// Unix time in milliseconds.
    pub at: u64,
    pub src: Source,
    pub ev: Event,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_keeps_identifiers_and_drops_text() {
        assert_eq!(Token::new("workspace.select-next").as_str(), "workspace.select-next");
        assert_eq!(Token::new("claude-opus-5-5[1m]").as_str(), "claude-opus-5-5[1m]");
        assert_eq!(Token::new("my secret project").as_str(), Token::OTHER);
        assert_eq!(Token::new("/Users/leo/notes.md").as_str(), Token::OTHER);
        assert_eq!(Token::new("https://example.com").as_str(), Token::OTHER);
        assert_eq!(Token::new(&"a".repeat(65)).as_str(), Token::OTHER);
        assert_eq!(Token::new("").as_str(), Token::OTHER);
    }

    #[test]
    fn unknown_fields_are_refused() {
        let line = r#"{"at":1,"src":"app","ev":{"t":"active","on":true,"title":"secret"}}"#;
        assert!(serde_json::from_str::<Record>(line).is_err());
        let line = r#"{"at":1,"src":"app","ev":{"t":"active","on":true},"note":"secret"}"#;
        assert!(serde_json::from_str::<Record>(line).is_err());
    }

    #[test]
    fn a_free_text_token_is_written_as_other() {
        let line = r#"{"at":1,"src":"app","ev":{"t":"action","id":"cmuxConfig.deploy acme","via":"key","ms":2.5}}"#;
        let record: Record = serde_json::from_str(line).expect("valid shape");
        let Event::Action { id, .. } = record.ev else { panic!("action") };
        assert_eq!(id.as_str(), Token::OTHER);
    }

    #[test]
    fn ids_hash_with_the_salt() {
        let mut a = Event::Focus { surface: Surface::Chat, tab: Some(Id::new("tab-1")) };
        let mut b = a.clone();
        a.hash_ids(b"salt-a");
        b.hash_ids(b"salt-b");
        let (Event::Focus { tab: Some(ta), .. }, Event::Focus { tab: Some(tb), .. }) = (&a, &b)
        else {
            panic!("focus")
        };
        assert_eq!(ta.as_str().len(), 24);
        assert_ne!(ta, tb);
        assert!(!ta.as_str().contains("tab-1"));
    }

    /// A long id is cut at a character boundary before hashing (Codex review of 4cf46c11):
    /// `String::truncate` inside a multi-byte character panicked.
    #[test]
    fn a_long_multibyte_id_hashes_without_panicking() {
        let raw = format!("a{}", "é".repeat(200));
        let mut ev = Event::View { session: Id::new(raw.clone()), on: true };
        ev.hash_ids(b"salt");
        let Event::View { session, .. } = ev else { panic!("view") };
        assert_eq!(session.as_str().len(), 24);
        let mut same = Event::View { session: Id::new(raw[..ID_MAX - 1].to_owned()), on: true };
        same.hash_ids(b"salt");
        let Event::View { session: cut, .. } = same else { panic!("view") };
        assert_eq!(session, cut);
    }

    #[test]
    fn local_machine_stays_readable() {
        let mut ev = Event::Session {
            session: Id::new("s"),
            harness: Token::new("claude"),
            machine: Id::new("local"),
        };
        ev.hash_ids(b"salt");
        let Event::Session { machine, .. } = ev else { panic!("session") };
        assert_eq!(machine.as_str(), "local");
    }
}
