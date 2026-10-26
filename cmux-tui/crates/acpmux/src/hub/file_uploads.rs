//! Files the person drops or pastes into a chat that the composer can't attach as a prompt block
//! (a binary, a large text file): the app sends each one (`_acpmux/file_put {sessionId,
//! fileName, data}`), and the daemon that owns the session writes it owner-only on its own machine, under
//! `<ACPMUX_HOME>/uploads/<session id>/<random>/<name>` (its own folder, so two files may share a
//! name), and answers `{path}`. The composer puts the path in the prompt and the agent opens it
//! with its own tools. A chat on an ssh peer gets the file there: the request names the session, so
//! `peer_forward.rs` takes it to the daemon that owns it, and a peer that does not advertise
//! [`FEATURE`] is refused before anything is sent.
//!
//! The old one-shot request is bounded to [`LEGACY_MAX_BYTES`] because it crosses the peer link as
//! one WebSocket frame. New clients use the resumable methods below, whose chunks are bounded by
//! [`CHUNK_BYTES`], and a file of any size streams to disk chunk by chunk. A file has no size cap
//! (Leo, 2026-10-24: "I thought we removed the file size limit attachment situation... we
//! shouldn't have this limit"): `file_put_begin` refuses one only when this machine's disk lacks
//! room for it ([`room_for`], `filePut.noSpace`), and a chunk the disk cannot take is refused the
//! same way, its partial file deleted. `file_put_cancel` deletes a partial file and its folder.
//!
//! A chat's files go when the chat is deleted (`_acpmux/kill` with purge, [`remove_session`]; not
//! when Bring Back replaces its closed copy under the same id, `transfer_in.rs`), and
//! any file goes once it is older than `uploadsMaxAgeDays` (default 30; 0 keeps them), read from
//! the UUIDv7 name of its folder ([`sweep`], at the daemon's start and every day after). An upload
//! never finished (its client went away without a cancel) goes once it is a day old. A folder
//! the daemon did not name that way is never deleted.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// The `initialize` feature of a daemon that takes `_acpmux/file_put`.
pub const FEATURE: &str = "filePut";
/// The resumable upload feature advertised by current daemons.
pub const CHUNKS_FEATURE: &str = "filePutChunks";
/// The largest one-shot request accepted for compatibility with older peers.
pub const LEGACY_MAX_BYTES: usize = 10 << 20;
/// The largest decoded chunk. Its base64 form stays below one MiB on the wire.
pub const CHUNK_BYTES: usize = 512 << 10;
/// What an upload leaves free on the disk, so the daemon's own store and logs still write.
const DISK_RESERVE_BYTES: u64 = 256 << 20;
/// How old an unfinished upload (a `.part` its client never finished or cancelled) gets before
/// the sweep deletes it.
const PARTIAL_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);

fn root() -> PathBuf {
    crate::config::home().join("uploads")
}

/// The folder of session `id`'s uploads; none for an id that is not a plain name.
pub(crate) fn session_dir(id: &str) -> Option<PathBuf> {
    let plain =
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| root().join(id))
}

/// Deletes session `id`'s uploads: the chat was deleted. Blocking: run it off the runtime.
pub(crate) fn remove_session(id: &str) {
    let Some(dir) = session_dir(id) else { return };
    // Never follows a symlink: `remove_dir_all` removes the link, not what it names.
    match std::fs::remove_dir_all(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(session = id, "uploads not deleted: {e}"),
    }
}

/// When the folder `name` was made, in Unix ms: the time a UUIDv7 name holds ([`put`] names each
/// file's folder so); None for any other name.
fn made_at(name: &str) -> Option<u64> {
    let id = uuid::Uuid::try_parse(name).ok().filter(|id| id.get_version_num() == 7)?;
    let (secs, nanos) = id.get_timestamp()?.to_unix();
    Some(secs * 1000 + u64::from(nanos) / 1_000_000)
}

