//! The Auto mode socket ([`SOCKET`]): the machine's daemon asks one store
//! call per connection (`auto_session.rs`), and the agent sends it as this
//! machine's `vm` install and writes one reply line.
//!
//! It is not the agent socket, and its calls do not go through the GitHub
//! minter, for three reasons. A call's line is up to 2 MiB (a chunk), and the
//! agent socket drops a client past 64 KiB. One call, `assignments`, is held
//! by the store for 25 s, and the minter answers one ask at a time. And a
//! held chat renews every 10 s while its copy uploads: a renewal that waited
//! behind either would lose the chat to a lapsed lease.
//!
//! So each connection gets a thread of its own (at most [`MAX_ACTIVE`], more
//! are answered `busy` at once) and its own [`CloudClient`], taken from a
//! pool of idle ones or made by the bind's maker: the same bound machine and
//! install key, its own HTTPS connection and bearer cache. A request never
//! queues behind another.
//!
//! A resume ([`Resumes`], noted by the role itself): the connections from
//! before the pause are dead and nothing says so. Idle clients drop theirs at
//! once and busy ones when they come back. A held `assignments` wait is
//! answered `auto.resumed` right then, so the daemon asks again on a fresh
//! connection instead of waiting out a dead one; the abandoned request ends
//! by its own bound.
//!
//! Dropping the [`AutoSessions`] (the worker ending) stops the accepting
//! thread and joins it. A call in flight ends by its request's bound (at most
//! 35 s); its reply is written only while the role's stop is unset.

use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_server::cloud_http::{Payload, RawRequest};
use serde_json::Value;

use super::auto_session::{
    Call, Kind, MAX_LINE, REQUEST_KEY, SOCKET, machine_reply, note_for, refusal, reply_for,
};
use super::carrier_server::Resumes;
use super::client::{CloudClient, Http};
use super::github_minter::{Stop, connected};

/// The socket's path under the agent's run directory.
pub const AUTO_SESSION_SOCKET: &str = SOCKET;

/// Calls in flight at once; more are answered `busy`.
pub const MAX_ACTIVE: usize = 16;
/// Held `assignments` waits at once; more are answered `busy`. A daemon holds
/// one, and one more may be left from before a resume.
pub const MAX_HELD: usize = 4;
/// Idle clients kept for the next call (each has an HTTPS connection); a
/// burst's extra ones are dropped when they come back.
const MAX_IDLE: usize = 4;

/// How long the asker has to send its whole line (up to 2 MiB, from this
/// machine's own daemon).
const LINE_WAIT: Duration = Duration::from_secs(10);
/// A client that does not read its reply line within this is dropped.
const REPLY_WRITE_TIMEOUT: Duration = Duration::from_secs(20);
/// A `busy` reply never holds the accepting thread longer than this.
const BUSY_WRITE_TIMEOUT: Duration = Duration::from_millis(200);

/// Where the threads' clock and journal come from.
#[derive(Clone, Copy)]
pub struct Hooks {
    /// Wall-clock milliseconds.
    pub now: fn() -> u64,
    /// Journal lines: a call and its outcome, never a chat's content.
    pub log: fn(&str),
}

/// Makes one more client for the bound machine.
type Maker<H> = Arc<dyn Fn() -> Result<CloudClient<H>, String> + Send + Sync>;

/// What a held wait's thread is woken with: its answer, or `None` when the
/// machine resumed or the agent stops first.
type Wake = Sender<Option<Value>>;

struct State<H: Http> {
    /// The bound machine and the maker of its clients; `None` before a bind.
    bound: Option<(String, Maker<H>)>,
    idle: Vec<CloudClient<H>>,
    /// Counts binds: a client of an earlier bind is not kept.
    binds: u64,
    /// Counts resumes: a client from before one drops its connection.
    resumes: u64,
    active: usize,
    /// The held waits and their ids.
    held: Vec<(u64, Wake)>,
    next_held: u64,
    stopping: bool,
}

struct Shared<H: Http> {
    state: Mutex<State<H>>,
    stop: Arc<Stop>,
    hooks: Hooks,
}

impl<H: Http> Shared<H> {
    fn lock(&self) -> MutexGuard<'_, State<H>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The machine resumed: see the module's note.
    fn resumed(&self) {
        let mut state = self.lock();
        state.resumes += 1;
        for client in &state.idle {
            client.reset_transport();
        }
        for (_, wake) in state.held.drain(..) {
            let _ = wake.send(None);
        }
    }
}

