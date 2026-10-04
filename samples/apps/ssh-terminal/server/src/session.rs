//! One live SSH shell: a reader task (channel to [`Output`]) and a writer
//! task (ordered commands to the channel). The session is the only writer of
//! its channel; every input, resize, signal and close goes through one queue,
//! so they reach the server in the order the session host sent them.

use crate::client::HostKeyGate;
use crate::iface::{BackendError, ByteEvent, Close, ExitStatus, Grid, Input, ResumeToken, Signal};
use crate::output::Output;
use russh::client::{Handle, Msg};
use russh::{Channel, ChannelMsg, ChannelReadHalf, ChannelWriteHalf, Disconnect, Sig};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

/// Input chunks held while an earlier `seq` is missing. More is refused.
pub const MAX_PENDING_INPUT: usize = 256;
/// Commands queued for the writer task; a full queue blocks `write`.
const COMMAND_QUEUE: usize = 64;
/// Detached sessions kept for `resume`; the oldest is closed past this.
pub const MAX_DETACHED: usize = 16;

pub enum Command {
    Data(Vec<u8>),
    Resize(Grid),
    Signal(Signal),
    Close(Close),
}

#[derive(Default)]
struct InputOrder {
    next_seq: u64,
    pending: BTreeMap<u64, Vec<u8>>,
}

