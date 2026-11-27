//! Part of `Hub` (a child of `transfer_out.rs`). Live migration of a chat move: what lets a
//! chat whose history is gigabytes move while it keeps taking turns, over a slow link, freezing
//! only for the last few records (cmux-tui `cli/run/transfer.rs` `precopy` drives it).
//!
//! 2026-11-22: a move of a 7.26 GB coordinator chat to a host reached only through a ~96 KB/s
//! relay froze the chat for the whole copy (708 MB in 47 min, about 6 h to go). Pre-copy
//! (`transfer_precopy.rs`) takes the copy out of the freeze; this module makes that copy
//! affordable and safe to stop:
//!
//! - **Compressed pages.** `transfer_write {encoding: "zstd"}` takes a page the client
//!   compressed (an event log compresses about 10x). Daemons that take one list
//!   `crate::capabilities::TRANSFER_ZSTD`; a client compresses only for a target that lists it.
//! - **Resumable stages.** `transfer_stage {manifest, resume: true}` takes up the newest
//!   unfinished stage of the same chat (and base) instead of a new one, with the new manifest,
//!   and answers what it already holds (`have: [{path, bytes, sha256}]`). The source answers
//!   `_acpmux/transfer_digest {transferId, path, length}` for the same bytes of its new prepare;
//!   when the two agree, the client pages on from there. A prepare's prefix is the log's records
//!   in order, so a later prepare's file starts with an earlier one's: one round's copy is the
//!   next round's start, and a move begun again after its client went away starts where the
//!   target stopped, not from zero.
//! - **One prepare per chat.** A new prepare drops the chat's earlier ones: a round each
//!   writes the whole prefix, and a multi-gigabyte chat would fill the disk with them.
//! - **Progress.** The moving client reports each round (`_acpmux/transfer_progress`), and
//!   `session info` shows it (`moveProgress`): phase, bytes, rate, ETA. A report older than
//!   [`PROGRESS_FRESH`] is not shown: the client went away.

use super::*;
use crate::hub::transfer_out::{MAX_PAGE, inside, transfers_dir};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// A progress report older than this is the move's client gone: not shown.
pub(in crate::hub) const PROGRESS_FRESH: std::time::Duration = std::time::Duration::from_secs(90);

/// A move whose client was heard from this recently is not stale (`transfer_end_stale`).
const LIVE_CLIENT: std::time::Duration = std::time::Duration::from_secs(30);

