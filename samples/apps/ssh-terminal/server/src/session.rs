//! One live SSH shell: a reader task (channel to [`Output`]) and a writer
//! task (ordered commands to the channel). The session is the only writer of
//! its channel. Input chunks are put in `seq` order; resize, signal and close
//! follow the input accepted before them, so the server sees everything in
//! the order the session host sent it.
//!
//! No call from the session host waits: a full buffer is an `Unavailable
//! {retryable: true}` answer that changes nothing (a host thread that waited
//! in `write` could never call `take_events`, and the two would deadlock).

use crate::client::HostKeyGate;
use crate::iface::{BackendError, ByteEvent, Close, ExitStatus, Grid, Input, ResumeToken, Signal};
use crate::output::Output;
use russh::client::{Handle, Msg};
use russh::{ChannelMsg, ChannelReadHalf, ChannelWriteHalf, Disconnect, Sig};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::runtime::Runtime;
use tokio::sync::{Notify, oneshot};

/// Input chunks held while an earlier `seq` is missing. More is refused.
pub const MAX_PENDING_INPUT: usize = 256;
/// Input bytes accepted but not yet sent (in order or waiting for an earlier
/// `seq`). More is refused as retryable.
pub const MAX_BUFFERED_BYTES: usize = 1024 * 1024;
/// Commands accepted but not yet sent. More is refused as retryable.
const MAX_QUEUED_COMMANDS: usize = 1024;
/// Detached sessions kept for `resume`; the oldest is closed past this.
pub const MAX_DETACHED: usize = 16;

pub enum Command {
    Data(Vec<u8>),
    Resize(Grid),
    Signal(Signal),
    Close(Close),
}

/// Everything the session host sent that the writer task has not sent yet.
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
}

struct Shared {
    outbox: Mutex<Outbox>,
    wake: Notify,
}

pub struct Session {
    pub terminal: String,
    /// Random per session; the resume token must carry it.
    nonce: u128,
    pub output: Arc<Output>,
    shared: Arc<Shared>,
    closed: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn buffer_full() -> BackendError {
    BackendError::Unavailable { reason: "the input buffer is full".into(), retryable: true }
}

pub fn start(
    runtime: &Runtime,
    terminal: String,
    ssh: Handle<HostKeyGate>,
    read: ChannelReadHalf,
    write: ChannelWriteHalf<Msg>,
    early: &[u8],
) -> Arc<Session> {
    let shared = Arc::new(Shared { outbox: Mutex::new(Outbox::default()), wake: Notify::new() });
    let (ended, ended_rx) = oneshot::channel();
    let output = Arc::new(Output::default());
    output.push_early(early);
    runtime.spawn(read_loop(read, output.clone(), ended));
    runtime.spawn(write_loop(ssh, write, shared.clone(), ended_rx));
    Arc::new(Session {
        terminal,
        nonce: rand::random(),
        output,
        shared,
        closed: AtomicBool::new(false),
    })
}

impl Session {
    fn usable(&self) -> Result<(), BackendError> {
        if self.closed.load(Ordering::Acquire) || self.output.has_ended() {
            Err(BackendError::Closed)
        } else {
            Ok(())
        }
    }

    fn push(&self, command: Command) -> Result<(), BackendError> {
        self.usable()?;
        {
            let mut outbox = lock(&self.shared.outbox);
            if !outbox.has_room(0) {
                return Err(buffer_full());
            }
            outbox.ready.push_back(command);
        }
        self.shared.wake.notify_one();
        Ok(())
    }

