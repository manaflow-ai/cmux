//! [`HostRelay`]: the real [`ControlPlane`], one JSON-lines channel to the
//! host that supervises this server.
//!
//! TODO(APP-R1): replace this channel with the app platform's provider
//! channel and its credential relay op (`op:cmux.credential.relay` in the
//! manifest, not defined yet). Until then the shape is:
//!
//! - host -> server: `{"type":"op","id","op","args","origin","idempotency_key"}`
//! - server -> host: `{"type":"result","id","ok","result"|"error"}`
//! - server -> host: `{"type":"event","event":"cloud.machine.watch","data"}`
//!   with `data` = `{"type":"upsert","revision","machine"}` or
//!   `{"type":"removed","revision","id"}`; `{"type":"event","event":"cloud.link.changed",...}`;
//!   `{"type":"event","event":"cloud.port.changed","machine","kind":"forward"|"browser",
//!   "port"?,"host","localPort","generation","state":"down","reason"}` when a link change
//!   closed a forward or a browser route. Link and port lines go out as soon as the
//!   loop is free (with no op after the change); while an op runs (a relay call, or a
//!   connect waiting for the link's ready line) they wait for the end of that op.
//! - server -> host: `{"type":"relay.op","id","op","params","idempotency_key"?,"origin"?}`: one
//!   `cmux.wire/1` op. The host sends `{op, params, idempotency_key, origin}` to
//!   `POST /v1/read` (no key) or `POST /v1/ops` with the install token and folds the
//!   answer into `{"type":"relay.result","id","ok":true,"value","revision"?,"replayed"?}`
//!   or `{"type":"relay.result","id","ok":false,"error":{"code","message","retryable","details"?}}`
//!   (a `/v1/ops` `OpResponse` as is; a non-200 HTTP answer's `{code, message}` body
//!   as the error, retryable on 503).
//! - host -> server, for any relay call: `{"type":"relay.error","id",
//!   "code":"not_signed_in"|"unavailable","message"}`
//! - server -> host: `{"type":"relay.session","id"}`; host -> server:
//!   `{"type":"relay.session","id","signed_in","team"}`
//! - host-only ops (`cmux.host.link.get`): `t` frames, see [`super::host`].
//!   A host frame that arrives during a relay call is kept and applied
//!   after the call, on the loop thread: a `host.event` replaces a waiting
//!   one of the same op, at most 64 events (distinct ops) and 64 answers
//!   are kept, other frames are dropped (see `HostRelay::hold`).
//!
//! The host adds the install token when it sends the call (never a Stack
//! bearer, contract 1.1 and state-placement 5.5); no line in either
//! direction carries a credential. The host answers every relay request,
//! with `relay.error` when its own HTTP deadline passes; the server has no
//! timer of its own. Op lines that arrive while a relay call
//! waits are queued and served in order after it, at most
//! [`RELAY_QUEUE_LINES`]; one more gets `cmux.cloud.relay_busy` (retryable)
//! at once. A `host.event` replaces a waiting one of the same op.
//!
//! In the serve loop ([`super::serve`]) a reader thread reads the host
//! lines into one inbox that link processes also wake, so the loop blocks
//! on one channel and sends a link change at once, with no op after it.

use super::control_plane::{
    ControlPlane, RelayError, SessionStatus, WireCall, WireError, WireReply, WireResult,
};
use super::error::{CloudError, codes};
use serde_json::{Value, json};
use std::collections::{BTreeSet, VecDeque};
use std::io::{BufRead, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};

/// One item of the serve loop's inbox.
enum Inbound {
    /// A host line (or the end of input, or a read error) from the reader thread.
    Host(std::io::Result<Option<Value>>),
    /// Link or forward state changed: drain the events.
    Wake,
}

/// What the serve loop does next.
pub(crate) enum Next {
    Message(Value),
    /// Drain the link and forward events; no host message came.
    Wake,
}

/// Op lines a relay call keeps waiting while it waits for its answer, the
/// same bound as the inbox. One more op line is answered at once with
/// `cmux.cloud.relay_busy` (retryable); it never waits and is never dropped
/// without an answer.
pub const RELAY_QUEUE_LINES: usize = 64;

/// Host lines the inbox holds before the reader thread waits (the stdin
/// pipe then pushes back on the host, as before the reader thread).
const INBOX_LINES: usize = 64;

/// Wakes the serve loop. Wakes coalesce: at most one is in the inbox until
/// the loop takes the events ([`Waker::taken`]), so a busy link never grows
/// the inbox.
#[derive(Clone)]
pub(crate) struct Waker {
    pending: Arc<AtomicBool>,
    inbox: SyncSender<Inbound>,
}

