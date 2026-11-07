//! `cmux cloud hands`: the macOS app's Chief hands engine (docs/chief-hands.md,
//! bead cx-om025). The app runs one for its life and keeps only what views
//! observe and what needs its keys: the install key's and the Secure
//! Enclave presence key's signatures. Everything else is here: the user
//! socket, the list reads, merging both ([`hands::tracker::Tracker`]), the
//! hand routes, the level rules and the texts the app signs
//! (`cmux_cloud_wire::hands`).
//!
//! The app writes JSON lines on stdin and reads JSON lines on stdout. stdin's
//! end (the app quit or crashed) ends the engine.
//!
//! In: `{"t":"start","api":ORIGIN,"app_version":V}` (signed in: follow the
//! socket), `{"t":"stop"}` (signed out: every request settles), `{"t":"token",
//! "id":N,"credential":C|null}` (the answer to a token ask), and
//! `{"t":"call","id":N,"op":OP,...}`, answered by one `reply`:
//!
//! - `refresh`: read the hands and their waiting requests now.
//! - `allow_text {key, environment}`: the text the install key signs to allow `key`.
//! - `answer {key, allow, install?, signature?}`: Deny, or Allow with the install proof.
//!   A request the server already ended answers `{already: true}`; either way it settles.
//! - `set_level {target, level, known?, proof?: {install, nonce, signature}}`: a hand id or
//!   `default:<profile>`. Without a proof, a raise answers `{needs_proof: true}` (a lower is sent;
//!   the server's `hand.level_refused` also answers `needs_proof`).
//! - `challenge {target, level, environment}`: `{nonce, text}`, the text the presence key signs.
//! - `presence_text {environment, install, x, y}` and `register_presence_key {install, x, y, signature}`.
//! - `report {prompt, secure_enclave, result, log}`: `debug.hands`'s JSON text.
//!
//! Out: `{"event":"token","id":N}`, `{"event":"hands","hands":[...]}`, `{"event":"pending",
//! "approval":A,"name":S}`, `{"event":"settled","approval":A,"outcome":O|null}`, `{"event":"log",
//! "line":S}` and `{"event":"reply","id":N,"ok":true,"value":V}` or `{..., "ok":false,"error":
//! {kind, status, code, message}}`.

mod http;
mod socket;

use std::collections::HashMap;
use std::io::{BufRead as _, Write as _};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_cloud_wire::hands::tracker::{Change, Tracker};
use cmux_cloud_wire::hands::{
    self, HandApproval, HandLevel, HandOutcome, HandSummary, LevelPlan, Target,
};
use reqwest::Method;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use super::cloud_client_session::secure_origin;
use http::Failure;

/// How long a token ask waits for the app.
const TOKEN_WAIT: Duration = Duration::from_secs(30);

/// `Some(exit code)` when `args` is `cloud hands`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "hands" {
        return None;
    }
    if !rest.is_empty() {
        eprintln!("cmux cloud hands takes its commands as JSON lines on stdin");
        return Some(2);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return Some(1);
    };
    let (lines, input) = mpsc::unbounded_channel();
    // stdin blocks: a thread of its own feeds the engine, and its end ends the engine.
    let _ = std::thread::Builder::new().name("cmux-hands-stdin".into()).spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if lines.send(line).is_err() {
                break;
            }
        }
    });
    runtime.block_on(serve(input, |line: Value| {
        let mut stdout = std::io::stdout().lock();
        let _ = writeln!(stdout, "{line}");
        let _ = stdout.flush();
    }));
    Some(0)
}

/// What the engine's own tasks tell it.
enum Internal {
    Token(oneshot::Sender<Option<String>>),
    Subscribed(u64),
    Frame(u64, hands::HandFrame),
    Hands(u64, Vec<HandSummary>),
    /// A read of `generation` (its sequence, when it began) ended: the rows it got, and
    /// its failure when it stopped part way.
    Listed(u64, u64, u64, Vec<HandApproval>, Option<Failure>),
    /// A route call of `generation` (its id) ended.
    Done(u64, u64, Result<Value, Failure>, Option<(String, Option<HandOutcome>, String)>),
}

struct Engine<E> {
    emit: E,
    internal: mpsc::UnboundedSender<Internal>,
    tracker: Tracker,
    origin: Instant,
    /// The API origin while following (signed in).
    api: Option<String>,
    app_version: Option<String>,
    generation: u64,
    socket: Option<JoinHandle<()>>,
    read: Option<JoinHandle<()>>,
    /// The sequence of the newest read: an earlier one's end is ignored.
    reads: u64,
    /// `refresh` calls that wait for the next read to end.
    refreshes: Vec<u64>,
    tokens: HashMap<u64, oneshot::Sender<Option<String>>>,
    next_token: u64,
    /// The route calls of the current start, by call id: a stop or a new start aborts them.
    calls: HashMap<u64, JoinHandle<()>>,
    /// `generation`, for the calls' own check before they send anything.
    current: Arc<AtomicU64>,
}

