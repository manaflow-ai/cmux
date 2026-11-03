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
}

impl Automation {
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

/// A fresh `auto_` id: 20 base32 characters (100 bits) from the OS random source.
pub fn new_automation_id() -> std::io::Result<String> {
    let mut bytes = [0u8; 13];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(format!("auto_{}", base32(&bytes, 20)))
}
