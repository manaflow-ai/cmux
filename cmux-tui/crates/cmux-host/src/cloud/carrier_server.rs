//! The session host's relay Register tickets on their own socket and thread
//! ([`CARRIER_SOCKET`]), so a Register never waits on the Cloud worker.
//!
//! The ticket used to be an agent socket line (`carrier_ticket.rs`): the
//! worker's poll loop accepted it and handed it to the GitHub minter. That
//! loop also sends the status reports, the Native receiving bootstrap and the
//! receiver's policy reads, each a blocking request of up to 20 s, and a
//! fresh machine runs all of them in its first seconds. The session host's
//! ticket command gives up after 10 s (cmux-remote `relay.rs`), so its first
//! Registers timed out behind them, two or three times in a row, and the
//! machine was unreachable over its relay for 10 to 30 s after boot.
//!
//! This thread owns its listener and its own [`CloudClient`] (the same bound
//! machine and install key) from each bind on, and asks the platform for the
//! ticket right away. It mints the client's bearer as soon as the bind hands
//! the client over, so the first ticket is one request. An ask that comes
//! before the bind waits for it, up to [`UNBOUND_WAIT`] (inside the ticket
//! command's 10 s), instead of failing into the session host's backoff.
//!
//! One line in (`{"carrier_ticket": {}}`, [`super::carrier_ticket::check_ask`]),
//! one reply line out ([`super::carrier_ticket::reply_for`]), then the
//! connection closes. Dropping the [`CarrierServer`] (the worker ending)
//! stops the thread and joins it; a request in flight is bounded by the API
//! client's timeouts, as the minter's are.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::carrier_ticket::{REQUEST_KEY, check_ask};
use super::client::{CloudClient, Http};
use super::github::refusal;
use super::github_minter::connected;

/// The socket the ticket command asks first (root and group cmux, 0660,
/// beside the agent socket). An older cmux-host has none, and the command
/// then asks the agent socket.
pub const CARRIER_SOCKET: &str = "/run/cmux-vm-agent/carrier.sock";

/// How long an ask made before the bind waits for it: under the session
/// host's 10 s ticket command timeout, so the ask is answered either way.
pub const UNBOUND_WAIT: Duration = Duration::from_secs(8);

/// How long the asker has to send its line.
const LINE_WAIT: Duration = Duration::from_secs(2);
/// A client that does not read its reply line within this is dropped.
const REPLY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// The ask is a short line; anything longer is refused.
const MAX_LINE: u64 = 1024;

/// What the worker hands the thread: the client of the latest bind, and the
/// stop.
struct Slot<H: Http> {
    next: Option<CloudClient<H>>,
    stopping: bool,
}

struct Shared<H: Http> {
    slot: Mutex<Slot<H>>,
    changed: Condvar,
}