/// Deletes each upload under `root` older than `max_age` at `now_ms` (none with no `max_age`), the
/// partial file of each unfinished one no chunk has written for [`PARTIAL_MAX_AGE`] (only its
/// `.part` and `.meta`: a finish that names the file meanwhile keeps it), and a folder either
/// leaves empty; answers how many uploads went. Only real folders with a UUIDv7 name are read as
/// uploads: a symlink, a file or another name is kept. Blocking: run it off the runtime.
pub(crate) fn sweep(root: &Path, now_ms: u64, max_age: Option<Duration>) -> usize {
    let before =
        |age: Duration| now_ms.saturating_sub(u64::try_from(age.as_millis()).unwrap_or(u64::MAX));
    let cutoff = max_age.map_or(0, before);
    let idle_cutoff = before(PARTIAL_MAX_AGE);
    let real_dirs =
        |dir: &Path| {
            std::fs::read_dir(dir).into_iter().flatten().flatten().filter(|entry| {
                entry.file_type().is_ok_and(|kind| kind.is_dir() && !kind.is_symlink())
            })
        };
    let mut removed = 0;
    for session in real_dirs(root) {
        for upload in real_dirs(&session.path()) {
            let Some(made) = upload.file_name().to_str().and_then(made_at) else { continue };
            let dir = upload.path();
            // Read and deleted under the lock a chunk writes and a finish names under.
            let _parts = parts_lock();
            if made < cutoff {
                if std::fs::remove_dir_all(&dir).is_ok() {
                    removed += 1;
                }
            } else if last_write(&dir).is_some_and(|at| at < idle_cutoff) {
                remove_unfinished(&dir.join(".part"), &dir.join(".meta"));
                removed += 1;
            }
        }
        // Only an empty folder goes (`remove_dir` refuses any other).
        let _ = std::fs::remove_dir(session.path());
    }
    removed
}

/// Held while a chunk writes an upload's `.part`, while a finish names it, and while the sweep
/// reads an upload's age and deletes it: the sweep never deletes a part a chunk is writing (whose
/// bytes would go to a file no longer named) or a finish is naming. Never held across a sync.
static PARTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn parts_lock() -> std::sync::MutexGuard<'static, ()> {
    PARTS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// When the unfinished upload in folder `dir` was last written, in Unix ms (its `.part`, which
/// every chunk writes, else its `.meta`); None for a finished one.
fn last_write(dir: &Path) -> Option<u64> {
    [".part", ".meta"].iter().find_map(|name| {
        let at = dir.join(name).symlink_metadata().ok()?.modified().ok()?;
        let since = at.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        Some(u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
    })
}

impl super::Hub {
    /// The age cap's sweep (module docs): at the start, then every day. `uploadsMaxAgeDays` is
    /// read at each sweep, so a config reload applies from the next.
    pub fn start_upload_sweep(self: &Arc<Self>) {
        let hub = self.clone();
        tokio::spawn(async move {
            let mut every = tokio::time::interval(Duration::from_secs(24 * 60 * 60));
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                every.tick().await;
                // With no age cap, unfinished uploads still go.
                let max_age = hub.config.read().await.uploads_max_age();
                let now = crate::store::now_ms();
                match tokio::task::spawn_blocking(move || sweep(&root(), now, max_age)).await {
                    Ok(0) => {}
                    Ok(n) => tracing::info!(uploads = n, "deleted uploads past the age cap"),
                    Err(e) => tracing::warn!("the upload sweep failed: {e}"),
                }
            }
        });
    }
}

/// A name a folder holds as one plain file (the app's `AgentPaneUpload.isFileName`): 1 to 255
/// UTF-8 bytes, not a dot file (nor `.` or `..`), no `/`, one plain path component, and no control
/// or bidirectional formatting character. On Windows also no `\` or `:` (a drive prefix such as
/// `C:x` replaces the folder it is joined to) and no device name (`windows_device_name`).
pub fn is_file_name(name: &str) -> bool {
    is_file_name_for(name, cfg!(windows))
}

/// `is_file_name` with Windows' rules when `windows`.
fn is_file_name_for(name: &str, windows: bool) -> bool {
    if !(1..=255).contains(&name.len())
        || name.starts_with('.')
        || name.contains('/')
        || (windows && (name.contains('\\') || name.contains(':') || windows_device_name(name)))
    {
        return false;
    }
    let mut parts = std::path::Path::new(name).components();
    if !matches!((parts.next(), parts.next()), (Some(std::path::Component::Normal(_)), None)) {
        return false;
    }
    !name.chars().any(|c| {
        let v = u32::from(c);
        v < 0x20
            || v == 0x7f
            || (0x80..=0x9f).contains(&v)
            || (0x202a..=0x202e).contains(&v)
            || (0x2066..=0x2069).contains(&v)
            || v == 0x200e
            || v == 0x200f
    })
}

