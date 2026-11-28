//! `sync.live`: the VM half of a chat's live two-way folder sync (cmux-live-sync) while the chat
//! runs on AutoCloud.
//!
//! The Mac (`cmux link live serve`) dials the machine link with one line,
//! `{"id":1,"cmd":"sync.live","root":"/abs/folder"}`. When the dial may (an owner's data frame,
//! fs_wire.rs) and `root` sits under one of this daemon's file roots, the answer is
//! `{"id":1,"ok":true,"data":{"root":CANONICAL}}` and the connection turns into the cmux-live-sync
//! stream, every byte of it in binary [`crate::projection::LineWriter`] lines both ways (the Cloud
//! carrier moves whole lines only): [`cmux_live_sync::Follower::serve`] until the Mac closes it or goes silent past
//! [`cmux_live_sync::IDLE_DROP`]. Otherwise the answer is one refusal line with an `error_code`
//! (`sync.bad_request`, `sync.denied`, `sync.unavailable`, `sync.busy`, `sync.failed`) and the
//! first line of its reason; nothing falls back silently.
//!
//! One [`Follower`] per root lives for the daemon's life, so a reconnect (a sleep, a network
//! change, a link swap) keeps its index and its synced copy (`ROOT/.cmux-sync/live-follower`). A
//! second dial for a root waits up to [`TAKEOVER_WAIT`] for the first to end (the old link's
//! connection idles out within [`cmux_live_sync::IDLE_DROP`]), then is refused `sync.busy`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, TryLockError};
use std::time::{Duration, Instant};

use cmux_live_sync::Follower;
use serde_json::Value;

/// Advertised in `identify` where `sync.live` is served (this daemon has file roots).
pub const CAPABILITY: &str = "sync-live-v1";
/// The dial's command.
pub const SERVE: &str = "sync.live";
/// The follower's synced copy, under its root (cmux-live-sync never syncs `.cmux-sync`).
pub const STATE_DIR: &str = ".cmux-sync/live-follower";
/// How long a dial waits for an earlier connection on the same root to end.
pub const TAKEOVER_WAIT: Duration = Duration::from_secs(20);

type Followers = Mutex<HashMap<PathBuf, Arc<Mutex<Follower>>>>;

fn followers() -> &'static Followers {
    static FOLLOWERS: OnceLock<Followers> = OnceLock::new();
    FOLLOWERS.get_or_init(Followers::default)
}

/// `sync.live` when `line` asks for it, exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    if !line.contains(SERVE) {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    if object.contains_key("protocol") {
        return None;
    }
    (object.get("cmd")?.as_str()? == SERVE).then_some(SERVE)
}

/// The capabilities to advertise: [`CAPABILITY`] where this daemon has file roots installed.
#[must_use]
pub fn advertised() -> Vec<&'static str> {
    if crate::fs_ops::installed().is_some() { vec![CAPABILITY] } else { Vec::new() }
}

/// A refusal: its `error_code` and reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub error: String,
}

impl Refusal {
    fn new(code: &'static str, error: impl Into<String>) -> Self {
        let error = error.into();
        let error = error.lines().next().unwrap_or_default().to_string();
        Self { code, error }
    }
}

/// The dial line's `id` (echoed in the answer), or null.
#[must_use]
pub fn line_id(first: &str) -> Value {
    serde_json::from_str::<Value>(first)
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null)
}

/// Writes one refusal line answering `first`.
pub fn refuse(mut writer: impl Write, first: &str, code: &'static str, error: &str) {
    let line = serde_json::json!({
        "id": line_id(first),
        "ok": false,
        "error": error.lines().next().unwrap_or_default(),
        "error_code": code,
    });
    if let Ok(mut bytes) = serde_json::to_vec(&line) {
        bytes.push(b'\n');
        let _ = writer.write_all(&bytes);
        let _ = writer.flush();
    }
}

/// The folder `root` asks for, canonical, when it sits under one of `roots` (created if missing:
/// the chat's folder may not exist on the machine yet). Its path must be absolute, without `..`.
pub fn resolve(root: &str, roots: &[PathBuf]) -> Result<PathBuf, Refusal> {
    let asked = Path::new(root);
    if !asked.is_absolute() || asked.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(Refusal::new("sync.bad_request", "root must be an absolute path without .."));
    }
    let under = |path: &Path| roots.iter().any(|allowed| path.starts_with(allowed));
    // The deepest part that exists, canonical, then the rest: a symlink can't lead outside.
    let mut existing = asked.to_path_buf();
    let mut rest = Vec::new();
    while !existing.exists() {
        let Some(name) = existing.file_name().map(std::ffi::OsStr::to_os_string) else {
            break;
        };
        rest.push(name);
        if !existing.pop() {
            break;
        }
    }
    let mut planned = std::fs::canonicalize(&existing)
        .map_err(|e| Refusal::new("sync.failed", format!("{}: {e}", existing.display())))?;
    for name in rest.iter().rev() {
        planned.push(name);
    }
    if !under(&planned) {
        return Err(Refusal::new(
            "sync.denied",
            format!("{} is not under this machine's file roots", asked.display()),
        ));
    }
    std::fs::create_dir_all(&planned)
        .map_err(|e| Refusal::new("sync.failed", format!("{}: {e}", planned.display())))?;
    let canonical = std::fs::canonicalize(&planned)
        .map_err(|e| Refusal::new("sync.failed", format!("{}: {e}", planned.display())))?;
    if !under(&canonical) || !canonical.is_dir() {
        return Err(Refusal::new(
            "sync.denied",
            format!("{} is not a folder under this machine's file roots", asked.display()),
        ));
    }
    Ok(canonical)
}

