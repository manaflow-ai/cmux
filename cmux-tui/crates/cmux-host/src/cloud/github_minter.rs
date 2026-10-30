//! The GitHub minter: one thread beside the Cloud worker that answers
//! GitHub token asks (`github.rs`) and hand-off reports (`handoff.rs`), so
//! an API call (up to 20 s, plus a bearer refresh) never stalls the
//! worker's poll loop.
//!
//! The worker hands over each asking connection; the minter answers it
//! with one line and closes it. Asks are answered one at a time; at most
//! [`MAX_PENDING`] wait, and the worker answers more with `busy` at once.
//! The minter has its own [`CloudClient`] (the same bound machine and
//! install key) from each bind on. Dropping the [`Minter`] (the worker
//! ending) stops it: asks still queued get `vm.agent_stopping`, and the
//! drop joins the thread, so it waits for the one mint in flight (bounded
//! by the API client's timeouts, as the worker's own requests are). The
//! stop flag is shared with the role, which sets it before it asks the
//! worker to stop: a token minted after that is never handed out, even
//! when the worker is stuck in a request and the role's deadline passes.
//!
//! Before each mint the minter checks the asker is still connected (a
//! client gone while queued costs no token) and that it has waited at
//! most [`MAX_QUEUE_WAIT`] (older asks get `busy`, so a reply always
//! comes within the CLI's timeout).

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::client::{CloudClient, Http};
use super::github::{self, TokenAsk};
use super::handoff::{self, HandoffReport};

/// Asks that may wait for the minter; more are answered `busy`.
pub const MAX_PENDING: usize = 8;
/// An ask that waited longer than this is answered `busy`, not minted:
/// with one mint (at most three 20 s API calls, twice with a bearer
/// retry) after it, the reply comes within the CLI's 240 s.
pub const MAX_QUEUE_WAIT: Duration = Duration::from_secs(60);
/// A client that does not read its reply line within this is dropped.
const REPLY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// One connection's ask: a GitHub token or a hand-off report, each as
/// checked (`Err` names what was wrong with it).
pub enum Ask {
    Github(Result<TokenAsk, String>),
    Handoff(Result<HandoffReport, String>),
}

impl From<Result<TokenAsk, String>> for Ask {
    fn from(ask: Result<TokenAsk, String>) -> Ask {
        Ask::Github(ask)
    }
}

impl From<Result<HandoffReport, String>> for Ask {
    fn from(report: Result<HandoffReport, String>) -> Ask {
        Ask::Handoff(report)
    }
}

enum Msg<H: Http> {
    Bound(Box<CloudClient<H>>),
    Ask(Ask, UnixStream, Instant),
}

/// A `busy` reply never holds the poll loop longer than this.
const BUSY_WRITE_TIMEOUT: Duration = Duration::from_millis(200);

/// The role's stop, shared with the minter. Setting it waits for a reply
/// being written, and a reply is written only while it is unset, so no
/// token is handed out once [`Stop::set`] returns.
#[derive(Default)]
pub struct Stop(Mutex<bool>);

impl Stop {
    pub fn set(&self) {
        *self.lock() = true;
    }

    fn is_set(&self) -> bool {
        *self.lock()
    }

