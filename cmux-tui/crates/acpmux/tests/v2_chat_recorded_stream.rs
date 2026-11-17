//! The recorded chat streams the pane's host and the page's store replay (the design doc's row 6,
//! "The client contract"). A fixed script of a daemon's bytes, built with the client's own wire
//! encoders, goes through the client's C entry points as the Swift wrapper calls them; the bytes
//! go to one file and the changes `acpmux_client_next_change` gave for them to another.
//!
//! Each `.jsonl` line is one of: `{"surfaces": [...]}`, the handle's (first line);
//! `{"step": name}`; a call the client made before the step's bytes (`{"call": "subscribe_chat"
//! | "chat_page" | "chat_blob" | "unsubscribe", "request": ..., "reply"?: ...}`, `{"call":
//! "connected" | "disconnected"}`); `{"feed": [start, end]}`, the step's daemon bytes in the
//! `.bytes` file; and a JSON string, one change exactly as the core gave it, in order (a blob
//! change is its JSON, a newline, then the text). A reader that wants only the changes takes the
//! string lines. Sends are not recorded: credit follows when changes are taken, so other pieces
//! send other frames; the changes are the same in every piece size.
//!
//! The test fails when a committed file differs from the run; `ACPMUX_CHAT_STREAM_BLESS=1`
//! rewrites them (or names a directory to write them to instead).

use acpmux_book::blobs::{Blobs, Body};
use acpmux_book::row::RowKind;
use acpmux_book::translate::{self, Change, Harness};
use acpmux_client::ffi::{
    ACPMUX_CLIENT_ABI_VERSION, ACPMUX_CLIENT_OK, Bytes, acpmux_client_abi_version,
    acpmux_client_bytes_free, acpmux_client_chat_blob, acpmux_client_chat_page,
    acpmux_client_connected, acpmux_client_disconnected, acpmux_client_free,
    acpmux_client_new_with_surfaces, acpmux_client_next_change, acpmux_client_received,
    acpmux_client_subscribe_chat, acpmux_client_take_send, acpmux_client_unsubscribe,
};
use acpmux_client::wire::{
    BlobHead, ChatDelta, ChatOp, ChatPageResult, ChatWindow, Frame, FrameKind, HelloReply, Limits,
    OpenRow, QueueHead, QueueItem, RawJson, ReplayMark, blob_frame,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::c_void;
use std::path::PathBuf;

const BLESS: &str = "ACPMUX_CHAT_STREAM_BLESS";
/// Both streams' files together stay under this.
const MAX_FIXTURE_BYTES: usize = 256 << 10;
/// The page's name for the one chat sub, in the `<prefix>.<n>` shape the host takes.
const SID: &str = "rows.1";
const CHAT: &str = "chat-a";

fn fixtures_dir() -> PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Tests/Fixtures/AgentChatStream")
}

/// One client handle driven through the C entry points, as the Swift wrapper drives it.
struct Ffi {
    handle: *mut c_void,
}

impl Ffi {
    fn new(surfaces: &Value) -> Self {
        assert_eq!(acpmux_client_abi_version(), ACPMUX_CLIENT_ABI_VERSION);
        let bytes = serde_json::to_vec(surfaces).unwrap();
        // SAFETY: the slice is readable for this call.
        let handle = unsafe { acpmux_client_new_with_surfaces(bytes.as_ptr(), bytes.len()) };
        assert!(!handle.is_null());
        Self { handle }
    }

    fn take(&mut self, call: unsafe extern "C" fn(*mut c_void, *mut Bytes) -> i32) -> Vec<u8> {
        let mut out = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: the handle is owned by `self`, and `&mut self` serializes calls.
        assert_eq!(unsafe { call(self.handle, &mut out) }, ACPMUX_CLIENT_OK);
        Self::own(out)
    }