impl<H: Http> Shared<H> {
    fn lock(&self) -> MutexGuard<'_, Slot<H>> {
        self.slot.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The worker's handle on the ticket thread.
pub struct CarrierServer<H: Http> {
    shared: Arc<Shared<H>>,
    /// One byte wakes the thread for a bind; shutting it down stops it.
    wake: UnixStream,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for CarrierServer<H> {
    fn drop(&mut self) {
        self.shared.lock().stopping = true;
        self.shared.changed.notify_all();
        let _ = self.wake.shutdown(std::net::Shutdown::Both);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> CarrierServer<H> {
    /// Serves `listener` on a new thread. `now` is wall-clock milliseconds;
    /// `log` takes journal lines (an outcome and its time, never a ticket).
    pub fn spawn(
        listener: UnixListener,
        now: fn() -> u64,
        log: fn(&str),
    ) -> io::Result<CarrierServer<H>> {
        listener.set_nonblocking(true)?;
        let (wake, woken) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        woken.set_nonblocking(true)?;
        let shared = Arc::new(Shared {
            slot: Mutex::new(Slot { next: None, stopping: false }),
            changed: Condvar::new(),
        });
        let theirs = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("cmux-host-carrier".to_owned())
            .spawn(move || run(&listener, &woken, &theirs, now, log))?;
        Ok(CarrierServer { shared, wake, thread: Some(thread) })
    }

    /// The machine is bound (again): ask as this client from now on.
    pub fn bound(&self, client: CloudClient<H>) {
        self.shared.lock().next = Some(client);
        self.shared.changed.notify_all();
        let _ = (&self.wake).write_all(&[1]);
    }
}

fn run<H: Http>(
    listener: &UnixListener,
    woken: &UnixStream,
    shared: &Shared<H>,
    now: fn() -> u64,
    log: fn(&str),
) {
    let mut client: Option<CloudClient<H>> = None;
    loop {
        if take_next(shared, &mut client, now) {
            return;
        }
        let mut fds = [
            libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: woken.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        // SAFETY: `fds` is a valid array of `fds.len()` pollfd entries.
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if n < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return log(&format!("carrier ticket: poll: {}", io::Error::last_os_error()));
        }
        let [listening, wake] = fds;
        if wake.revents != 0 && drained_to_end(woken) {
            return;
        }
        if listening.revents == 0 {
            continue;
        }
        while let Ok((stream, _)) = listener.accept() {
            if take_next(shared, &mut client, now) {
                return;
            }
            answer(stream, &mut client, shared, now, log);
        }
    }
}

/// Takes the client of a new bind and mints its bearer, so the first ticket
/// is one request. `true` once the server stops.
fn take_next<H: Http>(
    shared: &Shared<H>,
    client: &mut Option<CloudClient<H>>,
    now: fn() -> u64,
) -> bool {
    let mut slot = shared.lock();
    if slot.stopping {
        return true;
    }
    if let Some(mut next) = slot.next.take() {
        drop(slot);
        // A failure here is the first ticket's to report: it mints again.
        let _ = next.token(now());
        *client = Some(next);
    }
    false
}

/// Reads the wake bytes; `true` when the other end is gone (the stop).
fn drained_to_end(woken: &UnixStream) -> bool {
    let mut buf = [0_u8; 64];
    let mut reader = woken;
    loop {
        match reader.read(&mut buf) {
            Ok(0) => return true,
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return e.kind() != io::ErrorKind::WouldBlock,
        }
    }
}

/// Waits for the bind's client up to [`UNBOUND_WAIT`]; `None` when it did
/// not come or the server stops.
fn wait_bound<H: Http>(shared: &Shared<H>, now: fn() -> u64) -> Option<CloudClient<H>> {
    let deadline = Instant::now() + UNBOUND_WAIT;
    let mut slot = shared.lock();
    loop {
        if slot.stopping {
            return None;
        }
        if let Some(mut next) = slot.next.take() {
            drop(slot);
            let _ = next.token(now());
            return Some(next);
        }
        let left = deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())?;
        slot = shared.changed.wait_timeout(slot, left).unwrap_or_else(PoisonError::into_inner).0;
    }
}

/// One asker: its line, then the platform's ticket or a refusal.
fn answer<H: Http>(
    stream: UnixStream,
    client: &mut Option<CloudClient<H>>,
    shared: &Shared<H>,
    now: fn() -> u64,
    log: fn(&str),
) {
    let started = Instant::now();
    let reply = match read_ask(&stream) {
        Err(why) => refusal("request.invalid", &why),
        Ok(()) => {
            if client.is_none() {
                *client = wait_bound(shared, now);
            }
            if shared.lock().stopping {
                refusal("vm.agent_stopping", "the Cloud agent is stopping; retry")
            } else if !connected(&stream) {
                // Gone while it waited: no ticket for nobody.
                return;
            } else {
                match client.as_mut() {
                    None => refusal("vm.unbound", "this machine is not bound to cmux Cloud yet"),
                    Some(client) => client.carrier_ticket(now()),
                }
            }
        }
    };
    log(&note(&reply, started.elapsed()));
    let _ = write_reply(stream, &reply);
}

/// The ask's line: exactly a `carrier_ticket` ask.
fn read_ask(stream: &UnixStream) -> Result<(), String> {
    stream.set_nonblocking(false).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(LINE_WAIT)).map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream.take(MAX_LINE)).read_line(&mut line).map_err(|e| e.to_string())?;
    let value: Value =
        serde_json::from_str(&line).map_err(|_| "the ask is not one JSON line".to_owned())?;
    match value.get(REQUEST_KEY) {
        Some(ask) => check_ask(ask),
        None => Err("this socket answers only carrier_ticket".to_owned()),
    }
}

/// The journal line for one answer: its outcome and how long it took.
fn note(reply: &Value, took: Duration) -> String {
    let outcome = if reply.get("ok") == Some(&Value::Bool(true)) {
        "issued"
    } else {
        reply.get("error").and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("refused")
    };
    format!("carrier ticket: {outcome} in {} ms", took.as_millis())
}

fn write_reply(mut stream: UnixStream, reply: &Value) -> io::Result<()> {
    stream.set_write_timeout(Some(REPLY_WRITE_TIMEOUT))?;
    stream.write_all(format!("{reply}\n").as_bytes())
}

#[cfg(test)]
#[path = "carrier_server_tests.rs"]
mod tests;
