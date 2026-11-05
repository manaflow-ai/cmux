//! The simulation's app: one person's client of the daemon over the simulated network, as the
//! Mac app or the web pane talks to it. It makes one chat, then sends the plan's prompts and
//! steers at their times, each under its own client prompt id. A connection that breaks, or
//! that goes quiet while it waits for an answer (the one-way partition gives no error, only
//! silence), is dropped; the app connects again and sends every prompt it has no answer for
//! again under the same id, until each one has its answer: the retry HQ#6740 asks of a client
//! ("the client retries until acked, and the daemon dedupes by id").

use crate::plan::Prompt;
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

pub const DAEMON: &str = "daemon";
pub const PORT: u16 = 7000;
/// The person key every simulated daemon holds.
pub const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// A connection with nothing from the daemon this long while the app waits is dropped.
const QUIET: Duration = Duration::from_secs(20);
const QUIET_ERROR: &str = "the daemon went quiet";
/// Once every send has its answer, the app leaves after the daemon is this long quiet.
const SETTLE: Duration = Duration::from_secs(30);
/// How long the app keeps trying before it gives up on what it has no answer for.
pub const GIVE_UP: Duration = Duration::from_secs(30 * 60);

#[derive(Clone, Debug, Default)]
pub struct Item {
    pub sent: u32,
    pub accepted: bool,
    /// The answer's stopReason, or the error it ended with.
    pub outcome: Option<Result<String, String>>,
    /// Answers marked `_meta.acpmux.duplicate` (a resend answered from the log).
    pub duplicate_answers: u32,
}

#[derive(Default)]
pub struct App {
    pub session: Option<String>,
    /// Simulated time the chat existed at: the plan's times count from here.
    pub ready_at: Option<Duration>,
    pub items: Vec<(Prompt, Item)>,
    pub connections: u32,
    pub trace: Vec<String>,
    pub finished: bool,
    /// After the chat exists, when the plan's last fault has healed: a quiet before it may be
    /// a partition, not a settled daemon.
    pub calm_after: Duration,
    /// Simulated time as the driver last stepped it (outside the simulation's own context).
    pub clock: Duration,
}

/// The driver's clock, in milliseconds.
pub fn now_of(app: &App) -> u128 {
    app.clock.as_millis()
}

pub type Shared = Rc<RefCell<App>>;

/// Simulated time since the run started (the app never restarts; the daemon does).
pub fn now() -> Duration {
    turmoil::sim_elapsed().unwrap_or_default()
}

fn note(app: &Shared, line: String) {
    let t = now().as_millis();
    app.borrow_mut().trace.push(format!("{t:>8} app: {line}"));
}

struct Conn {
    write: turmoil::net::tcp::OwnedWriteHalf,
    lines: tokio::io::Lines<BufReader<turmoil::net::tcp::OwnedReadHalf>>,
    next_id: i64,
    /// Request id to the prompt id it carries.
    prompts: HashMap<i64, String>,
}

impl Conn {
    async fn open() -> std::io::Result<Self> {
        let stream = turmoil::net::TcpStream::connect((DAEMON, PORT)).await?;
        let (read, write) = stream.into_split();
        Ok(Self { write, lines: BufReader::new(read).lines(), next_id: 0, prompts: HashMap::new() })
    }

