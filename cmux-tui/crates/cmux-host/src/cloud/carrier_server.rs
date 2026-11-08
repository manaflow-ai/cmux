//! The session host's relay Register tickets on their own socket and threads
//! ([`CARRIER_SOCKET`]), so a Register never waits on the Cloud worker.
//!
//! The ticket used to be an agent socket line (`carrier_ticket.rs`): the
//! worker's poll loop accepted it and handed it to the GitHub minter. That
//! loop also sends the status reports and its other Cloud requests, each a
//! blocking request of up to 20 s, and a fresh machine runs them in its first
//! seconds. The session host's ticket command gave up after 10 s (cmux-remote
//! `relay.rs`), so its first Registers timed out behind them, two or three
//! times in a row (production probe, 2026-11-08), and the machine had no relay
//! route for 10 to 30 s after boot. The GitHub minter's queue (one mint at a
//! time, each up to three 20 s calls) was a second place to wait.
//!
//! Two threads serve it, with their own [`CloudClient`] (the same bound
//! machine and install key) from each bind on:
//!
//! - The fetch thread starts every platform request, each on a thread of its
//!   own, so it is never inside one. At a bind it mints the client's bearer
//!   at once and, on a machine with a relay carrier, asks for a ticket right
//!   then and keeps it ([`Warm`]). At a resume ([`Resumes`], noted by the
//!   role itself, never through the worker) it drops the kept ticket and the
//!   pooled connection from before the pause and asks for a fresh ticket. A
//!   request still in flight from before the pause (a dead connection hangs
//!   to its 20 s bound) is abandoned, not waited for: the fresh ticket is
//!   asked for on a transport of its own ([`CloudClient::fresh`]) and the late
//!   reply is dropped. Each bind and resume starts a generation, in the same
//!   step that notes it; no ticket asked for in an earlier one is kept or
//!   handed out. A kept ticket is
//!   refreshed [`REFRESH_BEFORE`] its expiry while no one took it, at most
//!   [`MAX_REFRESHES`] times per bind or resume; then it lapses and the
//!   thread waits with no timer. Otherwise it asks for a ticket only when an
//!   asker wants one.
//! - The socket thread answers the asks. An ask takes the kept ticket when
//!   there is one (no request). Otherwise it has the fetch thread ask and
//!   waits for the answer up to the ask wait ([`ASK_WAIT`], inside the
//!   command's own 30 s read), so a slow bearer mint or platform answer
//!   never runs past the session host's command: the ask gets a
//!   `carrier.slow` refusal and the ticket, when it comes, is kept for the
//!   next ask. An ask before the bind waits for it up to [`UNBOUND_WAIT`].
//!   A ticket handed out is not kept: an ask after that (a failed
//!   Register, a relay restart) is one request.
//!
//! All of the threads' shared state is one [`state::Core`] behind one lock,
//! and every change to it is one of its transitions (`carrier_state.rs`): a
//! bind, a resume note, an ask, a hand-out, the fetch thread's next job and
//! a request's start and answer.
//!
//! One line in (`{"carrier_ticket": {}}`, [`super::carrier_ticket::check_ask`]),
//! one reply line out ([`super::carrier_ticket::reply_for`]), then the
//! connection closes. Dropping the [`CarrierServer`] (the worker ending)
//! stops both threads and joins them; a request in flight is bounded by the
//! API client's timeouts, as the minter's are. The role's stop ([`Stop`],
//! shared with the minter) is the credential fence: once it is set, no ticket
//! is asked for ahead or handed out, also not one minted while it was set,
//! even when the worker is stuck past the role's deadline and has not
//! dropped this server yet.

use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::carrier_ticket::{REQUEST_KEY, check_ask};
use super::client::{CloudClient, Http};
use super::github::refusal;
use super::github_minter::{Stop, connected};

#[path = "carrier_state.rs"]
mod state;

