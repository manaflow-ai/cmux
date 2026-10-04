//! One live shell on a host channel. The session is the only writer of its
//! channel. Input chunks are put in `seq` order; resize and signal follow
//! the input accepted before them, so the far end sees everything in the
//! order the session host sent it.
//!
//! No call waits. The host's data-plane calls never wait either: a full
//! host buffer is an `Unavailable {retryable: true}` answer, and the session
//! keeps the command and sends it on the next call (write, resize, signal or
//! `take_events`). A full session buffer is the same answer to the session
//! host and changes nothing.

use crate::iface::{
    BackendError, ByteEvent, ChannelEvent, ChannelId, Close, ExitStatus, HostChannels, Input,
    MAX_EXIT_MESSAGE, ResumeToken, Signal,
};
use crate::output::Output;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};

/// Input chunks held while an earlier `seq` is missing. More is refused.
pub const MAX_PENDING_INPUT: usize = 256;
/// Input bytes accepted but not yet sent (in order or waiting for an earlier
/// `seq`). More is refused as retryable.
pub const MAX_BUFFERED_BYTES: usize = 1024 * 1024;
/// Commands accepted but not yet sent. More is refused as retryable.
const MAX_QUEUED_COMMANDS: usize = 1024;
/// Detached sessions kept for `resume`; the oldest is closed past this.
pub const MAX_DETACHED: usize = 16;

enum Command {
    Data(Vec<u8>),
    Resize(u16, u16),
    Signal(Signal),
}

/// Everything the session host sent that the host channel has not taken.
#[derive(Default)]
struct Outbox {
    next_seq: u64,
    /// Chunks that wait for an earlier `seq`.
    pending: BTreeMap<u64, Vec<u8>>,
    /// Commands in send order.
    ready: VecDeque<Command>,
    /// Input bytes in `pending` and `ready`.
    bytes: usize,
}

impl Outbox {
    fn has_room(&self, bytes: usize) -> bool {
        self.bytes + bytes <= MAX_BUFFERED_BYTES && self.ready.len() < MAX_QUEUED_COMMANDS
    }

    fn clear(&mut self) {
        self.pending.clear();
        self.ready.clear();
        self.bytes = 0;
    }
}

#[derive(Default)]
struct State {
    outbox: Outbox,
    output: Output,
    /// The session host closed the terminal.
    closed: bool,
    /// `connection.channel.close` was sent.
    released: bool,
}

pub struct Session {
    pub terminal: String,
    /// Random per session; the resume token must carry it.
    nonce: u128,
    channel: ChannelId,
    host: Arc<dyn HostChannels>,
    state: Mutex<State>,
}

fn buffer_full() -> BackendError {
    BackendError::Unavailable { reason: "the input buffer is full".into(), retryable: true }
}

/// Keeps far-end text within [`MAX_EXIT_MESSAGE`] bytes, on a char boundary.
fn bounded(mut status: ExitStatus) -> ExitStatus {
    if let Some(message) = &mut status.message
        && message.len() > MAX_EXIT_MESSAGE
    {
        let mut end = MAX_EXIT_MESSAGE;
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        message.truncate(end);
    }
    status
}