    fn own(out: Bytes) -> Vec<u8> {
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

    /// A request call; `answers` for the calls that give bytes back (`{sid}`, `{id}`).
    fn request(&mut self, name: &str, request: &Value) -> Option<Value> {
        let bytes = serde_json::to_vec(request).unwrap();
        let (ptr, len) = (bytes.as_ptr(), bytes.len());
        let mut out = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: owned handle; the slice is readable and `out` writable for this call.
        let (status, answers) = unsafe {
            match name {
                "subscribe_chat" => {
                    (acpmux_client_subscribe_chat(self.handle, ptr, len, &mut out), true)
                }
                "chat_blob" => (acpmux_client_chat_blob(self.handle, ptr, len, &mut out), true),
                "chat_page" => (acpmux_client_chat_page(self.handle, ptr, len), false),
                "unsubscribe" => (acpmux_client_unsubscribe(self.handle, ptr, len), false),
                other => panic!("no such call: {other}"),
            }
        };
        assert_eq!(status, ACPMUX_CLIENT_OK, "{name} {request}");
        answers.then(|| serde_json::from_slice(&Self::own(out)).unwrap())
    }

    fn connected(&mut self) {
        // SAFETY: owned handle, serialized by `&mut self`.
        assert_eq!(unsafe { acpmux_client_connected(self.handle) }, ACPMUX_CLIENT_OK);
    }

    fn disconnected(&mut self) {
        // SAFETY: owned handle, serialized by `&mut self`.
        assert_eq!(unsafe { acpmux_client_disconnected(self.handle) }, ACPMUX_CLIENT_OK);
    }

    fn sends(&mut self) -> Vec<Vec<u8>> {
        std::iter::from_fn(|| Some(self.take(acpmux_client_take_send)).filter(|b| !b.is_empty()))
            .collect()
    }

    fn changes(&mut self) -> Vec<String> {
        std::iter::from_fn(|| Some(self.take(acpmux_client_next_change)).filter(|b| !b.is_empty()))
            .map(|bytes| String::from_utf8(bytes).unwrap())
            .collect()
    }

    fn received(&mut self, bytes: &[u8]) -> usize {
        let mut consumed = 0;
        // SAFETY: owned handle; the slice is readable and `consumed` writable for this call.
        let status = unsafe {
            acpmux_client_received(self.handle, bytes.as_ptr(), bytes.len(), &mut consumed)
        };
        assert_eq!(status, ACPMUX_CLIENT_OK);
        consumed
    }

    /// Feeds `bytes` as a transport does, in pieces of at most `chunk` bytes, taking the changes
    /// each time the client holds some. Stops early when the client takes no more (a fallback):
    /// the bytes after it are not the client's.
    fn feed(&mut self, bytes: &[u8], chunk: usize) -> Vec<String> {
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
            self.sends();
        }
        changes.extend(self.changes());
        changes
    }
}

impl Drop for Ffi {
    fn drop(&mut self) {
        // SAFETY: the handle came from `acpmux_client_new_with_surfaces` and is freed once.
        unsafe { acpmux_client_free(self.handle) };
    }
}

/// One step of a run: the calls before it, its daemon bytes, and the changes the client gave.
struct Step {
    name: &'static str,
    calls: Vec<Value>,
    range: (usize, usize),
    changes: Vec<String>,
}

fn apply(ffi: &mut Ffi, call: &Value) -> Option<Value> {
    match call["call"].as_str() {
        Some("connected") => ffi.connected(),
        Some("disconnected") => ffi.disconnected(),
        Some(name) => return ffi.request(name, &call["request"]),
        None => panic!("no call: {call}"),
    }
    None
}

/// A run, step by step. The daemon's bytes for a step are written after its calls, so an upgrade
/// reply names the request the client sent.
struct Recorder {
    surfaces: Value,
    ffi: Ffi,
    bytes: Vec<u8>,
    sent: Vec<Vec<u8>>,
    calls: Vec<Value>,
    steps: Vec<Step>,
}

impl Recorder {
    fn new(surfaces: Value) -> Self {
        let ffi = Ffi::new(&surfaces);
        Self {
            surfaces,
            ffi,
            bytes: Vec::new(),
            sent: Vec::new(),
            calls: Vec::new(),
            steps: Vec::new(),
        }
    }

    fn call(&mut self, call: Value) -> Option<Value> {
        let reply = apply(&mut self.ffi, &call);
        self.sent.extend(self.ffi.sends());
        let mut call = call;
        if let Some(reply) = &reply {
            call["reply"] = reply.clone();
        }
        self.calls.push(call);
        reply
    }

    /// The id of the last `_acpmux/v2` request sent, which the daemon's reply names.
    fn upgrade_id(&self) -> Value {
        self.sent
            .iter()
            .rev()
            .filter_map(|send| serde_json::from_slice::<Value>(send).ok())
            .find(|request| request["method"] == "_acpmux/v2")
            .map(|request| request["id"].clone())
            .expect("an upgrade request was sent")
    }

