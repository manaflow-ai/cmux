//! Managed enrollment v2 session-journal forwarder.
//!
//! The forwarder is deliberately independent from the relay WebSocket. It
//! tails cmux-tui JSON-lines resource sockets and POSTs the original
//! `stream_item` envelopes to the origin-bound endpoint in the enrollment
//! file. Every queue and batch has a limit; network failures keep one bounded
//! batch for retry and never take down the relay session.

use std::collections::HashMap;
#[cfg(unix)]
use std::collections::HashSet;
#[cfg(unix)]
use std::collections::VecDeque;
use std::future::Future;
#[cfg(unix)]
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
#[cfg(unix)]
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::Arc;
#[cfg(unix)]
use std::sync::Mutex;
#[cfg(unix)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use tokio::io::AsyncBufReadExt;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use crate::config::ManagedEvents;

pub const JOURNAL_KIND_FILTERS: [&str; 2] = ["agent.*", "plugin.chatmux.*"];
pub const MAX_BATCH_RECORDS: usize = 100;
pub const MAX_BATCH_BODY_BYTES: usize = 4 * 1024 * 1024;
const MAX_JOURNAL_LINE_BYTES: usize = 1 << 20;
const DEFAULT_FLUSH_DEBOUNCE: Duration = Duration::from_millis(500);
const DEFAULT_MIN_BACKOFF: Duration = Duration::from_secs(1);
const DEFAULT_MAX_BACKOFF: Duration = Duration::from_secs(60);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const IDENTITY_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);
const DEFAULT_RECONNECT_MIN: Duration = Duration::from_secs(1);
const DEFAULT_RECONNECT_MAX: Duration = Duration::from_secs(30);
const SOCKET_SCAN_INTERVAL: Duration = Duration::from_secs(15);
const MAX_DISCOVERED_SESSIONS: usize = 128;
const MAX_SOCKET_ENTRIES_PER_ROOT: usize = 512;
const SUBSCRIBE_REQUEST_ID: &str = "chatmux-journal-subscribe";
const PROTOCOL: &str = "cmux.protocol/2";
const DEFAULT_CURSOR_PATH: &str = "/tmp/.chatmux-relay-cursors.json";
// Control prefix: it cannot pass core session-name validation and is never
// serialized as `sessionName`. It is only a local cursor/task key for hashed
// socket filenames whose original name is not recoverable.
const OPAQUE_SESSION_PREFIX: &str = "\u{001f}opaque:";
#[cfg(unix)]
const MAX_CURSOR_FILE_BYTES: usize = 1 << 20;
#[cfg(unix)]
const CURSOR_TEMP_ATTEMPTS: usize = 8;

#[cfg(unix)]
static NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct JournalCursor {
    pub generation: String,
    pub revision: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PendingSession {
    pub session_name: String,
    pub generation: Option<String>,
    pub records: Vec<Value>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionBatch {
    pub session_id: String,
    #[serde(rename = "sessionName", skip_serializing_if = "is_opaque_session_key")]
    pub session_name: String,
    pub records: Vec<Value>,
    pub cursor: JournalCursor,
}

#[derive(Debug, Deserialize)]
struct AckBody {
    #[serde(default)]
    cursors: HashMap<String, JournalCursor>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DeliveryDisposition {
    Ack,
    Drop,
    Stop,
    Split,
    Retry,
}

fn delivery_disposition(status: u16, record_count: usize) -> DeliveryDisposition {
    if (200..300).contains(&status) {
        DeliveryDisposition::Ack
    } else if status == 410 {
        DeliveryDisposition::Stop
    } else if status == 413 && record_count > 1 {
        DeliveryDisposition::Split
    } else if status == 413 {
        DeliveryDisposition::Drop
    } else {
        DeliveryDisposition::Retry
    }
}

fn batch_body_bytes(sessions: &[SessionBatch]) -> usize {
    serde_json::to_vec(&json!({ "sessions": sessions })).map_or(usize::MAX, |body| body.len())
}

/// One JSONL line to one usable envelope. Torn, empty, and non-object lines
/// are ignored exactly as the Node relay does.
pub fn parse_journal_line(line: &str) -> Option<Value> {
    if line.trim().is_empty() || line.len() > MAX_JOURNAL_LINE_BYTES {
        return None;
    }
    let value = serde_json::from_str::<Value>(line).ok()?;
    (value.is_object() && value.get("type").and_then(Value::as_str).is_some()).then_some(value)
}

#[cfg(unix)]
async fn read_bounded_line<R>(reader: &mut R, max_bytes: usize) -> std::io::Result<Option<String>>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            return if bytes.is_empty() {
                Ok(None)
            } else {
                String::from_utf8(bytes).map(Some).map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "journal line is not UTF-8",
                    )
                })
            };
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(buffer.len(), |index| index + 1);
        if bytes.len().saturating_add(take) > max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "journal line exceeds the configured bound",
            ));
        }
        bytes.extend_from_slice(&buffer[..take]);
        reader.consume(take);
        if newline.is_some() {
            return String::from_utf8(bytes).map(Some).map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, "journal line is not UTF-8")
            });
        }
    }
}

fn cursor_from_record(record: &Value, generation: Option<&str>) -> Option<JournalCursor> {
    if let Some(cursor) = record.get("cursor").and_then(Value::as_object) {
        let generation = cursor.get("generation").and_then(Value::as_str)?;
        let revision = cursor.get("revision").and_then(Value::as_str)?;
        if !generation.is_empty() && !revision.is_empty() {
            return Some(JournalCursor {
                generation: generation.to_owned(),
                revision: revision.to_owned(),
            });
        }
    }
    let generation = generation.filter(|generation| !generation.is_empty())?;
    let revision = record.get("sequence").and_then(Value::as_str)?;
    (!revision.is_empty())
        .then(|| JournalCursor { generation: generation.to_owned(), revision: revision.to_owned() })
}

/// Convert pending per-session records into bounded POST sessions. A session
/// without a cursor is skipped because the server cannot safely acknowledge it.
pub fn batch_records(pending: &[PendingSession]) -> Vec<SessionBatch> {
    pending
        .iter()
        .filter(|entry| !entry.records.is_empty())
        .filter_map(|entry| {
            let cursor = entry
                .records
                .iter()
                .rev()
                .find_map(|record| cursor_from_record(record, entry.generation.as_deref()))?;
            Some(SessionBatch {
                session_id: cursor.generation.clone(),
                session_name: entry.session_name.clone(),
                records: entry.records.clone(),
                cursor,
            })
        })
        .collect()
}

