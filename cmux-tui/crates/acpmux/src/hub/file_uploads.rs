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
//! [`CHUNK_BYTES`]: a file sent that way has no size cap (Leo, 2026-10-26: "I ALREADY SAID WE NEED
//! ARBITARRILY LARGE FILES OF ANY TYPE"), only the disk it is written to.
//!
//! A chat's files go when the chat is deleted (`_acpmux/kill` with purge, [`remove_session`]; not
//! when Bring Back replaces its closed copy under the same id, `transfer_in.rs`), and
//! any file goes once it is older than `uploadsMaxAgeDays` (default 30; 0 keeps them), read from
//! the UUIDv7 name of its folder ([`sweep`], at the daemon's start and every day after). A folder
//! the daemon did not name that way is never deleted.

use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// The `initialize` feature of a daemon that takes `_acpmux/file_put`.
pub const FEATURE: &str = "filePut";

pub(crate) mod web;
/// The resumable upload feature advertised by current daemons.
pub const CHUNKS_FEATURE: &str = "filePutChunks";
/// `_acpmux/file_put_status`, finish `sha256`, `upload.*` reasons and `upload.diskFull`.
pub const RESUME_FEATURE: &str = "uploadResume";
/// The largest one-shot request accepted for compatibility with older peers.
pub const LEGACY_MAX_BYTES: usize = 10 << 20;
/// The largest decoded chunk. Its base64 form stays below one MiB on the wire.
pub const CHUNK_BYTES: usize = 512 << 10;

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

/// Whether `path` is inside this daemon's uploads folder (no `..`).
pub(crate) fn is_upload(path: &Path) -> bool {
    path.starts_with(root())
        && !path.components().any(|c| matches!(c, std::path::Component::ParentDir))
}

/// Held while the sweep decides on and deletes an upload, and while a prompt marks one used and
/// checks it is there ([`touch`]): an upload in use is never deleted between the two.
pub(crate) static IN_USE: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The marker of an upload folder's last use ([`touch`]).
const USED: &str = ".used";

/// Marks the upload folder of `file` as used now, so the age sweep keeps it for another
/// `uploadsMaxAgeDays` from its last use, not its upload: a prompt that names it, or a turn that
/// starts with it. The caller holds [`IN_USE`] across this and its check that the file is there,
/// and refuses the prompt when the mark cannot be written: the sweep would not know it is in use.
/// Blocking.
pub(crate) fn touch(file: &Path) -> anyhow::Result<()> {
    let dir = file.parent().ok_or_else(|| anyhow::anyhow!("{} has no folder", file.display()))?;
    crate::agent_tools::write_private(&dir.join(USED), &[])
}

/// When upload folder `dir` was last used, in Unix ms; 0 when never: marked used ([`touch`]: a
/// prompt, a turn, a status call), or written to (its `.part`, an unfinished upload's bytes).
fn used_at(dir: &Path) -> u64 {
    let at = |name: &str| {
        let modified = std::fs::symlink_metadata(dir.join(name)).and_then(|m| m.modified());
        modified
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    };
    at(USED).max(at(".part"))
}