/// A name Windows does not keep as its own file in a folder: a device (`CON`, `PRN`, `AUX`, `NUL`,
/// `COM1`-`COM9`, `LPT1`-`LPT9` and their superscript-digit forms, `CONIN$`, `CONOUT$`) with any
/// extension, in any case, and a name that ends in a dot or a space, which Windows drops.
/// https://learn.microsoft.com/windows/win32/fileio/naming-a-file#naming-conventions
fn windows_device_name(name: &str) -> bool {
    if name.ends_with(['.', ' ']) {
        return true;
    }
    let stem = name.split('.').next().unwrap_or(name).trim_end_matches(' ').to_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$") {
        return true;
    }
    let mut chars = stem.chars();
    let head: String = chars.by_ref().take(3).collect();
    matches!(head.as_str(), "COM" | "LPT")
        && matches!(
            (chars.next(), chars.next()),
            (Some('1'..='9' | '\u{b9}' | '\u{b2}' | '\u{b3}'), None)
        )
}

/// The one-shot request past [`LEGACY_MAX_BYTES`]: such a file goes with `file_put_begin`.
fn too_large() -> RpcError {
    RpcError::invalid_params(format!(
        "a one-shot file is at most {} MiB; send a larger one with {}",
        LEGACY_MAX_BYTES >> 20,
        crate::rpc::method::MUX_FILE_PUT_BEGIN
    ))
    .with_data(json!({"reason": "filePut.tooLarge", "maxBytes": LEGACY_MAX_BYTES}))
}

/// The refusal of file `name` when this machine's disk has `free` bytes (`filePut.noSpace`, with
/// the machine's name and the free bytes for the app's own words).
fn no_space(name: &str, free: u64) -> RpcError {
    let machine = crate::host_pressure::host_name();
    RpcError::invalid_params(format!(
        "Not enough space on {machine} for {name} ({} free)",
        human_bytes(free)
    ))
    .with_data(json!({"reason": "filePut.noSpace", "machine": machine, "freeBytes": free}))
}

/// `bytes` in decimal units, as Finder counts them: `512 MB`, `1.2 GB`.
fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 || value >= 100.0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// The free bytes of the disk that holds `path`, read at its nearest existing folder; None where
/// the platform does not say (Windows), which takes any size.
fn free_bytes(path: &Path) -> Option<u64> {
    let existing = path.ancestors().find(|dir| dir.exists())?;
    crate::server::peer_status::disk(existing).map(|(free, _)| free)
}

/// Whether a disk with `free` bytes (None: unknown) takes file `name` of `size` bytes and still
/// keeps [`DISK_RESERVE_BYTES`] free: the one bound an upload has.
fn room_for(name: &str, size: u64, free: Option<u64>) -> Result<(), RpcError> {
    match free {
        Some(free) if size > free.saturating_sub(DISK_RESERVE_BYTES) => Err(no_space(name, free)),
        _ => Ok(()),
    }
}

/// Whether `error` says the disk is full.
fn disk_full(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::StorageFull
        || error.kind() == std::io::ErrorKind::QuotaExceeded
}

fn upload_id(id: &str) -> Option<String> {
    uuid::Uuid::try_parse(id).ok().filter(|id| id.get_version_num() == 7).map(|id| id.to_string())
}

fn part_path(session: &str, upload: &str) -> Option<PathBuf> {
    Some(session_dir(session)?.join(upload_id(upload)?).join(".part"))
}

fn meta_path(session: &str, upload: &str) -> Option<PathBuf> {
    Some(session_dir(session)?.join(upload_id(upload)?).join(".meta"))
}

fn begin(session: &str, params: &Value) -> Result<Value, RpcError> {
    let name = params
        .get("fileName")
        .and_then(Value::as_str)
        .filter(|name| is_file_name(name))
        .ok_or_else(|| {
            RpcError::invalid_params("fileName must be a plain file name")
                .with_data(json!({"reason": "filePut.name"}))
        })?;
    let size = params
        .get("size")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("size is required"))?;
    let id = uuid::Uuid::now_v7().to_string();
    let path = part_path(session, &id).ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    room_for(name, size, free_bytes(&path))?;
    let parent = path.parent().ok_or_else(|| RpcError::internal("upload path has no parent"))?;
    crate::config::private_state_dir(parent).map_err(|e| RpcError::internal(e.to_string()))?;
    crate::agent_tools::write_private(&path, &[])
        .map_err(|e| RpcError::internal(format!("cannot start upload: {e}")))?;
    let meta =
        meta_path(session, &id).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let metadata = serde_json::to_vec(&json!({"fileName": name, "size": size}))
        .map_err(|e| RpcError::internal(format!("cannot encode upload metadata: {e}")))?;
    crate::agent_tools::write_private(&meta, &metadata)
        .map_err(|e| RpcError::internal(format!("cannot record upload: {e}")))?;
    Ok(json!({"uploadId": id, "fileName": name, "size": size}))
}