/// Split a 413 response at the record midpoint, preserving session grouping
/// and recomputing a cursor for a session split across the two halves.
pub fn split_batch(sessions: &[SessionBatch]) -> Option<(Vec<SessionBatch>, Vec<SessionBatch>)> {
    let total = sessions.iter().map(|session| session.records.len()).sum::<usize>();
    if total <= 1 {
        return None;
    }
    let first_count = total.div_ceil(2);
    let mut first = Vec::new();
    let mut second = Vec::new();
    let mut taken = 0;
    for session in sessions {
        let room = first_count.saturating_sub(taken);
        if room >= session.records.len() {
            first.push(session.clone());
            taken += session.records.len();
        } else if room > 0 {
            let head = session.records[..room].to_vec();
            let tail = session.records[room..].to_vec();
            let cursor = head
                .iter()
                .rev()
                .find_map(|record| cursor_from_record(record, Some(&session.session_id)));
            if let Some(cursor) = cursor {
                first.push(SessionBatch {
                    session_id: session.session_id.clone(),
                    session_name: session.session_name.clone(),
                    records: head,
                    cursor,
                });
            }
            second.push(SessionBatch { records: tail, ..session.clone() });
            taken += room;
        } else {
            second.push(session.clone());
        }
    }
    Some((first, second))
}

/// Fold only server-returned cursors into the name-keyed local map.
pub fn advance_cursors(
    cursors: &HashMap<String, JournalCursor>,
    sessions: &[SessionBatch],
    acked: &HashMap<String, JournalCursor>,
) -> HashMap<String, JournalCursor> {
    let mut next = cursors.clone();
    for session in sessions {
        if let Some(cursor) = acked.get(&session.session_id).filter(|cursor| valid_cursor(cursor)) {
            next.insert(session.session_name.clone(), cursor.clone());
        }
    }
    next
}

fn valid_cursor(cursor: &JournalCursor) -> bool {
    !cursor.generation.is_empty() && !cursor.revision.is_empty()
}

/// Start a fire-and-forget forwarder owned by the caller's cancellation token.
pub fn start(events: ManagedEvents, cancellation: CancellationToken) -> JoinHandle<()> {
    tokio::spawn(async move {
        run(events, cancellation).await;
    })
}

#[cfg(not(unix))]
async fn run(_events: ManagedEvents, cancellation: CancellationToken) {
    // cmux-tui resource sockets are Unix-domain sockets. Managed enrollment
    // remains valid on other platforms, but forwarding is not available.
    cancellation.cancelled().await;
}

#[cfg(unix)]
#[derive(Clone)]
struct Shared {
    events: ManagedEvents,
    client: reqwest::Client,
    cursors: Arc<tokio::sync::Mutex<HashMap<String, JournalCursor>>>,
    cursor_path: PathBuf,
    cancellation: CancellationToken,
    claims: Arc<Mutex<HashSet<String>>>,
}

#[cfg(unix)]
async fn run(events: ManagedEvents, cancellation: CancellationToken) {
    let cursors = load_cursor_file(Path::new(DEFAULT_CURSOR_PATH)).await;
    let client = match build_http_client(DEFAULT_REQUEST_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("chatmux-relay: journal forwarder HTTP client failed: {error}");
            return;
        }
    };
    let shared = Shared {
        events,
        client,
        cursors: Arc::new(tokio::sync::Mutex::new(cursors)),
        cursor_path: PathBuf::from(DEFAULT_CURSOR_PATH),
        cancellation: cancellation.clone(),
        claims: Arc::new(Mutex::new(HashSet::new())),
    };
    let socket_dirs = socket_directories();
    let mut tasks: HashMap<String, JoinHandle<()>> = HashMap::new();
    let mut scan = tokio::time::interval(SOCKET_SCAN_INTERVAL);
    scan.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    discover_sessions(&shared, &socket_dirs, &mut tasks).await;
    loop {
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => break,
            _ = scan.tick() => discover_sessions(&shared, &socket_dirs, &mut tasks).await,
        }
    }
    for (_, task) in tasks {
        task.abort();
    }
}

fn build_http_client(timeout: Duration) -> Result<reqwest::Client, reqwest::Error> {
    reqwest::Client::builder().timeout(timeout).build()
}

#[cfg(unix)]
async fn discover_sessions(
    shared: &Shared,
    socket_dirs: &[PathBuf],
    tasks: &mut HashMap<String, JoinHandle<()>>,
) {
    tasks.retain(|_, task| !task.is_finished());
    let sessions = discover_session_candidates(socket_dirs).await;
    for candidate in sessions {
        if tasks.contains_key(&candidate.key) {
            continue;
        }
        // Include every resolver directory even when only one currently has
        // the socket. A session can move from the preferred directory to a
        // fallback after startup, and one worker can fail over without a
        // duplicate subscription race.
        let key = candidate.key.clone();
        let session_name = candidate.session_name.clone();
        let paths = candidate.socket_paths;
        let worker = shared.clone();
        tasks.insert(
            key,
            tokio::spawn(async move {
                run_session(worker, session_name, candidate.key, paths).await;
            }),
        );
    }
}

#[cfg(unix)]
#[derive(Clone, Debug, PartialEq, Eq)]
struct SessionCandidate {
    key: String,
    session_name: Option<String>,
    socket_paths: Vec<PathBuf>,
}

#[cfg(unix)]
async fn discover_session_candidates(socket_dirs: &[PathBuf]) -> Vec<SessionCandidate> {
    let mut candidates = HashMap::<String, SessionCandidate>::new();
    let mut safe_socket_dirs = Vec::new();
    for socket_dir in socket_dirs {
        if !safe_socket_directory(socket_dir).await {
            continue;
        }
        safe_socket_dirs.push(socket_dir.clone());
        let Ok(mut entries) = tokio::fs::read_dir(socket_dir).await else { continue };
        let mut entries_seen = 0;
        while entries_seen < MAX_SOCKET_ENTRIES_PER_ROOT {
            let Ok(Some(entry)) = entries.next_entry().await else { break };
            entries_seen += 1;
            let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else { continue };
            let Some(session_name) = file_name.strip_suffix(".sock") else { continue };
            let Ok(metadata) = tokio::fs::symlink_metadata(entry.path()).await else { continue };
            // Do not follow an attacker-controlled symlink and do not connect
            // to arbitrary files masquerading as sockets.
            if metadata.file_type().is_symlink()
                || !metadata.file_type().is_socket()
                || metadata.uid() != unsafe { libc::getuid() }
            {
                continue;
            }
            let (key, display_name, hashed_root) = if is_hashed_socket_directory(socket_dir) {
                if !valid_hashed_socket_stem(session_name) {
                    continue;
                }
                (opaque_session_key(session_name), None, true)
            } else {
                if !valid_session_name(session_name) {
                    continue;
                }
                (session_name.to_owned(), Some(session_name.to_owned()), false)
            };
            if !candidates.contains_key(&key) && candidates.len() >= MAX_DISCOVERED_SESSIONS {
                continue;
            }
            let candidate = candidates.entry(key.clone()).or_insert_with(|| SessionCandidate {
                key,
                session_name: display_name.clone(),
                socket_paths: Vec::new(),
            });
            if candidate.session_name.is_none() && !hashed_root {
                candidate.session_name = display_name;
            }
            let path = entry.path();
            if !candidate.socket_paths.contains(&path) {
                candidate.socket_paths.push(path);
            }
        }
    }
    // A normal name can be found in either normal resolver root. Include both
    // paths so a daemon that moves between preferred and fallback roots keeps
    // one worker. Hashed stems are opaque and are restricted to hashed roots.
    let normal_dirs = safe_socket_dirs.iter().filter(|dir| !is_hashed_socket_directory(dir));
    let hashed_dirs = safe_socket_dirs.iter().filter(|dir| is_hashed_socket_directory(dir));
    for candidate in candidates.values_mut() {
        if candidate.session_name.is_some() {
            for dir in normal_dirs.clone() {
                let stem = candidate
                    .session_name
                    .as_deref()
                    .or_else(|| candidate.key.strip_prefix(OPAQUE_SESSION_PREFIX))
                    .unwrap_or_default();
                let path = dir.join(format!("{stem}.sock"));
                if !candidate.socket_paths.contains(&path) {
                    candidate.socket_paths.push(path);
                }
            }
        } else {
            for dir in hashed_dirs.clone() {
                let stem = candidate
                    .session_name
                    .as_deref()
                    .or_else(|| candidate.key.strip_prefix(OPAQUE_SESSION_PREFIX))
                    .unwrap_or_default();
                let path = dir.join(format!("{stem}.sock"));
                if !candidate.socket_paths.contains(&path) {
                    candidate.socket_paths.push(path);
                }
            }
        }
    }
    candidates.into_values().collect()
}

