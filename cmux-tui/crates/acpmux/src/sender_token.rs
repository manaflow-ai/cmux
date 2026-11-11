//! The host's sender token: how our own tools on this machine (the outbox relay, glaeda-gh, the
//! watchers) prove a send is theirs, with no process reads (Leo, 2026-11-11, on our outbox
//! relay's notice drawn as "Unverified sender": "generally the "unverified sender" things should
//! be more verified").
//!
//! One token per host: 32 random bytes, hex, in `<acpmux home>/sender-token`, which the daemon
//! makes at start when it is missing (owner-only, written whole, never replacing one). A tool
//! that may read the file proves it runs as this machine's user with the daemon's own home, as
//! the person's terminal does; the file adds what the shared unix account cannot say, that the
//! sender is one the owner set up. The CLI sends it from `ACPMUX_SENDER_TOKEN`, or from the file
//! `--sender-token-file PATH` names, never in argv (a process listing shows argv), as
//! `_meta.acpmux.senderToken`. The daemon takes it out of the request before anything else reads
//! it ([`take`]): no record, event, log line, outbox entry or peer forward ever holds it.
//!
//! A match ([`matches`], constant time) on a local unix connection labels a named sender
//! (`--from`, `ACPMUX_FROM`, a notice's sender) `verified: true, verifiedBy: "host-token"`
//! ([`label`]). It only labels: the sender never becomes the person or the owner (who counts as
//! the owner is `server/requests.rs` `owner_terminal`'s, unchanged), and a send with no name gets
//! nothing from it. A wrong token is dropped: the send goes on as it would have, never refused. A
//! token from the Web, the app's pane or a peer link is dropped unread. The program behind an
//! unverified send is `sender_program.rs`'s, which this leaves as it is.
//!
//! The daemon's verdict travels as [`CHECKED_KEY`] in `_meta.acpmux`, so the outbox's later
//! delivery and a proven peer daemon's forward keep it; a client's own copy is dropped
//! ([`stamp`]), as `sender_harness::CHECKED_KEY` is.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The token file in the daemon's home.
pub const FILE: &str = "sender-token";
/// Where the CLI reads the token from.
pub const ENV: &str = "ACPMUX_SENDER_TOKEN";
/// The request key the CLI sends it under (`_meta.acpmux`), taken out by [`take`].
pub const META_KEY: &str = "senderToken";
/// `verifiedBy` of a sender the host token proved.
pub const VERIFIED_BY: &str = "host-token";
/// The provenance field saying how a sender was verified.
pub const VERIFIED_BY_KEY: &str = "verifiedBy";
/// Where the daemon carries its verdict on a send's token in `_meta.acpmux`: `true` when it
/// matched. Never taken from a client.
pub const CHECKED_KEY: &str = "senderTokenChecked";

/// The feature a daemon lists at `initialize` when it takes the token out of every request
/// ([`take`]). A CLI presents the token only to such a daemon ([`withhold_unless`], applied to
/// every request `client.rs` sends): an older one would keep it in its outbox and forward it.
pub const FEATURE: &str = "senderToken";

/// Random bytes in the token.
const BYTES: usize = 32;
/// Longest presented token read, in bytes; a longer one is no token.
const MAX_PRESENTED: usize = 256;

/// A presented token: never printed, whole or in part.
#[derive(Clone, PartialEq, Eq)]
pub struct Presented(String);

impl std::fmt::Debug for Presented {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Presented(<redacted>)")
    }
}

impl Presented {
    /// A token as given (trimmed); `None` for an empty or oversized one.
    pub fn new(raw: &str) -> Option<Self> {
        let raw = raw.trim();
        (!raw.is_empty() && raw.len() <= MAX_PRESENTED).then(|| Self(raw.to_owned()))
    }

    /// The request field the CLI sends.
    pub fn to_value(&self) -> Value {
        json!(self.0)
    }
}

/// The token this CLI presents: the file `file` names (`--sender-token-file`), else
/// `ACPMUX_SENDER_TOKEN`. A file that cannot be read is an error, so a tool that asked to prove
/// itself learns it did not.
pub fn of_this_send(file: Option<&Path>) -> anyhow::Result<Option<Presented>> {
    if let Some(path) = file {
        let text = std::fs::read_to_string(path).map_err(|e| {
            anyhow::anyhow!("--sender-token-file {}: cannot read it: {}", path.display(), e.kind())
        })?;
        return Presented::new(&text)
            .map(Some)
            .ok_or_else(|| anyhow::anyhow!("--sender-token-file {}: empty", path.display()));
    }
    Ok(std::env::var(ENV).ok().as_deref().and_then(Presented::new))
}

/// Takes the presented token out of a request (`_meta.acpmux.senderToken`, and a queued send's
/// `request._meta.acpmux.senderToken`), whatever its transport, before anything else reads the
/// request. Every copy is removed; the first one found is returned.
pub fn take(params: &mut Value) -> Option<Presented> {
    let mut found = None;
    for pointer in ["/_meta/acpmux", "/request/_meta/acpmux"] {
        if let Some(mux) = params.pointer_mut(pointer).and_then(Value::as_object_mut)
            && let Some(value) = mux.remove(META_KEY)
            && found.is_none()
        {
            found = value.as_str().and_then(Presented::new);
        }
    }
    found
}