use state::{Asked, Back, Core, Done, Hands, Job, Task, Warm};

/// The socket the ticket command asks first (root and group cmux, 0660,
/// beside the agent socket). An older cmux-host has none, and the command
/// then asks the agent socket.
pub const CARRIER_SOCKET: &str = "/run/cmux-vm-agent/carrier.sock";

/// How long an ask made before the bind waits for it, when no bind is in
/// progress.
pub const UNBOUND_WAIT: Duration = Duration::from_secs(8);

/// How long an ask waits for a ticket being asked for: under the 30 s that
/// `host cloud carrier-ticket` reads the answer for and well under the
/// session host's command timeout (cmux-remote
/// `DAEMON_TICKET_COMMAND_TIMEOUT`, 35 s), so the asker always gets a line.
pub const ASK_WAIT: Duration = Duration::from_secs(25);

/// A kept ticket is asked for again this long before it expires.
pub const REFRESH_BEFORE: Duration = Duration::from_secs(60);
/// A kept ticket with less than this left is not handed out (the device side
/// keeps the same margin, cmux-tui `carrier/answer.rs`).
pub const HAND_OUT_MARGIN: Duration = Duration::from_secs(30);
/// How many times an unused ticket is refreshed after a bind or a resume
/// before it lapses (with 300 s tickets, about 15 minutes warm).
pub const MAX_REFRESHES: u32 = 3;

/// How long the asker has to send its whole line.
const LINE_WAIT: Duration = Duration::from_secs(2);
/// A client that does not read its reply line within this is dropped.
const REPLY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// The ask is a short line; anything longer is refused.
const MAX_LINE: u64 = 1024;

type Waker = Box<dyn Fn() + Send + Sync>;

/// The machine's resumes, noted by the role on `HostEvent::Resumed`. The
/// role notes them itself, so a resume reaches the ticket threads even while
/// the worker is in a request, and the note is a transition on their state:
/// the ticket kept from before the pause is gone before `note` returns.
#[derive(Default)]
pub struct Resumes {
    /// Notes the resume in the ticket threads' state (set by
    /// [`CarrierServer::spawn`]).
    noter: Mutex<Option<Waker>>,
}

impl Resumes {
    /// The machine resumed.
    pub fn note(&self) {
        if let Some(note) = self.noter.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            note();
        }
    }

    fn set_noter(&self, noter: Option<Waker>) {
        *self.noter.lock().unwrap_or_else(PoisonError::into_inner) = noter;
    }
}

/// Where the threads' clock and journal come from, and the ask wait.
#[derive(Clone, Copy)]
pub struct Hooks {
    /// Wall-clock milliseconds.
    pub now: fn() -> u64,
    /// Journal lines: an outcome and its time, never a ticket.
    pub log: fn(&str),
    /// [`ASK_WAIT`] (shorter in tests).
    pub ask_wait: Duration,
}

/// What the worker hands the threads at a bind: the client, and whether the
/// machine has a relay carrier (then a ticket is asked for at once).
struct Next<H: Http> {
    client: CloudClient<H>,
    prefetch: bool,
}

/// What the threads share: the state and the client-bearing payloads it
/// carries, behind one lock.
type State<H> = Core<Next<H>, CloudClient<H>>;

struct Shared<H: Http> {
    state: Mutex<State<H>>,
    changed: Condvar,
    /// Tests: points where a test steps in between two steps of the threads.
    #[cfg(test)]
    test_points: TestPoints,
}

/// Tests: each is run once, where it is named, then cleared.
#[cfg(test)]
#[derive(Default)]
struct TestPoints {
    /// The socket thread, right before it hands out a ticket.
    before_handout: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// The fetch thread waits here (its state unlocked) at the top of its
    /// job loop until the sender sends or is dropped.
    hold_fetcher: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
    /// The fetch thread, after it took an asker's want and before it asks.
    before_wanted: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

#[cfg(test)]
impl TestPoints {
    fn run(point: &Mutex<Option<Box<dyn FnOnce() + Send>>>) {
        let step = point.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(step) = step {
            step();
        }
    }