#[cfg(all(unix, test))]
async fn discover_session_names(socket_dirs: &[PathBuf]) -> HashSet<String> {
    discover_session_candidates(socket_dirs)
        .await
        .into_iter()
        .map(|candidate| candidate.session_name.unwrap_or(candidate.key))
        .collect()
}

#[cfg(unix)]
async fn safe_socket_directory(path: &Path) -> bool {
    let Ok(metadata) = tokio::fs::symlink_metadata(path).await else { return false };
    !metadata.file_type().is_symlink()
        && metadata.is_dir()
        && metadata.uid() == unsafe { libc::getuid() }
        && metadata.permissions().mode() & 0o077 == 0
}

#[cfg(unix)]
async fn safe_socket_entry(path: &Path) -> bool {
    let Some(parent) = path.parent() else { return false };
    if !safe_socket_directory(parent).await {
        return false;
    }
    let Ok(metadata) = tokio::fs::symlink_metadata(path).await else { return false };
    !metadata.file_type().is_symlink()
        && metadata.file_type().is_socket()
        && metadata.uid() == unsafe { libc::getuid() }
}

#[cfg(unix)]
fn is_hashed_socket_directory(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("cmux-tui-hashed-"))
}

#[cfg(unix)]
fn valid_hashed_socket_stem(name: &str) -> bool {
    name.len() == 64
        && name.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

#[cfg(unix)]
fn opaque_session_key(stem: &str) -> String {
    format!("{OPAQUE_SESSION_PREFIX}{stem}")
}

fn is_opaque_session_key(name: &str) -> bool {
    name.starts_with(OPAQUE_SESSION_PREFIX)
}

#[cfg(unix)]
fn valid_session_key(name: &str) -> bool {
    valid_session_name(name)
        || (name.strip_prefix(OPAQUE_SESSION_PREFIX).is_some_and(valid_hashed_socket_stem))
}

#[cfg(unix)]
fn parse_session_identity(response: &str) -> Option<String> {
    let envelope = parse_journal_line(response.trim_end_matches(['\r', '\n']))?;
    if envelope.get("protocol").and_then(Value::as_str) != Some(PROTOCOL)
        || envelope.get("type").and_then(Value::as_str) != Some("response")
        || envelope.get("id").and_then(Value::as_str) != Some("chatmux-journal-identity")
        || envelope.get("ok").and_then(Value::as_bool) != Some(true)
    {
        return None;
    }
    let sessions = envelope.get("result")?.as_array()?;
    if sessions.len() != 1 {
        return None;
    }
    let session = sessions.first()?.as_object()?;
    let name = session.get("name")?.as_str()?;
    valid_session_name(name).then(|| name.to_owned())
}

#[cfg(unix)]
fn identity_matches(expected_name: &Option<String>, session_key: &str, actual_name: &str) -> bool {
    if let Some(expected_name) = expected_name {
        return expected_name == actual_name;
    }
    let Some(stem) = session_key.strip_prefix(OPAQUE_SESSION_PREFIX) else { return false };
    let digest = Sha256::digest(actual_name.as_bytes());
    format!("{digest:x}") == stem
}

#[cfg(unix)]
struct SessionClaim {
    claims: Arc<Mutex<HashSet<String>>>,
    name: String,
}

#[cfg(unix)]
impl Drop for SessionClaim {
    fn drop(&mut self) {
        if let Ok(mut claims) = self.claims.lock() {
            claims.remove(&self.name);
        }
    }
}

#[cfg(unix)]
fn claim_session(claims: &Arc<Mutex<HashSet<String>>>, name: &str) -> Option<SessionClaim> {
    let mut claimed = claims.lock().ok()?;
    if !claimed.insert(name.to_owned()) {
        return None;
    }
    drop(claimed);
    Some(SessionClaim { claims: Arc::clone(claims), name: name.to_owned() })
}

#[cfg(all(unix, test))]
fn socket_paths_for_session(socket_dirs: &[PathBuf], session_name: &str) -> Vec<PathBuf> {
    socket_dirs.iter().map(|directory| directory.join(format!("{session_name}.sock"))).collect()
}

#[cfg(unix)]
fn valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && !matches!(name, "." | "..")
        && name.chars().all(|character| {
            character != '/'
                && character != '\\'
                && character != '\0'
                && !character.is_control()
                && !matches!(character, '\u{0085}' | '\u{2028}' | '\u{2029}')
        })
}

#[cfg(unix)]
fn socket_directories() -> Vec<PathBuf> {
    let runtime = absolute_env_path("XDG_RUNTIME_DIR")
        .or_else(|| absolute_env_path("TMPDIR"))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    socket_directories_for(&runtime, unsafe { libc::getuid() })
}

#[cfg(unix)]
fn absolute_env_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from)?;
    path.is_absolute().then_some(path)
}

/// Resolver-compatible socket roots in preference order. The cmux-tui server
/// uses the normal root first, then `/tmp`, then hashed roots when a Unix
/// socket path cannot fit `sockaddr_un`; scan all roots because the relay may
/// start before or after a daemon selected any one of them.
#[cfg(unix)]
fn socket_directories_for(runtime_base: &Path, uid: u32) -> Vec<PathBuf> {
    let preferred = runtime_base.join(format!("cmux-tui-{uid}"));
    let fallback = Path::new("/tmp").join(format!("cmux-tui-{uid}"));
    let preferred_hashed = runtime_base.join(format!("cmux-tui-hashed-{uid}"));
    let fallback_hashed = Path::new("/tmp").join(format!("cmux-tui-hashed-{uid}"));
    let mut directories = Vec::with_capacity(4);
    for directory in [preferred, fallback, preferred_hashed, fallback_hashed] {
        if !directories.iter().any(|existing| existing == &directory) {
            directories.push(directory);
        }
    }
    directories
}