    /// Accepts a chunk and moves every chunk that is now in order to the
    /// send queue. A refused write changes nothing; the host retries it.
    pub fn write(&self, input: Input) -> Result<(), BackendError> {
        self.usable()?;
        {
            let mut outbox = lock(&self.shared.outbox);
            let next = outbox.next_seq;
            if input.seq < next || outbox.pending.contains_key(&input.seq) {
                return Err(BackendError::Invalid(format!(
                    "seq {} was already written",
                    input.seq
                )));
            }
            if input.seq - next > MAX_PENDING_INPUT as u64 {
                return Err(BackendError::Invalid(format!(
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
        }
        self.shared.wake.notify_one();
        Ok(())
    }

    pub fn resize(&self, grid: Grid) -> Result<(), BackendError> {
        self.push(Command::Resize(grid))
    }

    pub fn signal(&self, signal: Signal) -> Result<(), BackendError> {
        self.push(Command::Signal(signal))
    }

    /// Closes the channel. Later calls on the terminal are refused. `Now`
    /// drops unsent input; `Graceful` sends it first. Never waits: closing
    /// the output also frees a reader that waits for room.
    pub fn close(&self, how: Close) -> Result<(), BackendError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Err(BackendError::Closed);
        }
        self.output.close();
        {
            let mut outbox = lock(&self.shared.outbox);
            if how == Close::Now {
                outbox.ready.clear();
                outbox.pending.clear();
                outbox.bytes = 0;
            }
            outbox.ready.push_back(Command::Close(how));
        }
        self.shared.wake.notify_one();
        Ok(())
    }

    /// Closes without an answer (backend shutdown, eviction, replacement).
    pub fn close_now(session: &Arc<Session>) {
        let _already = session.close(Close::Now);
    }

    pub fn resume_token(&self) -> ResumeToken {
        ResumeToken(format!(
            "ssh:{}@{}#{:032x}",
            self.terminal,
            self.output.delivered(),
            self.nonce
        ))
    }

    pub fn nonce_matches(&self, nonce: u128) -> bool {
        self.nonce == nonce
    }
}

/// `ssh:<terminal>@<offset>#<nonce>` back to its parts.
pub fn parse_token(token: &ResumeToken) -> Result<(String, u64, u128), BackendError> {
    let invalid = || BackendError::Invalid("not an ssh resume token".into());
    let rest = token.0.strip_prefix("ssh:").ok_or_else(invalid)?;
    let (rest, nonce) = rest.rsplit_once('#').ok_or_else(invalid)?;
    let (terminal, offset) = rest.rsplit_once('@').ok_or_else(invalid)?;
    let offset = offset.parse().map_err(|_| invalid())?;
    let nonce = u128::from_str_radix(nonce, 16).map_err(|_| invalid())?;
    Ok((terminal.to_owned(), offset, nonce))
}

async fn read_loop(mut read: ChannelReadHalf, output: Arc<Output>, ended: oneshot::Sender<()>) {
    let mut code = None;
    let mut exited = false;
    while let Some(message) = read.wait().await {
        match message {
            ChannelMsg::Data { data } => output.push(&data).await,
            ChannelMsg::ExtendedData { data, .. } => output.push(&data).await,
            ChannelMsg::ExitStatus { exit_status } => {
                code = Some(i32::try_from(exit_status).unwrap_or(i32::MAX));
                exited = true;
            }
            ChannelMsg::ExitSignal { .. } | ChannelMsg::Close => exited = true,
            _ => {}
        }
    }
    // The channel ended. Without an exit status or a close from the server,
    // the transport dropped: the terminal is lost, not exited.
    output.finish(if exited {
        ByteEvent::Exit(ExitStatus { code })
    } else {
        ByteEvent::Lost("the ssh connection ended".into())
    });
    let _writer_gone = ended.send(());
}

async fn write_loop(
    ssh: Handle<HostKeyGate>,
    write: ChannelWriteHalf<Msg>,
    shared: Arc<Shared>,
    mut ended: oneshot::Receiver<()>,
) {
    loop {
        let next = {
            let mut outbox = lock(&shared.outbox);
            let command = outbox.ready.pop_front();
            if let Some(Command::Data(bytes)) = &command {
                outbox.bytes -= bytes.len();
            }
            command
        };
        let Some(command) = next else {
            tokio::select! {
                () = shared.wake.notified() => continue,
                // The reader ended (exit or lost): drop the connection now
                // instead of keeping it alive for nothing.
                _ = &mut ended => break,
            }
        };
        let sent = match command {
            Command::Data(bytes) => write.data_bytes(bytes).await,
            Command::Resize(grid) => {
                write.window_change(u32::from(grid.cols), u32::from(grid.rows), 0, 0).await
            }
            Command::Signal(signal) => write.signal(ssh_signal(signal)).await,
            Command::Close(how) => {
                if how == Close::Graceful {
                    // End of input first, so the shell sees a hang-up.
                    let _eof = write.eof().await;
                }
                let _closed = write.close().await;
                break;
            }
        };
        if sent.is_err() {
            break;
        }
    }
    let _gone = ssh.disconnect(Disconnect::ByApplication, "", "en").await;
}

fn ssh_signal(signal: Signal) -> Sig {
    match signal {
        Signal::Interrupt => Sig::INT,
        Signal::Terminate => Sig::TERM,
        Signal::Hangup => Sig::HUP,
        Signal::Kill => Sig::KILL,
    }
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
    pub fn get(&self, terminal: &str) -> Option<Arc<Session>> {
        lock(&self.inner).sessions.get(terminal).cloned()
    }

    pub fn is_current(&self, session: &Arc<Session>) -> bool {
        lock(&self.inner).sessions.get(&session.terminal).is_some_and(|s| Arc::ptr_eq(s, session))
    }

    /// Adds a session. An older session with the same id that ended or was
    /// detached is replaced and closed; an attached, live one is refused.
    pub fn insert(&self, session: Arc<Session>) -> Result<(), BackendError> {
        let old = {
            let mut inner = lock(&self.inner);
            if let Some(old) = inner.sessions.get(&session.terminal) {
                let detached = inner.detached.iter().any(|d| Arc::ptr_eq(d, old));
                if !detached && !old.output.has_ended() {
                    return Err(BackendError::Invalid(format!(
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
        let inner = lock(&self.inner);
        inner.sessions.get(terminal).is_some_and(|s| {
            !s.output.has_ended() && !inner.detached.iter().any(|d| Arc::ptr_eq(d, s))
        })
    }

    pub fn remove(&self, session: &Arc<Session>) {
        let mut inner = lock(&self.inner);
        if inner.sessions.get(&session.terminal).is_some_and(|s| Arc::ptr_eq(s, session)) {
            inner.sessions.remove(&session.terminal);
        }
        inner.detached.retain(|d| !Arc::ptr_eq(d, session));
    }

    pub fn is_detached(&self, session: &Arc<Session>) -> bool {
        lock(&self.inner).detached.iter().any(|d| Arc::ptr_eq(d, session))
    }

    pub fn attached(&self, session: &Arc<Session>) {
        lock(&self.inner).detached.retain(|d| !Arc::ptr_eq(d, session));
    }

    /// The session host dropped the terminal without `close`: keep the
    /// session for `resume`, and close the oldest past [`MAX_DETACHED`].
    pub fn detached(&self, session: &Arc<Session>) {
        let evicted = {
            let mut inner = lock(&self.inner);
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
        let mut inner = lock(&self.inner);
        inner.detached.clear();
        inner.sessions.drain().map(|(_, s)| s).collect()
    }
}
