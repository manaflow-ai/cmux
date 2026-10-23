//! The daemon's concurrent link to its holder: one reader thread routes each
//! terminal's output, gap and exit to the sink its surface registered, while
//! any thread spawns, writes, resizes or closes.

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use crate::wire::{self, In, Kind, Out};
use crate::{ExitStatus, Listed, SpawnRequest};

/// Where one terminal's events go. Called on the link's reader thread, in
/// stream order; an implementation must not block on the link.
pub trait TerminalSink: Send + Sync {
    /// Output bytes starting at `offset`.
    fn data(&self, offset: u64, bytes: &[u8]);
    /// The holder's ring dropped bytes `requested..oldest` before they were sent.
    fn gap(&self, requested: u64, oldest: u64);
    /// The terminal ended after `end` output bytes.
    fn exit(&self, status: ExitStatus, end: u64);
    /// A VT replay of the screen at output offset `base` (the newest
    /// snapshot the holder keeps, or the screen it adopted the terminal
    /// with). Output from `base` follows; a `base` before the next byte the
    /// sink expects means the bytes between are gone.
    fn prologue(&self, _base: u64, _bytes: &[u8]) {}
    /// Whether this sink acknowledges what it consumed itself, with
    /// [`HolderLink::ack`] (a sink that queues bytes for a slower reader).
    /// When false, the link acknowledges each byte as it delivers it.
    fn acks_itself(&self) -> bool {
        false
    }
}

/// Why a link ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkEnd {
    /// The holder closed the link or died.
    Lost,
    /// Another daemon of the session authenticated and took the holder: do
    /// not take it back (two daemons would take turns forever).
    Superseded,
}

type SpawnReply = io::Result<(i32, OwnedFd)>;

#[derive(Default)]
struct State {
    sinks: HashMap<u32, Arc<dyn TerminalSink>>,
    spawns: HashMap<u32, SyncSender<SpawnReply>>,
    open: bool,
}

/// An authenticated, concurrent link to a holder.
pub struct HolderLink {
    writer: Mutex<UnixStream>,
    state: Mutex<State>,
    /// The holder takes [`Kind::Ack`] (wire version 2).
    credit: bool,
    /// The wire version the holder settled on.
    version: u16,
}

/// How long a spawn waits for the holder's answer.
const SPAWN_TIMEOUT: Duration = Duration::from_secs(10);

impl HolderLink {
    /// Connect and authenticate, return the terminals the holder runs, and
    /// start the reader thread. `on_lost` runs on that thread once, when the
    /// link ends (a holder crash, or another daemon took the holder).
    pub fn connect(
        socket: &Path,
        token: &[u8; 32],
        on_lost: Box<dyn FnOnce(LinkEnd) + Send>,
    ) -> io::Result<(Arc<Self>, Vec<Listed>)> {
        let (client, listed) = crate::client::HolderClient::connect(socket, token)?;
        let (stream, reader, version) = client.into_parts();
        stream.set_read_timeout(None)?;
        let link = Arc::new(Self {
            writer: Mutex::new(stream.try_clone()?),
            state: Mutex::new(State { open: true, ..State::default() }),
            credit: version >= 2,
            version,
        });
        let weak = Arc::downgrade(&link);
        std::thread::Builder::new().name("holder-link".into()).spawn(move || {
            let end = read_loop(&stream, reader, &weak);
            if let Some(link) = weak.upgrade() {
                link.lost();
            }
            on_lost(end);
        })?;
        Ok((link, listed))
    }

    /// Whether the holder still answers.
    pub fn is_open(&self) -> bool {
        self.lock().open
    }