fn chunk(params: &Value) -> Result<Value, RpcError> {
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?;
    let session = params
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let offset = params
        .get("offset")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("offset is required"))?;
    let data = params
        .get("data")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("data (base64) is required"))?;
    if decoded_len(data) > CHUNK_BYTES {
        return Err(RpcError::invalid_params(format!(
            "a chunk is at most {} KiB",
            CHUNK_BYTES >> 10
        )));
    }
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| RpcError::invalid_params(format!("data is not base64: {e}")))?;
    let path =
        part_path(session, upload).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let meta =
        meta_path(session, upload).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let metadata = crate::config::private_state_file(&meta)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    let declared: Value = serde_json::from_reader(metadata)
        .map_err(|e| RpcError::invalid_params(format!("invalid upload metadata: {e}")))?;
    let declared_size = declared
        .get("size")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("invalid upload size"))?;
    // Never made here: a chunk that lost a race with a finish, a cancel or the sweep finds none.
    let _parts = parts_lock();
    let mut file = crate::config::private_state_existing_rw(&path)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    let current = file.metadata().map_err(|e| RpcError::internal(e.to_string()))?.len();
    if current != offset {
        return Err(RpcError::invalid_params(format!("upload offset is {current}, got {offset}")));
    }
    let next = current.saturating_add(bytes.len() as u64);
    if next > declared_size {
        return Err(RpcError::invalid_params(format!(
            "the chunk ends at {next}, past the upload's {declared_size} bytes"
        )));
    }
    file.seek(SeekFrom::End(0)).map_err(|e| RpcError::internal(e.to_string()))?;
    // Synced once, at the finish: a sync per chunk made a large file's upload wait on the disk
    // thousands of times.
    if let Err(e) = file.write_all(&bytes) {
        drop(file);
        let name = declared.get("fileName").and_then(Value::as_str).unwrap_or("the file");
        return Err(write_failed(e, "append", &path, &meta, name));
    }
    Ok(json!({"offset": next}))
}

/// The refusal for an upload whose write or sync (`what`) failed with `error`. A full disk (the
/// disk filled meanwhile: another upload, another program) deletes the unfinished upload, so its
/// space comes back, and says so (`filePut.noSpace`). The caller closes the part first.
fn write_failed(
    error: std::io::Error,
    what: &str,
    part: &Path,
    meta: &Path,
    name: &str,
) -> RpcError {
    if !disk_full(&error) {
        return RpcError::internal(format!("cannot {what} upload: {error}"));
    }
    remove_unfinished(part, meta);
    no_space(name, free_bytes(part).unwrap_or(0))
}

/// Deletes an unfinished upload's `.part` and `.meta`, then its folder when that is empty.
fn remove_unfinished(part: &Path, meta: &Path) {
    let _ = std::fs::remove_file(part);
    let _ = std::fs::remove_file(meta);
    if let Some(dir) = part.parent() {
        // `remove_dir` refuses a folder that is not empty: a finished file in it stays.
        let _ = std::fs::remove_dir(dir);
    }
}

fn finish(session: &str, params: &Value) -> Result<Value, RpcError> {
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?;
    let name = params
        .get("fileName")
        .and_then(Value::as_str)
        .filter(|name| is_file_name(name))
        .ok_or_else(|| RpcError::invalid_params("fileName must be a plain file name"))?;
    let size = params
        .get("size")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("size is required"))?;
    let part =
        part_path(session, upload).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let meta =
        meta_path(session, upload).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let metadata = crate::config::private_state_file(&meta)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    let declared: Value = serde_json::from_reader(metadata)
        .map_err(|e| RpcError::invalid_params(format!("invalid upload metadata: {e}")))?;
    if declared.get("fileName").and_then(Value::as_str) != Some(name)
        || declared.get("size").and_then(Value::as_u64) != Some(size)
    {
        return Err(RpcError::invalid_params("upload metadata does not match"));
    }
    let current = std::fs::metadata(&part)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?
        .len();
    if current != size {
        return Err(RpcError::invalid_params(format!(
            "upload has {current} bytes, expected {size}"
        )));
    }
    // On the disk before it is named: the chunks were not synced one by one. Opened to write
    // (Windows flushes only such a handle) but never made: a second finish that made an empty
    // `.part` would name it over the finished file.
    // A disk that fills shows here too: buffered writes reach it only now.
    let file = crate::config::private_state_existing_rw(&part)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    if let Err(e) = file.sync_all() {
        drop(file);
        return Err(write_failed(e, "sync", &part, &meta, name));
    }
    drop(file);
    let dir = part.parent().ok_or_else(|| RpcError::internal("upload has no folder"))?;
    let path = dir.join(name);
    {
        // The sweep may have deleted an idle part meanwhile: then there is nothing to name.
        let _parts = parts_lock();
        let len = std::fs::symlink_metadata(&part)
            .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?
            .len();
        if len != size {
            return Err(RpcError::invalid_params(format!(
                "upload has {len} bytes, expected {size}"
            )));
        }
        std::fs::rename(&part, &path)
            .map_err(|e| RpcError::internal(format!("cannot finish upload: {e}")))?;
    }
    // The name on the disk too (best effort: the file is named either way).
    #[cfg(unix)]
    let _ = std::fs::File::open(dir).and_then(|dir| dir.sync_all());
    let _ = std::fs::remove_file(meta);
    Ok(json!({"path": path.to_string_lossy()}))
}