    fn lock(&self) -> MutexGuard<'_, bool> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The worker's handle on the minter thread.
pub struct Minter<H: Http> {
    tx: Option<Sender<Msg<H>>>,
    pending: Arc<AtomicUsize>,
    stop: Arc<Stop>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for Minter<H> {
    fn drop(&mut self) {
        self.stop.set();
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> Minter<H> {
    /// Starts the thread. `now` is wall-clock milliseconds; `log` takes
    /// journal lines (repo, permissions and outcome; never a token). Once
    /// `stop` is set no token is handed out.
    pub fn spawn(now: fn() -> u64, log: fn(&str), stop: Arc<Stop>) -> io::Result<Minter<H>> {
        let (tx, rx) = mpsc::channel();
        let pending = Arc::new(AtomicUsize::new(0));
        let (counter, stopping) = (Arc::clone(&pending), Arc::clone(&stop));
        let thread = std::thread::Builder::new()
            .name("cmux-host-github".to_owned())
            .spawn(move || run(&rx, &counter, &stopping, now, log))?;
        Ok(Minter { tx: Some(tx), pending, stop, thread: Some(thread) })
    }

    /// The machine is bound (again): mint as this client from now on.
    pub fn bound(&self, client: CloudClient<H>) {
        if let Some(tx) = self.tx.as_ref() {
            let _ = tx.send(Msg::Bound(Box::new(client)));
        }
    }

    /// Hands one asking connection to the minter, or answers `busy` now.
    pub fn ask(&self, ask: impl Into<Ask>, mut stream: UnixStream) {
        let ask = ask.into();
        if self.pending.fetch_add(1, Ordering::SeqCst) >= MAX_PENDING {
            self.pending.fetch_sub(1, Ordering::SeqCst);
            let busy = github::refusal("busy", "too many asks are waiting; retry");
            let _ = write_reply(&mut stream, &busy, BUSY_WRITE_TIMEOUT);
            return;
        }
        let sent = self.tx.as_ref().map(|tx| tx.send(Msg::Ask(ask, stream, Instant::now())));
        if !matches!(sent, Some(Ok(()))) {
            self.pending.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

fn run<H: Http>(
    rx: &Receiver<Msg<H>>,
    pending: &AtomicUsize,
    stop: &Stop,
    now: fn() -> u64,
    log: fn(&str),
) {
    let mut client: Option<Box<CloudClient<H>>> = None;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Bound(next) => client = Some(next),
            Msg::Ask(ask, mut stream, queued) => {
                let stopping =
                    || github::refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
                let mut reply = if stop.is_set() {
                    stopping()
                } else if queued.elapsed() > MAX_QUEUE_WAIT {
                    github::refusal("busy", "the ask waited too long; retry")
                } else if !connected(&stream) {
                    pending.fetch_sub(1, Ordering::SeqCst);
                    continue;
                } else {
                    match ask {
                        Ask::Github(ask) => answer(client.as_deref_mut(), ask, now(), log),
                        Ask::Handoff(report) => {
                            answer_report(client.as_deref_mut(), report, now(), log)
                        }
                    }
                };
                // A stop during the mint (a park or shutdown): the token is
                // not handed out after it; the API keeps it in its ledger.
                // The check and the write hold the lock, so a stop is
                // either before both or after the write.
                let stopped = stop.lock();
                if *stopped {
                    reply = stopping();
                }
                let _ = write_reply(&mut stream, &reply, REPLY_WRITE_TIMEOUT);
                drop(stopped);
                pending.fetch_sub(1, Ordering::SeqCst);
            }
        }
    }
}

/// The reply for one ask: a refusal before a bind or for a malformed ask,
/// else the API's answer.
pub fn answer<H: Http>(
    client: Option<&mut CloudClient<H>>,
    ask: Result<TokenAsk, String>,
    now_wall_ms: u64,
    log: fn(&str),
) -> Value {
    let ask = match ask {
        Ok(ask) => ask,
        Err(why) => return github::refusal("request.invalid", &why),
    };
    let Some(client) = client else {
        return github::refusal("vm.unbound", "this machine is not bound to cmux Cloud yet");
    };
    let reply = github::reply_for(&ask, &client.github_token(&ask, now_wall_ms));
    log(&github::note_for(&ask, &reply));
    reply
}

/// The reply for one hand-off report: a refusal before a bind or for a
/// malformed report, else the API's answer.
pub fn answer_report<H: Http>(
    client: Option<&mut CloudClient<H>>,
    report: Result<HandoffReport, String>,
    now_wall_ms: u64,
    log: fn(&str),
) -> Value {
    let report = match report {
        Ok(report) => report,
        Err(why) => return handoff::refusal("request.invalid", &why),
    };
    let Some(client) = client else {
        return handoff::refusal("vm.unbound", "this machine is not bound to cmux Cloud yet");
    };
    let (id, answer) = client.handoff_report(&report, now_wall_ms);
    let reply = handoff::reply_for(&answer);
    log(&handoff::note_for(&id, &report, &reply));
    reply
}

/// Whether the asker is still there: its connection is not at EOF. It sent
/// its one line and waits, so anything it sends more is dropped.
pub fn connected(stream: &UnixStream) -> bool {
    let mut byte = [0_u8; 1];
    let mut reader = stream;
    if stream.set_nonblocking(true).is_err() {
        return false;
    }
    loop {
        match reader.read(&mut byte) {
            Ok(n) => return n > 0,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return e.kind() == io::ErrorKind::WouldBlock,
        }
    }
}

/// One reply line, blocking, bounded by `timeout`.
fn write_reply(stream: &mut UnixStream, reply: &Value, timeout: Duration) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(format!("{reply}\n").as_bytes())
}