/// Deletes each upload under `root` older than `max_age` at `now_ms`, and a session folder it
/// leaves empty; answers how many uploads went. Only real folders with a UUIDv7 name are read as
/// uploads: a symlink, a file or another name is kept. Blocking: run it off the runtime.
pub(crate) fn sweep(root: &Path, now_ms: u64, max_age: Duration) -> usize {
    let cutoff = now_ms.saturating_sub(u64::try_from(max_age.as_millis()).unwrap_or(u64::MAX));
    let real_dirs =
        |dir: &Path| {
            std::fs::read_dir(dir).into_iter().flatten().flatten().filter(|entry| {
                entry.file_type().is_ok_and(|kind| kind.is_dir() && !kind.is_symlink())
            })
        };
    let mut removed = 0;
    for session in real_dirs(root) {
        for upload in real_dirs(&session.path()) {
            // Made and last used before the cutoff (`used_at`), decided and deleted under `IN_USE`
            // and the upload's own lock, so no write, status, finish or cancel on it runs between.
            let _held = IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let _upload = upload.file_name().to_str().map(hold);
            let old = upload.file_name().to_str().and_then(made_at).is_some_and(|at| at < cutoff)
                && used_at(&upload.path()) < cutoff;
            if old && std::fs::remove_dir_all(upload.path()).is_ok() {
                removed += 1;
            }
        }
        // Only an empty folder goes (`remove_dir` refuses any other).
        let _ = std::fs::remove_dir(session.path());
    }
    removed
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
                let Some(max_age) = hub.config.read().await.uploads_max_age() else { continue };
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

/// A one-shot `_acpmux/file_put` past [`LEGACY_MAX_BYTES`]: the resumable methods take it.
fn too_large() -> RpcError {
    RpcError::invalid_params(format!(
        "a one-shot file_put is at most {} MiB: send a larger file with file_put_begin",
        LEGACY_MAX_BYTES >> 20
    ))
    .with_data(json!({"reason": "filePut.tooLarge", "maxBytes": LEGACY_MAX_BYTES}))
}

/// A chunk past the size its upload began with.
fn past_declared(size: u64) -> RpcError {
    RpcError::invalid_params(format!("the upload began as {size} bytes"))
        .with_data(json!({"reason": "filePut.pastSize", "size": size}))
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

/// Where a finished upload `upload` of session `session` named `name` is (`finish`); None for an
/// id that is not a UUIDv7 or a name that is not a plain file name (`prompt_uploads.rs`).
pub(crate) fn finished_path(session: &str, upload: &str, name: &str) -> Option<PathBuf> {
    is_file_name(name).then_some(())?;
    Some(session_dir(session)?.join(upload_id(upload)?).join(name))
}

/// Opens a finished upload at `path` ([`finished_path`]) to read: its chat's folder and its own
/// folder are real folders (no symlink anywhere below `uploads`), and the file is this user's
/// owner-only file with no other name (one hard link), so nothing outside the uploads can be
/// read through it. `NotFound` when it is not there. Blocking.
pub(crate) fn open_finished(path: &Path) -> std::io::Result<std::fs::File> {
    for dir in path.ancestors().skip(1).take(2) {
        let meta = std::fs::symlink_metadata(dir)?;
        if !meta.is_dir() {
            return Err(std::io::Error::other(format!("{} is not a folder", dir.display())));
        }
    }
    let file = crate::config::private_state_file(path).map_err(|e| {
        match e.chain().find_map(|c| c.downcast_ref::<std::io::Error>()) {
            Some(io) if io.kind() == std::io::ErrorKind::NotFound => {
                std::io::Error::from(std::io::ErrorKind::NotFound)
            }
            _ => std::io::Error::other(e.to_string()),
        }
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if file.metadata()?.nlink() != 1 {
            return Err(std::io::Error::other(format!("{} has another name", path.display())));
        }
    }
    Ok(file)
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
    let parent = path.parent().ok_or_else(|| RpcError::internal("upload path has no parent"))?;
    crate::config::private_state_dir(parent)
        .map_err(|e| failed_anyhow("cannot start upload", parent, &e, None))?;
    // The one failure about size: the disk that would hold it has no room (Leo, 2026-10-26).
    if let Some(free) = free_bytes(parent)
        && free < size
    {
        let _ = std::fs::remove_dir(parent);
        return Err(disk_full(parent, Some(size), Some(free), None));
    }
    crate::agent_tools::write_private(&path, &[])
        .map_err(|e| failed_anyhow("cannot start upload", &path, &e, None))?;
    let meta =
        meta_path(session, &id).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let metadata = serde_json::to_vec(&json!({"fileName": name, "size": size}))
        .map_err(|e| RpcError::internal(format!("cannot encode upload metadata: {e}")))?;
    crate::agent_tools::write_private(&meta, &metadata)
        .map_err(|e| failed_anyhow("cannot record upload", &meta, &e, None))?;
    let mut answer = json!({"uploadId": id, "fileName": name, "size": size});
    // An upload for one prompt alone (`attach::blocks_for`): a token only its sender learns, which
    // the prompt's reference carries to have it deleted if the prompt is refused
    // (`prompt_uploads::owned`). A reference without it deletes nothing.
    if params.get("forPrompt") == Some(&Value::Bool(true)) {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes)
            .map_err(|e| RpcError::internal(format!("the OS random generator: {e}")))?;
        let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let owner = parent.join(OWNER);
        crate::agent_tools::write_private(&owner, token.as_bytes())
            .map_err(|e| failed_anyhow("cannot record upload", &owner, &e, None))?;
        answer.set("ownerToken", json!(token));
    }
    Ok(answer)
}

/// The file in an upload's folder that holds its owner token ([`begin`] with `forPrompt`).
const OWNER: &str = ".owner";

/// The folder of upload `upload` of session `session` when `token` is its owner token: the
/// sender that began it for one prompt alone. Blocking.
pub(crate) fn owned_dir(session: &str, upload: &str, token: &str) -> Option<PathBuf> {
    let dir = upload_dir(session, upload)?;
    let saved = std::fs::read(dir.join(OWNER)).ok()?;
    (!token.is_empty() && saved == token.as_bytes()).then_some(dir)
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
    append(session, upload, offset, &bytes)
}

/// No unfinished upload `upload` of this chat.
fn unknown(upload: &str) -> RpcError {
    RpcError::invalid_params(format!("unknown upload {upload}"))
        .with_data(json!({"reason": "upload.unknown"}))
}

/// One upload's calls (append, status, finish, cancel) run one at a time: a write and its
/// cut-back, a finish's check and rename, never interleave with another call on the same upload.
/// Striped by upload id, so the set is fixed and needs no cleanup.
fn hold(upload: &str) -> std::sync::MutexGuard<'static, ()> {
    static LOCKS: [std::sync::Mutex<()>; 64] = [const { std::sync::Mutex::new(()) }; 64];
    // By the id as its folder is named (`upload_id`), so every spelling of one id shares a lock.
    let canonical = upload_id(upload).unwrap_or_else(|| upload.to_owned());
    let stripe =
        canonical.bytes().fold(0usize, |h, b| h.wrapping_mul(31).wrapping_add(usize::from(b)));
    let [first, ..] = &LOCKS;
    LOCKS
        .get(stripe % LOCKS.len())
        .unwrap_or(first)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The declared `{fileName, size}` of unfinished upload `upload`.
fn declared(session: &str, upload: &str) -> Result<(String, u64), RpcError> {
    let meta = meta_path(session, upload).ok_or_else(|| unknown(upload))?;
    let file = crate::config::private_state_file(&meta).map_err(|_| unknown(upload))?;
    let declared: Value = serde_json::from_reader(file)
        .map_err(|e| RpcError::invalid_params(format!("invalid upload metadata: {e}")))?;
    let name = declared.get("fileName").and_then(Value::as_str).map(str::to_owned);
    let size = declared.get("size").and_then(Value::as_u64);
    name.zip(size).ok_or_else(|| RpcError::invalid_params("invalid upload metadata"))
}

/// Appends `bytes` at `offset`, which must be the upload's current end, and answers the new end
/// once the bytes are on disk: a base64 chunk's and a binary data frame's write
/// (`server/upload_frames.rs`). Blocking: run it off the runtime.
pub(crate) fn append(
    session: &str,
    upload: &str,
    offset: u64,
    bytes: &[u8],
) -> Result<Value, RpcError> {
    let _held = hold(upload);
    let (_, size) = declared(session, upload)?;
    let path = part_path(session, upload).ok_or_else(|| unknown(upload))?;
    let mut file = crate::config::private_state_rw(&path).map_err(|_| unknown(upload))?;
    let current = file.metadata().map_err(|e| RpcError::internal(e.to_string()))?.len();
    if current != offset {
        return Err(RpcError::invalid_params(format!("upload offset is {current}, got {offset}"))
            .with_data(json!({"reason": "upload.offset", "offset": current})));
    }
    let next = current.saturating_add(bytes.len() as u64);
    if next > size {
        return Err(past_declared(size));
    }
    let write = |file: &mut std::fs::File| -> std::io::Result<()> {
        file.seek(SeekFrom::End(0))?;
        file.write_all(bytes)?;
        file.sync_data()
    };
    if let Err(e) = write(&mut file) {
        // A short write leaves the file past `current`: cut it back, so the sender resumes there.
        let _ = file.set_len(current);
        return Err(failed("cannot append upload", &path, &e, Some(current)));
    }
    Ok(json!({"offset": next}))
}

/// `_acpmux/file_put_status`: where an upload stands, so a sender resumes after a disconnect or
/// a restart. `{uploadId, fileName, size, offset, finished, path?}`. Blocking.
fn status(session: &str, params: &Value) -> Result<Value, RpcError> {
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?;
    // A sender asking where an upload stands is using it, finished or not: marked used under
    // the sweep's lock (`IN_USE`, then the upload's, the order the sweep takes them), so the
    // sweep never deletes one it just answered for.
    let _in_use = IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let _held = hold(upload);
    let dir = part_path(session, upload)
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .ok_or_else(|| unknown(upload))?;
    let mark = |file: &Path| {
        touch(file).map_err(|e| {
            RpcError::internal(format!("cannot mark upload {upload} in use: {e}"))
                .with_data(json!({"reason": "upload.unreadable"}))
        })
    };
    // Unfinished: its `.part`. A finish that renamed it and stopped before removing `.meta`
    // (a crash) left the finished file, which the scan below finds.
    if let Ok((name, size)) = declared(session, upload)
        && let Ok(part) = std::fs::symlink_metadata(dir.join(".part"))
    {
        mark(&dir.join(".part"))?;
        return Ok(json!({"uploadId": upload, "fileName": name, "size": size,
            "offset": part.len(), "finished": false}));
    }
    // A finished upload's folder holds its one file (`finish`).
    for entry in std::fs::read_dir(&dir).map_err(|_| unknown(upload))?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let meta = std::fs::symlink_metadata(entry.path());
        if let Ok(meta) = meta
            && meta.is_file()
            && is_file_name(&name)
        {
            mark(&entry.path())?;
            return Ok(json!({"uploadId": upload, "fileName": name, "size": meta.len(),
                "offset": meta.len(), "finished": true,
                "path": entry.path().to_string_lossy()}));
        }
    }
    Err(unknown(upload))
}

/// Lowercase hex SHA-256 of the file at `path`, read 1 MiB at a time.
fn sha256_of(path: &Path) -> std::io::Result<String> {
    use sha2::Digest;
    use std::io::Read;
    let mut file = crate::config::private_state_file(path).map_err(std::io::Error::other)?;
    let mut hash = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(buf.get(..n).unwrap_or_default());
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Whether `e` says the disk (or the owner's quota) is full.
pub(crate) fn is_disk_full(e: &std::io::Error) -> bool {
    #[cfg(unix)]
    let full = [libc::ENOSPC, libc::EDQUOT];
    // ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL.
    #[cfg(windows)]
    let full = [39, 112];
    #[cfg(not(any(unix, windows)))]
    let full: [i32; 0] = [];
    e.raw_os_error().is_some_and(|code| full.contains(&code))
}

/// `upload.diskFull`: the one size failure, naming this host and the path that had no room.
pub(crate) fn disk_full(
    path: &Path,
    needed: Option<u64>,
    free: Option<u64>,
    offset: Option<u64>,
) -> RpcError {
    let host = crate::host_pressure::host_name();
    RpcError::new(-32000, format!("the disk on {host} is full at {}", path.display())).with_data(
        json!({"reason": "upload.diskFull", "host": host, "path": path.to_string_lossy(),
            "needed": needed, "free": free, "offset": offset, "retryable": false}),
    )
}

/// An I/O failure writing `path`: `upload.diskFull` when the disk is full.
fn failed(what: &str, path: &Path, e: &std::io::Error, offset: Option<u64>) -> RpcError {
    if is_disk_full(e) {
        disk_full(path, None, None, offset)
    } else {
        RpcError::internal(format!("{what}: {e}"))
    }
}

fn failed_anyhow(what: &str, path: &Path, e: &anyhow::Error, offset: Option<u64>) -> RpcError {
    match e.chain().find_map(|cause| cause.downcast_ref::<std::io::Error>()) {
        Some(io) => failed(what, path, io, offset),
        None => RpcError::internal(format!("{what}: {e}")),
    }
}

/// Bytes free to this user on the file system of `dir`; None where unknown.
#[cfg(unix)]
fn free_bytes(dir: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    // SAFETY: a NUL-terminated path and a zeroed struct statvfs fills.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    #[allow(clippy::useless_conversion)]
    (rc == 0).then(|| u64::from(st.f_bavail).saturating_mul(u64::from(st.f_frsize)))
}

#[cfg(not(unix))]
fn free_bytes(_dir: &Path) -> Option<u64> {
    None
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
    let want = match params.get("sha256") {
        None | Some(Value::Null) => None,
        Some(Value::String(h))
            if h.len() == 64 && h.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) =>
        {
            Some(h.as_str())
        }
        Some(_) => return Err(RpcError::invalid_params("sha256 is 64 lowercase hex digits")),
    };
    let _held = hold(upload);
    let part = part_path(session, upload).ok_or_else(|| unknown(upload))?;
    let meta = meta_path(session, upload).ok_or_else(|| unknown(upload))?;
    let dir = part.parent().ok_or_else(|| RpcError::internal("upload has no folder"))?;
    let path = dir.join(name);
    let done = || std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file() && m.len() == size);
    // Finished already: a finish whose answer was lost is answered again, its `sha256` checked
    // against the file's bytes.
    let again = || -> Result<Value, RpcError> {
        if let Some(want) = want {
            let got =
                sha256_of(&path).map_err(|e| failed("cannot read upload", &path, &e, None))?;
            if got != want {
                return Err(RpcError::invalid_params("the upload's sha256 does not match")
                    .with_data(json!({"reason": "upload.corrupt", "sha256": got})));
            }
        }
        Ok(finished(&path, size, upload))
    };
    let declared = match declared(session, upload) {
        Ok(declared) => declared,
        Err(e) => return if done() { again() } else { Err(e) },
    };
    if declared.0 != name || declared.1 != size {
        return Err(RpcError::invalid_params("upload metadata does not match"));
    }
    let current = match std::fs::metadata(&part) {
        Ok(m) => m.len(),
        // Renamed by a finish that stopped before removing `.meta` (a crash): finished.
        Err(_) if done() => {
            let answer = again()?;
            let _ = std::fs::remove_file(&meta);
            return Ok(answer);
        }
        Err(_) => return Err(unknown(upload)),
    };
    if current != size {
        return Err(RpcError::invalid_params(format!(
            "upload has {current} bytes, expected {size}"
        ))
        .with_data(json!({"reason": "upload.incomplete", "offset": current})));
    }
    if let Some(want) = want {
        let got = sha256_of(&part).map_err(|e| failed("cannot read upload", &part, &e, None))?;
        if got != want {
            // The bytes are not the sender's: it begins again.
            let _ = std::fs::remove_file(&part);
            let _ = std::fs::remove_file(&meta);
            return Err(RpcError::invalid_params("the upload's sha256 does not match")
                .with_data(json!({"reason": "upload.corrupt", "sha256": got})));
        }
    }
    std::fs::rename(&part, &path).map_err(|e| failed("cannot finish upload", &path, &e, None))?;
    let _ = std::fs::remove_file(meta);
    Ok(finished(&path, size, upload))
}

/// A finish's answer: the finished file's path and byte count, and the upload it was, all a
/// sender needs to call it finished (`docs/prompt-uploads.md` section 1b).
fn finished(path: &Path, size: u64, upload: &str) -> Value {
    let id = upload_id(upload).unwrap_or_else(|| upload.to_owned());
    json!({"path": path.to_string_lossy(), "size": size, "uploadId": id})
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
/// so a one-shot file one byte past [`LEGACY_MAX_BYTES`] is refused here and never sent on.
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

pub async fn handle_status(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || status(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    reject_purged(&session).await?;
    answer
}

/// One binary data frame's bytes for this daemon's chat `session` (`server/upload_frames.rs`).
pub async fn handle_data(
    session: Arc<super::Session>,
    upload: String,
    offset: u64,
    bytes: impl AsRef<[u8]> + Send + 'static,
) -> Result<Value, RpcError> {
    let id = session.id.clone();
    let answer = tokio::task::spawn_blocking(move || append(&id, &upload, offset, bytes.as_ref()))
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

/// Removes an unfinished resumable upload. The operation is idempotent so a failed client can
/// retry cleanup without learning whether the daemon already removed its partial files.
pub fn cancel(id: &str, params: &Value) -> Result<Value, RpcError> {
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .and_then(upload_id)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?;
    let token = params.get("ownerToken").and_then(Value::as_str).unwrap_or_default();
    // Under the sweep's lock, so a prompt reading it at that moment never sees it half gone.
    let _in_use = IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let _held = hold(&upload);
    let Some(dir) = upload_dir(id, &upload) else { return Ok(json!({})) };
    // An upload begun for a prompt goes whole, finished or not, only with its owner token (a
    // sender that will not send the prompt naming it): nobody else's cancel deletes it. Any
    // other upload's cancel deletes it while it is unfinished, as before.
    let owner = dir.join(OWNER);
    let goes = if owner.exists() {
        owned_dir(id, &upload, token).is_some()
    } else {
        dir.join(".part").exists()
    };
    if goes {
        let _ = std::fs::remove_dir_all(&dir);
    }
    Ok(json!({}))
}

/// Deletes upload folders `dirs` (each an [`upload_dir`]) under the sweep's lock and then each
/// upload's own, the order the sweep and `cancel` take them, so a prompt reading one at that
/// moment never sees it half gone and no write, status, finish or cancel on it runs between.
/// Blocking.
pub(crate) fn remove_uploads(dirs: &[PathBuf]) {
    let _in_use = IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    for dir in dirs {
        let _held = dir.file_name().and_then(|n| n.to_str()).map(hold);
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The folder of upload `upload` of session `session`; None for an id that is not a UUIDv7.
pub(crate) fn upload_dir(session: &str, upload: &str) -> Option<PathBuf> {
    Some(session_dir(session)?.join(upload_id(upload)?))
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
        // An old upload that a prompt used just now stays.
        let used = root.join("chat-a").join(named(now - 35 * day));
        for dir in [&old, &new, &only_old, &other, &v4, &used] {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(dir.join("f.txt"), b"x").unwrap();
        }
        touch(&used.join("f.txt")).unwrap();
        // An old upload still being written (its `.part` just now) stays.
        let writing = root.join("chat-a").join(named(now - 45 * day));
        std::fs::create_dir_all(&writing).unwrap();
        std::fs::write(writing.join(".part"), b"x").unwrap();
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
        assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 2);
        assert!(!old.exists() && new.exists() && used.exists() && writing.exists());
        assert!(!root.join("chat-b").exists(), "an emptied session folder stays");
        assert!(other.exists() && v4.exists());
        assert!(outside.join("keep.txt").exists() && outside_old.exists());
        // Nothing past the cap is left: a second sweep deletes nothing.
        assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 0);
        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn a_full_disk_is_the_one_size_failure_and_names_the_host_and_path() {
        let e = std::io::Error::from_raw_os_error(libc::ENOSPC);
        let err = failed("cannot append upload", Path::new("/x/.part"), &e, Some(7));
        let data = err.data.unwrap();
        assert_eq!(data["reason"], "upload.diskFull");
        assert_eq!(data["path"], "/x/.part");
        assert_eq!(data["offset"], 7);
        assert_eq!(data["host"], crate::host_pressure::host_name());
        let other = failed("x", Path::new("/x"), &std::io::Error::other("no"), None);
        assert!(other.data.is_none());
    }

    #[test]
    fn the_cap_leaves_the_frame_room_on_an_old_peers_link() {
        // tungstenite's default frame limit, which an older peer's listener keeps.
        let frame = 16 << 20;
        assert!(LEGACY_MAX_BYTES.div_ceil(3) * 4 + 4096 < frame);
    }
}