/// The follower of `root`, made on its first dial.
fn follower(root: &Path) -> Result<Arc<Mutex<Follower>>, Refusal> {
    let mut all = followers().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(found) = all.get(root) {
        return Ok(found.clone());
    }
    let made = Follower::new(root, root.join(STATE_DIR))
        .map_err(|e| Refusal::new("sync.failed", format!("{e:#}")))?;
    let made = Arc::new(Mutex::new(made));
    all.insert(root.to_path_buf(), made.clone());
    Ok(made)
}

/// Serves one `sync.live` dial whose line is `first`: the answer, then the live stream until it
/// ends. `reader` carries every byte after the line (the caller chains what it read ahead).
pub fn serve_io(
    reader: impl Read + Send + 'static,
    mut writer: impl Write,
    first: &str,
    roots: &[PathBuf],
) {
    let asked = serde_json::from_str::<Value>(first)
        .ok()
        .and_then(|value| value.get("root").and_then(Value::as_str).map(str::to_string));
    let Some(asked) = asked else {
        refuse(&mut writer, first, "sync.bad_request", "sync.live needs a root");
        return;
    };
    let follower = match resolve(&asked, roots).and_then(|root| Ok((follower(&root)?, root))) {
        Ok(found) => found,
        Err(refusal) => {
            refuse(&mut writer, first, refusal.code, &refusal.error);
            return;
        }
    };
    let (follower, root) = follower;
    let end = Instant::now() + TAKEOVER_WAIT;
    let mut held = loop {
        match follower.try_lock() {
            Ok(held) => break held,
            Err(TryLockError::Poisoned(poisoned)) => break poisoned.into_inner(),
            Err(TryLockError::WouldBlock) if Instant::now() < end => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(TryLockError::WouldBlock) => {
                refuse(
                    &mut writer,
                    first,
                    "sync.busy",
                    &format!("{} is already syncing on another connection", root.display()),
                );
                return;
            }
        }
    };
    let answer = serde_json::json!({
        "id": line_id(first),
        "ok": true,
        "data": {"root": root.display().to_string()},
    });
    let Ok(mut bytes) = serde_json::to_vec(&answer) else { return };
    bytes.push(b'\n');
    if writer.write_all(&bytes).and_then(|()| writer.flush()).is_err() {
        return;
    }
    // The Cloud carrier moves whole lines only: every byte after the answer, both ways, travels
    // as binary projection lines (`!` and the bytes, newline and escape escaped).
    let reader =
        crate::projection::LineReader::new(std::io::BufReader::with_capacity(256 * 1024, reader));
    let writer = crate::projection::LineWriter::binary(writer);
    if let Err(error) = held.serve(reader, writer) {
        let error = format!("{error:#}");
        eprintln!(
            "cmux sync.live: {} ended: {}",
            root.display(),
            error.lines().next().unwrap_or_default()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_command_is_exact() {
        assert_eq!(frame_command(r#"{"id":1,"cmd":"sync.live","root":"/a"}"#), Some(SERVE));
        assert_eq!(frame_command(r#"{"id":1,"cmd":"sync.lives"}"#), None);
        assert_eq!(frame_command(r#"{"protocol":1,"cmd":"sync.live"}"#), None);
        assert_eq!(frame_command(r#"{"cmd":"projection.serve","x":"sync.live"}"#), None);
    }

    #[test]
    fn resolve_keeps_inside_roots() {
        let base =
            std::env::temp_dir().join(format!("cmux-live-sync-resolve-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let base = std::fs::canonicalize(&base).unwrap();
        let allowed = base.join("work");
        std::fs::create_dir_all(&allowed).unwrap();
        let outside = base.join("other");
        std::fs::create_dir_all(&outside).unwrap();
        let roots = vec![allowed.clone()];
        let made = resolve(allowed.join("new/chat").to_str().unwrap(), &roots).unwrap();
        assert_eq!(made, allowed.join("new/chat"));
        assert!(made.is_dir());
        assert_eq!(resolve("relative", &roots).unwrap_err().code, "sync.bad_request");
        let dotdot = format!("{}/../other", allowed.display());
        assert_eq!(resolve(&dotdot, &roots).unwrap_err().code, "sync.bad_request");
        assert_eq!(resolve(outside.to_str().unwrap(), &roots).unwrap_err().code, "sync.denied");
        std::os::unix::fs::symlink(&outside, allowed.join("link")).unwrap();
        let through = allowed.join("link/x");
        assert_eq!(resolve(through.to_str().unwrap(), &roots).unwrap_err().code, "sync.denied");
        std::fs::remove_dir_all(&base).unwrap();
    }
}
