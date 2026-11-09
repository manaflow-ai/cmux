//! A turn's before and after picture of the chat's page (wow idea 26): when a turn starts in a chat
//! whose cmux workspace shows a web page in a browser pane, acpmux captures that page, and once the
//! turn has settled it captures it again. The pair is kept only when the pictures differ, so the
//! chat's edited-files card shows what the turn changed on screen (`_acpmux/turn_shots`, the
//! webview's `TurnShots`).
//!
//! The capture is the browser host's own `screenshot` (cmux-browser-host, `js/api.js`), through one
//! REPL session of this daemon on the `cef` engine: the app's tabs only, never a headless browser
//! started for it, and the host masks typed secrets in every capture. The tab is the selected live
//! http(s) tab of the chat's workspace (`tabs.list({all: true})`); a hibernated tab is never woken.
//! No page, no host or no workspace: no capture, and the turn never waits on one.
//!
//! Disk: `<ACPMUX_HOME>/turn-shots/<session>/<turn>/{before,after}.png`, at most [`KEEP_TURNS`]
//! turns per chat and [`KEEP_CHATS`] chats (the oldest go first), each picture at most
//! [`MAX_SHOT_BYTES`]: at most 12 pictures (48 MiB) per chat. A deleted chat's go with it.

use super::Session;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Write as _};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::Duration;
use tokio::sync::watch;

/// Turns per chat whose pair is kept.
pub(crate) const KEEP_TURNS: usize = 6;
/// Chats whose pairs are kept.
pub(crate) const KEEP_CHATS: usize = 32;
/// A larger picture is not kept (the host inlines up to 4 MiB too).
pub(crate) const MAX_SHOT_BYTES: usize = 4 << 20;
/// One capture's bound, connect to answer.
const CAPTURE_LIMIT: Duration = Duration::from_secs(20);
/// How long `_acpmux/turn_shots` waits on a turn's capture still running.
const READ_WAIT: Duration = Duration::from_secs(30);
/// This daemon's REPL session on the browser host.
const REPL_SESSION: &str = "acpmux-turn-shots";
const BEFORE: &str = "before.png";
const AFTER: &str = "after.png";

/// Where a turn's pair is: its before being taken, its before taken (the turn's end takes the
/// after), or kept or dropped.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Phase {
    Before,
    Ready,
    Done,
}

/// A turn whose pair is not done: its phase, and its workspace for the after.
struct Pending {
    workspace: String,
    phase: watch::Sender<Phase>,
    /// The turn settled (`turn_ended` took its after).
    ended: bool,
}

/// The turns whose pair is not done, by session and turn. A chat has at most one: a new turn's
/// start drops an older one that never ended (a failed turn writes no settled result).
static PENDING: LazyLock<Mutex<HashMap<(String, String), Pending>>> =
    LazyLock::new(Default::default);

/// The phase of a settled turn's pair still being taken.
fn pending_phase(key: &(String, String)) -> Option<watch::Receiver<Phase>> {
    let pending = PENDING.lock().unwrap_or_else(PoisonError::into_inner);
    pending.get(key).filter(|p| p.ended).map(|p| p.phase.subscribe())
}

/// Ends a turn's pending pair: its readers stop waiting.
fn finish(key: &(String, String)) {
    if let Some(pending) = PENDING.lock().unwrap_or_else(PoisonError::into_inner).remove(key) {
        let _ = pending.phase.send_replace(Phase::Done);
    }
}

fn root() -> PathBuf {
    crate::config::home().join("turn-shots")
}

/// A session or turn id as one path segment: ids are letters, digits, `-` and `_`.
fn segment(id: &str) -> Option<&str> {
    let safe = !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    safe.then_some(id)
}

fn turn_dir(base: &Path, session: &str, turn: &str) -> Option<PathBuf> {
    Some(base.join(segment(session)?).join(segment(turn)?))
}

/// A workspace id as the app and acpmux spell it, compared: a UUID or `ws_` and its 32 hex digits.
fn workspace_key(id: &str) -> String {
    let id = id.strip_prefix("ws_").unwrap_or(id);
    id.chars().filter(|c| *c != '-').flat_map(char::to_lowercase).collect()
}

