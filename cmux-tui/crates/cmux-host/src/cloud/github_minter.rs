//! The GitHub minter: one thread beside the Cloud worker that answers
//! GitHub token asks (`github.rs`), so a mint (an API call of up to 20 s,
//! plus a bearer refresh) never stalls the worker's poll loop.
//!
//! The worker hands over each asking connection; the minter answers it
//! with one line and closes it. Asks are answered one at a time; at most
//! [`MAX_PENDING`] wait, and the worker answers more with `busy` at once.
//! The minter has its own [`CloudClient`] (the same bound machine and
//! install key) from each bind on. It ends when the worker drops its
//! [`Minter`] (the channel closes).

use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

use serde_json::Value;

use super::client::{CloudClient, Http};
use super::github::{self, TokenAsk};

/// Asks that may wait for the minter; more are answered `busy`.
pub const MAX_PENDING: usize = 8;
/// A client that does not read its reply line within this is dropped.
const REPLY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);

enum Msg<H: Http> {
    Bound(Box<CloudClient<H>>),
    Ask(Result<TokenAsk, String>, UnixStream),
}

/// The worker's handle on the minter thread.
pub struct Minter<H: Http> {
    tx: Sender<Msg<H>>,
    pending: Arc<AtomicUsize>,
}

impl<H: Http + Send + 'static> Minter<H> {
    /// Starts the thread. `now` is wall-clock milliseconds; `log` takes
    /// journal lines (repo, permissions and outcome; never a token).
    pub fn spawn(now: fn() -> u64, log: fn(&str)) -> io::Result<Minter<H>> {
        let (tx, rx) = mpsc::channel();
        let pending = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&pending);
        std::thread::Builder::new()
            .name("cmux-host-github".to_owned())
            .spawn(move || run(&rx, &counter, now, log))?;
        Ok(Minter { tx, pending })
    }

    /// The machine is bound (again): mint as this client from now on.
    pub fn bound(&self, client: CloudClient<H>) {
        let _ = self.tx.send(Msg::Bound(Box::new(client)));
    }

    /// Hands one asking connection to the minter, or answers `busy` now.
    pub fn ask(&self, ask: Result<TokenAsk, String>, mut stream: UnixStream) {
        if self.pending.fetch_add(1, Ordering::SeqCst) >= MAX_PENDING {
            self.pending.fetch_sub(1, Ordering::SeqCst);
            let busy = github::refusal("busy", "too many GitHub token asks are waiting; retry");
            let _ = stream.set_nonblocking(true);
            let _ = stream.write_all(format!("{busy}\n").as_bytes());
            return;
        }
        // The minter is gone only when the worker is: the connection closes.
        if self.tx.send(Msg::Ask(ask, stream)).is_err() {
            self.pending.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

fn run<H: Http>(rx: &Receiver<Msg<H>>, pending: &AtomicUsize, now: fn() -> u64, log: fn(&str)) {
    let mut client: Option<Box<CloudClient<H>>> = None;
    while let Ok(msg) = rx.recv() {
        match msg {
            Msg::Bound(next) => client = Some(next),
            Msg::Ask(ask, mut stream) => {
                let reply = answer(client.as_deref_mut(), ask, now(), log);
                let _ = write_reply(&mut stream, &reply);
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

/// One reply line, blocking, bounded by [`REPLY_WRITE_TIMEOUT`].
fn write_reply(stream: &mut UnixStream, reply: &Value) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(REPLY_WRITE_TIMEOUT))?;
    stream.write_all(format!("{reply}\n").as_bytes())
}