/// Each chat's last move progress report, and when it came.
static PROGRESS: LazyLock<Mutex<HashMap<String, (std::time::Instant, Value)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The steps of one move request (a finish, a stage's finish, a prepare), timed: one
/// `acpmux::move_steps` line when it ends, at info once it took a second, else at debug. A slow
/// move then says which step grew with the history (cmux#54461: a 250 MB move's target finish
/// took 169 s and nothing said where).
pub(in crate::hub) struct MoveSteps {
    what: &'static str,
    started: std::time::Instant,
    last: std::time::Instant,
    steps: Vec<(&'static str, std::time::Duration)>,
}

impl MoveSteps {
    pub(in crate::hub) fn new(what: &'static str) -> Self {
        let now = std::time::Instant::now();
        Self { what, started: now, last: now, steps: Vec::new() }
    }

    /// The step that ends now.
    pub(in crate::hub) fn step(&mut self, name: &'static str) {
        let now = std::time::Instant::now();
        self.steps.push((name, now - self.last));
        self.last = now;
    }
}

impl Drop for MoveSteps {
    fn drop(&mut self) {
        let total = self.started.elapsed();
        let steps: Vec<String> =
            self.steps.iter().map(|(n, d)| format!("{n} {}ms", d.as_millis())).collect();
        let steps = steps.join(", ");
        let ms = total.as_millis() as u64;
        if total >= std::time::Duration::from_secs(1) {
            tracing::info!(target: "acpmux::move_steps", what = self.what, ms, "{steps}");
        } else {
            tracing::debug!(target: "acpmux::move_steps", what = self.what, ms, "{steps}");
        }
    }
}

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// A page's bytes as `transfer_write` takes them: base64, zstd-compressed with
/// `encoding: "zstd"`. A compressed page holds at most [`MAX_PAGE`] bytes once decompressed.
pub(in crate::hub) fn page_bytes(params: &Value) -> Result<Vec<u8>, RpcError> {
    let data = params.get("data").and_then(Value::as_str).unwrap_or("");
    let raw = BASE64.decode(data).map_err(|e| transfer_error("data", e))?;
    match params.get("encoding").and_then(Value::as_str) {
        None | Some("") | Some("identity") => Ok(raw),
        Some("zstd") => zstd::bulk::decompress(&raw, MAX_PAGE as usize)
            .map_err(|e| transfer_error("data", format!("zstd: {e}"))),
        Some(other) => Err(transfer_error("encoding", format!("{other:?} is not taken here"))),
    }
}

/// The lowercase hex SHA-256 of the first `length` bytes of `path`; `None` when it is shorter.
pub(in crate::hub) fn prefix_digest(path: &Path, length: u64) -> std::io::Result<Option<String>> {
    use sha2::Digest as _;
    use std::io::Read as _;
    let file = std::fs::File::open(path)?;
    if file.metadata()?.len() < length {
        return Ok(None);
    }
    let mut hasher = sha2::Sha256::new();
    let mut reader = std::io::BufReader::with_capacity(1 << 20, file.take(length));
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(buf.get(..n).unwrap_or_default());
    }
    Ok(Some(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()))
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

impl Hub {
    /// `_acpmux/transfer_digest {transferId, path, length}` (source): the SHA-256 of the first
    /// `length` bytes of a file of its prepare or move, for a target's resumed stage to check
    /// that the bytes it holds are these. `{sha256: null}` when the file is shorter.
    pub(in crate::hub) fn transfer_digest(&self, params: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        let transfer_id = text("transferId");
        if transfer_id.to_ascii_lowercase().starts_with("in-") {
            return Err(RpcError::not_found(format!("transfer.unknown: no move {transfer_id:?}")));
        }
        let dir = inside(&transfers_dir(), transfer_id)?;
        let bundle = std::fs::read_dir(&dir)
            .ok()
            .and_then(|entries| entries.flatten().find(|e| e.path().is_dir()))
            .map(|e| e.path())
            .ok_or_else(|| {
                RpcError::not_found(format!("transfer.unknown: no move {transfer_id:?} here"))
            })?;
        let file = inside(&bundle, text("path"))?;
        let length = params.get("length").and_then(Value::as_u64).unwrap_or(0);
        // A history-later move's bundle file grew from the prepare's copy of these bytes, whose
        // digest the prepare took (`transfer.rs` `export_grown`): no read under the freeze.
        let known = read_json(&dir.join(super::super::transfer::NATIVE_DIGESTS))
            .and_then(|all| all.get(text("path")).cloned())
            .filter(|d| d.get("length").and_then(Value::as_u64) == Some(length))
            .and_then(|d| d.get("sha256").and_then(Value::as_str).map(str::to_owned));
        let sha = match known {
            Some(sha) => Some(sha),
            None => prefix_digest(&file, length).map_err(|e| transfer_error("read", e))?,
        };
        super::super::transfer_watch::note_activity(&dir, None);
        Ok(json!({"transferId": transfer_id, "length": length, "sha256": sha}))
    }

    /// `_acpmux/transfer_progress {sessionId, ...}` (source): the moving client's report of
    /// where its move is, shown by `session info` while fresh.
    pub(in crate::hub) fn transfer_progress(&self, params: &Value) -> Result<Value, RpcError> {
        let session =
            self.resolve(params.get("sessionId").and_then(Value::as_str).unwrap_or(""))?;
        let mut report = params.clone();
        if let Some(obj) = report.as_object_mut() {
            obj.remove("sessionId");
            obj.insert("at".into(), json!(crate::store::now_ms()));
        }
        let mut all = PROGRESS.lock().unwrap_or_else(|e| e.into_inner());
        all.retain(|_, (at, _)| at.elapsed() < PROGRESS_FRESH);
        if field(&report, "phase") == "done" {
            all.remove(&session.id);
        } else {
            all.insert(session.id.clone(), (std::time::Instant::now(), report));
        }
        Ok(json!({"sessionId": session.id}))
    }

    /// `_acpmux/transfer_end_stale {sessionId}` (`acpmux session move --abort CHAT`): ends a
    /// move of the chat whose client is gone, now, the way its watch would after the lease
    /// (`transfer_watch.rs` `end_stalled_move`): one not read to its end is given back here; one
    /// that was is committed when its target took the chat and given back when it did not. A
    /// target that cannot say keeps it frozen: two copies of one chat would both run. A move whose
    /// client was heard from in the last [`LIVE_CLIENT`] is refused: it is not stale.
    ///
    /// `takeBack: true` (`--take-back`): the person's answer to a move whose target stayed
    /// undecided past the bound (`transfer_undecided`, `transfer_watch.rs`): the target is asked
    /// once more, and if it still cannot say, the chat is given back here all the same.
    pub(in crate::hub) async fn transfer_end_stale(
        self: &Arc<Self>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let session =
            self.resolve(params.get("sessionId").and_then(Value::as_str).unwrap_or(""))?;
        let Some(transfer_id) = session
            .moving()
            .filter(|m| super::names_a_move(m))
            .filter(|_| session.meta().moved_to.is_none())
        else {
            return Err(transfer_error("not_moving", "this chat is in no move to end"));
        };
        let dir = transfers_dir().join(&transfer_id);
        let heard =
            super::super::transfer_watch::last_activity(&dir).and_then(|t| t.elapsed().ok());
        // A quarter of a shortened lease (tests) at most.
        let lease = *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(ago) = heard.filter(|ago| *ago < LIVE_CLIENT.min(lease / 4)) {
            return Err(transfer_error(
                "live",
                format!(
                    "its move {transfer_id} heard from its client {}s ago; it is not stale",
                    ago.as_secs()
                ),
            ));
        }
        let take_back = params.get("takeBack").and_then(Value::as_bool) == Some(true);
        if !self.end_stalled_move(&session, &transfer_id, &dir).await {
            if take_back {
                self.take_back_undecided(&session, &transfer_id, &dir)?;
                return Ok(json!({"sessionId": session.id, "transferId": transfer_id,
                                 "ended": "taken back", "movedTo": null}));
            }
            return Err(transfer_error(
                "undecided",
                format!(
                    "the target of move {transfer_id} cannot say whether it took the chat, so it \
                     stays frozen here (two copies would both run); reach the target and try again"
                ),
            ));
        }
        let moved_to = session.meta().moved_to;
        Ok(json!({"sessionId": session.id, "transferId": transfer_id,
                  "ended": if moved_to.is_some() { "committed" } else { "given back" },
                  "movedTo": moved_to}))
    }

    /// A move of chat `id` whose target cannot say whether it took the chat, for `session info`
    /// (`moveUndecided`): `{transferId, since, offeredAt}` (Unix ms; `offeredAt` once the chat
    /// was offered back, when `--take-back` ends it). Null while no move is undecided.
    pub(crate) fn move_undecided(&self, session: &Session) -> Value {
        let Some(transfer_id) = session.moving().filter(|m| super::names_a_move(m)) else {
            return Value::Null;
        };
        let dir = transfers_dir().join(&transfer_id);
        match super::super::transfer_watch::undecided(&dir) {
            Some((since, offered)) => {
                json!({"transferId": transfer_id, "since": since, "offeredAt": offered})
            }
            None => Value::Null,
        }
    }

    /// The chat's fresh move progress report, for `session info` (`moveProgress`).
    pub(crate) fn move_progress(&self, id: &str) -> Value {
        let all = PROGRESS.lock().unwrap_or_else(|e| e.into_inner());
        all.get(id)
            .filter(|(at, _)| at.elapsed() < PROGRESS_FRESH)
            .map(|(_, report)| report.clone())
            .unwrap_or(Value::Null)
    }

    /// The bytes of chat `id`'s event log on disk (`historyBytes` in `session info`): what a
    /// move copies, before compression. `None` for a store with no folder of its own.
    pub(crate) fn history_bytes(&self, id: &str) -> Option<u64> {
        let events = self.store.session_path(id)?.join("events");
        let entries = std::fs::read_dir(events).ok()?;
        Some(
            entries
                .flatten()
                .filter(|e| e.path().extension().is_some_and(|x| x == "ndjson"))
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum(),
        )
    }
}

/// Drops every prepare of chat `chat` but `keep` (`transfers/pre-*`): a new round's prepare
/// holds all an earlier one did.
pub(in crate::hub) fn drop_other_prepares(chat: &str, keep: &str) {
    let Ok(entries) = std::fs::read_dir(transfers_dir()) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("pre-") || name == keep {
            continue;
        }
        let record = read_json(&entry.path().join("prefix.json"));
        if record.as_ref().is_some_and(|r| *field(r, "sessionId") == chat) {
            let _ = crate::home_fs::remove_dir_all(entry.path());
        }
    }
}

/// The newest unfinished stage (`transfers/in-*`, no `staged.json`) of a prefix of chat `chat`
/// from the same `base`: what a resumed stage takes up. Its id, the folder, and what each file
/// holds.
pub(in crate::hub) fn resumable_stage(chat: &str, base: &Value) -> Option<(String, PathBuf)> {
    let entries = std::fs::read_dir(transfers_dir()).ok()?;
    let mut found: Vec<(std::time::SystemTime, String, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(stage_id) = name.strip_prefix("in-") else { continue };
        let dir = entry.path();
        if dir.join("staged.json").exists() {
            continue;
        }
        let Some(manifest) = read_json(&dir.join("manifest.json")) else { continue };
        if *field(&manifest, "schema") != super::transfer_precopy::PREFIX_SCHEMA
            || *field(&manifest, "sessionId") != chat
            || field(&manifest, "base") != base
        {
            continue;
        }
        let when = std::fs::metadata(dir.join("alive"))
            .or_else(|_| std::fs::metadata(&dir))
            .and_then(|m| m.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        found.push((when, stage_id.to_owned(), dir));
    }
    found.sort_by_key(|(when, _, _)| *when);
    found.pop().map(|(_, id, dir)| (id, dir))
}

/// What the stage at `dir` holds of each file `manifest` lists (`{path, bytes, sha256}`), for
/// the client to check against the source's new prepare. A file it holds more of than the new
/// manifest's size is not resumable: `None`.
pub(in crate::hub) fn stage_holds(dir: &Path, manifest: &Value) -> Option<Vec<Value>> {
    let bundle = dir.join("bundle");
    let mut have = Vec::new();
    for f in field(manifest, "files").as_array().into_iter().flatten() {
        let path = field(f, "path").as_str()?;
        let size = field(f, "size").as_u64()?;
        let file = inside(&bundle, path).ok()?;
        let bytes = std::fs::metadata(&file).map_or(0, |m| m.len());
        if bytes > size {
            return None;
        }
        if bytes == 0 {
            continue;
        }
        let sha = prefix_digest(&file, bytes).ok().flatten()?;
        have.push(json!({"path": path, "bytes": bytes, "sha256": sha}));
    }
    Some(have)
}

/// Truncates the stage's copy of `path` to `bytes`: a resumed file the source does not hold as
/// the stage does starts again from zero (`bytes: 0`).
pub(in crate::hub) fn truncate_stage_file(
    dir: &Path,
    path: &str,
    bytes: u64,
) -> Result<(), RpcError> {
    let file = inside(&dir.join("bundle"), path)?;
    if !file.exists() {
        return Ok(());
    }
    let f = crate::home_fs::OpenOptions::new()
        .write(true)
        .open(&file)
        .map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
    f.set_len(bytes).map_err(|e| RpcError::internal(format!("transfer: {e}")))
}

/// Every file under `root`, as `(path relative to root, absolute path)`.
fn files_under(root: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(t) if t.is_dir() => dirs.push(path),
                Ok(t) if t.is_file() => {
                    if let Ok(rel) = path.strip_prefix(root) {
                        out.push((rel.to_string_lossy().into_owned(), path.clone()));
                    }
                }
                _ => {}
            }
        }
    }
    out.sort();
    out
}