    fn hold(&self) {
        let gate = self.hold_fetcher.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(gate) = gate {
            let _ = gate.recv();
        }
    }
}

impl<H: Http> Shared<H> {
    fn lock(&self) -> MutexGuard<'_, State<H>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Runs one transition under the lock and wakes the threads.
    fn change<T>(&self, transition: impl FnOnce(&mut State<H>) -> T) -> T {
        let made = transition(&mut self.lock());
        self.changed.notify_all();
        made
    }

    fn wait<'g>(
        &self,
        state: MutexGuard<'g, State<H>>,
        left: Option<Duration>,
    ) -> MutexGuard<'g, State<H>> {
        match left {
            Some(left) => {
                self.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0
            }
            None => self.changed.wait(state).unwrap_or_else(PoisonError::into_inner),
        }
    }
}

/// The worker's handle on the ticket threads.
pub struct CarrierServer<H: Http> {
    shared: Arc<Shared<H>>,
    resumes: Arc<Resumes>,
    /// Shutting it down stops the socket thread.
    wake: UnixStream,
    threads: Vec<JoinHandle<()>>,
}

impl<H: Http> Drop for CarrierServer<H> {
    fn drop(&mut self) {
        self.shared.change(|state| state.stop());
        self.resumes.set_noter(None);
        let _ = self.wake.shutdown(std::net::Shutdown::Both);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> CarrierServer<H> {
    /// Serves `listener` on new threads.
    pub fn spawn(
        listener: UnixListener,
        hooks: Hooks,
        stop: Arc<Stop>,
        resumes: Arc<Resumes>,
    ) -> io::Result<CarrierServer<H>> {
        listener.set_nonblocking(true)?;
        let (wake, woken) = UnixStream::pair()?;
        woken.set_nonblocking(true)?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            #[cfg(test)]
            test_points: TestPoints::default(),
        });
        let noting = Arc::clone(&shared);
        resumes.set_noter(Some(Box::new(move || noting.change(|state| state.note_resume()))));
        let (theirs, fetch_stop) = (Arc::clone(&shared), Arc::clone(&stop));
        let fetcher = std::thread::Builder::new()
            .name("cmux-host-carrier-fetch".to_owned())
            .spawn(move || {
                Fetcher {
                    shared: theirs,
                    stop: fetch_stop,
                    hooks,
                    hands: Hands::default(),
                    requests: Vec::new(),
                }
                .run();
            })?;
        let mut server = CarrierServer { shared, resumes, wake, threads: vec![fetcher] };
        // On a failed spawn, `server`'s drop stops the fetch thread.
        let theirs = Arc::clone(&server.shared);
        let socket = std::thread::Builder::new()
            .name("cmux-host-carrier".to_owned())
            .spawn(move || serve(&listener, &woken, &theirs, &stop, hooks))?;
        server.threads.push(socket);
        Ok(server)
    }

    /// The machine is bound (again): ask as this client from now on. With
    /// `prefetch` (the machine has a relay carrier), a ticket is asked for at
    /// once and kept for the session host's Register.
    pub fn bound(&self, client: CloudClient<H>, prefetch: bool) {
        // The bind's generation starts now, not when the fetch thread takes
        // it: an ask in between waits for the bind's ticket.
        self.shared.change(|state| state.bind(Next { client, prefetch }));
    }
}

/// The fetch thread: starts every platform request and takes its answer.
struct Fetcher<H: Http> {
    shared: Arc<Shared<H>>,
    stop: Arc<Stop>,
    hooks: Hooks,
    /// The bound client and its spare.
    hands: Hands<CloudClient<H>>,
    /// The request threads, joined at the stop (each is bounded by the API
    /// client's timeouts).
    requests: Vec<JoinHandle<()>>,
}