#[cfg(unix)]
fn stream_id() -> String {
    format!("stream_{:032x}", NEXT_STREAM_ID.fetch_add(1, Ordering::Relaxed))
}

#[cfg(unix)]
async fn run_session(
    shared: Shared,
    session_name: Option<String>,
    session_key: String,
    socket_paths: Vec<PathBuf>,
) {
    let mut failures = 0_u32;
    let mut volatile_resume = None;
    let mut claim: Option<SessionClaim> = None;
    loop {
        if shared.cancellation.is_cancelled() {
            return;
        }
        let mut stream = None;
        for socket_path in &socket_paths {
            if !safe_socket_entry(socket_path).await {
                continue;
            }
            let connected = await_with_cancellation(
                &shared.cancellation,
                tokio::time::timeout(
                    Duration::from_secs(3),
                    tokio::net::UnixStream::connect(socket_path),
                ),
            )
            .await;
            match connected {
                None => return,
                Some(Ok(Ok(connected_stream))) => {
                    stream = Some(connected_stream);
                    break;
                }
                Some(Ok(Err(_)) | Err(_)) => {}
            }
        }
        let Some(stream) = stream else {
            failures = failures.saturating_add(1);
            if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                return;
            }
            continue;
        };
        let (read_half, mut write_half) = stream.into_split();
        let mut reader = tokio::io::BufReader::new(read_half);
        let identity_request = json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "chatmux-journal-identity",
            "operation": "session.list",
            "params": {"machine": "current"},
        });
        let Ok(mut identity_line) = serde_json::to_vec(&identity_request) else { return };
        identity_line.push(b'\n');
        if tokio::select! {
            biased;
            _ = shared.cancellation.cancelled() => return,
            result = tokio::time::timeout(
                IDENTITY_HANDSHAKE_TIMEOUT,
                tokio::io::AsyncWriteExt::write_all(&mut write_half, &identity_line),
            ) => !matches!(result, Ok(Ok(()))),
        } {
            failures = failures.saturating_add(1);
            if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                return;
            }
            continue;
        }
        let identity_read = tokio::select! {
            biased;
            _ = shared.cancellation.cancelled() => return,
            result = tokio::time::timeout(
                IDENTITY_HANDSHAKE_TIMEOUT,
                read_bounded_line(&mut reader, MAX_JOURNAL_LINE_BYTES),
            ) => result,
        };
        let Some(identity_name) = identity_read
            .ok()
            .and_then(Result::ok)
            .flatten()
            .and_then(|line| parse_session_identity(&line))
        else {
            failures = failures.saturating_add(1);
            if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                return;
            }
            continue;
        };
        if !identity_matches(&session_name, &session_key, &identity_name) {
            failures = failures.saturating_add(1);
            if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                return;
            }
            continue;
        }
        if let Some(existing) = claim.as_ref() {
            if existing.name != identity_name {
                return;
            }
        } else {
            claim = claim_session(&shared.claims, &identity_name);
            if claim.is_none() {
                // Another worker already verified this session identity.
                return;
            }
        }
        let wire_session_name = Some(identity_name);
        let effective_session_key = wire_session_name.as_deref().unwrap_or(&session_key).to_owned();
        let stream_id = stream_id();
        let cursor = match volatile_resume.take() {
            Some(cursor) => Some(cursor),
            None => {
                let cursors = shared.cursors.lock().await;
                cursors
                    .get(&effective_session_key)
                    .cloned()
                    .or_else(|| cursors.get(&session_key).cloned())
            }
        };
        let request = json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": SUBSCRIBE_REQUEST_ID,
            "operation": "session.journal.subscribe",
            "params": {
                "machine": "current",
                "session": "current",
                "stream_id": stream_id,
                "filter": {"kinds": JOURNAL_KIND_FILTERS, "max_sensitivity": "sensitive"},
                "cursor": cursor,
            },
        });
        let mut request = request;
        if request["params"]["cursor"].is_null() {
            let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
                return;
            };
            params.remove("cursor");
            if session_name.is_none() {
                // A hash leaf does not identify the original session name. Do
                // not start at the current head, or events created before the
                // first scan would be lost before a cursor can be persisted.
                params.insert("start".to_owned(), json!("beginning"));
            }
        }
        let Ok(mut request_line) = serde_json::to_vec(&request) else { return };
        request_line.push(b'\n');
        if tokio::select! {
            biased;
            _ = shared.cancellation.cancelled() => return,
            result = tokio::time::timeout(
                DEFAULT_REQUEST_TIMEOUT,
                tokio::io::AsyncWriteExt::write_all(&mut write_half, &request_line),
            ) => !matches!(result, Ok(Ok(()))),
        } {
            failures = failures.saturating_add(1);
            if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                return;
            }
            continue;
        }
        let mut subscribed = false;
        let mut generation = cursor.as_ref().map(|cursor| cursor.generation.clone());
        let mut last_delivered = None;
        let mut pending = Vec::new();
        let mut flush_armed = false;
        let mut flush_timer = Box::pin(tokio::time::sleep(Duration::from_secs(24 * 60 * 60)));
        let mut cursor_invalid = false;
        loop {
            tokio::select! {
                biased;
                _ = shared.cancellation.cancelled() => return,
                _ = &mut flush_timer, if flush_armed => {
                    flush_armed = false;
                    if !flush_pending(
                        &shared,
                        &effective_session_key,
                        wire_session_name.as_deref(),
                        &generation,
                        &mut pending,
                    )
                    .await
                    {
                        return;
                    }
                }
                result = read_bounded_line(&mut reader, MAX_JOURNAL_LINE_BYTES) => {
                    let Ok(Some(line)) = result else { break };
                    let Some(envelope) = parse_journal_line(line.trim_end_matches(['\r', '\n'])) else { continue };
                    if !subscribed {
                        if envelope.get("type").and_then(Value::as_str) != Some("response")
                            || envelope.get("id").and_then(Value::as_str) != Some(SUBSCRIBE_REQUEST_ID) {
                            continue;
                        }
                        if envelope.get("ok").and_then(Value::as_bool) == Some(true) {
                            subscribed = true;
                            if let Some(opened) = envelope.pointer("/result/cursor") {
                                generation = opened.get("generation").and_then(Value::as_str).map(str::to_owned).or(generation);
                            }
                            failures = 0;
                            continue;
                        }
                        cursor_invalid = envelope.pointer("/error/code").and_then(Value::as_str) == Some("cursor.invalid");
                        break;
                    }
                    if envelope.get("stream_id").and_then(Value::as_str) != Some(stream_id.as_str()) {
                        continue;
                    }
                    match envelope.get("type").and_then(Value::as_str) {
                        Some("stream_item") => {
                            if let Some(cursor) = parse_cursor(envelope.get("cursor")) {
                                generation.get_or_insert_with(|| cursor.generation.clone());
                                last_delivered = Some(cursor);
                            }
                            pending.push(envelope);
                            if pending.len() >= MAX_BATCH_RECORDS {
                                if !flush_pending(&shared, &effective_session_key, wire_session_name.as_deref(), &generation, &mut pending).await { return; }
                                flush_armed = false;
                            } else {
                                flush_armed = true;
                                flush_timer.as_mut().reset(tokio::time::Instant::now() + DEFAULT_FLUSH_DEBOUNCE);
                            }
                        }
                        Some("stream_end") => {
                            if envelope.get("reason").and_then(Value::as_str) == Some("gap") {
                                volatile_resume = parse_cursor(envelope.get("cursor")).or(last_delivered.clone());
                            }
                            break;
                        }
                        _ => {}
                    }
                }
            }
        }
        if !pending.is_empty()
            && !flush_pending(
                &shared,
                &effective_session_key,
                wire_session_name.as_deref(),
                &generation,
                &mut pending,
            )
            .await
        {
            return;
        }
        if let Some(cursor) = volatile_resume.clone().or(last_delivered) {
            update_resume(&mut volatile_resume, cursor);
        }
        if cursor_invalid {
            volatile_resume = None;
            let mut cursors = shared.cursors.lock().await;
            cursors.remove(&effective_session_key);
            if effective_session_key != session_key {
                cursors.remove(&session_key);
            }
            drop(cursors);
            persist_cursors(&shared).await;
            failures = 0;
        } else {
            failures = failures.saturating_add(1);
        }
        if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
            return;
        }
    }
}