    fn step(&mut self, name: &'static str, daemon: Vec<u8>) -> &Step {
        // The step names are the fixture's index.
        assert!(self.steps.iter().all(|step| step.name != name), "step {name} twice");
        let start = self.bytes.len();
        self.bytes.extend_from_slice(&daemon);
        let mut changes = self.ffi.changes();
        changes.extend(self.ffi.feed(&daemon, usize::MAX));
        self.sent.extend(self.ffi.sends());
        self.steps.push(Step {
            name,
            calls: std::mem::take(&mut self.calls),
            range: (start, self.bytes.len()),
            changes,
        });
        self.steps.last().unwrap()
    }

    fn jsonl(&self) -> Vec<u8> {
        let mut lines = vec![json!({"surfaces": self.surfaces})];
        for step in &self.steps {
            lines.push(json!({"step": step.name}));
            lines.extend(step.calls.iter().cloned());
            lines.push(json!({"feed": [step.range.0, step.range.1]}));
            lines.extend(step.changes.iter().map(|change| Value::String(change.clone())));
        }
        let mut out = Vec::new();
        for line in lines {
            out.extend(serde_json::to_vec(&line).unwrap());
            out.push(b'\n');
        }
        out
    }

    /// The same calls and bytes through a new handle, the bytes in pieces of at most `chunk`.
    fn replay(&self, chunk: usize) {
        let mut ffi = Ffi::new(&self.surfaces);
        for step in &self.steps {
            for call in &step.calls {
                let reply = apply(&mut ffi, call);
                assert_eq!(reply.as_ref(), call.get("reply"), "step {}: {call}", step.name);
            }
            ffi.sends();
            let mut changes = ffi.changes();
            changes.extend(ffi.feed(&self.bytes[step.range.0..step.range.1], chunk));
            ffi.sends();
            assert_eq!(changes, step.changes, "step {} in pieces of {chunk} bytes", step.name);
        }
    }
}

/// Fails when the committed file differs from this run's; under the bless variable, writes it.
fn check_or_bless(name: &str, actual: &[u8]) {
    if let Some(dir) = std::env::var_os(BLESS) {
        let dir = if dir == "1" { fixtures_dir() } else { PathBuf::from(dir) };
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(name), actual).unwrap();
        return;
    }
    let path = fixtures_dir().join(name);
    let committed = std::fs::read(&path).unwrap_or_else(|error| {
        panic!("{}: {error}; record it with {BLESS}=1", path.display());
    });
    if committed != actual {
        let at = committed
            .iter()
            .zip(actual)
            .position(|(a, b)| a != b)
            .unwrap_or(committed.len().min(actual.len()));
        let around = |bytes: &[u8]| {
            let start = at.saturating_sub(80);
            String::from_utf8_lossy(&bytes[start..bytes.len().min(at + 80)]).into_owned()
        };
        panic!(
            "{name} differs from this run at byte {at} (committed {} bytes, recorded {}): \
             committed {:?}, recorded {:?}. If the change is meant, rerun with {BLESS}=1",
            committed.len(),
            actual.len(),
            around(&committed),
            around(actual),
        );
    }
}

fn upgrade_reply(id: &Value, surfaces: &Value) -> Vec<u8> {
    let reply = json!({"jsonrpc": "2.0", "id": id, "result": {
        "protocol": 2, "surfaces": surfaces, "upgrade": true,
    }});
    format!("{reply}\n").into_bytes()
}

fn hello() -> Vec<u8> {
    let reply = HelloReply { daemon_id: "fixture-daemon".into(), limits: Limits::default() };
    Frame::json(FrameKind::Hello, &reply).unwrap().encode()
}

fn raw(text: &str) -> RawJson {
    RawJson::from_bytes(text.as_bytes()).unwrap()
}

/// A settled row as the daemon stores it: its bytes are passed on as they are, escapes and all.
fn row(id: u64, rev: u32) -> RawJson {
    raw(&format!(
        r#"{{"id":{id},"rev":{rev},"kind":"assistant","body":{{"text":"row {id} r{rev}: caf\u00e9 \"quoted\" \u2713"}}}}"#
    ))
}

/// An open row: a turn still streaming its text.
fn open_row(id: u64, text: &str) -> RawJson {
    raw(&format!(
        r#"{{"id":{id},"rev":1,"kind":"assistant","open":true,"body":{{"text":"{text}"}}}}"#
    ))
}

