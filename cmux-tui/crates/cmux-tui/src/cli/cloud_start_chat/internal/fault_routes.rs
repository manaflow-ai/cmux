//! The fault drill's event source (crate::carrier::drill [`EventRoutes`]): the chat tab's acpmux event
//! stream over one running Cloud carrier session (crate::carrier::drill_dial), pinned to one carrier.
//!
//! - The first open dials the machine (the one Cloud dial, relay then ssh), and only when the session came up on
//!   the route asked for does it go on; then `identify` and `agent-session-attach` on the chat's tab with
//!   `after_seq` (cmux-tui/spec/commands.md "Agent session attach"), every record from the log's start for a
//!   connect, after the client's last seq for a resume. Then the prompt is sent ([`SessionRoutes::new`]'s `send`),
//!   so the turn runs while the stream is attached.
//! - `from_seq` is the server's own: the first record of its attach page. A page with none says nothing, and the
//!   first record it pushes tells (the drill fills it in).
//! - Every record the stream reads is checked to have come over its carrier: a session that moved to another
//!   carrier before the kill ends the stream, rather than label another route's records.
//! - The kill is the session's own carrier kill ([`CarrierSession::kill`]): the route dies under the session,
//!   whose reconnect resumes on the next route. The next open attaches again on that same session, after the
//!   client's last seq, and checks the session is on the next route.
//!
//! Within one stream, the one push of a record its own attach page held is not delivered twice: the attachment
//! subscribes before it reads its page, so that overlap is the attach protocol's own. Only those exact seqs, once
//! each: any other record, one the client had from the old carrier included, is delivered as it came and is in
//! the drill's record, for its judge.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};
use tokio::time::Instant;

use super::link_wait::turn_ended;
use crate::carrier::drill::{EventRoutes, EventStream, Opened, TurnEvent};
use crate::carrier::drill_dial::{CarrierSession, DialSpec, Lines};
use crate::carrier::fault::Route;

/// The capability a daemon serves `agent-session-attach` under.
const ATTACH: &str = "agent-session-attach-v1";
/// Records asked per page.
const PAGE: u64 = 500;
/// A resume's open waits for the session to come back on the next carrier this long at most, a try at a time.
const RESUME_TRIES: u32 = 40;
const RESUME_PAUSE: Duration = Duration::from_millis(250);

/// Dials the session, once.
pub(crate) type Connect = Box<
    dyn FnOnce() -> std::pin::Pin<
            Box<dyn Future<Output = Result<Arc<dyn CarrierSession>, String>> + Send>,
        > + Send,
>;
/// Sends the turn's prompt, once, after the first stream attached (a blocking run of this binary's steps).
pub(crate) type SendPrompt = Box<dyn FnOnce() -> Result<(), String> + Send>;

/// The drill's [`EventRoutes`] over one carrier session.
pub(crate) struct SessionRoutes {
    connect: Option<Connect>,
    session: Option<Arc<dyn CarrierSession>>,
    surface: u64,
    send: Option<SendPrompt>,
}

impl SessionRoutes {
    /// The chat tab `surface`'s stream over the session `connect` dials; `send` runs once the first stream attached.
    pub(crate) fn new(connect: Connect, surface: u64, send: SendPrompt) -> Self {
        Self { connect: Some(connect), session: None, surface, send: Some(send) }
    }
}

/// The key of a promptless start's answer that holds the chat tab's number on the machine's daemon.
pub(crate) const DAEMON_TAB: &str = "daemon_tab";

/// Puts the chat tab's handle from `started` (`cloud start-session`'s answer, its `surface_id`) into a start's
/// `answer` as [`DAEMON_TAB`], where [`cloud_routes`] reads it.
pub(crate) fn keep_chat_tab(answer: &mut Value, started: &Value) {
    if let (Some(tab), Some(fields)) = (super::chat_tab(started), answer.as_object_mut()) {
        fields.insert(DAEMON_TAB.into(), json!(tab));
    }
}

/// The routes of a chat `cloud start-chat` just started (`started`: its answer, `machine_id` and [`DAEMON_TAB`]) over
/// a dial with the signed-in app's credential (`token`: `auth.token`'s answer), by `deadline`.
pub(crate) fn cloud_routes(
    started: &Value,
    token: &Value,
    deadline: Instant,
    send: SendPrompt,
) -> Result<SessionRoutes, String> {
    let machine = started
        .get("machine_id")
        .and_then(Value::as_str)
        .ok_or("the chat's start named no machine")?
        .to_owned();
    let surface = started
        .get(DAEMON_TAB)
        .and_then(Value::as_u64)
        .ok_or("the chat's start named no chat tab to attach to")?;
    let text = |key: &str| token.get(key).and_then(Value::as_str).map(str::to_owned);
    let api = text("api_origin").ok_or("the app's token names no cmux API")?;
    let token_text = text("access_token").ok_or("the app gave no access token")?;
    let team = text("team");
    let spec =
        DialSpec { machine, api, token: zeroize::Zeroizing::new(token_text), team, deadline };
    let connect: Connect = Box::new(move || Box::pin(crate::carrier::drill_dial::dial(spec)));
    Ok(SessionRoutes::new(connect, surface, send))
}

