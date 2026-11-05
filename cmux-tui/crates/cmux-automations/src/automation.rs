//! The automation definition.

use std::io::Read;

use serde::{Deserialize, Serialize};

use crate::catch_up::CatchUp;
use crate::trigger::Trigger;

/// What a run does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Body {
    /// One agent turn through acpmux: a new session gets `prompt`.
    Prompt {
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        folder: Option<String>,
        /// acpmux `HARNESS[/MODEL]` (`claude`, `codex/gpt-5.5`); default harness when absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    /// One shell command (`/bin/sh -c`).
    Command {
        command: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        folder: Option<String>,
    },
}

impl Body {
    /// The folder the run starts in, when set.
    pub fn folder(&self) -> Option<&str> {
        match self {
            Body::Prompt { folder, .. } | Body::Command { folder, .. } => folder.as_deref(),
        }
    }
}

/// The editable part of an automation (create and update take it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutomationSpec {
    pub name: String,
    pub trigger: Trigger,
    pub body: Body,
    pub catch_up: CatchUp,
    /// A run longer than this is stopped and recorded as `timeout`.
    pub timeout_seconds: u64,
    pub enabled: bool,
}

/// The home of an automation made by a store that was not told its machine.
pub const LOCAL_HOME: &str = "mac:local";

fn default_home() -> String {
    LOCAL_HOME.to_string()
}

fn first_epoch() -> u64 {
    1
}

/// A pending move (teleport) of an automation. While it is set the
/// automation never fires here (docs/automations-teleport-teams.md, section 2).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Handoff {
    /// `tp_` and 32 lowercase hex digits; a resumed move reuses it.
    pub id: String,
    /// The destination as given (`cloud`, `home`, `ssh:HOST[:DIR]`).
    pub to: String,
    /// The epoch the destination's copy gets (this one's plus one).
    pub epoch: u64,
    /// When the fence was written, in milliseconds.
    pub at: i64,
}

/// Where an imported automation came from (the Cloud schema's `origin`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Origin {
    /// The handoff id that brought it here.
    pub handoff: String,
    /// The source's home (`cloud`, `mac:<machine id>`).
    pub from: String,
    /// Its id at the source.
    pub source_id: String,
}

/// What stays of an automation that moved away. It never fires; `list`
/// shows it for 30 days.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tombstone {
    pub id: String,
    pub name: String,
    /// The destination (`cloud`, `ssh:HOST[:DIR]`).
    pub moved_to: String,
    /// The automation's id at the destination.
    pub moved_id: String,
    /// The destination copy's epoch.
    pub epoch: u64,
    /// When it moved, in milliseconds.
    pub moved_at: i64,
}

/// A stored automation (`<root>/<id>/automation.json`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Automation {
    pub id: String,
    pub name: String,
    /// Starts at 1, one up on every update.
    pub version: u64,
    pub enabled: bool,
    pub trigger: Trigger,
    pub body: Body,
    #[serde(default)]
    pub catch_up: CatchUp,
    pub timeout_seconds: u64,
    pub created_at: i64,
    pub updated_at: i64,
    /// The one store that fires it: `cloud` or `mac:<machine id>`.
    #[serde(default = "default_home")]
    pub home: String,
    /// 1 at create, one more on each teleport; the newer epoch wins.
    #[serde(default = "first_epoch")]
    pub epoch: u64,
    /// The newest scheduled time this store handled (a run row, run or
    /// skipped), in milliseconds.
    #[serde(default)]
    pub last_slot: Option<i64>,
    /// A pending move; a fenced automation never fires.
    #[serde(default)]
    pub handoff: Option<Handoff>,
    /// Set on an automation that arrived by teleport.
    #[serde(default)]
    pub origin: Option<Origin>,
}

impl Automation {
    /// Whether a move is pending, so it must not fire.
    pub fn fenced(&self) -> bool {
        self.handoff.is_some()
    }

    /// The editable fields, for an update that changes some of them.
    pub fn spec(&self) -> AutomationSpec {
        AutomationSpec {
            name: self.name.clone(),
            trigger: self.trigger.clone(),
            body: self.body.clone(),
            catch_up: self.catch_up,
            timeout_seconds: self.timeout_seconds,
            enabled: self.enabled,
        }
    }
}

const ALPHABET: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

/// Lowercase base32 of `bytes`, cut to `len` characters.
pub(crate) fn base32(bytes: &[u8], len: usize) -> String {
    let mut out = String::with_capacity(len);
    let mut buffer = 0u32;
    let mut bits = 0;
    for &b in bytes {
        buffer = (buffer << 8) | b as u32;
        bits += 8;
        while bits >= 5 && out.len() < len {
            bits -= 5;
            // The index is 5 bits, so `get` always finds a letter.
            if let Some(&letter) = ALPHABET.get(((buffer >> bits) & 31) as usize) {
                out.push(char::from(letter));
            }
        }
    }
    out
}

/// A fresh handoff id: `tp_` and 32 lowercase hex digits (the Chief teleport's shape).
pub fn new_handoff_id() -> std::io::Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(format!("tp_{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()))
}

/// Whether `id` has the handoff id shape (`tp_` and 32 lowercase hex digits).
pub fn is_handoff_id(id: &str) -> bool {
    id.len() == 35
        && id.strip_prefix("tp_").is_some_and(|hex| {
            hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// A fresh `auto_` id: 20 base32 characters (100 bits) from the OS random source.
pub fn new_automation_id() -> std::io::Result<String> {
    let mut bytes = [0u8; 13];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(format!("auto_{}", base32(&bytes, 20)))
}