impl Waker {
    /// Called after an event was queued, on the thread that queued it.
    /// Never blocks: a full inbox holds host lines, and the loop takes the
    /// events after each of them anyway (`pending` stays set until then).
    pub(crate) fn wake(&self) {
        if !self.pending.swap(true, Ordering::AcqRel) {
            match self.inbox.try_send(Inbound::Wake) {
                // Full: the loop drains after the next host line. Closed:
                // the loop ended; nothing waits for the wake.
                Ok(()) | Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {}
            }
        }
    }

    /// The loop calls this BEFORE it takes the events: an event queued after
    /// this sends a new wake, so none is left behind. A swap (not a store)
    /// so this read synchronizes with the sender's release.
    pub(crate) fn taken(&self) {
        self.pending.swap(false, Ordering::AcqRel);
    }
}

/// Sends a last read error if the reader thread ends by a panic, so the
/// loop never waits on an inbox whose other senders (the wakers) stay open.
struct ReaderGuard {
    inbox: SyncSender<Inbound>,
    done: bool,
}

impl Drop for ReaderGuard {
    fn drop(&mut self) {
        if !self.done {
            let error = std::io::Error::other("the host reader thread stopped");
            let _ = self.inbox.send(Inbound::Host(Err(error)));
        }
    }
}

enum Input<R> {
    /// Read on the caller's thread (tests and direct use).
    Direct(R),
    /// The serve loop's inbox: host lines and wakes, in arrival order.
    Inbox(Receiver<Inbound>),
}

pub struct HostRelay<R, W> {
    input: Input<R>,
    writer: W,
    next_id: u64,
    queued: VecDeque<Value>,
    /// Lines in `queued` that get a result line (not host frames).
    waiting_ops: usize,
    /// `host.result` and `host.error` frames in `queued`.
    host_answers: usize,
    /// `host.event` frames in `queued` (one per op).
    host_events: usize,
    /// `team.event` lines in `queued` (they get no result line).
    team_events: usize,
    /// Frame lines (`data`, `credit`, `end`) in `queued`.
    frame_lines: usize,
    /// Channels with a [`FRAME_OVERFLOW`] marker in `queued`.
    frame_overflows: BTreeSet<String>,
}

/// Team wire events a relay call keeps waiting. They are kept in order and
/// never answered; one more is dropped (the projection compares revisions,
/// and the next listing repairs a dropped change).
const TEAM_EVENT_LINES: usize = 256;

/// Frame lines a relay call keeps waiting (all frame links together).
const FRAME_LINES: usize = 4096;

/// Channels whose frames overflowed during a relay call, at most (the
/// host's link bound per app).
const FRAME_OVERFLOWS: usize = 64;

/// The internal line that ends a frame link whose lines overflowed during
/// a relay call (never sent by the host; the serve loop handles it).
pub(crate) const FRAME_OVERFLOW: &str = "cmux.cloud.internal.frame_overflow";

impl<R: BufRead, W: Write> HostRelay<R, W> {
    pub fn new(reader: R, writer: W) -> Self {
        Self {
            input: Input::Direct(reader),
            writer,
            next_id: 0,
            queued: VecDeque::new(),
            waiting_ops: 0,
            host_answers: 0,
            host_events: 0,
            team_events: 0,
            frame_lines: 0,
            frame_overflows: BTreeSet::new(),
        }
    }

    /// The next host message that is not a relay answer: queued ones first.
    /// `None` at end of input. Wakes are skipped (only the serve loop takes them).
    pub fn next_message(&mut self) -> std::io::Result<Option<Value>> {
        if let Some(m) = self.pop_queued() {
            return Ok(Some(m));
        }
        self.read_line()
    }

    /// The serve loop's next step: a queued or new host message, or a wake.
    /// `None` at end of input.
    pub(crate) fn next_step(&mut self) -> std::io::Result<Option<Next>> {
        if let Some(m) = self.pop_queued() {
            return Ok(Some(Next::Message(m)));
        }
        match &mut self.input {
            Input::Direct(reader) => Ok(read_json_line(reader)?.map(Next::Message)),
            Input::Inbox(inbox) => match inbox.recv() {
                Ok(Inbound::Host(line)) => Ok(line?.map(Next::Message)),
                Ok(Inbound::Wake) => Ok(Some(Next::Wake)),
                // The reader thread ended without an end-of-input item.
                Err(_) => Ok(None),
            },
        }
    }

