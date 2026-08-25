//! Managed enrollment v2 session-journal forwarder.
//!
//! The forwarder is deliberately independent from the relay WebSocket. It
//! tails cmux-tui JSON-lines resource sockets and POSTs the original
//! `stream_item` envelopes to the origin-bound endpoint in the enrollment
//! file. Every queue and batch has a limit; network failures keep one bounded
//! batch for retry and never take down the relay session.

use std::collections::HashMap;
#[cfg(unix)]
use std::collections::VecDeque;
#[cfg(unix)]
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::Arc;
#[cfg(unix)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
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
const DEFAULT_RECONNECT_MIN: Duration = Duration::from_secs(1);
const DEFAULT_RECONNECT_MAX: Duration = Duration::from_secs(30);
const SOCKET_SCAN_INTERVAL: Duration = Duration::from_secs(15);
const SOCKET_NAME_MAX: usize = 64;
const SUBSCRIBE_REQUEST_ID: &str = "chatmux-journal-subscribe";
const PROTOCOL: &str = "cmux.protocol/2";
const DEFAULT_CURSOR_PATH: &str = "/tmp/.chatmux-relay-cursors.json";

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
}

#[cfg(unix)]
async fn run(events: ManagedEvents, cancellation: CancellationToken) {
    let cursors = load_cursor_file(Path::new(DEFAULT_CURSOR_PATH)).await;
    let shared = Shared {
        events,
        client: reqwest::Client::new(),
        cursors: Arc::new(tokio::sync::Mutex::new(cursors)),
        cursor_path: PathBuf::from(DEFAULT_CURSOR_PATH),
        cancellation: cancellation.clone(),
    };
    let socket_dir = socket_directory();
    let mut tasks: HashMap<String, JoinHandle<()>> = HashMap::new();
    let mut scan = tokio::time::interval(SOCKET_SCAN_INTERVAL);
    scan.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    discover_sessions(&shared, &socket_dir, &mut tasks).await;
    loop {
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => break,
            _ = scan.tick() => discover_sessions(&shared, &socket_dir, &mut tasks).await,
        }
    }
    for (_, task) in tasks {
        task.abort();
    }
}

#[cfg(unix)]
async fn discover_sessions(
    shared: &Shared,
    socket_dir: &Path,
    tasks: &mut HashMap<String, JoinHandle<()>>,
) {
    tasks.retain(|_, task| !task.is_finished());
    let Ok(mut entries) = tokio::fs::read_dir(socket_dir).await else { return };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else { continue };
        let Some(session_name) = file_name.strip_suffix(".sock") else { continue };
        if !valid_session_name(session_name) || tasks.contains_key(session_name) {
            continue;
        }
        let path = entry.path();
        let session = session_name.to_owned();
        let worker = shared.clone();
        tasks.insert(
            session_name.to_owned(),
            tokio::spawn(async move {
                run_session(worker, session, path).await;
            }),
        );
    }
}

#[cfg(unix)]
fn valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= SOCKET_NAME_MAX
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

#[cfg(unix)]
fn socket_directory() -> PathBuf {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .or_else(|| std::env::var_os("TMPDIR"))
        .unwrap_or_else(|| "/tmp".into());
    PathBuf::from(runtime).join(format!("cmux-tui-{}", unsafe { libc::geteuid() }))
}

#[cfg(unix)]
fn stream_id() -> String {
    format!("stream_{:032x}", NEXT_STREAM_ID.fetch_add(1, Ordering::Relaxed))
}

#[cfg(unix)]
async fn run_session(shared: Shared, session_name: String, socket_path: PathBuf) {
    let mut failures = 0_u32;
    let mut volatile_resume = None;
    loop {
        if shared.cancellation.is_cancelled() {
            return;
        }
        let stream = match tokio::time::timeout(
            Duration::from_secs(3),
            tokio::net::UnixStream::connect(&socket_path),
        )
        .await
        {
            Ok(Ok(stream)) => stream,
            _ => {
                failures = failures.saturating_add(1);
                if !wait_backoff(&shared.cancellation, reconnect_delay(failures)).await {
                    return;
                }
                continue;
            }
        };
        let (read_half, mut write_half) = stream.into_split();
        let stream_id = stream_id();
        let cursor = match volatile_resume.take() {
            Some(cursor) => Some(cursor),
            None => shared.cursors.lock().await.get(&session_name).cloned(),
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
        }
        let Ok(mut request_line) = serde_json::to_vec(&request) else { return };
        request_line.push(b'\n');
        if tokio::select! {
            biased;
            _ = shared.cancellation.cancelled() => return,
            result = tokio::io::AsyncWriteExt::write_all(&mut write_half, &request_line) => result.is_err(),
        } {
            continue;
        }
        let mut reader = tokio::io::BufReader::new(read_half);
        let mut line = String::new();
        let mut subscribed = false;
        let mut generation = cursor.as_ref().map(|cursor| cursor.generation.clone());
        let mut last_delivered = None;
        let mut pending = Vec::new();
        let mut flush_armed = false;
        let mut flush_timer = Box::pin(tokio::time::sleep(Duration::from_secs(24 * 60 * 60)));
        let mut cursor_invalid = false;
        loop {
            line.clear();
            tokio::select! {
                biased;
                _ = shared.cancellation.cancelled() => return,
                _ = &mut flush_timer, if flush_armed => {
                    flush_armed = false;
                    if !flush_pending(&shared, &session_name, &generation, &mut pending).await {
                        return;
                    }
                }
                result = tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line) => {
                    let Ok(bytes) = result else { break };
                    if bytes == 0 { break }
                    if bytes > MAX_JOURNAL_LINE_BYTES { continue }
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
                                if !flush_pending(&shared, &session_name, &generation, &mut pending).await { return; }
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
            && !flush_pending(&shared, &session_name, &generation, &mut pending).await
        {
            return;
        }
        if let Some(cursor) = volatile_resume.clone().or(last_delivered) {
            update_resume(&mut volatile_resume, cursor);
        }
        if cursor_invalid {
            volatile_resume = None;
            shared.cursors.lock().await.remove(&session_name);
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
    session_name: &str,
    generation: &Option<String>,
    pending: &mut Vec<Value>,
) -> bool {
    if pending.is_empty() {
        return true;
    }
    let entry = PendingSession {
        session_name: session_name.to_owned(),
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
            let response = shared
                .client
                .post(&shared.events.url)
                .bearer_auth(&shared.events.token)
                .json(&json!({"sessions": &batches}))
                .send()
                .await;
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
                    let acked = response
                        .json::<AckBody>()
                        .await
                        .map(|body| body.cursors)
                        .unwrap_or_default();
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
    let Ok(raw) = tokio::fs::read_to_string(path).await else { return HashMap::new() };
    serde_json::from_str::<HashMap<String, JournalCursor>>(&raw)
        .unwrap_or_default()
        .into_iter()
        .filter(|(name, cursor)| {
            valid_session_name(name) && parse_cursor(Some(&json!(cursor))).is_some()
        })
        .collect()
}

#[cfg(unix)]
async fn persist_cursors(shared: &Shared) {
    let cursors = shared.cursors.lock().await.clone();
    let Ok(raw) = serde_json::to_string_pretty(&cursors) else { return };
    let _ = tokio::fs::write(&shared.cursor_path, format!("{raw}\n")).await;
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
