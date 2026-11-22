//! `source_trusted` of `cmux link start-chat copy --acpmux-home H`: whether this
//! Mac's acpmux (home `H`, the one the App's chats use) answers the chat's
//! folder here trusted, so the App records the same answer for the copy on the
//! person's own Cloud machine and they are not asked again there for it.
//!
//! `cmux link start-chat trust --folder F --acpmux-home H` reads the same
//! answer before any machine is taken (`cmux cloud start-session
//! --from-folder`): a folder this Mac does not trust would be copied to a
//! machine whose agent then refuses the copy, so the App refuses the start
//! here, with the fix on this Mac, before it leases anything.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::{Flags, StartCopy, join};

/// `--acpmux-home`: an absolute folder, else none (never trusted).
pub(super) fn acpmux_home(flags: &Flags) -> Option<PathBuf> {
    flags.one("--acpmux-home").filter(|home| home.starts_with('/')).map(PathBuf::from)
}

impl StartCopy {
    /// The chat's folder on this Mac: `local`, or `subpath` in it.
    pub(super) fn local_chat(&self) -> String {
        if self.subpath.is_empty() { self.local.clone() } else { join(&self.local, &self.subpath) }
    }

    /// Whether this Mac's acpmux answers the chat's folder here trusted, as its
    /// own pane reads it (`acp.trust.get`'s `level`: the person's decision, a
    /// rule of theirs, or each agent's own level). Only then does the App
    /// record trust for the copy on the machine (`agent-session-trust`), so a
    /// send from a folder the person trusts never asks again for its own copy;
    /// an unknown or untrusted folder, or no acpmux home given, is still asked
    /// there. Unreadable trust is not trusted.
    pub(super) fn source_trusted(&self) -> bool {
        let Some(home) = &self.acpmux_home else { return false };
        let Some(paths) = paths_at(home) else { return false };
        trusted_at(&paths, &self.local_chat())
    }
}

/// This Mac's acpmux trust files, with the record of the acpmux at `home`.
fn paths_at(home: &Path) -> Option<acpmux::trust::Paths> {
    let mut paths = acpmux::trust::Paths::current()?;
    paths.record = home.join("trust.json");
    Some(paths)
}

/// `trust --folder F --acpmux-home H`: `acp.trust.get`'s `level` for `F` as
/// this Mac's acpmux at `H` reads it (`trusted`, `untrusted` or `unknown`),
/// `{"ok":true,"folder":F,"level":L}`. Unreadable trust answers
/// `trust_unreadable`: the App then lets the start go on, as before. None:
/// bad usage.
pub(super) fn cli(flags: &Flags) -> Option<Value> {
    let folder = flags.one("--folder").filter(|folder| folder.starts_with('/'))?;
    let home = acpmux_home(flags)?;
    let Some(paths) = paths_at(&home) else {
        return Some(super::refused("trust_unreadable", "this Mac has no home folder"));
    };
    Some(level_at(&paths, folder))
}

/// The `trust` verb's answer for `folder` read with `paths`.
pub(super) fn level_at(paths: &acpmux::trust::Paths, folder: &str) -> Value {
    match acpmux::trust::get(paths, folder) {
        Ok(answer) => match answer.get("level").and_then(Value::as_str) {
            Some(level) => json!({"ok": true, "folder": folder, "level": level}),
            None => super::refused("trust_unreadable", "acpmux answered no trust level"),
        },
        Err(acpmux::trust::Failure::Invalid(error) | acpmux::trust::Failure::Record(error)) => {
            super::refused("trust_unreadable", error)
        }
    }
}

/// `acp.trust.get`'s `level` for `folder` is `trusted` ([`StartCopy::source_trusted`]).
pub(super) fn trusted_at(paths: &acpmux::trust::Paths, folder: &str) -> bool {
    acpmux::trust::get(paths, folder)
        .is_ok_and(|answer| answer.get("level").and_then(Value::as_str) == Some("trusted"))
}