#[async_trait]
impl EventRoutes for SessionRoutes {
    async fn open(
        &mut self,
        index: usize,
        route: Route,
        after_seq: Option<u64>,
    ) -> Result<Opened, String> {
        let session = match (&self.session, self.connect.take()) {
            (Some(session), _) => session.clone(),
            (None, Some(connect)) => {
                let session = connect().await?;
                self.session = Some(session.clone());
                session
            }
            (None, None) => return Err("the carrier session did not dial".into()),
        };
        if index == 0 && session.route() != Some(route) {
            return Err(format!(
                "the session connected over {}, not {}",
                session.route().map_or("no carrier", Route::name),
                route.name()
            ));
        }
        let tries = if index == 0 { 1 } else { RESUME_TRIES };
        let mut last = String::new();
        for _ in 0..tries {
            match attach(session.clone(), route, self.surface, after_seq.unwrap_or(0)).await {
                Ok(opened) => {
                    if let Some(send) = self.send.take() {
                        send_off(send).await?;
                    }
                    return Ok(opened);
                }
                Err(why) => last = why,
            }
            tokio::time::sleep(RESUME_PAUSE).await;
        }
        Err(last)
    }
}

/// Runs the prompt's send (a blocking run of this binary's steps) on a thread of its own. The drill's deadline drops
/// the wait for it, and nothing waits for that thread after: the runtime's shutdown never blocks on a send, which
/// itself sends nothing past the deadline (`prompt_send`).
async fn send_off(send: SendPrompt) -> Result<(), String> {
    let (done, sent) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("carrier-drill-send".into())
        .spawn(move || {
            let _ = done.send(send());
        })
        .map_err(|error| format!("the prompt's send did not start: {error}"))?;
    sent.await
        .map_err(|_| "the prompt's send ended without an answer".to_owned())?
        .map_err(|why| format!("the prompt was not sent: {why}"))
}

/// One stream: a line stream on the session, `identify`, then the attach after `after`, on `route`.
async fn attach(
    session: Arc<dyn CarrierSession>,
    route: Route,
    surface: u64,
    after: u64,
) -> Result<Opened, String> {
    let lines = session.lines().await?;
    let mut stream = Stream {
        session,
        route,
        surface,
        lines,
        queued: VecDeque::new(),
        early: VecDeque::new(),
        newest: 0,
        overlap: HashSet::new(),
        more: false,
    };
    let identity = stream.ask("identify", json!({"id": "identify", "cmd": "identify"})).await?;
    let serves = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|names| names.iter().any(|name| name == ATTACH));
    if !serves {
        return Err("the machine's daemon does not serve agent-session-attach".into());
    }
    let page = stream
        .ask(
            "attach",
            json!({"id": "attach", "cmd": "agent-session-attach", "surface": surface, "after_seq": after, "limit": PAGE}),
        )
        .await?;
    stream.page(&page);
    // The server's own resume point: the first record it sent.
    let from_seq =
        stream.queued.front().and_then(|record| record.get("seq")).and_then(Value::as_u64);
    // Only a stream that opened over the carrier asked for counts as that carrier's.
    stream.on_route()?;
    Ok(Opened { stream: Box::new(stream), from_seq })
}

struct Stream {
    session: Arc<dyn CarrierSession>,
    route: Route,
    surface: u64,
    lines: Lines,
    /// Records read and not yet delivered, in order.
    queued: VecDeque<Value>,
    /// Lines pushed while a page was awaited: read after the pages.
    early: VecDeque<Value>,
    /// The newest seq the attach pages held: where the next page starts.
    newest: u64,
    /// The seqs the pages held that no push has repeated yet: the attach subscribes before it reads its page, so
    /// the push of exactly one of these is the attach's own overlap, and only that one push is not delivered again.
    /// Any other push is delivered as it came, a seq the client already had included (the judge's repeat).
    overlap: HashSet<u64>,
    /// The last page said there is more.
    more: bool,
}