    /// Start `request` on `chan`, streaming its output to `sink` from its
    /// first byte. Returns the child's pid and the caller's custody dup of
    /// the PTY master.
    pub fn spawn(
        &self,
        chan: u32,
        request: &SpawnRequest,
        sink: Arc<dyn TerminalSink>,
    ) -> io::Result<(i32, OwnedFd)> {
        let (reply, answered) = sync_channel(1);
        {
            let mut state = self.lock();
            if !state.open {
                return Err(lost());
            }
            state.sinks.insert(chan, sink);
            state.spawns.insert(chan, reply);
        }
        let sent = self
            .send(Kind::Spawn, chan, &request.encode(), None)
            .and_then(|()| self.send(Kind::Attach, chan, &Out::default().u64(0).0, None));
        let result = sent.and_then(|()| {
            answered
                .recv_timeout(SPAWN_TIMEOUT)
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "holder did not spawn"))?
        });
        if result.is_err() {
            let mut state = self.lock();
            state.sinks.remove(&chan);
            state.spawns.remove(&chan);
        }
        result
    }

    /// Hand a running terminal to this holder (after a holder crash): its
    /// custody master, pid and the offset its output continues from. Its
    /// output then streams to `sink` from `base`.
    pub fn adopt(
        &self,
        chan: u32,
        id: &[u8; 16],
        (pid, base): (i32, u64),
        master: &OwnedFd,
        (sink, prologue): (Arc<dyn TerminalSink>, &[u8]),
    ) -> io::Result<()> {
        self.lock().sinks.insert(chan, sink);
        let payload = Out::default().i32(pid).u64(base).bytes(id).bytes(prologue).0;
        self.send(Kind::Adopt, chan, &payload, Some(master))?;
        self.send(Kind::Attach, chan, &Out::default().u64(base).0, None)
    }

    /// Stream a listed terminal's output to `sink` from `from`, after its
    /// prologue if it has one (a restarted daemon re-attaching).
    pub fn attach(&self, chan: u32, from: u64, sink: Arc<dyn TerminalSink>) -> io::Result<()> {
        self.attach_flagged(chan, from, sink, wire::FLAG_WITH_PROLOGUE)
    }

    /// Stream a terminal this daemon already shows to `sink` from `from`,
    /// without its prologue: the same holder, after the link dropped.
    pub fn resume(&self, chan: u32, from: u64, sink: Arc<dyn TerminalSink>) -> io::Result<()> {
        self.attach_flagged(chan, from, sink, 0)
    }

    fn attach_flagged(
        &self,
        chan: u32,
        from: u64,
        sink: Arc<dyn TerminalSink>,
        flags: u16,
    ) -> io::Result<()> {
        self.lock().sinks.insert(chan, sink);
        let frame = wire::encode_flagged(Kind::Attach, flags, chan, &Out::default().u64(from).0);
        let writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        wire::send_all(writer.as_raw_fd(), &frame, &[])
    }

    /// Tell the holder the daemon parsed `chan`'s output before `offset`,
    /// so it sends up to [`wire::CREDIT_WINDOW`] past it. A holder older
    /// than wire version 2 sends without credit and is not told.
    pub fn ack(&self, chan: u32, offset: u64) -> io::Result<()> {
        if !self.credit {
            return Ok(());
        }
        self.send(Kind::Ack, chan, &Out::default().u64(offset).0, None)
    }

    /// Hand the holder a VT replay of `chan`'s parsed screen at output
    /// offset `base`, the prologue a restarted daemon gets (wire version 3;
    /// an older holder is not told).
    pub fn snapshot(&self, chan: u32, base: u64, replay: &[u8]) -> io::Result<()> {
        if self.version < 3 {
            return Ok(());
        }
        self.send(Kind::Snapshot, chan, &Out::default().u64(base).bytes(replay).0, None)
    }

    /// Leave `chan` on purpose (the daemon shuts down and the holder keeps
    /// the shell): the link's end is then no strike against its stream
    /// (wire version 3).
    pub fn detach(&self, chan: u32) -> io::Result<()> {
        if self.version < 3 {
            return Ok(());
        }
        self.send(Kind::Detach, chan, &[], None)
    }

    pub fn write(&self, chan: u32, bytes: &[u8]) -> io::Result<()> {
        for chunk in bytes.chunks(wire::MAX_PAYLOAD) {
            self.send(Kind::Write, chan, chunk, None)?;
        }
        Ok(())
    }

    pub fn signal(&self, chan: u32, signal: i32) -> io::Result<()> {
        self.send(Kind::Signal, chan, &Out::default().i32(signal).0, None)
    }

    /// Hang up the terminal; SIGKILL its group after `grace_ms`.
    pub fn close(&self, chan: u32, grace_ms: u32) -> io::Result<()> {
        self.send(Kind::Close, chan, &Out::default().u32(grace_ms).0, None)
    }

    /// Stop routing `chan` (its surface is gone).
    pub fn forget(&self, chan: u32) {
        self.lock().sinks.remove(&chan);
    }

    fn send(&self, kind: Kind, chan: u32, payload: &[u8], fd: Option<&OwnedFd>) -> io::Result<()> {
        let fds: Vec<_> = fd.map(AsRawFd::as_raw_fd).into_iter().collect();
        let writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        wire::send_all(writer.as_raw_fd(), &wire::encode(kind, chan, payload), &fds)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lost(&self) {
        let mut state = self.lock();
        state.open = false;
        for (_, reply) in state.spawns.drain() {
            let _ = reply.try_send(Err(lost()));
        }
    }
}