/// Runs the engine until `input` ends.
pub(super) async fn serve(
    mut input: mpsc::UnboundedReceiver<String>,
    emit: impl Fn(Value) + Clone + Send + 'static,
) {
    let (internal, mut events) = mpsc::unbounded_channel();
    let mut engine = Engine {
        emit,
        internal,
        tracker: Tracker::default(),
        origin: Instant::now(),
        api: None,
        app_version: None,
        generation: 0,
        socket: None,
        read: None,
        reads: 0,
        refreshes: Vec::new(),
        tokens: HashMap::new(),
        next_token: 0,
        calls: HashMap::new(),
        current: Arc::new(AtomicU64::new(0)),
    };
    loop {
        tokio::select! {
            line = input.recv() => match line {
                Some(line) => engine.command(&line),
                None => break,
            },
            Some(event) = events.recv() => engine.internal(event),
        }
    }
    engine.halt();
}

fn wall_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_millis() as f64)
}

/// A number in 0..1 for the backoff's spread.
fn spread() -> f64 {
    f64::from(SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.subsec_nanos()) % 1000)
        / 1000.0
}

/// Asks the app for a fresh token (none: signed out, or no answer in time).
async fn token(internal: &mpsc::UnboundedSender<Internal>) -> Option<String> {
    let (sender, receiver) = oneshot::channel();
    internal.send(Internal::Token(sender)).ok()?;
    tokio::time::timeout(TOKEN_WAIT, receiver).await.ok()?.ok().flatten()
}

fn text<'a>(object: &'a Value, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

