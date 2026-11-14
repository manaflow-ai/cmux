//! The macOS sidebar's mirror of the live view (the design doc's row 7), end to end: a v1 hub's
//! sessions, summarized by the list tee's own builder, served through the daemon's upgrade path
//! (`Upgrade::serve`), and read through the client's C entry points the way the Swift wrapper
//! calls them. The gates measure it; the recorded streams are what the Swift tests replay.

use super::{Limits, MAX_LINE_BYTES, SMALL_LINE_BYTES, read_lines};
use crate::hub::{Hub, Session};
use acpmux_book::index::{OriginState, Summary, SummaryIndex};
use acpmux_client::ffi::{
    ACPMUX_CLIENT_ABI_VERSION, ACPMUX_CLIENT_OK, Bytes, acpmux_client_abi_version,
    acpmux_client_bytes_free, acpmux_client_connected, acpmux_client_disconnected,
    acpmux_client_free, acpmux_client_new, acpmux_client_next_change, acpmux_client_received,
    acpmux_client_subscribe_mirror, acpmux_client_take_send, acpmux_client_want,
};
use acpmux_core::hub::HubWriter;
use acpmux_core::life::V2;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::sync::{mpsc, oneshot};

#[path = "sidebar_mirror_gate_tests.rs"]
mod gates;
#[path = "sidebar_mirror_recorded_tests.rs"]
mod recorded;

/// The sidebar's one mirror: the live view, its rows as v1 gave them.
const SID: &str = "sidebar";
/// The longest one step of a run may wait for the daemon.
const STEP_WAIT: Duration = Duration::from_secs(10);

fn mirror_request() -> Value {
    json!({
        "sub": {"sid": SID, "stream": "list", "view": "live", "rows": "v1"},
        "held": [],
        "whole": false,
    })
}

fn want_request(keys: &[Value]) -> Value {
    json!({"sid": SID, "keys": keys})
}

fn key(summary: &Summary) -> Value {
    json!({
        "lastActivity": summary.last_activity,
        "chatId": summary.chat_id,
        "origin": summary.origin,
    })
}

/// A v1 session record with only what the sidebar reads.
fn meta(id: &str, status: &str, at: u64, tags: Value) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": id,
        "name": id,
        "title": format!("{id}: the sidebar fixture"),
        "harness": "claude",
        "cwd": "/home/agent/work",
        "status": status,
        "createdAt": at,
        "updatedAt": at,
        "tags": tags,
    }))
    .unwrap()
}

fn memory_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

/// The rows both sides of a run hold, in a v1 hub, and the list hub fed from it.
pub(super) struct Fixture {
    pub(super) v1: Arc<Hub>,
    pub(super) sessions: BTreeMap<String, Arc<Session>>,
    pub(super) wanted: Vec<Value>,
    pub(super) v2: Arc<V2>,
    writer: HubWriter,
}

impl Fixture {
    /// `live` rows the live view holds, then `closed` closed rows, the first `want` of them
    /// wanted. `god` gives each session the god fixture's full record instead of the lean one.
    fn new(live: &[(&str, &str, Value)], closed: usize, want: usize, god: bool) -> Self {
        let v1 = memory_hub();
        let mut sessions = BTreeMap::new();
        let base = 1_791_540_000_000_u64;
        let mut insert = |id: String, status: &str, at: u64, tags: Value| {
            let mut record = if god {
                let mut value = crate::god_fixture::session_meta(
                    &id,
                    &id,
                    "/home/agent/work",
                    &crate::god_fixture::agent_session_id(sessions.len()),
                    400,
                    at,
                );
                value["status"] = json!(status);
                value["updatedAt"] = json!(at);
                serde_json::from_value(value).unwrap()
            } else {
                meta(&id, status, at, json!({}))
            };
            if let Ok(tags) = serde_json::from_value(tags) {
                record.tags = tags;
            }
            sessions.insert(id, v1.insert_test_session(record));
        };
        for (n, (id, status, tags)) in live.iter().enumerate() {
            insert((*id).to_owned(), status, base + 100_000 + n as u64 * 1_000, tags.clone());
        }
        for n in 0..closed {
            insert(format!("closed-{n:05}"), "closed", base + n as u64, json!({}));
        }
        let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        let v2 = Arc::new(V2::new(hub, writer));
        let writer = v2.take_writer().unwrap();
        let mut fixture = Self { v1, sessions, wanted: Vec::new(), v2, writer };
        let ids: Vec<String> = fixture.sessions.keys().cloned().collect();
        for id in &ids {
            fixture.publish(id);
        }
        fixture.wanted =
            (0..want).map(|n| key(&fixture.summary(&format!("closed-{n:05}")))).collect();
        fixture
    }