#[cfg(unix)]
async fn flush_pending(
    shared: &Shared,
    session_key: &str,
    session_name: Option<&str>,
    generation: &Option<String>,
    pending: &mut Vec<Value>,
) -> bool {
    if pending.is_empty() {
        return true;
    }
    let entry = PendingSession {
        session_name: session_name.unwrap_or(session_key).to_owned(),
        generation: generation.clone(),
        records: std::mem::take(pending),
    };
    let batches = batch_records(&[entry]);
    if batches.is_empty() {
        return true;
    }
    post_with_retry(shared, batches).await
}

#[cfg(unix)]
async fn post_with_retry(shared: &Shared, batches: Vec<SessionBatch>) -> bool {
    let mut queue = VecDeque::from([batches]);
    while let Some(mut batches) = queue.pop_front() {
        let mut attempt = 0_u32;
        loop {
            if shared.cancellation.is_cancelled() {
                return false;
            }
            let record_count = batches.iter().map(|session| session.records.len()).sum();
            if record_count > 1 && batch_body_bytes(&batches) > MAX_BATCH_BODY_BYTES {
                let Some((first, second)) = split_batch(&batches) else { break };
                queue.push_front(second);
                batches = first;
                attempt = 0;
                continue;
            }
            let response = await_with_cancellation(
                &shared.cancellation,
                shared
                    .client
                    .post(&shared.events.url)
                    .bearer_auth(&shared.events.token)
                    .json(&json!({"sessions": &batches}))
                    .send(),
            )
            .await;
            let Some(response) = response else { return false };
            let Ok(response) = response else {
                attempt = attempt.saturating_add(1);
                if !wait_backoff(&shared.cancellation, post_delay(attempt)).await {
                    return false;
                }
                continue;
            };
            let status = response.status();
            match delivery_disposition(status.as_u16(), record_count) {
                DeliveryDisposition::Ack => {
                    let acked = match await_with_cancellation(
                        &shared.cancellation,
                        response.json::<AckBody>(),
                    )
                    .await
                    {
                        Some(Ok(body)) => body.cursors,
                        Some(Err(_)) => HashMap::new(),
                        None => return false,
                    };
                    let mut cursors = shared.cursors.lock().await;
                    *cursors = advance_cursors(&cursors, &batches, &acked);
                    drop(cursors);
                    persist_cursors(shared).await;
                    break;
                }
                DeliveryDisposition::Stop => {
                    shared.cancellation.cancel();
                    return false;
                }
                DeliveryDisposition::Drop => break,
                DeliveryDisposition::Split => {
                    let Some((first, second)) = split_batch(&batches) else { break };
                    // The first half is retried before the second half.
                    // Keeping the second half in the queue bounds memory and
                    // preserves journal order across a 413 split.
                    queue.push_front(second);
                    batches = first;
                    attempt = 0;
                    continue;
                }
                DeliveryDisposition::Retry => {
                    attempt = attempt.saturating_add(1);
                    if !wait_backoff(
                        &shared.cancellation,
                        if status == reqwest::StatusCode::UNAUTHORIZED {
                            DEFAULT_MAX_BACKOFF
                        } else {
                            post_delay(attempt)
                        },
                    )
                    .await
                    {
                        return false;
                    }
                }
            }
        }
    }
    true
}

async fn await_with_cancellation<F>(
    cancellation: &CancellationToken,
    future: F,
) -> Option<F::Output>
where
    F: Future,
{
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = future => Some(result),
    }
}

#[cfg(unix)]
async fn wait_backoff(cancellation: &CancellationToken, delay: Duration) -> bool {
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => false,
        _ = tokio::time::sleep(jittered(delay)) => true,
    }
}

#[cfg(unix)]
fn reconnect_delay(failures: u32) -> Duration {
    DEFAULT_RECONNECT_MIN.saturating_mul(1_u32 << failures.min(10)).min(DEFAULT_RECONNECT_MAX)
}

#[cfg(unix)]
fn post_delay(attempt: u32) -> Duration {
    DEFAULT_MIN_BACKOFF
        .saturating_mul(1_u32 << attempt.saturating_sub(1).min(30))
        .min(DEFAULT_MAX_BACKOFF)
}

#[cfg(unix)]
fn jittered(delay: Duration) -> Duration {
    let mut byte = [0_u8; 1];
    let _ = getrandom::fill(&mut byte);
    delay.mul_f64(0.5 + f64::from(byte[0]) / 512.0)
}

fn parse_cursor(value: Option<&Value>) -> Option<JournalCursor> {
    let object = value?.as_object()?;
    let generation = object.get("generation")?.as_str()?;
    let revision = object.get("revision")?.as_str()?;
    let cursor = JournalCursor { generation: generation.to_owned(), revision: revision.to_owned() };
    valid_cursor(&cursor).then_some(cursor)
}

fn update_resume(resume: &mut Option<JournalCursor>, candidate: JournalCursor) {
    if resume.as_ref().is_none_or(|previous| {
        previous.generation != candidate.generation
            || decimal_less(&previous.revision, &candidate.revision)
    }) {
        *resume = Some(candidate);
    }
}

fn decimal_less(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return left.len() < right.len();
    }
    left < right
}