impl<H: Http + Send + 'static> Fetcher<H> {
    fn run(&mut self) {
        while let Some(job) = self.next_job() {
            match job {
                Job::Stop | Job::Wait(_) => {}
                Job::Bind(next, generation) => {
                    let Next { client, prefetch } = *next;
                    self.hands.bound(client, prefetch);
                    let ticket = prefetch.then_some(("prefetched", false));
                    self.start(Task { mint: true, ticket }, generation);
                }
                Job::Resume(generation) => {
                    self.hands.refreshes = 0;
                    self.resume(generation);
                }
                Job::Wanted(generation) => {
                    #[cfg(test)]
                    TestPoints::run(&self.shared.test_points.before_wanted);
                    self.start(Task::ticket("fetched for an ask", true), generation);
                }
                Job::Refresh(generation) => {
                    if self.hands.refreshes >= MAX_REFRESHES {
                        (self.hooks.log)("carrier ticket: the unused ticket lapses");
                        continue;
                    }
                    self.hands.refreshes += 1;
                    self.start(Task::ticket("refreshed", false), generation);
                }
                Job::Done(done, back, generation) => self.done(*done, back, generation),
            }
        }
        for request in self.requests.drain(..) {
            let _ = request.join();
        }
    }

    /// Waits for the next job; `None` once the server stops. The only timer
    /// is a kept ticket's refresh, bounded by [`MAX_REFRESHES`].
    fn next_job(&mut self) -> Option<Job<Next<H>, CloudClient<H>>> {
        let shared = Arc::clone(&self.shared);
        let mut state = shared.lock();
        loop {
            #[cfg(test)]
            if shared
                .test_points
                .hold_fetcher
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_some()
            {
                drop(state);
                shared.test_points.hold();
                state = shared.lock();
            }
            match state.next_job(self.hands.view(), (self.hooks.now)()) {
                Job::Stop => return None,
                Job::Wait(left) => state = shared.wait(state, left),
                job => {
                    // A request's answer is kept or answered in the pick itself.
                    shared.changed.notify_all();
                    return Some(job);
                }
            }
        }
    }

    /// The machine resumed: a request from before the pause is abandoned (a
    /// spare client on its own transport asks now), the pooled connection
    /// dropped, and on a carrier machine a fresh ticket asked for.
    fn resume(&mut self, generation: u64) {
        let Some(client) = self.hands.for_resume() else {
            // No spare: the resume acts once a client comes back, if no bind
            // or other resume came first.
            return self.shared.change(|state| state.defer_resume(generation));
        };
        client.reset_transport();
        if self.hands.prefetch {
            self.start(Task::ticket("prefetched after resume", false), generation);
        }
    }

    /// A request came back. One from an earlier generation is dropped; its
    /// client is used again only when there is no other or a resume of this
    /// generation waits for it (`resume`).
    fn done(&mut self, done: Done<CloudClient<H>>, back: Back, generation: u64) {
        let Done { client, task, reply, took, .. } = done;
        self.hands.returned(client, back);
        let Back { current, resume, .. } = back;
        let took = took.as_millis();
        if !current && task.ticket.is_some() && reply.is_some() {
            (self.hooks.log)(&format!(
                "carrier ticket: a ticket asked for before a resume or bind is dropped ({took} ms)"
            ));
        }
        if current && let (Some(reply), Some((what, _))) = (&reply, task.ticket) {
            let said =
                if reply.get("ok") == Some(&Value::Bool(true)) { what } else { outcome(reply) };
            (self.hooks.log)(&format!("carrier ticket: {said} in {took} ms"));
        }
        if resume {
            self.resume(generation);
        }
    }

    /// Runs `task` on the client, on a thread of its own, keeping a spare
    /// client for a resume while it is in flight. The request is of
    /// `generation`, the one its job was picked in: when a bind or resume
    /// came since, its reply is dropped. Nothing is asked once the role stops.
    fn start(&mut self, task: Task, generation: u64) {
        let Some(mut client) = self.hands.take(CloudClient::fresh) else {
            return;
        };
        self.shared.change(|state| state.starting(generation));
        self.requests.retain(|request| !request.is_finished());
        let (shared, stop, hooks) = (Arc::clone(&self.shared), Arc::clone(&self.stop), self.hooks);
        let spawned = std::thread::Builder::new()
            .name("cmux-host-carrier-request".to_owned())
            .spawn(move || {
                let started = Instant::now();
                if task.mint {
                    // A failure here is the first ticket's to report: it mints again.
                    let _ = client.token((hooks.now)());
                }
                let reply = task
                    .ticket
                    .filter(|_| !stop.is_set())
                    .map(|_| client.carrier_ticket((hooks.now)()));
                let took = started.elapsed();
                shared.change(|state| {
                    state.finished(Done { generation, client, task, reply, took });
                });
            });
        match spawned {
            Ok(request) => self.requests.push(request),
            Err(e) => {
                (self.hooks.log)(&format!("carrier ticket: request thread: {e}"));
                self.hands.not_started();
                self.shared.change(|state| state.not_started(generation));
            }
        }
    }
}