impl Stream {
    async fn write(&mut self, request: &Value) -> Result<(), String> {
        let mut line = request.to_string();
        line.push('\n');
        self.lines.writer.write_all(line.as_bytes()).await.map_err(|error| error.to_string())?;
        self.lines.writer.flush().await.map_err(|error| error.to_string())
    }

    /// The next JSON line; `None` at the stream's end.
    async fn read(&mut self) -> Result<Option<Value>, String> {
        loop {
            let mut line = String::new();
            let read =
                self.lines.reader.read_line(&mut line).await.map_err(|error| error.to_string())?;
            if read == 0 {
                return Ok(None);
            }
            if let Ok(value) = serde_json::from_str::<Value>(line.trim()) {
                return Ok(Some(value));
            }
        }
    }

    /// `request`'s answer (`data`), the pushes before it kept for later.
    async fn ask(&mut self, id: &str, request: Value) -> Result<Value, String> {
        self.write(&request).await?;
        loop {
            let answer = self.read().await?.ok_or("the stream closed")?;
            if answer.get("id").and_then(Value::as_str) != Some(id) {
                if answer.get("event").is_some() {
                    self.early.push_back(answer);
                }
                continue;
            }
            if answer.get("ok") == Some(&Value::Bool(false)) {
                return Err(format!(
                    "{id} refused: {}",
                    answer.get("error").unwrap_or(&Value::Null)
                ));
            }
            return Ok(answer.get("data").cloned().unwrap_or(Value::Null));
        }
    }

    fn page(&mut self, page: &Value) {
        for record in page.get("events").and_then(Value::as_array).into_iter().flatten() {
            if let Some(seq) = record.get("seq").and_then(Value::as_u64) {
                self.newest = self.newest.max(seq);
                self.overlap.insert(seq);
            }
            self.queued.push_back(record.clone());
        }
        self.more = page.get("hasMore") == Some(&Value::Bool(true));
    }

    fn on_route(&self) -> Result<(), String> {
        match self.session.route() {
            Some(now) if now == self.route => Ok(()),
            now => Err(format!(
                "the session is on {}, not {}",
                now.map_or("no carrier", Route::name),
                self.route.name()
            )),
        }
    }

    /// One pushed line: a record it queues, or `Err` when it ends the stream.
    fn pushed(&mut self, line: &Value) -> Result<(), String> {
        if line.get("surface").and_then(Value::as_u64).is_some_and(|tab| tab != self.surface) {
            return Ok(());
        }
        match line.get("event").and_then(Value::as_str) {
            Some("agent-session-record") => {
                if let Some(record) = line.get("record") {
                    let seq = record.get("seq").and_then(Value::as_u64);
                    if !seq.is_some_and(|seq| self.overlap.remove(&seq)) {
                        self.queued.push_back(record.clone());
                    }
                }
                Ok(())
            }
            Some("agent-session-permission") => Err("the agent asked a permission".into()),
            Some("agent-session-closed") => Err(format!(
                "the attachment closed: {}",
                line.get("reason").and_then(Value::as_str).unwrap_or("no reason")
            )),
            _ => Ok(()),
        }
    }

    fn event(&self, record: &Value) -> Result<TurnEvent, String> {
        self.on_route()?;
        let seq = record.get("seq").and_then(Value::as_u64).ok_or("a record without a seq")?;
        Ok(TurnEvent { seq, last: turn_ended(record).is_some() })
    }
}

#[async_trait]
impl EventStream for Stream {
    async fn next(&mut self) -> Option<Result<TurnEvent, String>> {
        loop {
            if let Some(record) = self.queued.pop_front() {
                return Some(self.event(&record));
            }
            if self.more {
                let id = format!("events-{}", self.newest);
                let request = json!({"id": id, "cmd": "agent-session-events", "surface": self.surface,
                                     "after_seq": self.newest, "limit": PAGE});
                let before = self.newest;
                match self.ask(&id, request).await {
                    Ok(page) => self.page(&page),
                    Err(why) => return Some(Err(why)),
                }
                if self.more && self.newest == before {
                    return Some(Err("a replay page made no progress".into()));
                }
                continue;
            }
            let line = match self.early.pop_front() {
                Some(line) => line,
                None => match self.read().await {
                    Ok(Some(line)) => line,
                    Ok(None) => return None,
                    Err(why) => return Some(Err(why)),
                },
            };
            if let Err(why) = self.pushed(&line) {
                return Some(Err(why));
            }
        }
    }

    async fn kill(self: Box<Self>) {
        let Self { session, route, lines, .. } = *self;
        session.kill(route).await;
        drop(lines);
    }
}

#[cfg(test)]
#[path = "fault_routes_tests.rs"]
pub(crate) mod tests;