fn prompt(id: &str, text: &str, at: u64) -> QueueItem {
    QueueItem { id: id.into(), text: text.into(), len: text.len() as u64, held: false, at }
}

fn window(
    cursor: u64,
    edition: u32,
    ids: std::ops::RangeInclusive<u64>,
    open: Vec<OpenRow>,
) -> Vec<u8> {
    let has_before = *ids.start() > 1;
    let window = ChatWindow {
        sid: SID.into(),
        cursor,
        edition,
        rows: ids.map(|id| row(id, 1)).collect(),
        has_before,
        has_after: false,
        open,
        queue: QueueHead { entries: vec![prompt("p1", "and then the tests", 1_000)], count: 1 },
        seen: Some(cursor),
        folds: Vec::new(),
        refused: Vec::new(),
    };
    Frame::json(FrameKind::Window, &window).unwrap().encode()
}

fn delta(replay: Option<ReplayMark>, ops: Vec<ChatOp>) -> Vec<u8> {
    Frame::json(FrameKind::Delta, &ChatDelta { sid: SID.into(), replay, ops }).unwrap().encode()
}

fn error(method: &str, code: &str) -> Vec<u8> {
    Frame::json(FrameKind::Error, &json!({"method": method, "sid": SID, "code": code}))
        .unwrap()
        .encode()
}

fn settled(seq: u64, id: u64) -> ChatOp {
    ChatOp::Row { seq, row: row(id, 1), body_len: None }
}

fn kinds(step: &Step) -> Vec<String> {
    step.changes
        .iter()
        .map(|change| {
            let head = change.split('\n').next().unwrap();
            serde_json::from_str::<Value>(head).unwrap()["kind"].as_str().unwrap().to_owned()
        })
        .collect()
}

/// The body of open row 30, as the daemon stores it, and the two ranges of it the script reads.
const OPEN_BODY: &str = r#"{"text":"streaming caf\u00e9 so far"}"#;