/// The socket thread: accepts askers one at a time until the stop.
fn serve<H: Http>(
    listener: &UnixListener,
    woken: &UnixStream,
    shared: &Shared<H>,
    stop: &Stop,
    hooks: Hooks,
) {
    loop {
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
            return (hooks.log)(&format!("carrier ticket: poll: {}", io::Error::last_os_error()));
        }
        let [listening, wake] = fds;
        if wake.revents != 0 && drained_to_end(woken) {
            return;
        }
        if listening.revents == 0 {
            continue;
        }
        while let Ok((stream, _)) = listener.accept() {
            if shared.lock().stopping {
                return;
            }
            answer(stream, shared, stop, hooks);
        }
    }
}

/// One asker: its line, then the kept ticket, a ticket asked for now or a
/// refusal.
fn answer<H: Http>(stream: UnixStream, shared: &Shared<H>, stop: &Stop, hooks: Hooks) {
    let started = Instant::now();
    let stopping = || refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
    if let Err(why) = read_ask(&stream) {
        return finish(stream, refusal("request.invalid", &why), false, started, hooks);
    }
    loop {
        let (mut reply, kept, generation) = ticket(shared, stop, hooks, started);
        if reply.get("ok") == Some(&Value::Bool(true)) && !connected(&stream) {
            // Gone while it waited: the ticket stays here for the next ask while
            // it may be handed out (the fetch thread refreshes it when it is due).
            if kept && let Some(warm) = Warm::handout(&reply, (hooks.now)()) {
                shared.change(|state| state.keep_unsent(warm, generation));
            }
            return;
        }
        #[cfg(test)]
        TestPoints::run(&shared.test_points.before_handout);
        // The checks and the write hold the state's lock (a bind's or a
        // resume's generation changes only under it) and then the stop's, so
        // a stop, a bind or a resume is either before both (no ticket from
        // before it goes out) or after the write. A ticket from before a
        // resume or bind is not handed out: the ask waits for the fresh one
        // (still within its wait). The reply is one short line, far under the
        // socket's buffer, and its write is bounded by REPLY_WRITE_TIMEOUT.
        let state = shared.lock();
        let stopped = stop.lock();
        if *stopped {
            reply = stopping();
        } else if reply.get("ok") == Some(&Value::Bool(true)) && !state.may_hand_out(generation) {
            drop(stopped);
            drop(state);
            continue;
        }
        let _ = write_reply(stream, &reply);
        drop(stopped);
        drop(state);
        return (hooks.log)(&note(&reply, kept, started.elapsed()));
    }
}

