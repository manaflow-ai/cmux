//! Auto mode's store for the machine's daemon (sans I/O): the socket line
//! `{"auto_session": {"call": "<kind>", ...}}` that acpmux sends for each
//! store route a Cloud machine may call, the Cloud API request it becomes
//! (`/v1/auto-sessions/...` as this machine's `vm` install), and the one reply
//! line the agent writes back (plans/cmux-next/auto-mode/DESIGN.md "Cloud
//! API"; the routes are backend/apps/api/src/auto-sessions/routes.ts).
//!
//! The store takes a VM install bound to a machine as that machine: its holder
//! is `vm:<that machine>` and it reaches only the chats that machine holds
//! (callers.ts). So the daemon needs no credential, and the bearer stays in
//! the agent as it does for hand-off reports (`handoff.rs`). The agent names
//! neither the holder nor the epoch: they are the daemon's, and the store
//! checks them.
//!
//! The calls and what each needs beside `call`:
//!
//! | `call` | Fields | Route |
//! |---|---|---|
//! | `machine` | | none: answers `{"ok": true, "machine": "<id>"}` |
//! | `assignments` | `timeoutMs` | `GET assignments?timeoutMs=` (held) |
//! | `get` | `session` | `GET :id` |
//! | `lease` | `session`, `body` | `POST :id/lease` |
//! | `release` | `session`, `body` | `POST :id/release` |
//! | `give` | `session`, `body` | `POST :id/give` |
//! | `events_append` | `session`, `body` | `POST :id/events` |
//! | `events` | `session`, `after`, `limit`? | `GET :id/events?after=&limit=` |
//! | `chunk_put` | `session`, `sha256`, `holder`, `epoch`, `bytes` | `PUT :id/chunks/:sha256` |
//! | `chunk` | `session`, `sha256` | `GET :id/chunks/:sha256` |
//! | `snapshot_post` | `session`, `body` | `POST :id/snapshot` |
//! | `snapshot` | `session` | `GET :id/snapshot` |
//! | `inbox` | `session`, `after` | `GET :id/inbox?after=` |
//! | `inbox_ack` | `session`, `body` | `POST :id/inbox/ack` |
//! | `assignment_ack` | `session`, `body` | `POST :id/assignment/ack` |
//! | `move` | `session`, `body` (`{to, device?}`) | `POST :id/move` |
//! | `keep` | `session`, `body` (`{keepInCloud}`) | `POST :id/keep` |
//!
//! `move` and `keep` are the chat's own agent moving it while this machine
//! holds it (acpmux `chat_place.rs`): home to the laptop that stands by, or
//! between Cloud and AutoCloud. The store takes them only from the holder.
//!
//! `body` is the route's JSON body as the store reads it (it names `holder`
//! and `epoch`). `bytes` is a chunk in base64, on the way in and in a `chunk`
//! reply.
//!
//! The reply is `{"ok": true, "status", "body"}` with the store's JSON answer
//! (`"bytes"` for a chunk, neither for a 204), `{"ok": false, "status",
//! "body"}` with the store's refusal as it sent it (`{error: {code, message},
//! session?, lastSeq?, missing?}`), or `{"ok": false, "error": {code,
//! message}}` when the agent did not send the call or got no answer.
//!
//! A chat's content (events, chunks, messages) is never in a journal line:
//! [`note_for`] names the call, the chat and the outcome only.

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_server::cloud_http::Response;
use serde_json::{Map, Value, json};

use crate::json::JsonField;

/// The socket line's key.
pub const REQUEST_KEY: &str = "auto_session";

/// The socket these lines go to (root and group cmux, 0660, beside the agent
/// socket). It is its own socket because its lines are large (a chunk is
/// 1 MiB) and one of its calls is held for 25 s: neither fits the agent
/// socket's poll loop (`auto_session_server.rs`).
pub const SOCKET: &str = "/run/cmux-vm-agent/auto-session.sock";

/// The most a call's line may have: a chunk in base64 (1.4 MiB), an events
/// append (1 MiB) and a snapshot manifest (1 MiB) all fit. A reply line is as
/// long as its answer ([`Call::answer_limit`], and a third more for a chunk).
pub const MAX_LINE: usize = 2 * 1024 * 1024;

/// The store's chunk size limit (`MAX_CHUNK_BYTES`).
pub const MAX_CHUNK: usize = 1024 * 1024;

/// The longest the store holds an `assignments` request (`MAX_WAIT_MS`).
pub const MAX_WAIT_MS: u64 = 25_000;