pub struct Session {
    pub terminal: String,
    pub output: Arc<Output>,
    commands: mpsc::Sender<Command>,
    input: Mutex<InputOrder>,
    closed: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn start(
    runtime: &Runtime,
    terminal: String,
    ssh: Handle<HostKeyGate>,
    channel: Channel<Msg>,
) -> Arc<Session> {
    let (read, write) = channel.split();
    let (commands, queue) = mpsc::channel(COMMAND_QUEUE);
    let output = Arc::new(Output::default());
    runtime.spawn(read_loop(read, output.clone()));
    runtime.spawn(write_loop(ssh, write, queue));
    Arc::new(Session {
        terminal,
        output,
        commands,
        input: Mutex::new(InputOrder::default()),
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

    fn send(&self, command: Command) -> Result<(), BackendError> {
        self.commands.blocking_send(command).map_err(|_| BackendError::Closed)
    }

    /// Sends chunks in `seq` order. Holds the input lock while it sends, so
    /// two callers never interleave a ready run of chunks.
    pub fn write(&self, input: Input) -> Result<(), BackendError> {
        self.usable()?;
        let mut order = lock(&self.input);
        if input.seq < order.next_seq || order.pending.contains_key(&input.seq) {
            return Err(BackendError::Invalid(format!("seq {} was already written", input.seq)));
        }
        if input.seq - order.next_seq > MAX_PENDING_INPUT as u64 {
            return Err(BackendError::Invalid(format!(
                "seq {} is more than {MAX_PENDING_INPUT} ahead of {}",
                input.seq, order.next_seq
            )));
        }
        order.pending.insert(input.seq, input.bytes);
        loop {
            let next = order.next_seq;
            let Some(bytes) = order.pending.remove(&next) else { break };
            order.next_seq = next + 1;
            self.send(Command::Data(bytes))?;
        }
        Ok(())
    }

    pub fn resize(&self, grid: Grid) -> Result<(), BackendError> {
        self.usable()?;
        self.send(Command::Resize(grid))
    }

    pub fn signal(&self, signal: Signal) -> Result<(), BackendError> {
        self.usable()?;
        self.send(Command::Signal(signal))
    }

    /// Closes the channel. Later calls on the terminal are refused.
    pub fn close(&self, how: Close) -> Result<(), BackendError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Err(BackendError::Closed);
        }
        self.output.detach();
        self.send(Command::Close(how))
    }

    /// Closes without waiting for queue room (backend shutdown, eviction).
    pub fn close_now(session: &Arc<Session>) {
        if !session.closed.swap(true, Ordering::AcqRel) {
            session.output.detach();
            let _ignored = session.commands.try_send(Command::Close(Close::Now));
        }
    }

    pub fn resume_token(&self) -> ResumeToken {
        ResumeToken(format!("ssh:{}@{}", self.terminal, self.output.delivered()))
    }
}

/// `ssh:<terminal>@<offset>` back to its parts.
pub fn parse_token(token: &ResumeToken) -> Result<(String, u64), BackendError> {
    let invalid = || BackendError::Invalid("not an ssh resume token".into());
    let rest = token.0.strip_prefix("ssh:").ok_or_else(invalid)?;
    let (terminal, offset) = rest.rsplit_once('@').ok_or_else(invalid)?;
    Ok((terminal.to_owned(), offset.parse().map_err(|_| invalid())?))
}

async fn read_loop(mut read: ChannelReadHalf, output: Arc<Output>) {
    let mut code = None;
    let mut ended = false;
    while let Some(message) = read.wait().await {
        match message {
            ChannelMsg::Data { data } => output.push(&data).await,
            ChannelMsg::ExtendedData { data, .. } => output.push(&data).await,
            ChannelMsg::ExitStatus { exit_status } => {
                code = Some(i32::try_from(exit_status).unwrap_or(i32::MAX));
                ended = true;
            }
            ChannelMsg::ExitSignal { .. } | ChannelMsg::Close => ended = true,
            _ => {}
        }
    }
    // The channel ended. Without an exit status or a close from the server,
    // the transport dropped: the terminal is lost, not exited.
    output.finish(if ended {
        ByteEvent::Exit(ExitStatus { code })
    } else {
        ByteEvent::Lost("the ssh connection ended".into())
    });
}

async fn write_loop(
    ssh: Handle<HostKeyGate>,
    write: ChannelWriteHalf<Msg>,
    mut queue: mpsc::Receiver<Command>,
) {
    while let Some(command) = queue.recv().await {
        let sent = match command {
            Command::Data(bytes) => write.data_bytes(bytes).await,
            Command::Resize(grid) => {
                write.window_change(u32::from(grid.cols), u32::from(grid.rows), 0, 0).await
            }
            Command::Signal(signal) => write.signal(ssh_signal(signal)).await,
            Command::Close(how) => {
                let _ignored = write.close().await;
                if how == Close::Now {
                    let _ignored = ssh.disconnect(Disconnect::ByApplication, "", "en").await;
                }
                return;
            }
        };
        if sent.is_err() {
            // The reader reports exit or lost; nothing more can be sent.
            return;
        }
    }
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
#[derive(Default)]
pub struct Registry {
    inner: Mutex<RegistryInner>,
}

#[derive(Default)]
struct RegistryInner {
    sessions: HashMap<String, Arc<Session>>,
    detached: VecDeque<String>,
}

impl Registry {
    pub fn contains(&self, terminal: &str) -> bool {
        lock(&self.inner).sessions.contains_key(terminal)
    }

    pub fn get(&self, terminal: &str) -> Option<Arc<Session>> {
        lock(&self.inner).sessions.get(terminal).cloned()
    }

    pub fn insert(&self, session: Arc<Session>) {
        lock(&self.inner).sessions.insert(session.terminal.clone(), session);
    }

    pub fn remove(&self, terminal: &str) {
        let mut inner = lock(&self.inner);
        inner.sessions.remove(terminal);
        inner.detached.retain(|t| t != terminal);
    }

    pub fn attached(&self, session: &Session) {
        lock(&self.inner).detached.retain(|t| *t != session.terminal);
    }

    /// The session host dropped the terminal without `close`: keep the
    /// session for `resume`, and close the oldest past [`MAX_DETACHED`].
    pub fn detached(&self, session: &Session) {
        let evicted = {
            let mut inner = lock(&self.inner);
            inner.detached.push_back(session.terminal.clone());
            if inner.detached.len() > MAX_DETACHED {
                inner.detached.pop_front().and_then(|t| inner.sessions.remove(&t))
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