    /// The oldest kept line, with the counts kept in step.
    fn pop_queued(&mut self) -> Option<Value> {
        let m = self.queued.pop_front()?;
        match m["t"].as_str() {
            Some("host.result" | "host.error") => self.host_answers -= 1,
            Some("host.event") => self.host_events -= 1,
            _ if super::host::is_host_frame(&m) => {}
            _ if crate::connector::is_frame_line(&m) => self.frame_lines -= 1,
            _ if m["type"] == FRAME_OVERFLOW => {
                self.frame_overflows.remove(m["channel"].as_str().unwrap_or_default());
            }
            _ if m["type"] == "team.event" => self.team_events -= 1,
            _ => self.waiting_ops -= 1,
        }
        Some(m)
    }

    /// Writes one JSON line to the host.
    pub fn send(&mut self, message: &Value) -> std::io::Result<()> {
        serde_json::to_writer(&mut self.writer, message)?;
        self.writer.write_all(b"\n")?;
        self.writer.flush()
    }

    /// The next host line. In the inbox, a wake that arrives during a relay
    /// call is dropped: the loop takes every event after each op anyway
    /// (and clears the pending flag first, so later events wake it again).
    fn read_line(&mut self) -> std::io::Result<Option<Value>> {
        match &mut self.input {
            Input::Direct(reader) => read_json_line(reader),
            Input::Inbox(inbox) => loop {
                match inbox.recv() {
                    Ok(Inbound::Host(line)) => return line,
                    Ok(Inbound::Wake) => {}
                    Err(_) => return Ok(None),
                }
            },
        }
    }

    fn exchange(&mut self, mut request: Value) -> Result<Value, RelayError> {
        self.next_id += 1;
        let id = format!("r{}", self.next_id);
        request["id"] = json!(id);
        let kind = request["type"].clone();
        self.send(&request).map_err(|e| RelayError::Unavailable(e.to_string()))?;
        loop {
            let message = self
                .read_line()
                .map_err(|e| RelayError::Unavailable(e.to_string()))?
                .ok_or_else(|| RelayError::Unavailable("the host closed the channel".into()))?;
            let is_answer = message["type"].as_str().is_some_and(|t| t.starts_with("relay."));
            if !is_answer {
                self.hold(message).map_err(|e| RelayError::Unavailable(e.to_string()))?;
                continue;
            }
            if message["id"] != json!(id) {
                // An answer to no call that is waiting: never apply it to this one.
                continue;
            }
            if message["type"] == "relay.error" {
                return Err(match message["code"].as_str() {
                    Some("not_signed_in") => RelayError::NotSignedIn,
                    _ => RelayError::Unavailable(
                        message["message"].as_str().unwrap_or("relay error").to_owned(),
                    ),
                });
            }
            let expected = match kind.as_str() {
                Some("relay.session") => "relay.session",
                _ => "relay.result",
            };
            if message["type"] != expected {
                return Err(RelayError::Unavailable("unexpected relay answer".into()));
            }
            return Ok(message);
        }
    }
}

impl<R: BufRead, W: Write> HostRelay<R, W> {
    /// Keeps a line that came during a relay call for after it. Host frames
    /// are answers and events, never op lines: a `host.event` replaces the
    /// waiting one of the same op in place (only the newest counts), at most
    /// [`RELAY_QUEUE_LINES`] host answers are kept (the server has far fewer
    /// waiting), and other host frames are dropped. Every other line gets a
    /// result line from the loop, so at most [`RELAY_QUEUE_LINES`] of them
    /// wait; one more is answered now with the retryable
    /// `cmux.cloud.relay_busy`. When that write fails the channel is dead,
    /// and the call that waits fails as `relay_unavailable`.
    fn hold(&mut self, message: Value) -> std::io::Result<()> {
        if super::host::is_host_frame(&message) {
            match message["t"].as_str() {
                Some("host.event") => {
                    let op = message["op"].clone();
                    // A frame link close names its channel: only the same
                    // channel's close is the same event.
                    let data = (op == crate::connector::frames::CONNECTOR_CLOSE)
                        .then(|| message["data"].clone());
                    let same = |m: &Value| {
                        m["t"] == "host.event"
                            && m["op"] == op
                            && data.as_ref().is_none_or(|d| &m["data"] == d)
                    };
                    // In place: the newest event keeps the older one's turn.
                    if let Some(waiting) = self.queued.iter_mut().find(|m| same(m)) {
                        *waiting = message;
                    } else if self.host_events < RELAY_QUEUE_LINES {
                        self.host_events += 1;
                        self.queued.push_back(message);
                    } else {
                        eprintln!("cmux-cloud: dropped a host event that came during a relay call");
                    }
                }
                Some("host.result" | "host.error") if self.host_answers < RELAY_QUEUE_LINES => {
                    self.host_answers += 1;
                    self.queued.push_back(message);
                }
                // More host answers than the server ever has waiting, or a
                // frame type the server does not know: the loop would drop
                // it anyway.
                _ => eprintln!("cmux-cloud: dropped a host frame that came during a relay call"),
            }
            return Ok(());
        }
        if crate::connector::is_frame_line(&message) {
            // The host sends data only inside the credit this server
            // granted, so these stay within the windows; past the bound a
            // line is dropped, and the pump ends its channel (gap).
            if self.frame_lines < FRAME_LINES {
                self.frame_lines += 1;
                self.queued.push_back(message);
                return Ok(());
            }
            // Past the bound a dropped line would break the channel's
            // offsets or credit: the channel ends instead (one marker per
            // channel; its later lines find no link and are dropped).
            let channel = message["channel"].as_str().unwrap_or_default().to_owned();
            if self.frame_overflows.len() < FRAME_OVERFLOWS && self.frame_overflows.insert(channel.clone()) {
                self.queued.push_back(json!({ "type": FRAME_OVERFLOW, "channel": channel }));
            } else {
                eprintln!("cmux-cloud: dropped a frame line that came during a relay call");
            }
            return Ok(());
        }
        if message["type"] == "team.event" {
            if self.team_events < TEAM_EVENT_LINES {
                self.team_events += 1;
                self.queued.push_back(message);
            } else {
                eprintln!("cmux-cloud: dropped a team event that came during a relay call");
            }
            return Ok(());
        }
        if self.waiting_ops < RELAY_QUEUE_LINES {
            self.waiting_ops += 1;
            self.queued.push_back(message);
            return Ok(());
        }
        let error = CloudError {
            retryable: true,
            ..CloudError::new(
                codes::RELAY_BUSY,
                "cmux Cloud is busy with other requests: try again",
            )
        };
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        self.send(&json!({ "type": "result", "id": id, "ok": false, "error": error }))
    }
}