impl Session {
    pub fn new(terminal: String, channel: ChannelId, host: Arc<dyn HostChannels>) -> Arc<Self> {
        Arc::new(Self {
            terminal,
            nonce: rand::random(),
            channel,
            host,
            state: Mutex::new(State::default()),
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        // A panic while the lock was held leaves only plain data behind.
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn usable(state: &State) -> Result<(), BackendError> {
        if state.closed || state.output.has_ended() {
            Err(BackendError::not_open())
        } else {
            Ok(())
        }
    }

    /// Sends queued commands in order until the host answers "full".
    fn flush(&self, state: &mut State) {
        while let Some(command) = state.outbox.ready.front() {
            let sent = match command {
                Command::Data(bytes) => self.host.send(&self.channel, bytes),
                Command::Resize(cols, rows) => self.host.resize(&self.channel, *cols, *rows),
                Command::Signal(signal) => self.host.signal(&self.channel, *signal),
            };
            match sent {
                Ok(()) => {
                    if let Some(Command::Data(bytes)) = state.outbox.ready.pop_front() {
                        state.outbox.bytes -= bytes.len();
                    }
                }
                Err(BackendError::Unavailable { retryable: true, .. }) => return,
                Err(error) => {
                    // The channel cannot take more. Read what the host still
                    // has (often the exit); without an end, it is lost.
                    state.outbox.clear();
                    self.pull(state);
                    state.output.finish(ByteEvent::Lost {
                        reason: format!("the host channel failed: {error}"),
                        retryable: false,
                    });
                    self.release(state);
                    return;
                }
            }
        }
    }

    /// Reads at most the free room from the host channel.
    fn pull(&self, state: &mut State) {
        if state.output.is_closed() || state.output.has_ended() {
            return;
        }
        let mut room = state.output.room();
        for event in self.host.receive(&self.channel, room) {
            match event {
                ChannelEvent::Data(data) if data.len() <= room => {
                    room -= data.len();
                    state.output.push(&data);
                }
                ChannelEvent::Data(_) => state.output.finish(ByteEvent::Lost {
                    reason: "the host channel sent more than the free room".into(),
                    retryable: false,
                }),
                ChannelEvent::Exit(status) => state.output.finish(ByteEvent::Exit(bounded(status))),
                ChannelEvent::Dropped { reason, retryable } => {
                    state.output.finish(ByteEvent::Lost { reason, retryable });
                }
            }
            if state.output.has_ended() {
                state.outbox.clear();
                self.release(state);
                return;
            }
        }
    }

    /// Sends `connection.channel.close` once.
    fn release(&self, state: &mut State) {
        if !state.released {
            state.released = true;
            // The channel is gone either way; a refusal changes nothing.
            let _closed = self.host.close(&self.channel);
        }
    }

    fn push(&self, command: Command) -> Result<(), BackendError> {
        let mut state = self.lock();
        Self::usable(&state)?;
        if !state.outbox.has_room(0) {
            return Err(buffer_full());
        }
        state.outbox.ready.push_back(command);
        self.flush(&mut state);
        Ok(())
    }

    /// Accepts a chunk and moves every chunk that is now in order to the
    /// send queue. A refused write changes nothing; the host retries it.
    pub fn write(&self, input: Input) -> Result<(), BackendError> {
        let mut state = self.lock();
        Self::usable(&state)?;
        let outbox = &mut state.outbox;
        let next = outbox.next_seq;
        if input.seq < next || outbox.pending.contains_key(&input.seq) {
            return Err(BackendError::invalid(format!("seq {} was already written", input.seq)));
        }
        if input.seq - next > MAX_PENDING_INPUT as u64 {
            return Err(BackendError::invalid(format!(
                "seq {} is more than {MAX_PENDING_INPUT} ahead of {next}",
                input.seq
            )));
        }
        if !outbox.has_room(input.bytes.len()) {
            return Err(buffer_full());
        }
        outbox.bytes += input.bytes.len();
        outbox.pending.insert(input.seq, input.bytes);
        loop {
            let next = outbox.next_seq;
            let Some(bytes) = outbox.pending.remove(&next) else { break };
            outbox.next_seq = next + 1;
            outbox.ready.push_back(Command::Data(bytes));
        }
        self.flush(&mut state);
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), BackendError> {
        self.push(Command::Resize(cols, rows))
    }

    pub fn signal(&self, signal: Signal) -> Result<(), BackendError> {
        self.push(Command::Signal(signal))
    }

    /// Sends what waits, reads what the host has (within the room) and
    /// gives the attached terminal everything new.
    pub fn take_events(&self) -> Vec<ByteEvent> {
        let mut state = self.lock();
        if !state.closed && !state.output.has_ended() {
            self.flush(&mut state);
            self.pull(&mut state);
        }
        state.output.take()
    }

    /// Closes the channel. Later calls on the terminal are refused.
    /// `Graceful` first sends the input the host takes now; `Now` drops it.
    pub fn close(&self, how: Close) -> Result<(), BackendError> {
        let mut state = self.lock();
        if state.closed {
            return Err(BackendError::not_open());
        }
        state.closed = true;
        if how == Close::Graceful && !state.output.has_ended() {
            self.flush(&mut state);
        }
        state.outbox.clear();
        state.output.close();
        self.release(&mut state);
        Ok(())
    }

    /// Closes without an answer (backend shutdown, eviction, replacement).
    pub fn close_now(session: &Arc<Session>) {
        let _already = session.close(Close::Now);
    }

    pub fn has_ended(&self) -> bool {
        self.lock().output.has_ended()
    }

    pub fn detach(&self) {
        self.lock().output.detach();
    }

    pub fn attach_at(&self, offset: u64) -> bool {
        self.lock().output.attach_at(offset)
    }

    pub fn resume_token(&self) -> ResumeToken {
        let delivered = self.lock().output.delivered();
        ResumeToken(format!("ssh:{}@{delivered}#{:032x}", self.terminal, self.nonce))
    }

    pub fn nonce_matches(&self, nonce: u128) -> bool {
        self.nonce == nonce
    }
}

/// `ssh:<terminal>@<offset>#<nonce>` back to its parts.
pub fn parse_token(token: &ResumeToken) -> Result<(String, u64, u128), BackendError> {
    let invalid = || BackendError::invalid("not an ssh resume token");
    let rest = token.0.strip_prefix("ssh:").ok_or_else(invalid)?;
    let (rest, nonce) = rest.rsplit_once('#').ok_or_else(invalid)?;
    let (terminal, offset) = rest.rsplit_once('@').ok_or_else(invalid)?;
    let offset = offset.parse().map_err(|_| invalid())?;
    let nonce = u128::from_str_radix(nonce, 16).map_err(|_| invalid())?;
    Ok((terminal.to_owned(), offset, nonce))
}

/// Live sessions by terminal id, and the order in which they detached.
/// Every change compares the session itself, not only its terminal id, so a
/// stale handle never touches a newer session with the same id.
#[derive(Default)]
pub struct Registry {
    inner: Mutex<RegistryInner>,
}

#[derive(Default)]
struct RegistryInner {
    sessions: HashMap<String, Arc<Session>>,
    detached: VecDeque<Arc<Session>>,
}

impl Registry {
    fn lock(&self) -> MutexGuard<'_, RegistryInner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn get(&self, terminal: &str) -> Option<Arc<Session>> {
        self.lock().sessions.get(terminal).cloned()
    }

    pub fn is_current(&self, session: &Arc<Session>) -> bool {
        self.lock().sessions.get(&session.terminal).is_some_and(|s| Arc::ptr_eq(s, session))
    }

    /// Adds a session. An older session with the same id that ended or was
    /// detached is replaced and closed; an attached, live one is refused.
    pub fn insert(&self, session: Arc<Session>) -> Result<(), BackendError> {
        let old = {
            let mut inner = self.lock();
            if let Some(old) = inner.sessions.get(&session.terminal) {
                let detached = inner.detached.iter().any(|d| Arc::ptr_eq(d, old));
                if !detached && !old.has_ended() {
                    return Err(BackendError::invalid(format!(
                        "terminal {} is open",
                        session.terminal
                    )));
                }
            }
            let old = inner.sessions.insert(session.terminal.clone(), session);
            if let Some(old) = &old {
                inner.detached.retain(|d| !Arc::ptr_eq(d, old));
            }
            old
        };
        if let Some(old) = old {
            Session::close_now(&old);
        }
        Ok(())
    }

    /// True when a live, attached session holds `terminal`.
    pub fn is_busy(&self, terminal: &str) -> bool {
        let inner = self.lock();
        inner
            .sessions
            .get(terminal)
            .is_some_and(|s| !s.has_ended() && !inner.detached.iter().any(|d| Arc::ptr_eq(d, s)))
    }

    pub fn remove(&self, session: &Arc<Session>) {
        let mut inner = self.lock();
        if inner.sessions.get(&session.terminal).is_some_and(|s| Arc::ptr_eq(s, session)) {
            inner.sessions.remove(&session.terminal);
        }
        inner.detached.retain(|d| !Arc::ptr_eq(d, session));
    }

    pub fn is_detached(&self, session: &Arc<Session>) -> bool {
        self.lock().detached.iter().any(|d| Arc::ptr_eq(d, session))
    }

    pub fn attached(&self, session: &Arc<Session>) {
        self.lock().detached.retain(|d| !Arc::ptr_eq(d, session));
    }

    /// The session host dropped the terminal without `close`: keep the
    /// session for `resume`, and close the oldest past [`MAX_DETACHED`].
    pub fn detached(&self, session: &Arc<Session>) {
        let evicted = {
            let mut inner = self.lock();
            if !inner.sessions.get(&session.terminal).is_some_and(|s| Arc::ptr_eq(s, session)) {
                return;
            }
            inner.detached.push_back(session.clone());
            if inner.detached.len() > MAX_DETACHED {
                let old = inner.detached.pop_front();
                if let Some(old) = &old {
                    inner.sessions.remove(&old.terminal);
                }
                old
            } else {
                None
            }
        };
        if let Some(old) = evicted {
            Session::close_now(&old);
        }
    }

    pub fn drain(&self) -> Vec<Arc<Session>> {
        let mut inner = self.lock();
        inner.detached.clear();
        inner.sessions.drain().map(|(_, s)| s).collect()
    }
}