/// The worker's handle on the socket's threads.
pub struct AutoSessions<H: Http> {
    shared: Arc<Shared<H>>,
    /// Shutting it down stops the accepting thread.
    wake: UnixStream,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for AutoSessions<H> {
    fn drop(&mut self) {
        {
            let mut state = self.shared.lock();
            state.stopping = true;
            state.idle.clear();
            for (_, wake) in state.held.drain(..) {
                let _ = wake.send(None);
            }
        }
        let _ = self.wake.shutdown(std::net::Shutdown::Both);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> AutoSessions<H> {
    /// Serves `listener` on new threads. `resumes` is the role's resume note.
    pub fn spawn(
        listener: UnixListener,
        hooks: Hooks,
        stop: Arc<Stop>,
        resumes: &Resumes,
    ) -> io::Result<AutoSessions<H>> {
        listener.set_nonblocking(true)?;
        let (wake, woken) = UnixStream::pair()?;
        woken.set_nonblocking(true)?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                bound: None,
                idle: Vec::new(),
                binds: 0,
                resumes: 0,
                active: 0,
                held: Vec::new(),
                next_held: 0,
                stopping: false,
            }),
            stop,
            hooks,
        });
        let noting: Weak<Shared<H>> = Arc::downgrade(&shared);
        resumes.also(Box::new(move || {
            if let Some(shared) = noting.upgrade() {
                shared.resumed();
            }
        }));
        let theirs = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("cmux-host-auto-session".to_owned())
            .spawn(move || serve(&listener, &woken, &theirs))?;
        Ok(AutoSessions { shared, wake, thread: Some(thread) })
    }

    /// The machine is bound (again) as `machine`: call as clients `make`
    /// makes from now on.
    pub fn bound(
        &self,
        machine: &str,
        make: impl Fn() -> Result<CloudClient<H>, String> + Send + Sync + 'static,
    ) {
        let mut state = self.shared.lock();
        state.bound = Some((machine.to_owned(), Arc::new(make)));
        state.idle.clear();
        state.binds += 1;
    }

    /// The machine resumed. The role's [`Resumes`] note does the same.
    pub fn resumed(&self) {
        self.shared.resumed();
    }
}

fn serve<H: Http + Send + 'static>(
    listener: &UnixListener,
    woken: &UnixStream,
    shared: &Arc<Shared<H>>,
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
            return (shared.hooks.log)(&format!(
                "auto-session socket: poll: {}",
                io::Error::last_os_error()
            ));
        }
        let [listening, wake] = fds;
        if wake.revents != 0 && drained_to_end(woken) {
            return;
        }
        if listening.revents == 0 {
            continue;
        }
        while let Ok((stream, _)) = listener.accept() {
            {
                let mut state = shared.lock();
                if state.stopping {
                    return;
                }
                if state.active >= MAX_ACTIVE {
                    drop(state);
                    busy(stream);
                    continue;
                }
                state.active += 1;
            }
            let theirs = Arc::clone(shared);
            let spawned = std::thread::Builder::new().name("cmux-host-auto-call".to_owned()).spawn(
                move || {
                    answer(stream, &theirs);
                    theirs.lock().active -= 1;
                },
            );
            if spawned.is_err() {
                // The closure, and the stream in it, are gone: the asker reads an EOF and asks again.
                shared.lock().active -= 1;
            }
        }
    }
}

fn busy(mut stream: UnixStream) {
    let reply = refusal("busy", "too many Auto mode calls are in flight; retry");
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_write_timeout(Some(BUSY_WRITE_TIMEOUT));
    let _ = stream.write_all(format!("{reply}\n").as_bytes());
}

/// One asker: its line, the call, the reply.
fn answer<H: Http + Send + 'static>(stream: UnixStream, shared: &Arc<Shared<H>>) {
    let stopping = || refusal("vm.agent_stopping", "the Cloud agent is stopping; retry");
    let call = read_call(&stream);
    let mut reply = if shared.stop.is_set() {
        stopping()
    } else {
        match &call {
            Err(why) => refusal("request.invalid", why),
            Ok(call) if call.kind == Kind::Assignments => held(shared, call),
            Ok(call) => perform(shared, call),
        }
    };
    if let Ok(call) = &call
        && let Some(note) = note_for(call, &reply)
    {
        (shared.hooks.log)(&note);
    }
    // Gone while it waited (a daemon restart): nothing to write.
    if !connected(&stream) {
        return;
    }
    if shared.stop.is_set() {
        reply = stopping();
    }
    let _ = write_reply(stream, &reply);
}

/// An `assignments` wait on a thread of its own, so a resume or a stop answers
/// the asker at once and leaves the request to end by its bound.
fn held<H: Http + Send + 'static>(shared: &Arc<Shared<H>>, call: &Call) -> Value {
    let (tx, rx) = mpsc::channel();
    let id = {
        let mut state = shared.lock();
        if state.held.len() >= MAX_HELD {
            return refusal("busy", "too many assignment waits are in flight; retry");
        }
        state.next_held += 1;
        let id = state.next_held;
        state.held.push((id, tx.clone()));
        id
    };
    let (theirs, asked) = (Arc::clone(shared), call.clone());
    let spawned =
        std::thread::Builder::new().name("cmux-host-auto-wait".to_owned()).spawn(move || {
            let _ = tx.send(Some(perform(&theirs, &asked)));
        });
    let reply = match spawned {
        Ok(_) => rx.recv().ok().flatten(),
        Err(_) => Some(refusal("busy", "the agent could not start the wait; retry")),
    };
    shared.lock().held.retain(|(held, _)| *held != id);
    reply.unwrap_or_else(|| {
        refusal("auto.resumed", "the machine resumed or the agent is stopping; ask again")
    })
}