/// The request's `fileName` and `data` (base64) when they keep the contract, before anything is
/// decoded or sent on: the daemon a request reaches first checks it, so no oversize frame goes
/// over a peer link. (Not `name`: that names a session (`server::session_key`), and a forward to
/// a peer drops it.)
pub fn check(params: &Value) -> Result<(&str, &str), RpcError> {
    let name = params
        .get("fileName")
        .and_then(Value::as_str)
        .filter(|name| is_file_name(name))
        .ok_or_else(|| {
            RpcError::invalid_params("fileName must be a plain file name")
                .with_data(json!({"reason": "filePut.name"}))
        })?;
    let data = params
        .get("data")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("data (base64) is required"))?;
    if decoded_len(data) > LEGACY_MAX_BYTES {
        return Err(too_large());
    }
    Ok((name, data))
}

/// Validates a resumable chunk before a peer forward sends its base64 frame over the link.
pub fn check_chunk(params: &Value) -> Result<(), RpcError> {
    let data = params
        .get("data")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("data (base64) is required"))?;
    if decoded_len(data) > CHUNK_BYTES {
        return Err(RpcError::invalid_params(format!(
            "a chunk is at most {} KiB",
            CHUNK_BYTES >> 10
        )));
    }
    Ok(())
}

/// The bytes padded base64 `data` decodes to, read from its length and padding with no decode,
/// so a request one byte past its bound is refused here and never sent on.
fn decoded_len(data: &str) -> usize {
    let pad = data.bytes().rev().take(2).take_while(|&b| b == b'=').count();
    (data.len() / 4 * 3).saturating_sub(pad)
}

/// `_acpmux/file_put` for one of this daemon's chats: an unknown or purged one is refused.
pub async fn handle(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || put(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))??;
    reject_purged(&session).await?;
    Ok(answer)
}