const ROUTES: &str = "/v1/auto-sessions";

/// One store route a machine may call, or `Machine`: who this machine is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Machine,
    Assignments,
    Get,
    Lease,
    Release,
    /// The holder hands the chat to where the person moved it.
    Give,
    EventsAppend,
    Events,
    ChunkPut,
    Chunk,
    SnapshotPost,
    Snapshot,
    Inbox,
    InboxAck,
    AssignmentAck,
    /// The holder asks the store to move the chat it holds (`to: local`).
    Move,
    /// The holder sets whether the chat it holds is kept in the Cloud.
    Keep,
}

impl Kind {
    pub const ALL: [Kind; 17] = [
        Kind::Machine,
        Kind::Assignments,
        Kind::Get,
        Kind::Lease,
        Kind::Release,
        Kind::Give,
        Kind::EventsAppend,
        Kind::Events,
        Kind::ChunkPut,
        Kind::Chunk,
        Kind::SnapshotPost,
        Kind::Snapshot,
        Kind::Inbox,
        Kind::InboxAck,
        Kind::AssignmentAck,
        Kind::Move,
        Kind::Keep,
    ];

    /// The line's `call`.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Machine => "machine",
            Kind::Assignments => "assignments",
            Kind::Get => "get",
            Kind::Lease => "lease",
            Kind::Release => "release",
            Kind::Give => "give",
            Kind::EventsAppend => "events_append",
            Kind::Events => "events",
            Kind::ChunkPut => "chunk_put",
            Kind::Chunk => "chunk",
            Kind::SnapshotPost => "snapshot_post",
            Kind::Snapshot => "snapshot",
            Kind::Inbox => "inbox",
            Kind::InboxAck => "inbox_ack",
            Kind::AssignmentAck => "assignment_ack",
            Kind::Move => "move",
            Kind::Keep => "keep",
        }
    }

    fn parse(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|kind| kind.name() == name)
    }

    /// The HTTP method and what follows the chat's id in the path.
    fn route(self) -> (&'static str, &'static str) {
        match self {
            Kind::Machine | Kind::Assignments | Kind::Get => ("GET", ""),
            Kind::Lease => ("POST", "/lease"),
            Kind::Release => ("POST", "/release"),
            Kind::Give => ("POST", "/give"),
            Kind::EventsAppend => ("POST", "/events"),
            Kind::Events => ("GET", "/events"),
            Kind::ChunkPut => ("PUT", "/chunks/"),
            Kind::Chunk => ("GET", "/chunks/"),
            Kind::SnapshotPost => ("POST", "/snapshot"),
            Kind::Snapshot => ("GET", "/snapshot"),
            Kind::Inbox => ("GET", "/inbox"),
            Kind::InboxAck => ("POST", "/inbox/ack"),
            Kind::AssignmentAck => ("POST", "/assignment/ack"),
            Kind::Move => ("POST", "/move"),
            Kind::Keep => ("POST", "/keep"),
        }
    }

    /// The call carries the route's JSON body, which names its writer.
    pub fn has_body(self) -> bool {
        matches!(
            self,
            Kind::Lease
                | Kind::Release
                | Kind::Give
                | Kind::EventsAppend
                | Kind::SnapshotPost
                | Kind::InboxAck
                | Kind::AssignmentAck
        )
    }

    /// The call carries a wish body, which names no writer: the store reads
    /// the writer from the install (`move`, `keep`).
    pub fn has_wish(self) -> bool {
        matches!(self, Kind::Move | Kind::Keep)
    }

    fn names_chunk(self) -> bool {
        matches!(self, Kind::ChunkPut | Kind::Chunk)
    }

    fn names_session(self) -> bool {
        !matches!(self, Kind::Machine | Kind::Assignments)
    }
}

/// One checked call. A field a kind does not use is empty.
#[derive(Clone, Debug, PartialEq)]
pub struct Call {
    pub kind: Kind,
    /// The chat's id.
    pub session: String,
    /// `chunk_put` and `chunk`: the chunk's name.
    pub sha256: String,
    /// `events` and `inbox`: read what comes after this.
    pub after: u64,
    /// `events`: at most this many.
    pub limit: Option<u32>,
    /// `assignments`: how long the store may hold the request.
    pub timeout_ms: u64,
    /// The route's JSON body ([`Kind::has_body`]).
    pub body: Option<Value>,
    /// `chunk_put`: the writer's holder and epoch (the route's two headers).
    pub writer: Option<(String, u64)>,
    /// `chunk_put`: the chunk.
    pub bytes: Vec<u8>,
}