#[cfg(unix)]
async fn load_cursor_file(path: &Path) -> HashMap<String, JournalCursor> {
    let Some(file) = open_cursor_file(path).await else { return HashMap::new() };
    let mut bytes = Vec::with_capacity(MAX_CURSOR_FILE_BYTES.min(4096));
    let mut limited = tokio::io::AsyncReadExt::take(file, (MAX_CURSOR_FILE_BYTES + 1) as u64);
    if tokio::io::AsyncReadExt::read_to_end(&mut limited, &mut bytes).await.is_err()
        || bytes.len() > MAX_CURSOR_FILE_BYTES
    {
        return HashMap::new();
    }
    let Ok(raw) = String::from_utf8(bytes) else { return HashMap::new() };
    serde_json::from_str::<HashMap<String, JournalCursor>>(&raw)
        .unwrap_or_default()
        .into_iter()
        .filter(|(name, cursor)| {
            valid_session_key(name) && parse_cursor(Some(&json!(cursor))).is_some()
        })
        .collect()
}

#[cfg(unix)]
async fn persist_cursors(shared: &Shared) {
    let cursors = shared.cursors.lock().await.clone();
    let _ = persist_cursor_file(&shared.cursor_path, &cursors).await;
}

#[cfg(unix)]
fn cursor_file_metadata_ok(metadata: &std::fs::Metadata) -> bool {
    metadata.is_file()
        && metadata.uid() == unsafe { libc::getuid() }
        // Cursor revisions are not credentials, but sharing this file allows
        // another user to influence replay and delivery. Keep it private.
        && metadata.permissions().mode() & 0o077 == 0
}

#[cfg(unix)]
async fn open_cursor_file(path: &Path) -> Option<tokio::fs::File> {
    let mut options = tokio::fs::OpenOptions::new();
    options.read(true).custom_flags(libc::O_NOFOLLOW);
    let file = options.open(path).await.ok()?;
    let metadata = file.metadata().await.ok()?;
    if !cursor_file_metadata_ok(&metadata) || metadata.len() > MAX_CURSOR_FILE_BYTES as u64 {
        return None;
    }
    Some(file)
}

#[cfg(unix)]
async fn cursor_path_is_replaceable(path: &Path) -> bool {
    match tokio::fs::symlink_metadata(path).await {
        // An existing file from the Node relay may have been created with a
        // broad umask. It is safe to replace it because it is our regular
        // file; the new atomic file is always 0600. We still reject links,
        // directories, and files owned by another user.
        Ok(metadata) => metadata.is_file() && metadata.uid() == unsafe { libc::getuid() },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(_) => false,
    }
}

#[cfg(unix)]
fn cursor_temp_path(path: &Path, nonce: &[u8; 16]) -> Option<PathBuf> {
    let file_name = path.file_name()?.to_str()?;
    let suffix = nonce.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    Some(path.with_file_name(format!(".{file_name}.{suffix}.tmp")))
}