/// The browser host's agent socket, as a cmux terminal's client finds it: the daemon's
/// (`CMUX_BROWSER_HOST_SOCKET`, else `bh-<digest>` beside `CMUX_TUI_SOCKET`), else the default.
fn host_socket() -> PathBuf {
    let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if let Some(path) = env("CMUX_BROWSER_HOST_SOCKET") {
        return path.into();
    }
    if let Some(daemon) = env("CMUX_TUI_SOCKET") {
        use sha2::{Digest as _, Sha256};
        let daemon = PathBuf::from(daemon);
        let digest = format!("{:x}", Sha256::digest(daemon.as_os_str().as_encoded_bytes()));
        let parent = daemon.parent().map(Path::to_path_buf).unwrap_or_else(|| "/tmp".into());
        return parent.join(format!("bh-{}", &digest[..12])).join("browser-host.sock");
    }
    let base = match env("XDG_RUNTIME_DIR") {
        Some(dir) => PathBuf::from(dir).join("cmux"),
        // SAFETY: getuid(2) has no failure modes or memory effects.
        None => std::env::temp_dir().join(format!("cmux-{}", unsafe { libc::getuid() })),
    };
    base.join("browser-host.sock")
}

/// The REPL cell that writes the workspace's page to `out`, printing `TURN_SHOT <json>` when it did.
pub(crate) fn capture_code(workspace: &str, out: &Path) -> String {
    let workspace = json!(workspace_key(workspace));
    let out = json!(out.display().to_string());
    format!(
        r#"const key = (id) => String(id || "").replace(/^ws_/, "").replace(/-/g, "").toLowerCase();
const tab = (await tabs.list({{ all: true }})).find((t) => t.active && t.state === "live" && key(t.workspace) === {workspace} && /^https?:\/\//.test(t.url || ""));
if (tab) {{ await screenshot(await tabs.get(tab.id), {{ path: {out} }}); console.log("TURN_SHOT " + JSON.stringify({{ url: tab.url }})); }}"#
    )
}

/// One request to the browser host, answered by its `result`.
fn host_call(socket: &Path, method: &str, params: Value) -> Option<Value> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(CAPTURE_LIMIT)).ok()?;
    stream.set_write_timeout(Some(CAPTURE_LIMIT)).ok()?;
    let id = format!("{method}-{}", std::process::id());
    let mut line =
        serde_json::to_vec(&json!({"id": id, "method": method, "params": params, "origin": "mcp"}))
            .ok()?;
    line.push(b'\n');
    stream.write_all(&line).ok()?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut answer = String::new();
        if reader.read_line(&mut answer).ok()? == 0 {
            return None;
        }
        let Ok(reply) = serde_json::from_str::<Value>(&answer) else { continue };
        if reply["id"] != json!(id) {
            continue;
        }
        if reply.get("error").is_some_and(|e| !e.is_null()) {
            return None;
        }
        return Some(reply.get("result").cloned().unwrap_or(Value::Null));
    }
}

/// Captures the workspace's page into `out`. Blocking, bounded by [`CAPTURE_LIMIT`] per call.
fn capture(socket: &Path, base: &Path, workspace: &str, out: &Path) -> bool {
    if !socket.exists() {
        return false;
    }
    let params = json!({
        "session": REPL_SESSION,
        "engine": "cef",
        "label": "Turn pictures",
        "cwd": base.display().to_string(),
        "code": capture_code(workspace, out),
        "timeoutMs": CAPTURE_LIMIT.as_millis() as u64 - 2_000,
    });
    let taken = host_call(socket, "browser.repl.eval", params).is_some_and(|result| {
        result["error"].is_null()
            && result["output"]
                .as_str()
                .is_some_and(|text| text.lines().any(|l| l.starts_with("TURN_SHOT ")))
    });
    taken && std::fs::metadata(out).is_ok_and(|m| m.len() > 0 && m.len() as usize <= MAX_SHOT_BYTES)
}

/// Keeps a turn's pair when it shows a change: the after differs from the before. Then at most
/// [`KEEP_TURNS`] turns of the chat and [`KEEP_CHATS`] chats stay.
pub(crate) fn settle(base: &Path, session_dir: &Path, turn_dir: &Path) {
    let read = |name: &str| std::fs::read(turn_dir.join(name)).ok();
    let changed =
        matches!((read(BEFORE), read(AFTER)), (Some(before), Some(after)) if before != after);
    if !changed {
        let _ = std::fs::remove_dir_all(turn_dir);
    }
    prune(session_dir, KEEP_TURNS);
    prune(base, KEEP_CHATS);
}

/// Removes all but the `keep` newest folders of `dir` (by modification time).
fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut folders: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| {
            (e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), e.path())
        })
        .collect();
    if folders.len() <= keep {
        return;
    }
    folders.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, path) in folders.into_iter().skip(keep) {
        let _ = std::fs::remove_dir_all(path);
    }
}

/// Session `id`'s pictures, deleted with its chat. Blocking.
pub(crate) fn remove_session(id: &str) {
    if let Some(id) = segment(id) {
        let _ = std::fs::remove_dir_all(root().join(id));
    }
}

