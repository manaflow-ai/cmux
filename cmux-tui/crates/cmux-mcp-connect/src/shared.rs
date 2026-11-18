//! The machine's one store of MCP connections, as data: where it is and what
//! a record holds. Every Chief home (optchat-chief's MCP hub) and the acpmux
//! connect card read and write the same files, so a server connected
//! anywhere in cmux is connected everywhere on this machine. This module only
//! names paths and builds records; the callers do the I/O.
//!
//! The store is per build, like every cmux state root: it sits in the build's
//! acpmux home (NIGHTLY's for the person's own app), which acpmux and every
//! Chief of that build already resolve the same way, so a dev build never
//! reads the person's connections.
//!
//! ```text
//! $CMUX_MCP_HOME (default <acpmux home>/mcp)/
//!   servers/<name>.json   a record (never a secret), 0644
//!   secrets/<name>.json   {headers, env, oauth}, 0600 in a 0700 folder
//! ```

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The env that moves the store (tests, a second profile).
pub const HOME_ENV: &str = "CMUX_MCP_HOME";

/// The store's folder: `$CMUX_MCP_HOME`, else `<acpmux_home>/mcp`.
pub fn dir(acpmux_home: &Path, env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    if let Some(d) = env(HOME_ENV).filter(|d| !d.trim().is_empty()) {
        return PathBuf::from(d);
    }
    acpmux_home.join("mcp")
}

pub fn server_path(dir: &Path, name: &str) -> PathBuf {
    dir.join("servers").join(format!("{name}.json"))
}

pub fn secrets_path(dir: &Path, name: &str) -> PathBuf {
    dir.join("secrets").join(format!("{name}.json"))
}

/// A server name: `[a-z0-9_]`, starting with a letter (also the code-mode
/// namespace `mcp.<name>` and the file name).
pub fn clean_name(raw: &str) -> String {
    let mut s: String = raw
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    let s = s.trim_matches('_').to_owned();
    if s.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) { s } else { format!("s_{s}") }
}

/// The record of a remote server someone in cmux connected. `state` is
/// `connected`, `needs sign-in` or `failed: why`; `scope` is the person's
/// choice on the card (kept for the scope rules; today every Chief and
/// agent of the machine sees the store).
pub struct Remote<'a> {
    pub name: &'a str,
    pub url: &'a str,
    pub publisher: &'a str,
    pub verified: bool,
    pub added_by: &'a str,
    pub added_ms: u64,
    pub state: &'a str,
    pub scope: Option<&'a str>,
    /// The names (never the values) of its secret headers.
    pub secret_names: &'a [String],
}

impl Remote<'_> {
    pub fn record(&self) -> Value {
        let mut v = json!({
            "name": clean_name(self.name),
            "transport": {"type": "http", "url": self.url},
            "publisher": self.publisher,
            "verified": self.verified,
            "added_ms": self.added_ms,
            "added_by": self.added_by,
            "state": self.state,
        });
        if let Some(obj) = v.as_object_mut() {
            if let Some(scope) = self.scope {
                obj.insert("scope".into(), json!(scope));
            }
            if !self.secret_names.is_empty() {
                obj.insert("secret_names".into(), json!(self.secret_names));
            }
        }
        v
    }
}

/// The secrets file for a key the person typed into a card.
pub fn key_secrets(header: &str, value: &str) -> Value {
    json!({"headers": {header: value}})
}