/// Writes a reply that is not a ticket and journals it.
fn finish(stream: UnixStream, reply: Value, kept: bool, started: Instant, hooks: Hooks) {
    let _ = write_reply(stream, &reply);
    (hooks.log)(&note(&reply, kept, started.elapsed()));
}

/// The reply for an ask that came at `started`, whether it was the kept
/// ticket, and the generation it is of. Waits for a bind up to
/// [`UNBOUND_WAIT`] and for a ticket being asked for up to the ask wait.
fn ticket<H: Http>(
    shared: &Shared<H>,
    stop: &Stop,
    hooks: Hooks,
    started: Instant,
) -> (Value, bool, u64) {
    let unbound_until = started + UNBOUND_WAIT;
    let deadline = started + hooks.ask_wait;
    let mut state = shared.lock();
    loop {
        if stop.is_set() {
            let stopping = refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
            return (stopping, false, state.generation);
        }
        match state.ask((hooks.now)(), started) {
            Asked::Stopping => {
                let stopping = refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
                return (stopping, false, state.generation);
            }
            Asked::Reply { reply, kept, generation } => {
                shared.changed.notify_all();
                return (reply, kept, generation);
            }
            Asked::Wait { busy } => {
                shared.changed.notify_all();
                let until = if busy { deadline } else { unbound_until };
                if let Some(left) =
                    until.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())
                {
                    state = shared.wait(state, Some(left));
                    continue;
                }
                let generation = state.generation;
                return if busy {
                    let slow =
                        "the carrier ticket is still on its way; it is kept for the next ask";
                    (refusal("carrier.slow", slow), false, generation)
                } else {
                    let unbound = "this machine is not bound to cmux Cloud yet";
                    (refusal("vm.unbound", unbound), false, generation)
                };
            }
        }
    }
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

/// The ask's line: exactly a `carrier_ticket` ask, all of it within
/// [`LINE_WAIT`] (a client sending a byte at a time does not hold the thread).
fn read_ask(stream: &UnixStream) -> Result<(), String> {
    let deadline = Instant::now() + LINE_WAIT;
    stream.set_nonblocking(false).map_err(|e| e.to_string())?;
    let mut line = Vec::new();
    let mut byte = [0_u8; 256];
    let mut reader = stream;
    while !line.contains(&b'\n') {
        let left = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or("the ask's line did not come in time")?;
        stream.set_read_timeout(Some(left)).map_err(|e| e.to_string())?;
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(n) => line.extend_from_slice(byte.get(..n).unwrap_or_default()),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return Err("the ask's line did not come in time".to_owned()),
        }
        if line.len() as u64 > MAX_LINE {
            return Err("the ask is too long".to_owned());
        }
    }
    let value: Value =
        serde_json::from_slice(&line).map_err(|_| "the ask is not one JSON line".to_owned())?;
    match value.get(REQUEST_KEY) {
        Some(ask) => check_ask(ask),
        None => Err("this socket answers only carrier_ticket".to_owned()),
    }
}

/// A reply's outcome: `issued`, or its error code.
fn outcome(reply: &Value) -> &str {
    if reply.get("ok") == Some(&Value::Bool(true)) {
        "issued"
    } else {
        reply.get("error").and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("refused")
    }
}

/// The journal line for one answer: its outcome, whether it was the kept
/// ticket, and how long it took.
fn note(reply: &Value, kept: bool, took: Duration) -> String {
    let from = if kept { " (kept)" } else { "" };
    format!("carrier ticket: {}{from} in {} ms", outcome(reply), took.as_millis())
}

fn write_reply(mut stream: UnixStream, reply: &Value) -> io::Result<()> {
    stream.set_write_timeout(Some(REPLY_WRITE_TIMEOUT))?;
    stream.write_all(format!("{reply}\n").as_bytes())
}

#[cfg(test)]
#[path = "carrier_server_tests.rs"]
mod tests;