    /// The list tee's summary of one v1 session, as it is now.
    fn summary(&self, id: &str) -> Summary {
        crate::hub::list_tee::summary_from_session(&self.v1, &self.sessions[id]).unwrap()
    }

    /// Hands one session's summary to the list hub, as the tee does after a mark.
    fn publish(&mut self, id: &str) {
        let summary = self.summary(id);
        self.writer.apply(summary).unwrap();
    }

    fn edit(&mut self, id: &str, edit: impl FnOnce(&mut crate::store::SessionMeta)) {
        self.v1.edit_test_meta(&self.sessions[id], edit);
        self.publish(id);
    }

    /// A row of another machine, `origin`, in the live view.
    fn add_peer_row(&mut self, origin: &str, id: &str) {
        let peer = memory_hub();
        let session = peer.insert_test_session(meta(id, "running", 1_791_540_200_000, json!({})));
        let mut summary = crate::hub::list_tee::summary_from_session(&peer, &session).unwrap();
        summary.origin = origin.to_owned();
        self.writer.origin(origin, OriginState::Connected, 1).unwrap();
        self.writer.apply(summary).unwrap();
    }

    /// Restarts the daemon: a new list hub holding the local rows and none of the old hub's
    /// history (so a cursor from before it is past its head), and no other machine's rows.
    /// Later edits go to it.
    fn restart(&mut self) {
        let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        self.v2 = Arc::new(V2::new(hub, writer));
        self.writer = self.v2.take_writer().unwrap();
        let ids: Vec<String> = self.sessions.keys().cloned().collect();
        for id in &ids {
            self.publish(id);
        }
    }
}

/// One client handle driven through the C entry points, as the Swift wrapper drives it.
pub(super) struct Ffi {
    handle: *mut c_void,
}

impl Ffi {
    pub(super) fn new() -> Self {
        assert_eq!(acpmux_client_abi_version(), ACPMUX_CLIENT_ABI_VERSION);
        let handle = acpmux_client_new();
        assert!(!handle.is_null());
        Self { handle }
    }

    fn take(&mut self, call: unsafe extern "C" fn(*mut c_void, *mut Bytes) -> i32) -> Vec<u8> {
        let mut out = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: the handle is owned by `self`, and `&mut self` serializes calls.
        assert_eq!(unsafe { call(self.handle, &mut out) }, ACPMUX_CLIENT_OK);
        let bytes = if out.len == 0 {
            Vec::new()
        } else {
            // SAFETY: the library returned `len` readable bytes at `ptr`, freed below.
            unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec()
        };
        // SAFETY: `out` came from the library and is freed once.
        unsafe { acpmux_client_bytes_free(out) };
        bytes
    }

    fn request(
        &mut self,
        call: unsafe extern "C" fn(*mut c_void, *const u8, usize) -> i32,
        request: &Value,
    ) {
        let bytes = serde_json::to_vec(request).unwrap();
        // SAFETY: owned handle; the slice is readable for this call.
        assert_eq!(unsafe { call(self.handle, bytes.as_ptr(), bytes.len()) }, ACPMUX_CLIENT_OK);
    }

