//! `source_trusted` of `cmux link start-chat copy --acpmux-home H`: whether this
//! Mac's acpmux (home `H`, the one the App's chats use) answers the chat's
//! folder here trusted, so the App records the same answer for the copy on the
//! person's own Cloud machine and they are not asked again there for it.

use std::path::PathBuf;

use serde_json::Value;

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
        let Some(mut paths) = acpmux::trust::Paths::current() else { return false };
        paths.record = home.join("trust.json");
        trusted_at(&paths, &self.local_chat())
    }
}

/// `acp.trust.get`'s `level` for `folder` is `trusted` ([`StartCopy::source_trusted`]).
pub(super) fn trusted_at(paths: &acpmux::trust::Paths, folder: &str) -> bool {
    acpmux::trust::get(paths, folder)
        .is_ok_and(|answer| answer.get("level").and_then(Value::as_str) == Some("trusted"))
}