/// The store's chat id shape, `[A-Za-z0-9_.:-]{1,128}`, less the two names it
/// keeps for routes.
pub fn valid_session(session: &str) -> bool {
    super::handoff::valid_session(session) && session != "machine" && session != "assignments"
}

/// A chunk's name: 64 lowercase hex digits (the store's `SHA256_HEX`).
pub fn valid_sha256(name: &str) -> bool {
    name.len() == 64 && name.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A whole number the store reads as one (a JavaScript safe integer).
fn count(v: &Value) -> Option<u64> {
    v.as_u64().filter(|n| *n < (1 << 53))
}

/// A `move` or `keep` body as the store reads it, with nothing else in it.
fn wish(kind: Kind, body: &Value) -> Result<Value, String> {
    if kind == Kind::Keep {
        let keep = body.field("keepInCloud").as_bool().ok_or("body must be {keepInCloud: bool}")?;
        return Ok(json!({ "keepInCloud": keep }));
    }
    let to = body.field("to").as_str().filter(|to| matches!(*to, "cloud" | "local"));
    let to = to.ok_or("body must be {to: cloud|local, device?}")?;
    match body.field("device") {
        Value::Null => Ok(json!({ "to": to })),
        Value::String(device) if device.starts_with("device:") && valid_holder(device) => {
            Ok(json!({ "to": to, "device": device }))
        }
        _ => Err("device must be device:<id>".to_owned()),
    }
}

/// A holder as a writer names it: short, one line, no spaces.
fn valid_holder(holder: &str) -> bool {
    !holder.is_empty()
        && holder.len() <= 200
        && !holder.chars().any(|c| c.is_whitespace() || c.is_control())
}

impl Call {
    fn empty(kind: Kind) -> Call {
        Call {
            kind,
            session: String::new(),
            sha256: String::new(),
            after: 0,
            limit: None,
            timeout_ms: 0,
            body: None,
            writer: None,
            bytes: Vec::new(),
        }
    }

    /// Who this machine is.
    pub fn machine() -> Call {
        Call::empty(Kind::Machine)
    }

    /// This machine's assignments, held up to `timeout_ms`.
    pub fn assignments(timeout_ms: u64) -> Call {
        Call { timeout_ms: timeout_ms.min(MAX_WAIT_MS), ..Call::empty(Kind::Assignments) }
    }

    /// A read of one chat: `get`, `snapshot`.
    pub fn read(kind: Kind, session: &str) -> Call {
        Call { session: session.to_owned(), ..Call::empty(kind) }
    }

    /// A read of what comes after `after`: `events` (with `limit`), `inbox`.
    pub fn page(kind: Kind, session: &str, after: u64, limit: Option<u32>) -> Call {
        Call { session: session.to_owned(), after, limit, ..Call::empty(kind) }
    }

    /// A write with the route's JSON body: `lease`, `release`, `events_append`,
    /// `snapshot_post`, `inbox_ack`, `assignment_ack`.
    pub fn write(kind: Kind, session: &str, body: Value) -> Call {
        Call { session: session.to_owned(), body: Some(body), ..Call::empty(kind) }
    }

    /// One chunk's bytes.
    pub fn chunk(session: &str, sha256: &str) -> Call {
        Call { session: session.to_owned(), sha256: sha256.to_owned(), ..Call::empty(Kind::Chunk) }
    }

    /// Store one chunk as `holder` at `epoch`.
    pub fn chunk_put(session: &str, sha256: &str, holder: &str, epoch: u64, bytes: &[u8]) -> Call {
        Call {
            session: session.to_owned(),
            sha256: sha256.to_owned(),
            writer: Some((holder.to_owned(), epoch)),
            bytes: bytes.to_vec(),
            ..Call::empty(Kind::ChunkPut)
        }
    }

    /// The `auto_session` object of a socket line, refused unless it has the
    /// shape its route needs (the store checks again, and checks who writes).
    pub fn from_json(v: &Value) -> Result<Call, String> {
        let name = v.field("call").as_str().unwrap_or("");
        let Some(kind) = Kind::parse(name) else {
            return Err("call must name an Auto mode route".to_owned());
        };
        let mut call = Call::empty(kind);
        if kind.names_session() {
            let session = v.field("session").as_str().unwrap_or("");
            if !valid_session(session) {
                return Err("session must be 1-128 of [A-Za-z0-9_.:-]".to_owned());
            }
            call.session = session.to_owned();
        }
        if kind.names_chunk() {
            let sha256 = v.field("sha256").as_str().unwrap_or("");
            if !valid_sha256(sha256) {
                return Err("sha256 must be 64 lowercase hex digits".to_owned());
            }
            call.sha256 = sha256.to_owned();
        }
        match kind {
            Kind::Assignments => {
                let asked = match v.field("timeoutMs") {
                    Value::Null => MAX_WAIT_MS,
                    other => count(other).ok_or("timeoutMs must be a whole number")?,
                };
                call.timeout_ms = asked.min(MAX_WAIT_MS);
            }
            Kind::Events | Kind::Inbox => {
                call.after = match v.field("after") {
                    Value::Null => 0,
                    other => count(other).ok_or("after must be a whole number")?,
                };
                if kind == Kind::Events {
                    call.limit = match v.field("limit") {
                        Value::Null => None,
                        other => Some(
                            count(other)
                                .and_then(|n| u32::try_from(n).ok())
                                .filter(|n| *n >= 1)
                                .ok_or("limit must be a whole number from 1")?,
                        ),
                    };
                }
            }
            Kind::ChunkPut => {
                let holder = v.field("holder").as_str().unwrap_or("");
                let epoch = count(v.field("epoch"));
                let (true, Some(epoch)) = (valid_holder(holder), epoch) else {
                    return Err("holder and epoch must name the writer".to_owned());
                };
                let bytes = v
                    .field("bytes")
                    .as_str()
                    .and_then(|text| BASE64.decode(text).ok())
                    .ok_or("bytes must be the chunk in base64")?;
                if bytes.len() > MAX_CHUNK {
                    return Err("a chunk is at most 1 MiB".to_owned());
                }
                call.writer = Some((holder.to_owned(), epoch));
                call.bytes = bytes;
            }
            _ => {}
        }
        if kind.has_body() {
            let body = v.field("body");
            let named = body.is_object()
                && body.field("holder").as_str().is_some_and(valid_holder)
                && count(body.field("epoch")).is_some();
            if !named {
                return Err("body must be the route's body, naming holder and epoch".to_owned());
            }
            call.body = Some(body.clone());
        }
        if kind.has_wish() {
            call.body = Some(wish(kind, v.field("body"))?);
        }
        Ok(call)
    }

    /// The socket line a client sends.
    pub fn to_line(&self) -> String {
        let mut fields = Map::new();
        fields.insert("call".to_owned(), json!(self.kind.name()));
        if self.kind.names_session() {
            fields.insert("session".to_owned(), json!(self.session));
        }
        if self.kind.names_chunk() {
            fields.insert("sha256".to_owned(), json!(self.sha256));
        }
        match self.kind {
            Kind::Assignments => {
                fields.insert("timeoutMs".to_owned(), json!(self.timeout_ms));
            }
            Kind::Events | Kind::Inbox => {
                fields.insert("after".to_owned(), json!(self.after));
                if let Some(limit) = self.limit {
                    fields.insert("limit".to_owned(), json!(limit));
                }
            }
            Kind::ChunkPut => {
                if let Some((holder, epoch)) = &self.writer {
                    fields.insert("holder".to_owned(), json!(holder));
                    fields.insert("epoch".to_owned(), json!(epoch));
                }
                fields.insert("bytes".to_owned(), json!(BASE64.encode(&self.bytes)));
            }
            _ => {}
        }
        if let Some(body) = &self.body {
            fields.insert("body".to_owned(), body.clone());
        }
        json!({ REQUEST_KEY: Value::Object(fields) }).to_string()
    }

    /// The HTTP method; `None` for [`Kind::Machine`], which is no request.
    pub fn method(&self) -> Option<&'static str> {
        (self.kind != Kind::Machine).then(|| self.kind.route().0)
    }

    /// The route's path and query on the API origin.
    pub fn path(&self) -> String {
        let tail = self.kind.route().1;
        match self.kind {
            Kind::Machine => String::new(),
            Kind::Assignments => format!("{ROUTES}/assignments?timeoutMs={}", self.timeout_ms),
            Kind::ChunkPut | Kind::Chunk => {
                format!("{ROUTES}/{}{tail}{}", self.session, self.sha256)
            }
            Kind::Events => {
                let limit = self.limit.map(|n| format!("&limit={n}")).unwrap_or_default();
                format!("{ROUTES}/{}{tail}?after={}{limit}", self.session, self.after)
            }
            Kind::Inbox => format!("{ROUTES}/{}{tail}?after={}", self.session, self.after),
            _ => format!("{ROUTES}/{}{tail}", self.session),
        }
    }

    /// `chunk_put`'s two headers: the writer's holder and epoch.
    pub fn headers(&self) -> Vec<(&'static str, String)> {
        match &self.writer {
            Some((holder, epoch)) => vec![
                ("x-cmux-auto-holder", holder.clone()),
                ("x-cmux-auto-epoch", epoch.to_string()),
            ],
            None => Vec::new(),
        }
    }

    /// How long the request may take: the store's hold and 10 s for an
    /// `assignments` wait, 30 s for a route that carries a chat's content,
    /// else the 20 s of every other agent request.
    pub fn within(&self) -> Duration {
        match self.kind {
            Kind::Assignments => Duration::from_millis(self.timeout_ms + 10_000),
            Kind::EventsAppend
            | Kind::Events
            | Kind::ChunkPut
            | Kind::Chunk
            | Kind::SnapshotPost
            | Kind::Snapshot
            | Kind::Inbox => Duration::from_secs(30),
            _ => Duration::from_secs(20),
        }
    }

    /// The most bytes the answer may have. The store counts its page limits in
    /// characters, and a character is up to six bytes of JSON: an events page
    /// or a manifest of 1 MiB is read up to 8 MiB, and an inbox page (64
    /// messages of 256 KiB) up to 128 MiB.
    pub fn answer_limit(&self) -> usize {
        const MIB: usize = 1024 * 1024;
        match self.kind {
            Kind::Chunk => MAX_CHUNK,
            Kind::Inbox => 128 * MIB,
            Kind::Machine => 0,
            _ => 8 * MIB,
        }
    }
}