pub async fn handle_begin(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || begin(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}

pub async fn handle_chunk(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    if params.get("sessionId").and_then(Value::as_str) != Some(session.id.as_str()) {
        return Err(RpcError::invalid_params("sessionId is required"));
    }
    let answer = tokio::task::spawn_blocking(move || chunk(&params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}

pub async fn handle_finish(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || finish(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}

pub async fn handle_cancel(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || cancel(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}

/// A purge can race any blocking upload operation. Remove files created after the purge and
/// reject the late event, while keeping uploads for a chat that was brought back in place.
async fn reject_purged(session: &std::sync::Arc<super::Session>) -> Result<(), RpcError> {
    use std::sync::atomic::Ordering::SeqCst;
    if !session.purged.load(SeqCst) || session.replaced.load(SeqCst) {
        return Ok(());
    }
    let id = session.id.clone();
    let _ = tokio::task::spawn_blocking(move || remove_session(&id)).await;
    Err(RpcError::invalid_params("no such chat"))
}

/// Removes an unfinished resumable upload: its partial file and its folder. The operation is
/// idempotent so a failed client can retry cleanup without learning whether the daemon already
/// removed its partial files.
pub fn cancel(id: &str, params: &Value) -> Result<Value, RpcError> {
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .and_then(upload_id)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?;
    if let (Some(part), Some(meta)) = (part_path(id, &upload), meta_path(id, &upload)) {
        remove_unfinished(&part, &meta);
    }
    Ok(json!({}))
}

/// Writes the file of `params` for session `id` (this daemon's own) and answers `{path}`.
/// Blocking: run it off the runtime.
pub fn put(id: &str, params: &Value) -> Result<Value, RpcError> {
    use base64::Engine;
    let (name, data) = check(params)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| RpcError::invalid_params(format!("data is not base64: {e}")))?;
    let dir = session_dir(id).ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    room_for(name, bytes.len() as u64, free_bytes(&dir))?;
    let failed = |e: anyhow::Error| RpcError::internal(format!("cannot save the file: {e}"));
    crate::config::private_state_dir(&dir).map_err(failed)?;
    let path = dir.join(uuid::Uuid::now_v7().to_string()).join(name);
    crate::agent_tools::write_private(&path, &bytes).map_err(failed)?;
    Ok(json!({"path": path.to_string_lossy()}))
}

/// The refusal for a peer that does not take `_acpmux/file_put`: the app answers that the chat
/// takes no uploads.
pub fn peer_unsupported(peer: &crate::peer::Peer) -> RpcError {
    RpcError::method_not_found(&format!(
        "{} (peer {} runs acpmux build {}; run `acpmux host update {}`)",
        crate::rpc::method::MUX_FILE_PUT,
        peer.name,
        peer.remote_build().unwrap_or_else(|| "unknown".into()),
        peer.name
    ))
    .with_data(json!({"reason": "filePut.unsupported"}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_name_is_one_plain_file() {
        for good in ["state.sqlite", "a b.txt", "日本語.pdf", "x"] {
            assert!(is_file_name(good), "{good}");
        }
        let long = "a".repeat(256);
        for bad in [
            "",
            ".env",
            ".",
            "..",
            "a/b",
            "a\u{0}b",
            "a\nb",
            "a\u{7f}",
            "a\u{202e}txt",
            long.as_str(),
        ] {
            assert!(!is_file_name(bad), "{bad:?}");
        }
        // A drive prefix or a data stream on Windows, which a join would take out of the folder.
        if cfg!(windows) {
            for bad in ["C:evil.txt", "a.txt:stream", "a\\b"] {
                assert!(!is_file_name(bad), "{bad:?}");
            }
        }
    }

    #[test]
    fn a_windows_device_name_is_no_file_name_on_windows() {
        // Windows opens these as devices in any folder (`dir\CON` is the console), and drops a
        // trailing dot or space, so the write would not land in the upload's own file.
        for bad in [
            "CON",
            "con.txt",
            "NUL",
            "nul.tar.gz",
            "AUX",
            "PRN",
            "COM1",
            "lpt9.log",
            "COM\u{b9}",
            "CONIN$",
            "a.",
            "a ",
        ] {
            assert!(!is_file_name_for(bad, true), "{bad:?}");
            assert!(is_file_name_for(bad, false), "{bad:?}");
        }
        for good in
            ["CONSOLE.txt", "COM10", "COM0", "nullable.rs", "aux_data.csv", "LPT", "report.pdf"]
        {
            assert!(is_file_name_for(good, true), "{good:?}");
        }
    }

    #[test]
    fn one_byte_past_the_cap_is_refused_before_it_is_sent() {
        use base64::Engine;
        let encode = |n: usize| base64::engine::general_purpose::STANDARD.encode(vec![0u8; n]);
        for n in [0, 1, 2, 3, 4, LEGACY_MAX_BYTES] {
            assert_eq!(decoded_len(&encode(n)), n, "{n}");
        }
        for n in [LEGACY_MAX_BYTES + 1, LEGACY_MAX_BYTES + 2] {
            let params = json!({"fileName": "big.bin", "data": encode(n)});
            let err = check(&params).expect_err("past the cap");
            assert_eq!(err.data.as_ref().unwrap()["reason"], "filePut.tooLarge", "{n}");
        }
    }

    #[test]
    fn the_sweep_deletes_old_uploads_and_keeps_new_ones_and_what_it_did_not_name() {
        let root = std::env::temp_dir().join(format!("acpmux-sweep-{}", uuid::Uuid::now_v7()));
        let day = 24 * 60 * 60 * 1000;
        let now = crate::store::now_ms();
        let named = |ms: u64| {
            let at = uuid::Timestamp::from_unix(uuid::NoContext, ms / 1000, 0);
            uuid::Uuid::new_v7(at).to_string()
        };
        let old = root.join("chat-a").join(named(now - 31 * day));
        let new = root.join("chat-a").join(named(now - day));
        let only_old = root.join("chat-b").join(named(now - 40 * day));
        let other = root.join("chat-c").join("notes");
        let v4 = root.join("chat-c").join("0190a000-0000-4000-8000-000000000000");
        for dir in [&old, &new, &only_old, &other, &v4] {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(dir.join("f.txt"), b"x").unwrap();
        }
        // An old-named link, and a linked session folder: neither is followed.
        let outside = root.with_extension("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("keep.txt"), b"x").unwrap();
        let outside_old = outside.join(named(now - 90 * day));
        std::fs::create_dir_all(&outside_old).unwrap();
        #[cfg(unix)]
        {
            std::fs::create_dir_all(root.join("chat-d")).unwrap();
            std::os::unix::fs::symlink(&outside, root.join("chat-d").join(named(now - 90 * day)))
                .unwrap();
            std::os::unix::fs::symlink(&outside, root.join("chat-e")).unwrap();
        }
        assert_eq!(sweep(&root, now, Some(Duration::from_millis(30 * day))), 2);
        assert!(!old.exists() && new.exists());
        assert!(!root.join("chat-b").exists(), "an emptied session folder stays");
        assert!(other.exists() && v4.exists());
        assert!(outside.join("keep.txt").exists() && outside_old.exists());
        // Nothing past the cap is left: a second sweep deletes nothing.
        assert_eq!(sweep(&root, now, Some(Duration::from_millis(30 * day))), 0);
        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    #[test]
    fn a_file_of_any_size_goes_while_the_disk_has_room_for_it() {
        let gib = 1u64 << 30;
        // Past the old 1 GiB cap: refused only for the disk's room.
        assert!(room_for("movie.mov", 3 * gib, Some(4 * gib)).is_ok());
        assert!(room_for("movie.mov", 3 * gib, None).is_ok(), "a platform that does not say");
        let err = room_for("movie.mov", 3 * gib, Some(3 * gib)).expect_err("no room");
        let data = err.data.as_ref().unwrap();
        assert_eq!(data["reason"], "filePut.noSpace");
        assert_eq!(data["freeBytes"], 3 * gib);
        let machine = data["machine"].as_str().unwrap();
        assert_eq!(
            err.message,
            format!("Not enough space on {machine} for movie.mov (3.2 GB free)")
        );
        // What the disk keeps for the daemon's own writes.
        assert!(room_for("a.bin", gib, Some(gib + DISK_RESERVE_BYTES)).is_ok());
        assert!(room_for("a.bin", gib + 1, Some(gib + DISK_RESERVE_BYTES)).is_err());
        // Far past any disk: refused, with no overflow.
        assert!(room_for("a.bin", u64::MAX, Some(u64::MAX - 1)).is_err());
        assert!(room_for("a.bin", 1, Some(DISK_RESERVE_BYTES / 2)).is_err());
    }

    #[test]
    fn free_space_reads_in_finder_units() {
        for (bytes, text) in [
            (0, "0 bytes"),
            (999, "999 bytes"),
            (1_000, "1.0 KB"),
            (512 << 20, "537 MB"),
            (1_234_000_000, "1.2 GB"),
            (2_000_000_000_000, "2.0 TB"),
        ] {
            assert_eq!(human_bytes(bytes), text, "{bytes}");
        }
    }

    /// Sets when `path` was last written to `ms` (Unix ms).
    fn written_at(path: &Path, ms: u64) {
        let at = std::time::UNIX_EPOCH + Duration::from_millis(ms);
        std::fs::File::options().write(true).open(path).unwrap().set_modified(at).unwrap();
    }

    #[test]
    fn the_sweep_deletes_an_unfinished_upload_no_chunk_wrote_for_a_day() {
        let root = std::env::temp_dir().join(format!("acpmux-partials-{}", uuid::Uuid::now_v7()));
        let hour = 60 * 60 * 1000;
        let now = crate::store::now_ms();
        let named = |ms: u64| {
            let at = uuid::Timestamp::from_unix(uuid::NoContext, ms / 1000, 0);
            uuid::Uuid::new_v7(at).to_string()
        };
        let idle = root.join("chat").join(named(now - 30 * hour));
        // Begun more than a day ago, still streaming: its last chunk came a minute ago.
        let streaming = root.join("chat").join(named(now - 30 * hour));
        let finished = root.join("chat").join(named(now - 30 * hour));
        for (dir, file, at) in [
            (&idle, ".part", now - 25 * hour),
            (&streaming, ".part", now - 60_000),
            (&finished, "movie.mov", now - 25 * hour),
        ] {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(dir.join(file), b"x").unwrap();
            written_at(&dir.join(file), at);
        }
        std::fs::write(idle.join(".meta"), b"{}").unwrap();
        written_at(&idle.join(".meta"), now - 25 * hour);
        // With no age cap too (`uploadsMaxAgeDays` 0): a finished file stays.
        assert_eq!(sweep(&root, now, None), 1);
        assert!(!idle.exists() && streaming.join(".part").exists());
        assert!(finished.join("movie.mov").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The sweep reads an upload as idle, then a finish names its file before the sweep deletes:
    /// only the partial files go, never what the finish named.
    #[test]
    fn the_partial_sweep_never_deletes_a_file_a_finish_named() {
        let root = std::env::temp_dir().join(format!("acpmux-partials-{}", uuid::Uuid::now_v7()));
        let now = crate::store::now_ms();
        let dir = root.join("chat").join(uuid::Uuid::now_v7().to_string());
        std::fs::create_dir_all(&dir).unwrap();
        for name in [".part", "movie.mov"] {
            std::fs::write(dir.join(name), b"x").unwrap();
            written_at(&dir.join(name), now - 25 * 60 * 60 * 1000);
        }
        sweep(&root, now, None);
        assert!(!dir.join(".part").exists());
        assert_eq!(std::fs::read(dir.join("movie.mov")).unwrap(), b"x");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A disk that fills under an upload (a chunk's write, or the finish's sync, where buffered
    /// writes reach it) ends the upload: its partial file goes and the refusal says so.
    #[test]
    fn a_disk_that_fills_mid_upload_deletes_the_partial_file_and_says_so() {
        for kind in [std::io::ErrorKind::StorageFull, std::io::ErrorKind::QuotaExceeded] {
            let dir = std::env::temp_dir().join(format!("acpmux-full-{}", uuid::Uuid::now_v7()));
            std::fs::create_dir_all(&dir).unwrap();
            let (part, meta) = (dir.join(".part"), dir.join(".meta"));
            std::fs::write(&part, b"half").unwrap();
            std::fs::write(&meta, b"{}").unwrap();
            let err = write_failed(kind.into(), "sync", &part, &meta, "movie.mov");
            assert_eq!(err.data.as_ref().unwrap()["reason"], "filePut.noSpace", "{kind:?}");
            assert!(err.message.contains("movie.mov"), "{}", err.message);
            assert!(!dir.exists(), "the partial upload stayed on a full disk");
        }
        // Any other failure keeps the upload, for a retry or a cancel.
        let dir = std::env::temp_dir().join(format!("acpmux-full-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".part"), b"half").unwrap();
        let err = write_failed(
            std::io::ErrorKind::Interrupted.into(),
            "sync",
            &dir.join(".part"),
            &dir.join(".meta"),
            "a",
        );
        assert_eq!(err.code, -32603);
        assert!(dir.join(".part").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The sweep waits while a chunk or a finish holds an upload's part, and deletes an idle part
    /// only after it.
    #[test]
    fn the_sweep_waits_for_a_chunk_writing_the_part() {
        let root = std::env::temp_dir().join(format!("acpmux-partials-{}", uuid::Uuid::now_v7()));
        let now = crate::store::now_ms();
        let dir = root.join("chat").join(uuid::Uuid::now_v7().to_string());
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".part"), b"x").unwrap();
        written_at(&dir.join(".part"), now - 25 * 60 * 60 * 1000);
        let held = parts_lock();
        let sweeping = std::thread::spawn({
            let root = root.clone();
            move || sweep(&root, now, None)
        });
        std::thread::sleep(Duration::from_millis(200));
        assert!(dir.join(".part").exists(), "the sweep deleted a part a chunk held");
        drop(held);
        assert_eq!(sweeping.join().unwrap(), 1);
        assert!(!dir.exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Two finishes of one upload both pass the length check, and the first names the file: the
    /// second's sync finds no `.part` instead of making an empty one to name over the file.
    #[test]
    fn a_part_a_finish_took_is_never_made_again() {
        let dir = std::env::temp_dir().join(format!("acpmux-finish-{}", uuid::Uuid::now_v7()));
        crate::config::private_state_dir(&dir).unwrap();
        let part = dir.join(".part");
        crate::agent_tools::write_private(&part, b"whole").unwrap();
        assert!(crate::config::private_state_existing_rw(&part).is_ok());
        std::fs::rename(&part, dir.join("movie.mov")).unwrap();
        assert!(crate::config::private_state_existing_rw(&part).is_err());
        assert!(!part.exists(), "a late finish made a part to name over the finished file");
        assert_eq!(std::fs::read(dir.join("movie.mov")).unwrap(), b"whole");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_cap_leaves_the_frame_room_on_an_old_peers_link() {
        // tungstenite's default frame limit, which an older peer's listener keeps.
        let frame = 16 << 20;
        assert!(LEGACY_MAX_BYTES.div_ceil(3) * 4 + 4096 < frame);
    }
}