/// The turn's before picture, taken off the turn's path. Nothing for a chat with no workspace.
pub(super) fn turn_began(session: &Session, turn: &str) {
    let workspace =
        session.meta.lock().unwrap_or_else(PoisonError::into_inner).workspace_id.clone();
    let Some(workspace) = workspace else { return };
    let base = root();
    let Some(dir) = turn_dir(&base, &session.id, turn) else { return };
    let key = (session.id.clone(), turn.to_owned());
    {
        let mut pending = PENDING.lock().unwrap_or_else(PoisonError::into_inner);
        // A turn that never settled (it failed) never gets its after; a settled one's after may
        // still be taken, and finishes itself.
        let stale: Vec<_> = pending
            .iter()
            .filter(|(k, p)| k.0 == key.0 && !p.ended)
            .map(|(k, _)| k.clone())
            .collect();
        for old in stale {
            if let Some(old_pending) = pending.remove(&old) {
                let _ = old_pending.phase.send_replace(Phase::Done);
            }
            if let Some(old_dir) = turn_dir(&base, &old.0, &old.1) {
                let _ = std::fs::remove_dir_all(old_dir);
            }
        }
        let (phase, _) = watch::channel(Phase::Before);
        pending.insert(key.clone(), Pending { workspace: workspace.clone(), phase, ended: false });
    }
    let socket = host_socket();
    tokio::task::spawn_blocking(move || {
        let taken = std::fs::create_dir_all(&dir).is_ok()
            && capture(&socket, &base, &workspace, &dir.join(BEFORE));
        if !taken {
            let _ = std::fs::remove_dir_all(&dir);
            finish(&key);
            return;
        }
        if let Some(pending) = PENDING.lock().unwrap_or_else(PoisonError::into_inner).get(&key) {
            let _ = pending.phase.send_replace(Phase::Ready);
        }
    });
}

/// The turn's after picture, then the pair kept or dropped. A turn whose before is still being
/// taken gets its after once that is done.
pub(super) fn turn_ended(session: &Session, turn: &str) {
    let key = (session.id.clone(), turn.to_owned());
    let phase =
        PENDING.lock().unwrap_or_else(PoisonError::into_inner).get_mut(&key).map(|pending| {
            pending.ended = true;
            pending.phase.subscribe()
        });
    let Some(mut phase) = phase else { return };
    let socket = host_socket();
    tokio::spawn(async move {
        // The before is bounded by the capture limit, so this wait is too.
        let ready =
            tokio::time::timeout(CAPTURE_LIMIT * 2, phase.wait_for(|p| *p != Phase::Before))
                .await
                .map(|seen| seen.map(|p| *p));
        let workspace = match ready {
            Ok(Ok(Phase::Ready)) => PENDING
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&key)
                .map(|pending| pending.workspace.clone()),
            _ => None,
        };
        let Some(workspace) = workspace else {
            if let Some(dir) = turn_dir(&root(), &key.0, &key.1) {
                let _ = tokio::fs::remove_dir_all(dir).await;
            }
            finish(&key);
            return;
        };
        let _ = tokio::task::spawn_blocking(move || {
            let base = root();
            if let Some(dir) = turn_dir(&base, &key.0, &key.1) {
                capture(&socket, &base, &workspace, &dir.join(AFTER));
                settle(&base, &base.join(&key.0), &dir);
            }
            finish(&key);
        })
        .await;
    });
}

/// `_acpmux/turn_shots {sessionId, turnId}`: the turn's kept pair as `{mimeType, data}` pictures,
/// or no `before` and `after` when it has none. A pair still being taken is waited for, at most
/// [`READ_WAIT`].
pub(crate) async fn turn_shots(session: &str, turn: &str) -> Value {
    // Only a settled turn's after is coming: a turn that failed before its result never gets one.
    if let Some(mut phase) = pending_phase(&(session.to_owned(), turn.to_owned())) {
        let _ = tokio::time::timeout(READ_WAIT, phase.wait_for(|p| *p == Phase::Done)).await;
    }
    let dir = turn_dir(&root(), session, turn);
    let read = move || {
        let picture = |name: &str| {
            use base64::Engine as _;
            let bytes = std::fs::read(dir.as_ref()?.join(name)).ok()?;
            Some(
                json!({"mimeType": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(bytes)}),
            )
        };
        match (picture(BEFORE), picture(AFTER)) {
            (Some(before), Some(after)) => json!({"before": before, "after": after}),
            _ => json!({}),
        }
    };
    let mut reply = tokio::task::spawn_blocking(read).await.unwrap_or_else(|_| json!({}));
    reply["sessionId"] = json!(session);
    reply["turnId"] = json!(turn);
    reply
}

#[cfg(test)]
#[path = "turn_shots_tests.rs"]
mod tests;