    pub(super) fn connected(&mut self) {
        // SAFETY: owned handle, serialized by `&mut self`.
        assert_eq!(unsafe { acpmux_client_connected(self.handle) }, ACPMUX_CLIENT_OK);
    }

    pub(super) fn disconnected(&mut self) {
        // SAFETY: owned handle, serialized by `&mut self`.
        assert_eq!(unsafe { acpmux_client_disconnected(self.handle) }, ACPMUX_CLIENT_OK);
    }

    pub(super) fn subscribe_mirror(&mut self, request: &Value) -> String {
        let bytes = serde_json::to_vec(request).unwrap();
        let mut out = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: owned handle; the slice is readable and `out` writable for this call.
        let status = unsafe {
            acpmux_client_subscribe_mirror(self.handle, bytes.as_ptr(), bytes.len(), &mut out)
        };
        assert_eq!(status, ACPMUX_CLIENT_OK);
        // SAFETY: the library returned `len` readable bytes at `ptr`, freed below.
        let sid = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
        // SAFETY: `out` came from the library and is freed once.
        unsafe { acpmux_client_bytes_free(out) };
        String::from_utf8(sid).unwrap()
    }

    pub(super) fn want(&mut self, request: &Value) {
        self.request(acpmux_client_want, request);
    }

    pub(super) fn sends(&mut self) -> Vec<Vec<u8>> {
        std::iter::from_fn(|| Some(self.take(acpmux_client_take_send)).filter(|b| !b.is_empty()))
            .collect()
    }

    pub(super) fn changes(&mut self) -> Vec<Value> {
        std::iter::from_fn(|| Some(self.take(acpmux_client_next_change)).filter(|b| !b.is_empty()))
            .map(|bytes| serde_json::from_slice(&bytes).unwrap())
            .collect()
    }

    /// What `acpmux_client_received` consumed of `bytes`, once.
    pub(super) fn received(&mut self, bytes: &[u8]) -> usize {
        let mut consumed = 0;
        // SAFETY: owned handle; the slice is readable and `consumed` writable for this call.
        let status = unsafe {
            acpmux_client_received(self.handle, bytes.as_ptr(), bytes.len(), &mut consumed)
        };
        assert_eq!(status, ACPMUX_CLIENT_OK);
        consumed
    }

    /// Feeds `bytes` as a transport does, taking the changes each time the client holds some,
    /// in pieces of at most `chunk` bytes. Stops early when the client takes no more (a
    /// fallback): the bytes after it are not the client's.
    pub(super) fn feed(&mut self, bytes: &[u8], chunk: usize) -> Vec<Value> {
        let mut changes = Vec::new();
        let mut offset = 0;
        while offset < bytes.len() {
            let end = bytes.len().min(offset.saturating_add(chunk));
            let consumed = self.received(&bytes[offset..end]);
            let more = self.changes();
            if consumed == 0 && more.is_empty() {
                break;
            }
            offset += consumed;
            changes.extend(more);
        }
        changes.extend(self.changes());
        changes
    }
}

impl Drop for Ffi {
    fn drop(&mut self) {
        // SAFETY: the handle came from `acpmux_client_new` and is freed once.
        unsafe { acpmux_client_free(self.handle) };
    }
}

/// The daemon's end of one socket: the upgrade read by the v1 reader, then the list surface.
fn serve(v2: Arc<V2>, daemon_id: &'static str) -> (DuplexStream, tokio::task::JoinHandle<()>) {
    let (client, server) = tokio::io::duplex(1 << 20);
    let task = tokio::spawn(async move {
        let (rd, wr) = tokio::io::split(server);
        let (in_tx, _in_rx) = mpsc::channel(16);
        let (last, _last_rx) = oneshot::channel();
        let limits = Limits { line: MAX_LINE_BYTES, small: SMALL_LINE_BYTES };
        if let Some(upgrade) = read_lines(rd, in_tx, last, limits, Some(&v2)).await {
            let _ = upgrade.serve(wr, &v2, daemon_id.to_owned()).await;
        }
    });
    (client, task)
}