    async fn send(&mut self, method: &str, params: Value) -> std::io::Result<i64> {
        self.next_id += 1;
        let mut line =
            json!({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
                .to_string();
        line.push('\n');
        self.write.write_all(line.as_bytes()).await?;
        Ok(self.next_id)
    }

    async fn next(&mut self, quiet: Duration) -> std::io::Result<Value> {
        let deadline = tokio::time::Instant::now() + quiet;
        loop {
            match tokio::time::timeout_at(deadline, self.lines.next_line()).await {
                Err(_) => return Err(std::io::Error::other(QUIET_ERROR)),
                Ok(Ok(Some(line))) if line.trim().is_empty() => continue,
                Ok(Ok(Some(line))) => {
                    return serde_json::from_str(&line).map_err(|e| {
                        std::io::Error::other(format!(
                            "{e}: {}",
                            line.chars().take(200).collect::<String>()
                        ))
                    });
                }
                Ok(Ok(None)) => {
                    return Err(std::io::Error::other("the daemon closed the connection"));
                }
                Ok(Err(e)) => return Err(e),
            }
        }
    }

    /// One request's answer; notifications before it are read and handled.
    async fn call(&mut self, app: &Shared, method: &str, params: Value) -> std::io::Result<Value> {
        let id = self.send(method, params).await?;
        loop {
            let msg = self.next(QUIET).await?;
            if msg["id"] == json!(id) {
                if let Some(e) = msg.get("error") {
                    return Err(std::io::Error::other(format!("{method}: {e}")));
                }
                return Ok(msg["result"].clone());
            }
            self.handle(app, &msg);
        }
    }

    async fn handshake(&mut self, app: &Shared) -> std::io::Result<()> {
        let init = self
            .call(
                app,
                acpmux::rpc::method::INITIALIZE,
                json!({"protocolVersion": 1, "clientInfo": {"name": "sim"}}),
            )
            .await?;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap_or_default(),
            challenge["connection"].as_str().unwrap_or_default(),
        )
        .unwrap_or_default();
        self.call(app, "_acpmux/person_prove", json!({"proof": proof})).await?;
        Ok(())
    }

    /// A notification, or a prompt's answer.
    fn handle(&mut self, app: &Shared, msg: &Value) {
        if msg["method"] == acpmux::rpc::method::MUX_PROMPT_ACCEPTED {
            let pid = msg["params"]["promptId"].as_str().unwrap_or_default();
            let mut a = app.borrow_mut();
            if let Some((_, item)) = a.items.iter_mut().find(|(s, _)| s.prompt_id == pid) {
                item.accepted = true;
            }
            return;
        }
        let Some(id) = msg["id"].as_i64() else { return };
        let Some(pid) = self.prompts.remove(&id) else { return };
        let outcome = match msg.get("error") {
            Some(e) => Err(e["message"].as_str().unwrap_or("error").to_owned()),
            // A resend of a turn a restart cut answers from the log: no stopReason, its status
            // (`failed`, outcome unknown; the daemon goes on with its continuation).
            None => Ok(msg["result"]["stopReason"]
                .as_str()
                .or(msg["result"]["_meta"]["acpmux"]["status"].as_str())
                .unwrap_or("?")
                .to_owned()),
        };
        let duplicate = msg["result"]["_meta"]["acpmux"]["duplicate"] == json!(true);
        let odd = if matches!(&outcome, Ok(s) if s == "?") {
            format!(" {}", msg["result"])
        } else {
            String::new()
        };
        note(
            app,
            format!(
                "{pid} answered {outcome:?}{}{odd}",
                if duplicate { " (duplicate)" } else { "" }
            ),
        );
        let mut a = app.borrow_mut();
        if let Some((_, item)) = a.items.iter_mut().find(|(s, _)| s.prompt_id == pid) {
            item.duplicate_answers += duplicate as u32;
            if item.outcome.is_none() {
                item.outcome = Some(outcome);
            }
        }
    }

    async fn prompt(&mut self, app: &Shared, send: &Prompt, resend: bool) -> std::io::Result<()> {
        let session = app.borrow().session.clone().unwrap_or_default();
        let params = json!({
            "sessionId": session,
            "prompt": [{"type": "text", "text": send.text}],
            "_meta": {"acpmux": {"promptId": send.prompt_id, "steer": send.steer, "resend": resend}},
        });
        let id = self.send(acpmux::rpc::method::SESSION_PROMPT, params).await?;
        self.prompts.insert(id, send.prompt_id.clone());
        let mut a = app.borrow_mut();
        let first =
            a.items.iter_mut().find(|(s, _)| s.prompt_id == send.prompt_id).map(|(_, i)| {
                i.sent += 1;
                i.sent == 1
            });
        drop(a);
        note(
            app,
            format!("{} {}", if first == Some(true) { "send" } else { "resend" }, send.prompt_id),
        );
        Ok(())
    }
}

/// What the app still owes: sends due by now with no answer yet, and the time of the next send.
fn due(app: &Shared) -> (Vec<Prompt>, Option<Duration>) {
    let a = app.borrow();
    let Some(ready) = a.ready_at else { return (Vec::new(), None) };
    let elapsed = now().saturating_sub(ready);
    let mut owed = Vec::new();
    let mut next = None;
    for (send, item) in &a.items {
        if item.outcome.is_some() {
            continue;
        }
        if send.at <= elapsed {
            owed.push(send.clone());
        } else {
            next = next.min(Some(send.at)).or(Some(send.at));
        }
    }
    (owed, next.map(|t| ready + t))
}

fn all_answered(app: &Shared) -> bool {
    app.borrow().items.iter().all(|(_, i)| i.outcome.is_some())
}

/// The app's whole run: until every send has its answer and the daemon has settled (a quiet
/// connection after the last answer), or [`GIVE_UP`]. A connection that breaks while it
/// settles is opened again: a crash then still gets its restart and restore.
pub async fn run(app: Shared, resend_flag: bool) -> turmoil::Result {
    while now() <= GIVE_UP {
        let conn = tokio::time::timeout(Duration::from_secs(5), Conn::open()).await;
        let Ok(Ok(mut conn)) = conn else {
            tokio::time::sleep(Duration::from_millis(500)).await;
            continue;
        };
        app.borrow_mut().connections += 1;
        match session(&app, &mut conn, resend_flag).await {
            Ok(()) => break,
            Err(e) => {
                note(&app, format!("connection dropped: {e}"));
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
    }
    let mut a = app.borrow_mut();
    a.finished = true;
    Ok(())
}

/// One connection: the handshake, the chat (once), every unanswered send again, then new sends.
async fn session(app: &Shared, conn: &mut Conn, resend_flag: bool) -> std::io::Result<()> {
    conn.handshake(app).await?;
    if app.borrow().session.is_none() {
        let s = conn
            .call(
                app,
                acpmux::rpc::method::SESSION_NEW,
                json!({"cwd": std::env::temp_dir(), "mcpServers": []}),
            )
            .await?;
        let id = s["sessionId"].as_str().unwrap_or_default().to_owned();
        note(app, "chat started".into());
        let mut a = app.borrow_mut();
        a.session = Some(id);
        a.ready_at = Some(now());
    }
    // What this connection has sent, by prompt id.
    let mut sent_here = std::collections::HashSet::new();
    loop {
        let (owed, next) = due(app);
        for send in owed {
            if sent_here.insert(send.prompt_id.clone()) {
                let again = app
                    .borrow()
                    .items
                    .iter()
                    .any(|(s, i)| s.prompt_id == send.prompt_id && i.sent > 0);
                conn.prompt(app, &send, again && resend_flag).await?;
            }
        }
        if all_answered(app) {
            // Every send has its answer; the daemon may still be working (a turn a restart cut
            // goes on as its continuation). Stay until it has said nothing for SETTLE, so the
            // run ends on the daemon's settled state, not on the app's last answer.
            loop {
                match conn.next(SETTLE).await {
                    Ok(msg) => conn.handle(app, &msg),
                    Err(e) if e.to_string() == QUIET_ERROR => {
                        let calm = app.borrow().ready_at.map(|r| r + app.borrow().calm_after);
                        if calm.is_some_and(|c| now() >= c) {
                            return Ok(());
                        }
                        // A fault may still hide the daemon: drop this connection, open another.
                        return Err(e);
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        let waiting = !conn.prompts.is_empty();
        let until_next = next.map(|t| t.saturating_sub(now())).unwrap_or(QUIET);
        let wait = if waiting { until_next.min(QUIET) } else { until_next };
        match tokio::time::timeout(wait, conn.next(QUIET)).await {
            Ok(msg) => {
                let msg = msg?;
                conn.handle(app, &msg);
            }
            Err(_) => continue, // a send is due
        }
    }
}
