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
//!   reply is dropped. Each bind and resume starts a generation; no ticket
//!   asked for in an earlier one is kept or handed out. A kept ticket is
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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::carrier_ticket::{REQUEST_KEY, check_ask};
use super::client::{CloudClient, Http};
use super::github::refusal;
use super::github_minter::{Stop, connected};

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

/// The machine's resumes, noted by the role on `HostEvent::Resumed` and read
/// by the fetch thread. The role notes them itself, so a resume reaches the
/// thread even while the worker is in a request.
#[derive(Default)]
pub struct Resumes {
    count: AtomicU64,
    /// Wakes the fetch thread (set by [`CarrierServer::spawn`]).
    waker: Mutex<Option<Waker>>,
}

impl Resumes {
    /// The machine resumed.
    pub fn note(&self) {
        self.count.fetch_add(1, Ordering::SeqCst);
        if let Some(wake) = self.waker.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            wake();
        }
    }

    fn count(&self) -> u64 {
        self.count.load(Ordering::SeqCst)
    }

    fn set_waker(&self, waker: Option<Waker>) {
        *self.waker.lock().unwrap_or_else(PoisonError::into_inner) = waker;
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

/// What the two threads share.
struct State<H: Http> {
    /// The latest bind's client, until the fetch thread takes it.
    next: Option<Next<H>>,
    stopping: bool,
    /// The fetch thread holds a bound client.
    bound: bool,
    /// The fetch thread is minting or asking for a ticket.
    fetching: bool,
    /// An asker wants a ticket asked for.
    want: bool,
    /// A ticket asked for ahead, for the next ask.
    warm: Option<Warm>,
    /// The answer to a ticket an asker wanted, and when it came: for that
    /// asker, or, when it gave up, a ticket for the next ask.
    answered: Option<(Value, Instant)>,
    /// Requests that came back, for the fetch thread.
    done: Vec<Done<H>>,
}

struct Shared<H: Http> {
    state: Mutex<State<H>>,
    changed: Condvar,
    /// Bumped (under the state's lock) at each bind and resume. A ticket
    /// asked for in an earlier generation is never kept or handed out: the
    /// hand-out checks it and writes under the same lock.
    generation: AtomicU64,
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

    /// A bind or a resume (`state` is this lock's): nothing asked for before
    /// it is kept or handed out.
    fn new_generation(&self, state: &mut State<H>) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        state.warm = None;
        state.answered = None;
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
        self.shared.lock().stopping = true;
        self.shared.changed.notify_all();
        self.resumes.set_waker(None);
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
            state: Mutex::new(State {
                next: None,
                stopping: false,
                bound: false,
                fetching: false,
                want: false,
                warm: None,
                answered: None,
                done: Vec::new(),
            }),
            changed: Condvar::new(),
            generation: AtomicU64::new(0),
            #[cfg(test)]
            test_points: TestPoints::default(),
        });
        let waking = Arc::clone(&shared);
        resumes.set_waker(Some(Box::new(move || {
            let _held = waking.lock();
            waking.changed.notify_all();
        })));
        let (theirs, fetch_stop, fetch_resumes) =
            (Arc::clone(&shared), Arc::clone(&stop), Arc::clone(&resumes));
        let fetcher = std::thread::Builder::new()
            .name("cmux-host-carrier-fetch".to_owned())
            .spawn(move || {
                let seen = fetch_resumes.count();
                Fetcher {
                    shared: theirs,
                    stop: fetch_stop,
                    resumes: &fetch_resumes,
                    hooks,
                    client: None,
                    spare: None,
                    resume_waits: false,
                    requests: Vec::new(),
                    prefetch: false,
                    refreshes: 0,
                    seen,
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
        let mut state = self.shared.lock();
        // The bind's generation starts now, not when the fetch thread takes
        // it: an ask in between waits for the bind's ticket.
        self.shared.new_generation(&mut state);
        state.next = Some(Next { client, prefetch });
        drop(state);
        self.shared.changed.notify_all();
    }
}

/// A ticket asked for ahead and kept for the next ask: the reply line, and
/// its expiry (Unix seconds).
struct Warm {
    reply: Value,
    expires_at: u64,
}

impl Warm {
    /// The kept reply for a platform reply that is a ticket good past the
    /// refresh point at `now_ms`; `None` for a refusal or a ticket too short
    /// to keep. Only a ticket asked for ahead (prefetched or refreshed in the
    /// background) is held to this; one asked for an ask is good for
    /// [`Warm::handout`].
    fn of(reply: &Value, now_ms: u64) -> Option<Warm> {
        Self::handout(reply, now_ms).filter(|warm| {
            warm.expires_at.saturating_mul(1000) > now_ms + REFRESH_BEFORE.as_millis() as u64
        })
    }

    /// The reply for a platform reply that is a ticket that may still be
    /// handed out at `now_ms` ([`HAND_OUT_MARGIN`]); `None` for a refusal or
    /// a ticket too close to its expiry.
    fn handout(reply: &Value, now_ms: u64) -> Option<Warm> {
        let expires_at = reply.get("expires_at").and_then(Value::as_u64)?;
        let warm = Warm { reply: reply.clone(), expires_at };
        (reply.get("ok") == Some(&Value::Bool(true)) && warm.usable(now_ms)).then_some(warm)
    }

    /// How long from `now_ms` until it is refreshed (zero when due).
    fn refresh_in(&self, now_ms: u64) -> Duration {
        Duration::from_millis(
            self.expires_at
                .saturating_mul(1000)
                .saturating_sub(REFRESH_BEFORE.as_millis() as u64)
                .saturating_sub(now_ms),
        )
    }

    /// Whether it may still be handed out at `now_ms`.
    fn usable(&self, now_ms: u64) -> bool {
        self.expires_at.saturating_mul(1000) > now_ms + HAND_OUT_MARGIN.as_millis() as u64
    }
}

/// What the fetch thread does next, with the generation it is of, read
/// under the lock that picked it: a request it starts is of that generation,
/// also when a bind or resume comes before the request starts.
enum Job<H: Http> {
    Bind(Box<Next<H>>, u64),
    Resume(u64),
    Wanted(u64),
    Refresh(u64),
    /// A request came back; `current` when it is of this generation.
    Done(Box<Done<H>>, bool, u64),
}

/// One request: the bind's bearer mint, a ticket, or both.
#[derive(Clone, Copy)]
struct Task {
    /// Mint the bearer first (a bind).
    mint: bool,
    /// Ask for a ticket: what it is for the journal, and whether an asker
    /// wants it.
    ticket: Option<(&'static str, bool)>,
}

impl Task {
    fn ticket(what: &'static str, wanted: bool) -> Task {
        Task { mint: false, ticket: Some((what, wanted)) }
    }
}

/// A request that came back: its generation, the client it ran on and the
/// ticket reply (none for a bearer mint alone or once the role stopped).
struct Done<H: Http> {
    generation: u64,
    client: CloudClient<H>,
    task: Task,
    reply: Option<Value>,
    took: Duration,
}

/// The fetch thread: starts every platform request and takes its answer.
struct Fetcher<'a, H: Http> {
    shared: Arc<Shared<H>>,
    stop: Arc<Stop>,
    resumes: &'a Resumes,
    hooks: Hooks,
    /// The client, while no request is on it.
    client: Option<CloudClient<H>>,
    /// A client like the one in flight on a transport of its own, taken when
    /// a resume abandons that request.
    spare: Option<CloudClient<H>>,
    /// A resume came while the only client was in flight and none could be
    /// made: it acts once the client is back.
    resume_waits: bool,
    /// The request threads, joined at the stop (each is bounded by the API
    /// client's timeouts).
    requests: Vec<JoinHandle<()>>,
    /// The latest bind has a relay carrier: tickets are asked for ahead.
    prefetch: bool,
    /// Refreshes of an unused ticket since the last bind or resume.
    refreshes: u32,
    /// The resumes already acted on.
    seen: u64,
}

impl<H: Http + Send + 'static> Fetcher<'_, H> {
    fn run(&mut self) {
        while let Some(job) = self.next_job() {
            match job {
                Job::Bind(next, generation) => {
                    let Next { client, prefetch } = *next;
                    self.client = Some(client);
                    self.spare = None;
                    self.resume_waits = false;
                    self.prefetch = prefetch;
                    self.refreshes = 0;
                    let ticket = prefetch.then_some(("prefetched", false));
                    self.start(Task { mint: true, ticket }, generation);
                }
                Job::Resume(generation) => self.resume(generation),
                Job::Wanted(generation) => {
                    #[cfg(test)]
                    TestPoints::run(&self.shared.test_points.before_wanted);
                    self.start(Task::ticket("fetched for an ask", true), generation);
                }
                Job::Refresh(generation) => {
                    if self.refreshes >= MAX_REFRESHES {
                        (self.hooks.log)("carrier ticket: the unused ticket lapses");
                        continue;
                    }
                    self.refreshes += 1;
                    self.start(Task::ticket("refreshed", false), generation);
                }
                Job::Done(done, current, generation) => self.done(*done, current, generation),
            }
        }
        for request in self.requests.drain(..) {
            let _ = request.join();
        }
    }

    /// Waits for the next job; `None` once the server stops. The only timer
    /// is a kept ticket's refresh, bounded by [`MAX_REFRESHES`].
    fn next_job(&mut self) -> Option<Job<H>> {
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
            if state.stopping {
                return None;
            }
            // Read under the state's lock: a bind or resume bumps it only under it.
            let generation = shared.generation.load(Ordering::SeqCst);
            if let Some(done) = state.done.pop() {
                let current = done.generation == generation;
                if current {
                    state.fetching = false;
                    if let (Some(reply), Some((_, wanted))) = (&done.reply, done.task.ticket) {
                        if wanted {
                            state.answered = Some((reply.clone(), Instant::now()));
                        } else {
                            state.warm = Warm::of(reply, (self.hooks.now)());
                        }
                    }
                    shared.changed.notify_all();
                }
                return Some(Job::Done(Box::new(done), current, generation));
            }
            if let Some(next) = state.next.take() {
                state.bound = true;
                state.fetching = true;
                return Some(Job::Bind(Box::new(next), generation));
            }
            let resumes = self.resumes.count();
            if resumes != self.seen {
                self.seen = resumes;
                self.refreshes = 0;
                shared.new_generation(&mut state);
                let generation = shared.generation.load(Ordering::SeqCst);
                // A fresh ticket is asked for at once on a carrier machine;
                // otherwise an asker waiting on a request from before the
                // pause asks again.
                state.fetching = self.prefetch && (self.client.is_some() || self.spare.is_some());
                shared.changed.notify_all();
                return Some(Job::Resume(generation));
            }
            // `fetching` is set here, under the lock that took the want, so
            // an asker woken before the request starts does not ask again.
            if state.want && self.client.is_some() {
                state.want = false;
                state.fetching = true;
                return Some(Job::Wanted(generation));
            }
            let refresh = state.warm.as_ref().map(|warm| warm.refresh_in((self.hooks.now)()));
            if refresh.is_some_and(|left| left.is_zero()) && self.client.is_some() {
                state.warm = None;
                state.fetching = self.refreshes < MAX_REFRESHES;
                return Some(Job::Refresh(generation));
            }
            state = shared.wait(state, refresh.filter(|_| self.client.is_some()));
        }
    }

    /// The machine resumed: a request from before the pause is abandoned (a
    /// spare client on its own transport asks now), the pooled connection
    /// dropped, and on a carrier machine a fresh ticket asked for.
    fn resume(&mut self, generation: u64) {
        if self.client.is_none() {
            self.client = self.spare.take();
        }
        let Some(client) = self.client.as_ref() else {
            // No spare: the resume acts once the client from before it is back.
            self.resume_waits = true;
            return;
        };
        self.resume_waits = false;
        client.reset_transport();
        if self.prefetch {
            self.start(Task::ticket("prefetched after resume", false), generation);
        }
    }

    /// A request came back. One from an earlier generation is dropped; its
    /// client is used again only when there is no other.
    fn done(&mut self, done: Done<H>, current: bool, generation: u64) {
        let Done { client, task, reply, took, .. } = done;
        if self.client.is_none() && (current || self.spare.is_none() || self.resume_waits) {
            self.client = Some(client);
            if current {
                self.spare = None;
            }
        }
        let took = took.as_millis();
        if !current {
            if task.ticket.is_some() && reply.is_some() {
                (self.hooks.log)(&format!(
                    "carrier ticket: a ticket asked for before a resume or bind is dropped ({took} ms)"
                ));
            }
            if self.resume_waits {
                self.resume(generation);
            }
            return;
        }
        if let (Some(reply), Some((what, _))) = (&reply, task.ticket) {
            let said =
                if reply.get("ok") == Some(&Value::Bool(true)) { what } else { outcome(reply) };
            (self.hooks.log)(&format!("carrier ticket: {said} in {took} ms"));
        }
    }

    /// Runs `task` on the client, on a thread of its own, keeping a spare
    /// client for a resume while it is in flight. The request is of
    /// `generation`, the one its job was picked in: when a bind or resume
    /// came since, its reply is dropped. Nothing is asked once the role stops.
    fn start(&mut self, task: Task, generation: u64) {
        let Some(mut client) = self.client.take() else {
            return;
        };
        self.spare = client.fresh();
        {
            let mut state = self.shared.lock();
            if self.shared.generation.load(Ordering::SeqCst) == generation {
                state.fetching = true;
            }
        }
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
                shared.lock().done.push(Done { generation, client, task, reply, took });
                shared.changed.notify_all();
            });
        match spawned {
            Ok(request) => self.requests.push(request),
            Err(e) => {
                (self.hooks.log)(&format!("carrier ticket: request thread: {e}"));
                self.client = self.spare.take();
                self.shared.lock().fetching = false;
                self.shared.changed.notify_all();
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
        let current = || shared.generation.load(Ordering::SeqCst) == generation;
        if reply.get("ok") == Some(&Value::Bool(true)) && !connected(&stream) {
            // Gone while it waited: the ticket stays here for the next ask while
            // it may be handed out (the fetch thread refreshes it when it is due).
            if kept && let Some(warm) = Warm::handout(&reply, (hooks.now)()) {
                let mut state = shared.lock();
                if state.warm.is_none() && current() {
                    state.warm = Some(warm);
                }
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
        } else if reply.get("ok") == Some(&Value::Bool(true)) && !current() {
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
        // Read under the state's lock: the generation changes only with it.
        let generation = shared.generation.load(Ordering::SeqCst);
        if state.stopping || stop.is_set() {
            let stopping = refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
            return (stopping, false, generation);
        }
        if let Some(warm) = state.warm.take()
            && warm.usable((hooks.now)())
        {
            return (warm.reply, true, generation);
        }
        // A ticket asked for an ask is this ask's while it is good; a
        // refusal only when it came after this ask did.
        if let Some((answered, at)) = state.answered.take() {
            let good = Warm::handout(&answered, (hooks.now)()).is_some();
            let fresh = answered.get("ok") != Some(&Value::Bool(true)) && at >= started;
            if good || fresh {
                return (answered, false, generation);
            }
        }
        // A bind handed over or in progress counts: its ticket comes within the ask wait.
        let busy = state.bound || state.fetching || state.next.is_some();
        if state.bound && !state.fetching && !state.want {
            state.want = true;
            shared.changed.notify_all();
        }
        let until = if busy { deadline } else { unbound_until };
        let Some(left) = until.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())
        else {
            return if busy {
                let slow = "the carrier ticket is still on its way; it is kept for the next ask";
                (refusal("carrier.slow", slow), false, generation)
            } else {
                let unbound = "this machine is not bound to cmux Cloud yet";
                (refusal("vm.unbound", unbound), false, generation)
            };
        };
        state = shared.wait(state, Some(left));
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