#[cfg(unix)]
async fn persist_cursor_file(path: &Path, cursors: &HashMap<String, JournalCursor>) -> bool {
    let Ok(raw) = serde_json::to_string_pretty(cursors) else { return false };
    let body = format!("{raw}\n");
    if body.len() > MAX_CURSOR_FILE_BYTES || !cursor_path_is_replaceable(path).await {
        return false;
    }

    for _ in 0..CURSOR_TEMP_ATTEMPTS {
        let mut nonce = [0_u8; 16];
        if getrandom::fill(&mut nonce).is_err() {
            return false;
        }
        let Some(temp_path) = cursor_temp_path(path, &nonce) else { return false };
        let mut options = tokio::fs::OpenOptions::new();
        options.write(true).create_new(true).custom_flags(libc::O_NOFOLLOW).mode(0o600);
        let Ok(mut file) = options.open(&temp_path).await else { continue };
        let write_result = async {
            file.set_permissions(std::fs::Permissions::from_mode(0o600)).await?;
            tokio::io::AsyncWriteExt::write_all(&mut file, body.as_bytes()).await?;
            file.sync_data().await
        }
        .await;
        if write_result.is_err() {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return false;
        }
        drop(file);

        // Never replace a symlink, non-regular file, or foreign-owned file.
        // A legacy own file may be broader than 0600; remove that file only
        // after checking its owner, then install the private replacement.
        match tokio::fs::symlink_metadata(path).await {
            Ok(metadata) if cursor_file_metadata_ok(&metadata) => {}
            Ok(metadata) if metadata.is_file() && metadata.uid() == unsafe { libc::getuid() } => {
                if tokio::fs::remove_file(path).await.is_err() {
                    let _ = tokio::fs::remove_file(&temp_path).await;
                    return false;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => {
                let _ = tokio::fs::remove_file(&temp_path).await;
                return false;
            }
        }
        match tokio::fs::rename(&temp_path, path).await {
            Ok(()) => return true,
            Err(_) => {
                let _ = tokio::fs::remove_file(&temp_path).await;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    static NEXT_CURSOR_TEST_ID: AtomicU64 = AtomicU64::new(1);

    #[cfg(unix)]
    async fn cursor_test_path(label: &str) -> (PathBuf, PathBuf) {
        let id = NEXT_CURSOR_TEST_ID.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir()
            .join(format!("chatmux-relay-cursor-{label}-{}-{id}", std::process::id()));
        tokio::fs::create_dir(&root).await.expect("create cursor test directory");
        (root.clone(), root.join("cursors.json"))
    }

    #[cfg(unix)]
    async fn remove_cursor_test_path(root: &Path) {
        tokio::fs::remove_dir_all(root).await.expect("remove cursor test directory");
    }

    fn cursor(generation: &str, revision: &str) -> JournalCursor {
        JournalCursor { generation: generation.to_owned(), revision: revision.to_owned() }
    }

    fn record(generation: &str, revision: &str) -> Value {
        json!({
            "type": "stream_item",
            "sequence": revision,
            "cursor": {"generation": generation, "revision": revision},
        })
    }

    #[test]
    fn malformed_lines_are_ignored_without_unbounded_input() {
        assert!(parse_journal_line("{torn").is_none());
        assert!(parse_journal_line("[]").is_none());
        assert!(parse_journal_line(&"x".repeat(MAX_JOURNAL_LINE_BYTES + 1)).is_none());
        assert_eq!(
            parse_journal_line(r#"{"type":"stream_item"}"#).expect("valid envelope")["type"],
            "stream_item"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn bounded_reader_rejects_an_unterminated_oversized_line() {
        let payload = vec![b'x'; 32];
        let mut reader = tokio::io::BufReader::new(std::io::Cursor::new(payload));
        assert!(read_bounded_line(&mut reader, 16).await.is_err());
    }

    #[cfg(unix)]
    #[test]
    fn identity_handshake_requires_one_verified_session() {
        let valid = json!({
            "protocol": PROTOCOL,
            "type": "response",
            "id": "chatmux-journal-identity",
            "ok": true,
            "result": [{"name": "legacy name"}],
        })
        .to_string();
        assert_eq!(parse_session_identity(&valid), Some(String::from("legacy name")));
        let mut wrong_protocol = serde_json::from_str::<Value>(&valid).expect("identity JSON");
        wrong_protocol["protocol"] = json!("cmux.protocol/1");
        assert!(parse_session_identity(&wrong_protocol.to_string()).is_none());
        let ambiguous = json!({
            "protocol": PROTOCOL,
            "type": "response",
            "id": "chatmux-journal-identity",
            "ok": true,
            "result": [{"name": "one"}, {"name": "two"}],
        })
        .to_string();
        assert!(parse_session_identity(&ambiguous).is_none());
        assert!(identity_matches(&Some(String::from("legacy name")), "legacy", "legacy name"));
        assert!(!identity_matches(&Some(String::from("legacy name")), "legacy", "other"));
        let stem = format!("{:x}", Sha256::digest("legacy name".as_bytes()));
        assert!(identity_matches(&None, &opaque_session_key(&stem), "legacy name"));
        assert!(!identity_matches(&None, &opaque_session_key(&stem), "other"));
    }

    #[cfg(unix)]
    #[test]
    fn socket_roots_match_server_preferred_fallback_and_hashed_order() {
        let roots = socket_directories_for(Path::new("/run/user/501"), 501);
        assert_eq!(
            roots,
            vec![
                PathBuf::from("/run/user/501/cmux-tui-501"),
                PathBuf::from("/tmp/cmux-tui-501"),
                PathBuf::from("/run/user/501/cmux-tui-hashed-501"),
                PathBuf::from("/tmp/cmux-tui-hashed-501"),
            ]
        );
        let tmp_roots = socket_directories_for(Path::new("/tmp"), 501);
        assert_eq!(
            tmp_roots,
            vec![PathBuf::from("/tmp/cmux-tui-501"), PathBuf::from("/tmp/cmux-tui-hashed-501"),]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn discovery_merges_preferred_and_fallback_without_duplicate_session_workers() {
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::net::UnixListener;

        let root =
            std::env::temp_dir().join(format!("chatmux-relay-discovery-{}", std::process::id()));
        let _ = tokio::fs::remove_dir_all(&root).await;
        let preferred = root.join("preferred");
        let fallback = root.join("fallback");
        tokio::fs::create_dir_all(&preferred).await.expect("preferred directory");
        tokio::fs::create_dir_all(&fallback).await.expect("fallback directory");
        tokio::fs::set_permissions(&preferred, std::fs::Permissions::from_mode(0o700))
            .await
            .expect("preferred directory permissions");
        tokio::fs::set_permissions(&fallback, std::fs::Permissions::from_mode(0o700))
            .await
            .expect("fallback directory permissions");
        let preferred_main =
            UnixListener::bind(preferred.join("main.sock")).expect("preferred socket entry");
        let fallback_main =
            UnixListener::bind(fallback.join("main.sock")).expect("fallback socket entry");
        let fallback_late =
            UnixListener::bind(fallback.join("late.sock")).expect("fallback-only socket entry");

        let dirs = vec![preferred.clone(), fallback.clone()];
        let names = discover_session_names(&dirs).await;
        assert_eq!(names, HashSet::from([String::from("main"), String::from("late")]));
        let main_paths = socket_paths_for_session(&dirs, "main");
        assert_eq!(main_paths, vec![preferred.join("main.sock"), fallback.join("main.sock")]);

        drop(preferred_main);
        drop(fallback_main);
        drop(fallback_late);
        tokio::fs::remove_dir_all(root).await.expect("remove discovery fixture");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn hashed_socket_stem_is_opaque_and_session_name_is_omitted() {
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::net::UnixListener;

        let root = PathBuf::from("/tmp/cmh");
        let _ = tokio::fs::remove_dir_all(&root).await;
        let hashed = root.join("cmux-tui-hashed-501");
        tokio::fs::create_dir_all(&hashed).await.expect("hashed directory");
        tokio::fs::set_permissions(&hashed, std::fs::Permissions::from_mode(0o700))
            .await
            .expect("hashed directory permissions");
        let stem = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let listener =
            UnixListener::bind(hashed.join(format!("{stem}.sock"))).expect("hashed socket entry");

        let candidates = discover_session_candidates(std::slice::from_ref(&hashed)).await;
        assert_eq!(candidates.len(), 1);
        let candidate = &candidates[0];
        assert!(candidate.session_name.is_none());
        assert_eq!(candidate.key, opaque_session_key(stem));
        assert!(candidate.socket_paths.iter().all(|path| path.starts_with(&hashed)));

        let batch = SessionBatch {
            session_id: "generation".to_owned(),
            session_name: candidate.key.clone(),
            records: vec![record("generation", "1")],
            cursor: cursor("generation", "1"),
        };
        let body = serde_json::to_value(json!({"sessions": [batch]})).expect("batch JSON");
        assert!(body["sessions"][0].get("sessionName").is_none());

        drop(listener);
        tokio::fs::remove_dir_all(root).await.expect("remove hashed fixture");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn discovery_rejects_insecure_roots_and_symlink_entries() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        use std::os::unix::net::UnixListener;

        let root = PathBuf::from(format!("/tmp/cms-{}", std::process::id()));
        let _ = tokio::fs::remove_dir_all(&root).await;
        let insecure = root.join("insecure");
        tokio::fs::create_dir_all(&insecure).await.expect("insecure directory");
        tokio::fs::set_permissions(&insecure, std::fs::Permissions::from_mode(0o755))
            .await
            .expect("insecure permissions");
        let listener = UnixListener::bind(insecure.join("main.sock")).expect("socket");
        assert!(discover_session_candidates(std::slice::from_ref(&insecure)).await.is_empty());
        drop(listener);
        let _ = tokio::fs::remove_file(insecure.join("main.sock")).await;

        tokio::fs::set_permissions(&insecure, std::fs::Permissions::from_mode(0o700))
            .await
            .expect("private permissions");
        let target = insecure.join("target.sock");
        let target_listener = UnixListener::bind(&target).expect("target socket");
        symlink(&target, insecure.join("alias.sock")).expect("socket symlink");
        let candidates = discover_session_candidates(std::slice::from_ref(&insecure)).await;
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].key, "target");

        drop(target_listener);
        tokio::fs::remove_dir_all(root).await.expect("remove insecure fixture");
    }

    #[test]
    fn session_name_validation_matches_core_component_rules() {
        assert!(valid_session_name("legacy name: λ"));
        assert!(valid_session_name(&"x".repeat(512)));
        for invalid in ["", ".", "..", "a/b", "a\\b", "a\u{0000}b", "a\u{2028}b"] {
            assert!(!valid_session_name(invalid), "accepted invalid session {invalid:?}");
        }
    }

    #[test]
    fn batch_requires_a_cursor_and_preserves_envelopes() {
        let records = vec![record("session_a", "1"), record("session_a", "2")];
        let batches = batch_records(&[
            PendingSession {
                session_name: "main".to_owned(),
                generation: Some("session_a".to_owned()),
                records: records.clone(),
            },
            PendingSession { session_name: "idle".to_owned(), generation: None, records: vec![] },
        ]);
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].session_id, "session_a");
        assert_eq!(batches[0].cursor, cursor("session_a", "2"));
        assert_eq!(batches[0].records, records);
    }

    #[test]
    fn cursor_resume_prefers_ack_floor_and_never_moves_backwards() {
        let fallback = json!({"type": "stream_item", "sequence": "8"});
        assert_eq!(
            cursor_from_record(&fallback, Some("session_a")),
            Some(cursor("session_a", "8"))
        );
        let mut resume = Some(cursor("session_a", "8"));
        update_resume(&mut resume, cursor("session_a", "7"));
        assert_eq!(resume, Some(cursor("session_a", "8")));
        update_resume(&mut resume, cursor("session_a", "9"));
        assert_eq!(resume, Some(cursor("session_a", "9")));
    }

    #[test]
    fn split_batch_is_record_bounded_and_recomputes_cursor() {
        let sessions = vec![SessionBatch {
            session_id: "session_a".to_owned(),
            session_name: "main".to_owned(),
            records: (1..=4).map(|n| record("session_a", &n.to_string())).collect(),
            cursor: cursor("session_a", "4"),
        }];
        let (first, second) = split_batch(&sessions).expect("split");
        assert_eq!(first[0].records.len(), 2);
        assert_eq!(second[0].records.len(), 2);
        assert_eq!(first[0].cursor, cursor("session_a", "2"));
        assert!(
            split_batch(&[SessionBatch {
                records: vec![record("session_a", "1")],
                ..sessions[0].clone()
            }])
            .is_none()
        );
    }

    #[test]
    fn only_server_ack_cursors_advance() {
        let sessions = vec![SessionBatch {
            session_id: "session_a".to_owned(),
            session_name: "main".to_owned(),
            records: vec![record("session_a", "2")],
            cursor: cursor("session_a", "2"),
        }];
        let mut old = HashMap::from([(String::from("main"), cursor("session_a", "1"))]);
        assert_eq!(advance_cursors(&old, &sessions, &HashMap::new()), old);
        assert_eq!(
            advance_cursors(
                &old,
                &sessions,
                &HashMap::from([(String::from("session_a"), cursor("", ""))]),
            ),
            old
        );
        old = advance_cursors(
            &old,
            &sessions,
            &HashMap::from([(String::from("session_a"), cursor("session_a", "2"))]),
        );
        assert_eq!(old["main"], cursor("session_a", "2"));
    }

    #[test]
    fn delivery_status_boundaries_preserve_retry_and_stop_policy() {
        assert_eq!(delivery_disposition(200, 100), DeliveryDisposition::Ack);
        assert_eq!(delivery_disposition(204, 1), DeliveryDisposition::Ack);
        assert_eq!(delivery_disposition(413, 100), DeliveryDisposition::Split);
        // A single record cannot be split. The caller drops it after the
        // backend rejects it, matching the Node forwarder boundary.
        assert_eq!(delivery_disposition(413, 1), DeliveryDisposition::Drop);
        assert_eq!(delivery_disposition(410, 1), DeliveryDisposition::Stop);
        assert_eq!(delivery_disposition(401, 1), DeliveryDisposition::Retry);
        assert_eq!(delivery_disposition(503, 1), DeliveryDisposition::Retry);
    }

    #[test]
    fn body_budget_is_explicit_and_single_records_are_not_silently_split() {
        let oversized = SessionBatch {
            session_id: "session_a".to_owned(),
            session_name: "main".to_owned(),
            records: vec![json!({
                "type": "stream_item",
                "cursor": {"generation": "session_a", "revision": "1"},
                "payload": "x".repeat(MAX_BATCH_BODY_BYTES),
            })],
            cursor: cursor("session_a", "1"),
        };
        assert!(batch_body_bytes(&[oversized]) > MAX_BATCH_BODY_BYTES);
        assert_eq!(delivery_disposition(413, 1), DeliveryDisposition::Drop);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn retry_backoff_observes_cancellation() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        assert!(!wait_backoff(&cancellation, Duration::from_secs(60)).await);
    }

    #[tokio::test]
    async fn cancellation_interrupts_a_pending_request() {
        let cancellation = CancellationToken::new();
        let request_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            await_with_cancellation(&request_cancellation, std::future::pending::<()>()).await
        });
        cancellation.cancel();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .expect("cancellation must resolve the request")
                .expect("request task must not panic")
                .is_none()
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stalled_http_request_respects_the_configured_timeout() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind local test endpoint");
        let address = listener.local_addr().expect("read local test endpoint address");
        let server = tokio::spawn(async move {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let mut request = [0_u8; 1024];
            let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut request).await;
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        let client = build_http_client(Duration::from_millis(50)).expect("build test client");
        let started = std::time::Instant::now();
        let result = client.get(format!("http://{address}")).send().await;
        assert!(result.is_err(), "a stalled endpoint must time out");
        assert!(started.elapsed() < Duration::from_millis(500));
        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cursor_store_rejects_symlinks_and_non_regular_files_and_migrates_shared_modes() {
        let (root, path) = cursor_test_path("reject").await;
        let target = root.join("target.json");
        tokio::fs::write(&target, b"{}").await.expect("write target");
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600))
            .await
            .expect("protect target");
        std::os::unix::fs::symlink(&target, &path).expect("create cursor symlink");
        assert!(load_cursor_file(&path).await.is_empty());
        assert!(!persist_cursor_file(&path, &HashMap::new()).await);
        tokio::fs::remove_file(&path).await.expect("remove cursor symlink");

        tokio::fs::create_dir(&path).await.expect("create non-regular cursor path");
        assert!(load_cursor_file(&path).await.is_empty());
        assert!(!persist_cursor_file(&path, &HashMap::new()).await);
        tokio::fs::remove_dir(&path).await.expect("remove cursor directory");

        tokio::fs::write(&path, b"{}").await.expect("write shared cursor");
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))
            .await
            .expect("make cursor shared");
        assert!(load_cursor_file(&path).await.is_empty());
        assert!(persist_cursor_file(&path, &HashMap::new()).await);
        let metadata = tokio::fs::symlink_metadata(&path).await.expect("read migrated cursor");
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        remove_cursor_test_path(&root).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cursor_store_rejects_oversized_files_and_writes_private_atomically() {
        let (root, path) = cursor_test_path("bounded").await;
        tokio::fs::write(&path, vec![b'x'; MAX_CURSOR_FILE_BYTES + 1])
            .await
            .expect("write oversized cursor");
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .await
            .expect("protect oversized cursor");
        assert!(load_cursor_file(&path).await.is_empty());

        tokio::fs::remove_file(&path).await.expect("remove oversized cursor");
        let cursors = HashMap::from([(String::from("main"), cursor("session_a", "7"))]);
        assert!(persist_cursor_file(&path, &cursors).await);
        let metadata = tokio::fs::symlink_metadata(&path).await.expect("read cursor metadata");
        assert!(metadata.is_file());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(load_cursor_file(&path).await, cursors);
        remove_cursor_test_path(&root).await;
    }
}