impl<E: Fn(Value) + Clone + Send + 'static> Engine<E> {
    fn now(&self) -> u64 {
        u64::try_from(self.origin.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn log(&self, line: impl Into<String>) {
        (self.emit)(json!({ "event": "log", "line": line.into() }));
    }

    fn reply(&self, id: u64, result: Result<Value, Failure>) {
        (self.emit)(match result {
            Ok(value) => json!({ "event": "reply", "id": id, "ok": true, "value": value }),
            Err(failure) => {
                json!({ "event": "reply", "id": id, "ok": false, "error": failure.to_value() })
            }
        });
    }

    fn show(&self, changes: Vec<Change>) {
        for change in changes {
            (self.emit)(match change {
                Change::Pending { approval, name } => {
                    self.log(format!("pending {}", approval.key));
                    json!({ "event": "pending", "approval": approval, "name": name })
                }
                Change::Settled { approval, outcome } => {
                    self.log(format!(
                        "settled {} {}",
                        approval.key,
                        outcome.map_or("dropped", HandOutcome::as_str)
                    ));
                    json!({ "event": "settled", "approval": approval, "outcome": outcome })
                }
            });
        }
    }

    fn command(&mut self, line: &str) {
        let Ok(command) = serde_json::from_str::<Value>(line) else { return };
        match text(&command, "t") {
            Some("start") => match text(&command, "api").map(|api| secure_origin(api.trim())) {
                Some(Ok(api)) => {
                    self.app_version = text(&command, "app_version").map(str::to_owned);
                    self.start(api);
                }
                Some(Err(message)) => self.log(format!("start refused: {message}")),
                None => self.log("start refused: no api"),
            },
            Some("stop") => self.stop(),
            Some("token") => {
                let id = command.get("id").and_then(Value::as_u64).unwrap_or(u64::MAX);
                if let Some(sender) = self.tokens.remove(&id) {
                    let _ = sender.send(text(&command, "credential").map(str::to_owned));
                }
            }
            Some("call") => {
                let id = command.get("id").and_then(Value::as_u64).unwrap_or(0);
                self.call(id, &command);
            }
            _ => {}
        }
    }

    fn internal(&mut self, event: Internal) {
        match event {
            Internal::Token(sender) => {
                self.next_token = self.next_token.wrapping_add(1);
                self.tokens.retain(|_, waiting| !waiting.is_closed());
                self.tokens.insert(self.next_token, sender);
                (self.emit)(json!({ "event": "token", "id": self.next_token }));
            }
            Internal::Subscribed(generation) if generation == self.generation => self.refresh(),
            Internal::Frame(generation, frame) if generation == self.generation => {
                let now = self.now();
                let changes = match frame {
                    hands::HandFrame::Pending(approval) => {
                        self.tracker.add(approval, now).into_iter().collect()
                    }
                    hands::HandFrame::Settled { hand, id, outcome } => self
                        .tracker
                        .settle(&hands::approval_key(&hand, &id), Some(outcome), now)
                        .into_iter()
                        .collect(),
                    _ => Vec::new(),
                };
                self.show(changes);
            }
            Internal::Hands(generation, listed) if generation == self.generation => {
                (self.emit)(json!({ "event": "hands", "hands": listed }));
                self.tracker.set_hands(listed);
            }
            Internal::Listed(generation, read, began, listed, failed)
                if generation == self.generation && read == self.reads =>
            {
                self.read = None;
                let now = self.now();
                let result = match failed {
                    None => {
                        let changes = self.tracker.refreshed(began, listed, now);
                        self.show(changes);
                        self.log(format!(
                            "refreshed {} hands, {} waiting",
                            self.tracker.hands().len(),
                            self.tracker.pending().len()
                        ));
                        Ok(json!({}))
                    }
                    Some(failure) => {
                        // The hands read before the failure still show their requests.
                        let changes = self.tracker.partly_read(listed, now);
                        self.show(changes);
                        self.log(format!("refresh failed: {failure}"));
                        Err(failure)
                    }
                };
                for id in std::mem::take(&mut self.refreshes) {
                    self.reply(id, result.clone());
                }
            }
            // A call of an earlier start: a stop or a new start already answered it.
            Internal::Done(generation, id, ..) if generation != self.generation => {
                self.calls.remove(&id);
            }
            Internal::Done(_, id, result, settle) => {
                if self.calls.remove(&id).is_none() {
                    return;
                }
                if let Some((key, outcome, note)) = settle {
                    self.log(note);
                    let changes =
                        self.tracker.settle(&key, outcome, self.now()).into_iter().collect();
                    self.show(changes);
                }
                self.reply(id, result);
            }
            // A task of an earlier start.
            _ => {}
        }
    }

    fn start(&mut self, api: String) {
        self.halt();
        self.next_generation();
        self.api = Some(api.clone());
        let (generation, internal, version) =
            (self.generation, self.internal.clone(), self.app_version.clone());
        self.socket = Some(tokio::spawn(async move {
            let mut attempt = 0;
            loop {
                let credential = token(&internal).await;
                let sent = internal.clone();
                // A connection that ends for any reason (signed out, refused, closed) tries again later.
                let _ = socket::session(&api, credential, version.as_deref(), wall_ms, |seen| {
                    let event = match seen {
                        socket::Seen::Subscribed => {
                            attempt = 0;
                            Internal::Subscribed(generation)
                        }
                        socket::Seen::Frame(frame) => Internal::Frame(generation, frame),
                    };
                    let _ = sent.send(event);
                })
                .await;
                tokio::time::sleep(Duration::from_millis(hands::reconnect_delay_ms(
                    attempt,
                    spread(),
                )))
                .await;
                attempt = attempt.saturating_add(1);
            }
        }));
    }

    /// Ends the socket, the read and the route calls of the current start; each call
    /// and refresh still waiting answers that its session ended.
    fn halt(&mut self) {
        for task in [self.socket.take(), self.read.take()].into_iter().flatten() {
            task.abort();
        }
        for (id, call) in std::mem::take(&mut self.calls) {
            call.abort();
            self.reply(id, Err(Failure::new("not_signed_in", "the session ended")));
        }
        // The read they wait on is gone with its session: a new start never answers them.
        for id in std::mem::take(&mut self.refreshes) {
            self.reply(id, Err(Failure::new("not_signed_in", "the session ended")));
        }
    }

    /// A new session fence: nothing of an earlier start acts after this.
    fn next_generation(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.current.store(self.generation, Ordering::SeqCst);
    }

    fn stop(&mut self) {
        self.halt();
        self.next_generation();
        self.api = None;
        let changes = self.tracker.clear();
        self.show(changes);
        (self.emit)(json!({ "event": "hands", "hands": [] }));
    }

    /// Reads the hands and the waiting requests of each hand that has any;
    /// a read already running is replaced.
    fn refresh(&mut self) {
        let Some(api) = self.api.clone() else { return };
        if let Some(read) = self.read.take() {
            read.abort();
        }
        self.reads = self.reads.wrapping_add(1);
        let (generation, read, internal, began) =
            (self.generation, self.reads, self.internal.clone(), self.now());
        self.read = Some(tokio::spawn(async move {
            // A fresh token for each route call: one that rotates or expires mid-read never fails the rest.
            let mut waiting = Vec::new();
            let listed = async {
                let credential = token(&internal).await;
                let value =
                    http::call(&api, credential.as_deref(), Method::GET, "/v1/hands", None).await?;
                let hands = HandSummary::list(&value)
                    .ok_or_else(|| Failure::new("decoding", "hands is not a list of hands"))?;
                let _ = internal.send(Internal::Hands(generation, hands.clone()));
                for hand in Tracker::hands_to_read(&hands) {
                    let path = format!("/v1/hands/{hand}/approvals");
                    if !hands::is_hand_id(&hand) {
                        return Err(Failure::new("invalid", "not a hand id"));
                    }
                    let credential = token(&internal).await;
                    let rows =
                        http::call(&api, credential.as_deref(), Method::GET, &path, None).await?;
                    waiting.extend(HandApproval::list(&rows, &hand, wall_ms()));
                }
                Ok::<(), Failure>(())
            }
            .await;
            let _ = internal.send(Internal::Listed(generation, read, began, waiting, listed.err()));
        }));
    }

    fn call(&mut self, id: u64, request: &Value) {
        let op = text(request, "op").unwrap_or_default();
        let invalid = |message: &str| Err(Failure::new("invalid", message));
        let level = text(request, "level").and_then(HandLevel::parse);
        let environment = text(request, "environment").unwrap_or_default();
        match op {
            "refresh" => {
                if self.api.is_none() {
                    return self.reply(id, Err(Failure::new("not_signed_in", "not signed in")));
                }
                self.refreshes.push(id);
                self.refresh();
            }
            "allow_text" => {
                let result = match text(request, "key").and_then(|key| self.tracker.approval(key)) {
                    Some(a) => {
                        Ok(json!({ "text": hands::proof::approval(environment, &a.hand, &a.id) }))
                    }
                    None => Err(Failure::new(
                        "unknown_approval",
                        text(request, "key").unwrap_or_default(),
                    )),
                };
                self.reply(id, result);
            }
            "presence_text" => {
                let field = |key| text(request, key).unwrap_or_default();
                let made = hands::proof::presence_registration(
                    environment,
                    field("install"),
                    field("x"),
                    field("y"),
                );
                self.reply(id, Ok(json!({ "text": made })));
            }
            "report" => {
                let made = self.report(request);
                self.reply(id, Ok(json!({ "text": made })));
            }
            "answer" => {
                let Some(approval) =
                    text(request, "key").and_then(|key| self.tracker.approval(key)).cloned()
                else {
                    return self.reply(
                        id,
                        Err(Failure::new(
                            "unknown_approval",
                            text(request, "key").unwrap_or_default(),
                        )),
                    );
                };
                let allow = request.get("allow").and_then(Value::as_bool).unwrap_or(false);
                let mut body = json!({ "allow": allow });
                if let (Some(install), Some(signature)) =
                    (text(request, "install"), text(request, "signature"))
                    && let Some(fields) = body.as_object_mut()
                {
                    fields.insert("install".into(), json!(install));
                    fields.insert("signature".into(), json!(signature));
                }
                let path = format!("/v1/hands/{}/approvals/{}", approval.hand, approval.id);
                self.spawn_call(
                    id,
                    move |answered: Result<Value, Failure>| match answered {
                        Ok(_) => {
                            let outcome =
                                if allow { HandOutcome::Allowed } else { HandOutcome::Denied };
                            let note = format!(
                                "answered {} {}",
                                approval.key,
                                if allow { "allow" } else { "deny" }
                            );
                            (Ok(json!({})), Some((approval.key, Some(outcome), note)))
                        }
                        Err(failure)
                            if hands::ANSWERED_CODES.iter().any(|code| failure.code_is(code)) =>
                        {
                            let note = format!(
                                "answer {}: {} already",
                                approval.key,
                                failure.code.unwrap_or_default()
                            );
                            (Ok(json!({ "already": true })), Some((approval.key, None, note)))
                        }
                        Err(failure) => (Err(failure), None),
                    },
                    Method::POST,
                    path,
                    Some(body),
                );
            }
            "challenge" => {
                let (Some(target), Some(level)) =
                    (text(request, "target").and_then(Target::parse), level)
                else {
                    return self.reply(id, invalid("not a hand id"));
                };
                let environment = environment.to_owned();
                let path = target.challenge_path();
                self.spawn_call(
                    id,
                    move |answered: Result<Value, Failure>| {
                        let nonce = answered.map(|value| text(&value, "nonce").map(str::to_owned));
                        let result = match nonce {
                            Ok(Some(nonce)) if hands::is_nonce(&nonce) => {
                                let signed =
                                    hands::proof::level(&environment, &target, level, &nonce);
                                Ok(json!({ "nonce": nonce, "text": signed }))
                            }
                            Ok(_) => {
                                Err(Failure::new("decoding", "level challenge without a nonce"))
                            }
                            Err(failure) => Err(failure),
                        };
                        (result, None)
                    },
                    Method::POST,
                    path,
                    None,
                );
            }
            "set_level" => {
                let (Some(target), Some(level)) =
                    (text(request, "target").and_then(Target::parse), level)
                else {
                    return self.reply(id, invalid("not a hand id"));
                };
                let mut body = json!({ "level": level.as_str() });
                let proof = request.get("proof").filter(|p| p.is_object());
                if let Some(proof) = proof {
                    for key in ["install", "nonce", "signature"] {
                        if let Some(fields) = body.as_object_mut() {
                            fields.insert(key.into(), json!(text(proof, key).unwrap_or_default()));
                        }
                    }
                } else if hands::level_plan(
                    &target,
                    text(request, "known").and_then(HandLevel::parse),
                    level,
                ) == LevelPlan::Proof
                {
                    return self.reply(id, Ok(json!({ "needs_proof": true })));
                }
                let plain = proof.is_none();
                self.spawn_call(
                    id,
                    move |answered: Result<Value, Failure>| match answered {
                        Ok(_) => (Ok(json!({})), None),
                        // The known level was stale (a Chief lowered it), or a default's is not known: a raise after all.
                        Err(failure) if plain && failure.code_is(hands::LEVEL_REFUSED) => {
                            (Ok(json!({ "needs_proof": true })), None)
                        }
                        Err(failure) => (Err(failure), None),
                    },
                    Method::PUT,
                    target.level_path(),
                    Some(body),
                );
            }
            "register_presence_key" => {
                let field = |key| text(request, key).unwrap_or_default();
                let body = json!({
                    "install": field("install"),
                    "public_jwk": { "crv": "P-256", "kty": "EC", "x": field("x"), "y": field("y") },
                    "signature": field("signature"),
                });
                self.spawn_call(
                    id,
                    |answered| (answered.map(|_| json!({})), None),
                    Method::PUT,
                    "/v1/hands/presence-key".to_owned(),
                    Some(body),
                );
            }
            _ => self.reply(id, invalid("not a hands op")),
        }
    }

    /// Runs one route call off the engine's turn; `finish` reads its answer
    /// (and may settle a request).
    fn spawn_call(
        &mut self,
        id: u64,
        finish: impl FnOnce(
            Result<Value, Failure>,
        )
            -> (Result<Value, Failure>, Option<(String, Option<HandOutcome>, String)>)
        + Send
        + 'static,
        method: Method,
        path: String,
        body: Option<Value>,
    ) {
        let Some(api) = self.api.clone() else {
            return self.reply(id, Err(Failure::new("not_signed_in", "not signed in")));
        };
        let (internal, generation, current) =
            (self.internal.clone(), self.generation, Arc::clone(&self.current));
        let call = tokio::spawn(async move {
            let credential = token(&internal).await;
            // The session may have ended while the token came: send nothing for it.
            if current.load(Ordering::SeqCst) != generation {
                return;
            }
            let answered = http::call(&api, credential.as_deref(), method, &path, body).await;
            let (result, settle) = finish(answered);
            let _ = internal.send(Internal::Done(generation, id, result, settle));
        });
        self.calls.insert(id, call);
    }

    /// `debug.hands`'s state as JSON text (keys sorted).
    fn report(&self, request: &Value) -> String {
        let field = |key: &str| request.get(key).cloned().unwrap_or(Value::Null);
        let hands: Vec<Value> = self
            .tracker
            .hands()
            .iter()
            .map(|h| {
                json!({
                    "hand": h.hand, "level": h.level, "name": h.name, "online": h.online,
                    "pending": h.pending_approvals, "profile": h.profile,
                })
            })
            .collect();
        let pending: Vec<Value> = self
            .tracker
            .pending()
            .into_iter()
            .map(|a| json!({ "hand": a.hand, "id": a.id, "key": a.key, "summary": a.summary }))
            .collect();
        json!({
            "hands": hands,
            "log": request.get("log").cloned().unwrap_or_else(|| json!([])),
            "pending": pending,
            "prompt": field("prompt"),
            "result": field("result"),
            "secure_enclave": request.get("secure_enclave").and_then(Value::as_bool).unwrap_or(false),
        })
        .to_string()
    }
}

#[cfg(test)]
mod tests;