#[test]
fn the_chat_stream_is_recorded() {
    let surfaces = json!(["chat"]);
    let mut rec = Recorder::new(surfaces.clone());

    let request = json!({"sid": SID, "chat": CHAT});
    let reply = rec.call(json!({"call": "subscribe_chat", "request": request}));
    assert_eq!(reply, Some(json!({"sid": SID})), "the core takes the page's sid as it is");
    rec.call(json!({"call": "connected"}));
    let mut bytes = upgrade_reply(&rec.upgrade_id(), &surfaces);
    bytes.extend(hello());
    let step = rec.step("upgrade", bytes);
    assert!(step.changes.is_empty());

    let step = rec.step("not-ready", error("sub", "not_ready"));
    assert_eq!(kinds(step), ["chatError"]);
    let open = vec![OpenRow { row: open_row(11, "thinking"), body_len: None }];
    let step = rec.step("window", window(10, 1, 1..=10, open));
    assert_eq!(kinds(step), ["chatWindow"]);
    assert!(step.changes[0].contains(r#""replaces":true"#));

    // Each op: the open row settles, the next begins and streams, a settled row is patched, a
    // prompt is queued.
    let ops = vec![
        settled(11, 11),
        ChatOp::Row { seq: 11, row: open_row(12, "the next"), body_len: None },
        ChatOp::Text { seq: 11, row_id: 12, text: raw(r#"" turn \u2014 on""#) },
        ChatOp::Patch { seq: 12, row: row(4, 2) },
        ChatOp::Queue {
            seq: 12,
            entry: Some(prompt("p2", "then ship it", 2_000)),
            removed: None,
            count: 2,
            head: None,
        },
    ];
    let step = rec.step("ops", delta(None, ops));
    assert_eq!(kinds(step), ["chatOp"; 5]);

    // A drop and a resume: replay ops from the cursor to the resume's end.
    rec.call(json!({"call": "disconnected"}));
    rec.call(json!({"call": "connected"}));
    let mut bytes = upgrade_reply(&rec.upgrade_id(), &surfaces);
    bytes.extend(hello());
    bytes.extend(delta(Some(ReplayMark::Replay), vec![settled(13, 12), settled(14, 13)]));
    let state = ChatOp::Row { seq: 14, row: open_row(14, "after the drop"), body_len: None };
    bytes.extend(delta(Some(ReplayMark::End), vec![state]));
    let step = rec.step("resume", bytes);
    assert_eq!(kinds(step), ["chatOp", "chatOp", "chatOp", "chatResumeEnd"]);
    assert!(step.changes[..3].iter().all(|change| change.contains(r#""replay":true"#)));

    // A window in place of a resume, in the same edition: it adds to what the page holds.
    rec.call(json!({"call": "disconnected"}));
    rec.call(json!({"call": "connected"}));
    let mut bytes = upgrade_reply(&rec.upgrade_id(), &surfaces);
    bytes.extend(hello());
    bytes.extend(delta(Some(ReplayMark::Replay), vec![settled(15, 14)]));
    bytes.extend(window(40, 1, 31..=40, Vec::new()));
    let step = rec.step("window-same-edition", bytes);
    assert_eq!(kinds(step), ["chatOp", "chatResumeEnd", "chatWindow"]);
    assert!(step.changes[2].contains(r#""replaces":false"#));

    // And in another edition: it replaces.
    rec.call(json!({"call": "disconnected"}));
    rec.call(json!({"call": "connected"}));
    let mut bytes = upgrade_reply(&rec.upgrade_id(), &surfaces);
    bytes.extend(hello());
    // An open row whose body is past the window's budget: the row whole, its body left out.
    let open_30 = raw(r#"{"id":30,"rev":1,"kind":"assistant","open":true,"body":{}}"#);
    let open = vec![OpenRow { row: open_30, body_len: Some(OPEN_BODY.len() as u64) }];
    bytes.extend(window(30, 2, 21..=29, open));
    let step = rec.step("window-new-edition", bytes);
    assert_eq!(kinds(step), ["chatResumeEnd", "chatWindow"]);
    assert!(step.changes[1].contains(r#""replaces":true"#));

    rec.call(json!({"call": "chat_page", "request": {"sid": SID, "before": 21}}));
    let page = ChatPageResult {
        sid: SID.into(),
        edition: 2,
        rows: (18..=20).map(|id| row(id, 1)).collect(),
        has_before: true,
        has_after: true,
        refused: vec![19],
        turns: false,
    };
    let step = rec.step("page", Frame::json(FrameKind::Page, &page).unwrap().encode());
    assert_eq!(kinds(step), ["chatPage"]);

    rec.call(json!({"call": "chat_page", "request": {"sid": SID, "before": 18, "maxBytes": 4096}}));
    let step = rec.step("page-stale", error("page", "stale_edition"));
    assert_eq!(kinds(step), ["chatError"]);

    // A settled row's body, whole in one range.
    let reply = rec.call(json!({"call": "chat_blob", "request": {
        "sid": SID, "id": "blob.1", "rowId": 25, "len": 4096,
    }}));
    let id = reply.unwrap()["id"].as_str().unwrap().to_owned();
    assert_eq!(id, "blob.1", "the core takes the page's blob id as it is");
    let body = r#"{"text":"row 25 r1: caf\u00e9 \"quoted\" \u2713"}"#;
    let head = BlobHead {
        id,
        start: 0,
        len: body.len() as u64,
        total: body.len() as u64,
        next: None,
        open: false,
        generation: None,
        fixed: None,
    };
    let step = rec.step("blob-settled", blob_frame(&head, body.as_bytes()).unwrap().encode());
    assert_eq!(kinds(step), ["chatBlob"]);

    // The open row's body in two ranges; the first ends inside `\u00e9`, so the core gives the
    // bytes before it and names where the next range starts.
    let cut = OPEN_BODY.find("\\u00e9").unwrap() + 3;
    let reply = rec.call(json!({"call": "chat_blob", "request": {
        "sid": SID, "id": "blob.2", "rowId": 30, "len": cut,
    }}));
    let id = reply.unwrap()["id"].as_str().unwrap().to_owned();
    let open_head = |id: String, start: usize, len: usize| BlobHead {
        id,
        start: start as u64,
        len: len as u64,
        total: OPEN_BODY.len() as u64,
        next: None,
        open: true,
        generation: Some("0123456789abcdef".into()),
        fixed: Some(OPEN_BODY.len() as u64 - 2),
    };
    let first = blob_frame(&open_head(id, 0, cut), &OPEN_BODY.as_bytes()[..cut]).unwrap();
    let step = rec.step("blob-open-first", first.encode());
    assert_eq!(kinds(step), ["chatBlob"]);
    let next_start = OPEN_BODY.find("\\u00e9").unwrap();
    assert!(step.changes[0].contains(&format!(r#""nextStart":{next_start}"#)));
    let rest = OPEN_BODY.len() - next_start;
    let reply = rec.call(json!({"call": "chat_blob", "request": {
        "sid": SID, "id": "blob.3", "rowId": 30, "start": next_start, "len": rest,
    }}));
    let id = reply.unwrap()["id"].as_str().unwrap().to_owned();
    let second =
        blob_frame(&open_head(id, next_start, rest), &OPEN_BODY.as_bytes()[next_start..]).unwrap();
    let step = rec.step("blob-open-rest", second.encode());
    assert_eq!(kinds(step), ["chatBlob"]);

    // The daemon drops the sub; the core subscribes again from its cursor, and the window follows.
    let dropped = Frame::json(FrameKind::Dropped, &json!({"sid": SID, "cursor": 30})).unwrap();
    let mut bytes = dropped.encode();
    bytes.extend(window(31, 2, 22..=30, Vec::new()));
    let step = rec.step("dropped", bytes);
    assert_eq!(kinds(step), ["chatDropped", "chatResumeEnd", "chatWindow"]);

    // A page of turns: the group rows before the window, the newest two of three, as the
    // daemon's turns page reads them (`turn_heads`).
    let heads = turn_heads(3);
    let before = heads.iter().map(row_id).max().unwrap() + 1;
    let turns_page =
        json!({"call": "chat_page", "request": {"sid": SID, "before": before, "turns": true}});
    rec.call(turns_page.clone());
    let page = ChatPageResult {
        sid: SID.into(),
        edition: 2,
        rows: heads[1..].to_vec(),
        has_before: true,
        has_after: false,
        refused: Vec::new(),
        turns: true,
    };
    let step = rec.step("page-turns", Frame::json(FrameKind::Page, &page).unwrap().encode());
    assert_eq!(kinds(step), ["chatPage"]);
    assert!(step.changes[0].contains(r#""turns":true"#));

    // The same page answered by a daemon from before `turns`: an ordinary page, not turns.
    rec.call(turns_page);
    let page = ChatPageResult { turns: false, ..page };
    let step =
        rec.step("page-turns-unsupported", Frame::json(FrameKind::Page, &page).unwrap().encode());
    assert_eq!(kinds(step), ["chatError"]);
    assert!(step.changes[0].contains(r#""code":"turns_unsupported""#));

    // A `sub` error but `not_ready` ends the sub: the page runs v1 for the chat.
    let step = rec.step("sub-error", error("sub", "source_failed"));
    assert_eq!(kinds(step), ["chatError"]);
    // Its later frames are another sid's: skipped, no change.
    let step = rec.step("after-end", delta(None, vec![settled(32, 31)]));
    assert!(step.changes.is_empty());

    for chunk in [usize::MAX, 7, 1] {
        rec.replay(chunk);
    }
    let lines = rec.jsonl();
    check_or_bless("chat.bytes", &rec.bytes);
    check_or_bless("chat.jsonl", &lines);

    let fallback = fallback_stream();
    let total = rec.bytes.len() + lines.len() + fallback.bytes.len() + fallback.jsonl().len();
    assert!(total < MAX_FIXTURE_BYTES, "{total} bytes");
}

/// The group rows (turn heads) of `turns` settled tool turns, built as the daemon builds the rows
/// its turns page reads (`acpmux-core`'s `settle_or_open`): each harness line through the book's
/// translator, a row's fields merged into its body, the body written by `Blobs::settle`, and the
/// row encoded by `Row::encode`. The lines have the shape of `acpmux-core`'s `tool_turn` (a
/// prompt, a tool call and its result, a reply, the turn's end).
fn turn_heads(turns: u64) -> Vec<RawJson> {
    let dir = tempfile::tempdir().unwrap();
    let mut blobs = Blobs::open(dir.path()).unwrap();
    let mut state = translate::State::default();
    let mut fields: BTreeMap<u64, BTreeMap<String, String>> = BTreeMap::new();
    let mut bodied = BTreeSet::new();
    let mut heads = Vec::new();
    let mut place = 0;
    for line in (1..=turns).flat_map(tool_turn) {
        let span = line.len() as u64 + 1;
        let ops = translate::translate(&mut state, Harness::V1, place, span, line.as_bytes());
        place += span;
        for op in ops.unwrap() {
            let row = match op.change {
                Change::Row(row) => row,
                Change::Body { id, .. } => {
                    bodied.insert(id);
                    continue;
                }
                _ => continue,
            };
            fields.entry(row.id).or_default().extend(row.fields.clone());
            if row.kind != RowKind::Group || row.open {
                continue;
            }
            assert!(!bodied.contains(&row.id), "a group row's body is its fields alone");
            let mut body = Body::new(row.id).unwrap();
            for (key, value) in fields.remove(&row.id).unwrap() {
                blobs.set(&mut body, &key, &value, false).unwrap();
            }
            let text = blobs.settle(&body).unwrap().expect("a group row's body is inline");
            let mut encoded = Vec::new();
            row.as_row(std::str::from_utf8(&text).unwrap()).encode(None, &mut encoded).unwrap();
            heads.push(RawJson::from_bytes(&encoded).unwrap());
        }
    }
    assert_eq!(heads.len(), turns as usize, "one group row a settled turn");
    heads
}

fn row_id(row: &RawJson) -> u64 {
    serde_json::from_str::<Value>(row.0.get()).unwrap()["id"].as_u64().unwrap()
}

/// One settled turn with a tool call, as a v1 harness log has it.
fn tool_turn(n: u64) -> Vec<String> {
    let seq = n * 10;
    let line = |seq: u64, dir: &str, kind: &str, msg: Value| {
        json!({"seq": seq, "at": seq * 1000, "dir": dir, "kind": kind, "msg": msg}).to_string()
    };
    let update = |seq: u64, kind: &str, update: Value| {
        line(seq, "in", kind, json!({"method": "session/update", "params": {"update": update}}))
    };
    let (turn, prompt, call) = (format!("t{n}"), format!("p{n}"), format!("c{n}"));
    vec![
        line(
            seq + 1,
            "mux",
            "user_message",
            json!({"promptId": prompt, "turnId": turn, "text": format!("prompt {n}")}),
        ),
        line(seq + 2, "mux", "turn_started", json!({"turnId": turn, "promptId": prompt})),
        update(
            seq + 3,
            "tool_call",
            json!({"sessionUpdate": "tool_call", "toolCallId": call,
            "title": "Read a.rs", "kind": "read", "status": "pending"}),
        ),
        update(
            seq + 4,
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update",
            "toolCallId": call, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "fn a() {}"}}]}),
        ),
        update(
            seq + 5,
            "agent_message_chunk",
            json!({"sessionUpdate": "agent_message_chunk",
            "messageId": format!("m{n}"), "content": {"type": "text", "text": format!("reply {n}")}}),
        ),
        line(seq + 6, "mux", "turn_result", json!({"turnId": turn, "status": "completed"})),
    ]
}

/// A daemon whose upgrade is a v1 request it does not know: the client gives one fallback
/// change and reads no more. Before it, each open chat sub ends with its own `surface_off`, in
/// order of its sid, which the page takes as "run v1 for this chat".
fn fallback_stream() -> Recorder {
    let surfaces = json!(["chat"]);
    let mut rec = Recorder::new(surfaces);
    rec.call(json!({"call": "subscribe_chat", "request": {"sid": SID, "chat": CHAT}}));
    rec.call(json!({"call": "subscribe_chat", "request": {"sid": "rows.2", "chat": "chat-b"}}));
    rec.call(json!({"call": "connected"}));
    let reply = json!({"jsonrpc": "2.0", "id": rec.upgrade_id(), "error": {
        "code": -32601, "message": "Method not found",
    }});
    // The reply alone: the fallback change carries what came after it in the same read, which
    // depends on the piece size.
    let step = rec.step("upgrade", format!("{reply}\n").into_bytes());
    assert_eq!(kinds(step), ["chatError", "chatError", "fallback"]);
    assert!(step.changes[..2].iter().all(|change| change.contains(r#""code":"surface_off""#)));
    for chunk in [usize::MAX, 7, 1] {
        rec.replay(chunk);
    }
    rec
}

#[test]
fn the_v1_answer_stream_is_recorded() {
    let rec = fallback_stream();
    check_or_bless("fallback.bytes", &rec.bytes);
    check_or_bless("fallback.jsonl", &rec.jsonl());
}