/// The v1 rows a change carries: a window's or a page's rows, or one summary or left row.
fn rows(change: &Value) -> Vec<&Value> {
    match change.get("rows").or_else(|| change.pointer("/page/rows")) {
        Some(Value::Array(rows)) => rows.iter().collect(),
        _ => change.get("summary").into_iter().collect(),
    }
}

/// Whether a change carries the row of `chat_id`, or its key (a gone row).
fn names(change: &Value, chat_id: &str) -> bool {
    change.get("chatId").and_then(Value::as_str) == Some(chat_id)
        || rows(change)
            .iter()
            .any(|row| row.get("sessionId").and_then(Value::as_str) == Some(chat_id))
}

fn kind(change: &Value) -> Option<&str> {
    change.get("kind").and_then(Value::as_str)
}

/// One client's connection: its handle, its socket, and every byte the daemon sent it.
pub(super) struct Run {
    pub(super) ffi: Ffi,
    socket: Option<(DuplexStream, tokio::task::JoinHandle<()>)>,
    pub(super) bytes: Vec<u8>,
    pub(super) sent: Vec<Vec<u8>>,
}

impl Run {
    pub(super) fn new() -> Self {
        Self { ffi: Ffi::new(), socket: None, bytes: Vec::new(), sent: Vec::new() }
    }

    pub(super) fn connect(&mut self, v2: Arc<V2>, daemon_id: &'static str) {
        self.socket = Some(serve(v2, daemon_id));
    }

    /// Ends the socket and waits for the daemon's side of it to end.
    pub(super) async fn drop_socket(&mut self) {
        if let Some((socket, task)) = self.socket.take() {
            drop(socket);
            tokio::time::timeout(STEP_WAIT, task).await.unwrap().unwrap();
        }
    }

    /// Writes what the client queued to the socket.
    async fn flush(&mut self) {
        let sends = self.ffi.sends();
        let (socket, _) = self.socket.as_mut().expect("a connected run");
        for send in sends {
            socket.write_all(&send).await.unwrap();
            self.sent.push(send);
        }
    }

    /// Reads and feeds until `done` holds for this step's changes, then until the daemon has
    /// been quiet for `quiet`. Returns the step's changes, in order.
    pub(super) async fn step(
        &mut self,
        quiet: Duration,
        done: impl Fn(&[Value]) -> bool,
    ) -> Vec<Value> {
        let mut changes = self.ffi.changes();
        let deadline = Instant::now() + STEP_WAIT;
        let mut buf = vec![0_u8; 64 << 10];
        loop {
            self.flush().await;
            let satisfied = done(&changes);
            let wait =
                if satisfied { quiet } else { deadline.saturating_duration_since(Instant::now()) };
            let (socket, _) = self.socket.as_mut().expect("a connected run");
            match tokio::time::timeout(wait, socket.read(&mut buf)).await {
                Ok(Ok(0)) => {
                    assert!(satisfied, "the daemon ended the socket; changes so far: {changes:?}");
                    break;
                }
                Ok(Ok(n)) => {
                    self.bytes.extend_from_slice(&buf[..n]);
                    changes.extend(self.ffi.feed(&buf[..n], n));
                }
                Ok(Err(error)) => panic!("socket read failed: {error}"),
                Err(_) => {
                    assert!(satisfied, "the step timed out; changes so far: {changes:?}");
                    break;
                }
            }
        }
        changes
    }
}

/// The sidebar's first read is done: the mirror is whole and every wanted row has arrived.
fn connected_whole(wanted: &[Value]) -> impl Fn(&[Value]) -> bool + '_ {
    move |changes: &[Value]| {
        let Some(whole) = changes.iter().position(|change| kind(change) == Some("whole")) else {
            return false;
        };
        wanted.iter().all(|key| {
            let id = key["chatId"].as_str().unwrap_or_default();
            changes[whole..].iter().any(|change| names(change, id))
        })
    }
}