/// At a stage's finish: its native files (`bundle/native`) kept as `native/` beside the staged
/// store, and what each holds (`{path, bytes, sha256}`, `path` as a bundle names it), worked
/// out now, before any freeze.
pub(in crate::hub) fn keep_staged_native(stage: &Path) -> Vec<Value> {
    let from = stage.join("bundle").join("native");
    if !from.is_dir() {
        return Vec::new();
    }
    let kept = stage.join("native");
    if crate::home_fs::rename(&from, &kept).is_err() {
        return Vec::new();
    }
    files_under(&kept)
        .into_iter()
        .filter_map(|(rel, path)| {
            let bytes = std::fs::metadata(&path).ok()?.len();
            let sha = prefix_digest(&path, bytes).ok().flatten()?;
            Some(json!({"path": format!("native/{rel}"), "bytes": bytes, "sha256": sha}))
        })
        .collect()
}

/// At a receive that takes stage `stage`: its native files go into the receive's bundle at
/// their paths, noted as seeded (`seeded.json`, which `transfer_write` may write again from an
/// earlier offset), and what each holds is answered. `staged`: the stage's record.
pub(in crate::hub) fn seed_native(
    stage: &Path,
    receive: &Path,
    staged: Option<&Value>,
) -> Vec<Value> {
    let kept = stage.join("native");
    let listed =
        staged.and_then(|s| s.get("native")).and_then(Value::as_array).cloned().unwrap_or_default();
    if !kept.is_dir() || listed.is_empty() {
        return Vec::new();
    }
    let bundle_native = receive.join("bundle").join("native");
    if crate::home_fs::create_dirs(receive.join("bundle")).is_err()
        || crate::home_fs::rename(&kept, &bundle_native).is_err()
    {
        return Vec::new();
    }
    let seeded: Vec<Value> = listed
        .into_iter()
        .filter(|h| {
            let path = field(h, "path").as_str().unwrap_or_default();
            inside(&receive.join("bundle"), path).is_ok_and(|p| {
                std::fs::metadata(p).is_ok_and(|m| Some(m.len()) == field(h, "bytes").as_u64())
            })
        })
        .collect();
    let _ = crate::home_fs::write(receive.join("seeded.json"), json!(seeded).to_string());
    seeded
}

/// Whether the receive at `dir` was seeded with `path` from a stage.
pub(in crate::hub) fn seeded(dir: &Path, path: &str) -> bool {
    read_json(&dir.join("seeded.json"))
        .is_some_and(|s| s.as_array().into_iter().flatten().any(|h| field(h, "path") == path))
}

#[cfg(test)]
#[path = "transfer_live_tests.rs"]
mod tests;