/// A refusal reply the agent makes itself (`ok: false`, no status): the call
/// was not sent, or no answer came.
pub fn refusal(code: &str, message: &str) -> Value {
    json!({ "ok": false, "error": { "code": code, "message": message } })
}

/// The reply to [`Kind::Machine`]: the machine this agent's install is bound
/// to, whose holder name is `vm:<machine>`.
pub fn machine_reply(machine: &str) -> Value {
    json!({ "ok": true, "machine": machine })
}

/// The reply line for the store's answer to `call`; `None` is no answer.
pub fn reply_for(call: &Call, answer: Option<&Response>) -> Value {
    let Some(answer) = answer else {
        return refusal("auto.unreachable", "the cmux Cloud API did not answer");
    };
    let status = answer.status;
    let parsed: Option<Value> = serde_json::from_slice(&answer.bytes).ok();
    if !(200..300).contains(&status) {
        // The store's refusal as it sent it, so the daemon reads its code, the
        // chat as it is now, `lastSeq` and `missing`.
        let mut out = Map::new();
        out.insert("ok".to_owned(), json!(false));
        out.insert("status".to_owned(), json!(status));
        out.insert("body".to_owned(), parsed.unwrap_or(Value::Null));
        return Value::Object(out);
    }
    match call.kind {
        Kind::Chunk => {
            json!({ "ok": true, "status": status, "bytes": BASE64.encode(&answer.bytes) })
        }
        Kind::ChunkPut => json!({ "ok": true, "status": status }),
        _ => match parsed {
            Some(body) => json!({ "ok": true, "status": status, "body": body }),
            None => refusal("auto.bad_answer", "the API's answer is not JSON"),
        },
    }
}

/// A journal line for a call that did not go through: the call, the chat and
/// why. A call that went through leaves no line (a held chat renews every
/// 10 s), and no line ever holds a chat's content.
pub fn note_for(call: &Call, reply: &Value) -> Option<String> {
    if *reply.field("ok") == true {
        return None;
    }
    let chat = if call.session.is_empty() { String::new() } else { format!(" {}", call.session) };
    let code = |v: &Value| v.field("error").field("code").as_str().map(str::to_owned);
    let why = match reply.field("status").as_u64() {
        Some(status) => {
            format!("{status} {}", code(reply.field("body")).unwrap_or_else(|| "?".to_owned()))
        }
        None => code(reply).unwrap_or_else(|| "?".to_owned()),
    };
    let why: String = why.chars().filter(|c| !c.is_control()).take(80).collect();
    Some(format!("auto-session {}{chat}: refused {why}", call.kind.name()))
}