fn lost() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "holder link lost")
}

/// Route frames until the link ends; returns why it ended.
fn read_loop(
    stream: &UnixStream,
    mut reader: wire::Reader,
    link: &std::sync::Weak<HolderLink>,
) -> LinkEnd {
    let mut ending = LinkEnd::Lost;
    // Per channel, the offset the link last acknowledged for a sink that
    // does not acknowledge itself.
    let mut acked: HashMap<u32, u64> = HashMap::new();
    loop {
        loop {
            let mut frame = match reader.next_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(_) => return ending,
            };
            let Some(link) = link.upgrade() else { return ending };
            let chan = frame.chan;
            let mut input = In(&frame.payload);
            match Kind::from_u16(frame.kind) {
                Some(Kind::Spawned) => {
                    let reply = match (input.i32(), frame.fds.pop()) {
                        (Ok(pid), Some(fd)) => Ok((pid, fd)),
                        _ => Err(io::Error::other("malformed SPAWNED")),
                    };
                    if let Some(waiter) = link.lock().spawns.remove(&chan) {
                        let _ = waiter.try_send(reply);
                    }
                }
                Some(Kind::Error) => {
                    let request = input.u16().unwrap_or_default();
                    let rest = input.rest();
                    let code = In(rest).u16().unwrap_or_default();
                    let message =
                        String::from_utf8_lossy(rest.get(2..).unwrap_or_default()).into_owned();
                    if chan == 0
                        && request == Kind::Hello as u16
                        && code == crate::holder::error_code::SUPERSEDED
                    {
                        ending = LinkEnd::Superseded;
                    }
                    if request == Kind::Spawn as u16
                        && let Some(waiter) = link.lock().spawns.remove(&chan)
                    {
                        let _ = waiter.try_send(Err(io::Error::other(message)));
                    }
                }
                Some(Kind::Data) => {
                    if let Ok(offset) = input.u64()
                        && let Some(sink) = link.lock().sinks.get(&chan).cloned()
                    {
                        if frame.flags & wire::FLAG_PROLOGUE != 0 {
                            sink.prologue(offset, input.rest());
                        } else {
                            let bytes = input.rest();
                            sink.data(offset, bytes);
                            let through = offset + bytes.len() as u64;
                            if !sink.acks_itself() {
                                let last = acked.entry(chan).or_insert(offset);
                                if through >= *last + wire::ACK_EVERY {
                                    *last = through;
                                    let _ = link.ack(chan, through);
                                }
                            }
                        }
                    }
                }
                Some(Kind::Gap) => {
                    if let (Ok(requested), Ok(oldest)) = (input.u64(), input.u64())
                        && let Some(sink) = link.lock().sinks.get(&chan).cloned()
                    {
                        sink.gap(requested, oldest);
                    }
                }
                Some(Kind::Exit) => {
                    if let (Ok(kind), Ok(code), Ok(end)) = (input.u8(), input.i32(), input.u64())
                        && let Some(sink) = link.lock().sinks.remove(&chan)
                    {
                        acked.remove(&chan);
                        sink.exit(ExitStatus::decode(kind, code), end);
                    }
                }
                _ => {}
            }
        }
        match reader.fill(stream.as_raw_fd()) {
            Ok(true) => {}
            Ok(false) | Err(_) => return ending,
        }
    }
}