impl<R: BufRead + Send + 'static, W: Write> HostRelay<R, W> {
    /// Moves the reader to its own thread, which sends each host line to
    /// the inbox, and returns the waker that link events use. The thread
    /// ends at end of input (or when the loop is gone). Called once.
    pub(crate) fn into_inbox(mut self) -> std::io::Result<(Self, Waker)> {
        if matches!(self.input, Input::Inbox(_)) {
            return Err(std::io::Error::other("the host reader thread already runs"));
        }
        let (sender, inbox) = sync_channel(INBOX_LINES);
        let waker = Waker { pending: Arc::new(AtomicBool::new(false)), inbox: sender.clone() };
        let Input::Direct(mut reader) = std::mem::replace(&mut self.input, Input::Inbox(inbox))
        else {
            unreachable!("checked above");
        };
        std::thread::Builder::new().name("cmux-cloud-host-reader".into()).spawn(move || {
            let mut guard = ReaderGuard { inbox: sender, done: false };
            loop {
                let line = read_json_line(&mut reader);
                let more = matches!(line, Ok(Some(_)));
                // Each sent item ends the wait of the loop: the end of input
                // and a read error are sent too, then the thread ends.
                if guard.inbox.send(Inbound::Host(line)).is_err() || !more {
                    break;
                }
            }
            guard.done = true;
        })?;
        Ok((self, waker))
    }
}

/// One JSON line from `reader`; blank lines are skipped. A line that is
/// not JSON (or not UTF-8) is answered as invalid; it never stops the server.
fn read_json_line<R: BufRead>(reader: &mut R) -> std::io::Result<Option<Value>> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(None);
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        return match serde_json::from_slice(&line) {
            Ok(v) => Ok(Some(v)),
            Err(e) => Ok(Some(json!({ "type": "invalid", "error": e.to_string() }))),
        };
    }
}

impl<R: BufRead, W: Write> ControlPlane for HostRelay<R, W> {
    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        let mut request = serde_json::to_value(call).expect("WireCall serializes");
        request["type"] = json!("relay.op");
        let answer = self.exchange(request)?;
        match answer["ok"].as_bool() {
            Some(true) => Ok(WireReply::Result(WireResult {
                value: answer.get("value").cloned().unwrap_or(Value::Null),
                revision: answer["revision"].as_str().map(str::to_owned),
                replayed: answer["replayed"].as_bool().unwrap_or(false),
            })),
            Some(false) => serde_json::from_value::<WireError>(answer["error"].clone())
                .map(WireReply::Error)
                .map_err(|e| {
                    RelayError::Unavailable(format!("relay error has no typed error: {e}"))
                }),
            None => Err(RelayError::Unavailable("relay result has no ok".into())),
        }
    }

    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        let answer = self.exchange(json!({ "type": "relay.session" }))?;
        Ok(SessionStatus {
            signed_in: answer["signed_in"].as_bool().unwrap_or(false),
            team: answer["team"].as_str().map(str::to_owned),
        })
    }
}
