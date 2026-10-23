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
//! [`CHUNK_BYTES`], and may send a larger file up to [`MAX_BYTES`].
//!
//! A chat's files go when the chat is deleted (`_acpmux/kill` with purge, [`remove_session`]; not
//! when Bring Back replaces its closed copy under the same id, `transfer_in.rs`), and
//! any file goes once it is older than `uploadsMaxAgeDays` (default 30; 0 keeps them), read from
//! the UUIDv7 name of its folder ([`sweep`], at the daemon's start and every day after). A folder
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
/// The largest file a local or peer upload may hold.
pub const MAX_BYTES: usize = 1 << 30;
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
            let old = upload.file_name().to_str().and_then(made_at).is_some_and(|at| at < cutoff);
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

fn too_large() -> RpcError {
    RpcError::invalid_params(format!("a file is at most {} MiB", MAX_BYTES >> 20))
        .with_data(json!({"reason": "filePut.tooLarge", "maxBytes": MAX_BYTES}))
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
    if size > MAX_BYTES as u64 {
        return Err(too_large());
    }
    let id = uuid::Uuid::now_v7().to_string();
    let path = part_path(session, &id).ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    crate::config::private_state_dir(path.parent().unwrap())
        .map_err(|e| RpcError::internal(e.to_string()))?;
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
    let meta = meta_path(session, upload).ok_or_else(|| RpcError::invalid_params("invalid uploadId"))?;
    let metadata = crate::config::private_state_file(&meta)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    let declared: Value = serde_json::from_reader(metadata)
        .map_err(|e| RpcError::invalid_params(format!("invalid upload metadata: {e}")))?;
    let declared_size = declared
        .get("size")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("invalid upload size"))?;
    let mut file = crate::config::private_state_rw(&path)
        .map_err(|e| RpcError::invalid_params(format!("unknown upload: {e}")))?;
    let current = file.metadata().map_err(|e| RpcError::internal(e.to_string()))?.len();
    if current != offset {
        return Err(RpcError::invalid_params(format!("upload offset is {current}, got {offset}")));
    }
    let next = current.saturating_add(bytes.len() as u64);
    if next > declared_size || next > MAX_BYTES as u64 {
        return Err(too_large());
    }
    file.seek(SeekFrom::End(0)).map_err(|e| RpcError::internal(e.to_string()))?;
    file.write_all(&bytes).map_err(|e| RpcError::internal(format!("cannot append upload: {e}")))?;
    file.sync_data().map_err(|e| RpcError::internal(format!("cannot sync upload: {e}")))?;
    Ok(json!({"offset": next}))
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
    if size > MAX_BYTES as u64 {
        return Err(too_large());
    }
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
    let dir = part.parent().ok_or_else(|| RpcError::internal("upload has no folder"))?;
    let path = dir.join(name);
    std::fs::rename(&part, &path)
        .map_err(|e| RpcError::internal(format!("cannot finish upload: {e}")))?;
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

/// The bytes padded base64 `data` decodes to, read from its length and padding with no decode,
/// so a file one byte past [`MAX_BYTES`] is refused here and never sent on.
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
    // A purge while the file was written may have deleted the folder before it: the file goes too,
    // unless the chat came back under this id and keeps its folder.
    use std::sync::atomic::Ordering::SeqCst;
    if session.purged.load(SeqCst) && !session.replaced.load(SeqCst) {
        let id = session.id.clone();
        let _ = tokio::task::spawn_blocking(move || remove_session(&id)).await;
        return Err(RpcError::invalid_params("no such chat"));
    }
    Ok(answer)
}

pub async fn handle_begin(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    tokio::task::spawn_blocking(move || begin(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
}

pub async fn handle_chunk(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    if params.get("sessionId").and_then(Value::as_str) != Some(session.id.as_str()) {
        return Err(RpcError::invalid_params("sessionId is required"));
    }
    tokio::task::spawn_blocking(move || chunk(&params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
}

pub async fn handle_finish(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(&params)?)?;
    let id = session.id.clone();
    tokio::task::spawn_blocking(move || finish(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
}

/// Writes the file of `params` for session `id` (this daemon's own) and answers `{path}`.
/// Blocking: run it off the runtime.
pub fn put(id: &str, params: &Value) -> Result<Value, RpcError> {
    use base64::Engine;
    let (name, data) = check(params)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| RpcError::invalid_params(format!("data is not base64: {e}")))?;
    if bytes.len() > MAX_BYTES {
        return Err(too_large());
    }
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
        assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 2);
        assert!(!old.exists() && new.exists());
        assert!(!root.join("chat-b").exists(), "an emptied session folder stays");
        assert!(other.exists() && v4.exists());
        assert!(outside.join("keep.txt").exists() && outside_old.exists());
        // Nothing past the cap is left: a second sweep deletes nothing.
        assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 0);
        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    #[test]
    fn the_cap_leaves_the_frame_room_on_an_old_peers_link() {
        // tungstenite's default frame limit, which an older peer's listener keeps.
        let frame = 16 << 20;
        assert!(LEGACY_MAX_BYTES.div_ceil(3) * 4 + 4096 < frame);
    }
}
