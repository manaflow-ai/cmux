//! Part of `Hub`; see `hub/mod.rs`. Counts the packages an agent's shell calls
//! install, so a Cloud machine's image can come with them already downloaded
//! (Leo, 2026-11-05: "measure, say, like, what people end up putting onto
//! their thing ... so we can have it so the first time they don't need to do
//! that anymore").
//!
//! Only while Usage Patterns is on (`diagnostics.usagePatterns`, off by
//! default): the counts go into this machine's own usage-patterns file like
//! every other count, and `cmux usage-patterns` shows them. Nothing is sent.
//! `web/scripts/cmux-vm-image/install-census.ts` turns readouts into the
//! image's package list.
//!
//! Families, each key a code-defined identifier ([`cmux_usage_patterns::clean_key`]):
//! - `install`: one per install, by package manager (`npm`, `uv`, `apt`...).
//! - `install-manifest`: an install of the project's own manifest (`npm install`, `uv sync`).
//! - `install-package`: `manager:name` per registry package ([`package_key`]).
//!
//! A call is counted once, the first time a record shows its command (a call's
//! `tool_call` and its updates repeat it). Replays are never counted.

use cmux_command_class::package_installs;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::Mutex;

/// Calls remembered so a call's later records don't count it again; constant
/// memory and a constant-time scan, however long the daemon runs.
const REMEMBERED_CALLS: usize = 256;

static COUNTED: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());

/// Counts the installs a live `tool_call`/`tool_call_update` record's shell
/// command runs, once per call. One atomic load when counting is off.
pub(super) fn count_installs(session_id: &str, kind: &str, msg: &Value) {
    if !matches!(kind, "tool_call" | "tool_call_update") || !cmux_usage_patterns::enabled() {
        return;
    }
    let Some(update) = msg.pointer("/params/update") else { return };
    let Some(command) = shell_command(update.pointer("/rawInput/command")) else { return };
    let Some(call) = update.get("toolCallId").and_then(Value::as_str) else { return };
    let installs = package_installs(&command);
    if installs.is_empty() || !first_sighting(&format!("{session_id}\0{call}")) {
        return;
    }
    for install in installs {
        cmux_usage_patterns::count("install", install.manager);
        if install.packages.is_empty() {
            cmux_usage_patterns::count("install-manifest", install.manager);
        }
        for package in &install.packages {
            cmux_usage_patterns::count("install-package", &package_key(install.manager, package));
        }
    }
}

/// The command a shell call ran: a string, or Codex's argv
/// (`["bash", "-lc", "script"]` is the script; any other argv its words).
fn shell_command(command: Option<&Value>) -> Option<String> {
    match command? {
        Value::String(text) => Some(text.clone()),
        Value::Array(words) => {
            let words: Vec<&str> = words.iter().filter_map(Value::as_str).collect();
            match words.as_slice() {
                [_, flags, script] if flags.starts_with('-') && flags.contains('c') => {
                    Some((*script).to_owned())
                }
                _ => Some(words.join(" ")),
            }
        }
        _ => None,
    }
}

fn first_sighting(key: &str) -> bool {
    let mut counted = COUNTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if counted.iter().any(|seen| seen == key) {
        return false;
    }
    if counted.len() >= REMEMBERED_CALLS {
        counted.pop_front();
    }
    counted.push_back(key.to_owned());
    true
}

/// `manager:name`, in the characters a usage-patterns key keeps: an npm scope
/// drops its `@` (`npm:types/node` is `@types/node`; an unscoped npm name has
/// no `/`), and a Go module's `/` become `:` (`go:golang.org:x:tools:gopls`).
/// A key over the length cap counts as `other`.
pub(crate) fn package_key(manager: &str, package: &str) -> String {
    let name = match manager {
        "go" => package.replace('/', ":"),
        _ => package.strip_prefix('@').unwrap_or(package).to_owned(),
    };
    format!("{manager}:{name}")
}

#[cfg(test)]
mod tests;