/// The reply to `call`, sent as a client of the current bind.
fn perform<H: Http>(shared: &Shared<H>, call: &Call) -> Value {
    let unbound = || refusal("vm.unbound", "this machine is not bound to cmux Cloud yet");
    let (taken, binds, resumes) = {
        let mut state = shared.lock();
        let Some((machine, make)) = state.bound.as_ref() else { return unbound() };
        if call.kind == Kind::Machine {
            return machine_reply(machine);
        }
        let make = Arc::clone(make);
        (state.idle.pop().ok_or(make), state.binds, state.resumes)
    };
    let mut client = match taken {
        Ok(client) => client,
        Err(make) => match make() {
            Ok(client) => client,
            Err(why) => {
                (shared.hooks.log)(&format!("auto-session client: {why}"));
                return refusal("auto.unreachable", "the Cloud agent could not make a client");
            }
        },
    };
    let reply = send(&mut client, call, (shared.hooks.now)());
    let mut state = shared.lock();
    if state.binds == binds && !state.stopping && state.idle.len() < MAX_IDLE {
        if state.resumes != resumes {
            client.reset_transport();
        }
        state.idle.push(client);
    }
    reply
}

/// One call as `client`: the store's answer as a reply line.
pub fn send<H: Http>(client: &mut CloudClient<H>, call: &Call, now_wall_ms: u64) -> Value {
    let Some(method) = call.method() else {
        return machine_reply(&client.bound().machine);
    };
    let path = call.path();
    let headers = call.headers();
    let headers: Vec<(&str, &str)> =
        headers.iter().map(|(name, value)| (*name, value.as_str())).collect();
    let payload = match (&call.body, call.kind) {
        (Some(body), _) => Some(Payload::Json(body)),
        (None, Kind::ChunkPut) => Some(Payload::Bytes(&call.bytes)),
        (None, _) => None,
    };
    let request = RawRequest {
        method,
        url: &path,
        payload,
        bearer: None,
        headers: &headers,
        within: call.within(),
        limit: call.answer_limit(),
    };
    reply_for(call, client.raw_as_install(&request, now_wall_ms).as_ref())
}

/// The reply for one call before any socket: a refusal before a bind or for a
/// malformed call, else the store's answer.
pub fn answer_call<H: Http>(
    client: Option<&mut CloudClient<H>>,
    call: Result<Call, String>,
    now_wall_ms: u64,
) -> Value {
    let call = match call {
        Ok(call) => call,
        Err(why) => return refusal("request.invalid", &why),
    };
    let Some(client) = client else {
        return refusal("vm.unbound", "this machine is not bound to cmux Cloud yet");
    };
    send(client, &call, now_wall_ms)
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

/// The asker's line as a checked call: all of it within [`LINE_WAIT`] and
/// [`MAX_LINE`].
fn read_call(stream: &UnixStream) -> Result<Call, String> {
    let late = || "the call's line did not come in time".to_owned();
    let deadline = Instant::now() + LINE_WAIT;
    stream.set_nonblocking(false).map_err(|e| e.to_string())?;
    let mut line = Vec::new();
    let mut part = vec![0_u8; 64 * 1024];
    let mut reader = stream;
    // Where the line ends, looked for in each part as it comes (never the whole line again).
    let mut end = None;
    while end.is_none() {
        let left = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(late)?;
        stream.set_read_timeout(Some(left)).map_err(|e| e.to_string())?;
        match reader.read(&mut part) {
            Ok(0) => break,
            Ok(n) => {
                let read = part.get(..n).unwrap_or_default();
                end = read.iter().position(|b| *b == b'\n').map(|at| line.len() + at);
                line.extend_from_slice(read);
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return Err(late()),
        }
        if end.unwrap_or(line.len()) > MAX_LINE {
            return Err("the call's line is over 2 MiB".to_owned());
        }
    }
    let end = end.unwrap_or(line.len());
    let value: Value = serde_json::from_slice(line.get(..end).unwrap_or_default())
        .map_err(|_| "the call is not one JSON line".to_owned())?;
    match value.get(REQUEST_KEY) {
        Some(call) => Call::from_json(call),
        None => Err("this socket answers only auto_session".to_owned()),
    }
}

fn write_reply(mut stream: UnixStream, reply: &Value) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_write_timeout(Some(REPLY_WRITE_TIMEOUT))?;
    stream.write_all(format!("{reply}\n").as_bytes())
}

#[cfg(test)]
#[path = "auto_session_server_tests.rs"]
mod tests;