/// `params` without its token unless the daemon it goes to listed [`FEATURE`] (`supported`):
/// a daemon from before the token keeps unknown fields in what it stores and forwards (review of
/// #41064 at 8cc17ed2, F2). Every copy is removed, as [`take`] removes them.
pub fn withhold_unless(params: &mut Value, supported: bool) {
    if !supported {
        let _ = take(params);
    }
}

/// The token file in `home`.
pub fn path_in(home: &Path) -> PathBuf {
    home.join(FILE)
}

/// Makes the token file in `home` when there is none: 32 random bytes, hex, owner-only, written
/// to a temporary file and linked into place, so a reader never sees half of it and a file
/// already there (another daemon's) is never replaced. Leaves a file it does not trust
/// ([`read_trusted`]) as it is and says so.
pub fn ensure(home: &Path) -> anyhow::Result<()> {
    let path = path_in(home);
    if std::fs::symlink_metadata(&path).is_ok() {
        if read_trusted(&path).is_none() {
            tracing::warn!(
                "{} is not a regular owner-only file of this user: no send is verified by it",
                path.display()
            );
        }
        return Ok(());
    }
    let mut bytes = [0u8; BYTES];
    getrandom::fill(&mut bytes).map_err(|e| anyhow::anyhow!("the OS random generator: {e}"))?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let tmp = home.join(format!(".{FILE}.tmp-{}", std::process::id()));
    let made = write_new(&tmp, token.as_bytes()).and_then(|()| {
        match std::fs::hard_link(&tmp, &path) {
            Ok(()) => Ok(()),
            // Another daemon made it first: its token stands.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(e) => Err(e.into()),
        }
    });
    let _ = std::fs::remove_file(&tmp);
    made
}

#[cfg(unix)]
fn write_new(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let _ = std::fs::remove_file(path);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn write_new(_path: &Path, _bytes: &[u8]) -> anyhow::Result<()> {
    anyhow::bail!("the host sender token needs a unix file system")
}

/// The token in `path`, when the file is one to trust: a regular file (not a link), owned by
/// this process's user, with no group or other permission bits.
pub fn read_trusted(path: &Path) -> Option<String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::symlink_metadata(path).ok()?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let uid = unsafe { libc::geteuid() };
        if !meta.file_type().is_file() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
            return None;
        }
        let text = std::fs::read_to_string(path).ok()?;
        let token = text.trim();
        (token.len() == BYTES * 2 && token.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| token.to_owned())
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Whether `presented` is the host token in `home`, compared in constant time.
pub fn matches(home: &Path, presented: &Presented) -> bool {
    read_trusted(&path_in(home)).is_some_and(|token| same(token.as_bytes(), presented.0.as_bytes()))
}

/// `a == b` in time that depends on their lengths only.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The daemon's verdict on a prompt's token, before the outbox keeps it or a peer gets it:
/// `matched` for a local send that presented one ([`CHECKED_KEY`]); a client's own verdict is
/// dropped unless `carried` (the outbox's own connection, or a proven peer daemon's, as
/// `sender_harness::check_trust` says). The token itself is never written.
pub fn stamp(prompt: &mut Value, matched: Option<bool>, carried: bool) {
    let Some(mux) = prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) else {
        return;
    };
    if !carried {
        mux.remove(CHECKED_KEY);
    }
    if let Some(matched) = matched {
        mux.insert(CHECKED_KEY.into(), json!(matched));
    }
}

/// Whether the daemon's verdict on the prompt's token is a match.
pub fn matched(params: &Value) -> bool {
    params.pointer("/_meta/acpmux").and_then(|m| m.get(CHECKED_KEY)).and_then(Value::as_bool)
        == Some(true)
}

/// `provenance` labelled by the daemon's verdict on its token: a named sender (`--from`'s, a
/// notice's) whose send matched the host token is `verified` by it. Any other is left as it is,
/// and so is one the daemon verified otherwise (a caller-proven session). Labels only: who may do
/// what never reads them.
pub fn label(mut provenance: Value, matched: bool) -> Value {
    if !matched {
        return provenance;
    }
    let field = |k: &str| provenance.get(k).and_then(Value::as_str);
    if provenance.get(crate::prompt_provenance::VERIFIED).and_then(Value::as_bool) == Some(true) {
        return provenance;
    }
    let named = field("from") == Some(crate::prompt_provenance::NAMED_SENDER)
        && matches!(field("kind"), Some("agent_message" | crate::prompt_provenance::NOTICE_KIND))
        && field("fromName").is_some_and(|name| !name.trim().is_empty());
    if let (true, Some(fields)) = (named, provenance.as_object_mut()) {
        fields.insert(crate::prompt_provenance::VERIFIED.into(), json!(true));
        fields.insert(VERIFIED_BY_KEY.into(), json!(VERIFIED_BY));
    }
    provenance
}

/// Whether a provenance's sender was verified by the host token ([`label`]).
pub fn verified_by_token(provenance: &Value) -> bool {
    provenance.get(crate::prompt_provenance::VERIFIED).and_then(Value::as_bool) == Some(true)
        && provenance.get(VERIFIED_BY_KEY).and_then(Value::as_str) == Some(VERIFIED_BY)
}

#[cfg(test)]
#[path = "sender_token_tests.rs"]
mod tests;
