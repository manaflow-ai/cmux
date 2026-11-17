//! `cmux link start-chat preflight --local FOLDER`: whether a Cloud chat may start from `FOLDER`
//! at all, asked before any machine or lease is made for it (the App's `CloudStartChat`). Its
//! size never stops it: a folder past what a copy sends whole goes as a first pass, the rest on
//! this Mac until the chat asks for it ([`sync_cli::size_cap`]), so the chat starts at once in the
//! folder the person chose, a repository, a parent of many (`~/Projects`) or neither.
//!
//! Leo, 2026-11-15, on a Cloud chat at `~/Projects` refused as too big to copy (at least 20 GB in
//! 268,121 files) with the repositories inside it to pick from: "why are you guys still blocking
//! on these?"
//!
//! [`sync_cli::size_cap`]: super::super::sync_cli::size_cap

use std::path::Path;

use serde_json::{Value, json};

/// The answer for `local`: `{"ok":true,"estimate":{...}}` for any absolute folder, the copy's
/// estimate and decision (whole, first pass or seed) made here, before any machine
/// ([`estimate`]); `estimate` is `null` for a folder it could not read, and the start goes on.
///
/// [`estimate`]: super::super::sync_cli::estimate
pub(super) fn run(local: &str) -> Value {
    if !Path::new(local).is_absolute() {
        return super::refused("usage.invalid", "--local must be an absolute folder");
    }
    json!({"ok": true, "estimate": super::super::sync_cli::estimate::answer(Path::new(local))})
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
