//! The daemon's concurrent link to its holder: one reader thread routes each
//! terminal's output, gap and exit to the sink its surface registered, while
//! any thread spawns, writes, resizes or closes.

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use crate::client::Spawned;
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
    /// The holder refused to stream this terminal: it does not run the
    /// channel an ATTACH named, it could not take an ADOPT over, or the
    /// child of a terminal this sink attached while it started could not
    /// start. The link stopped routing the channel; no event comes for it
    /// any more, so the terminal ends as lost (or its owner recovers it).
    fn refused(&self, message: &str);
    /// Whether this sink acknowledges what it consumed itself, with
    /// [`HolderLink::ack`] (a sink that queues bytes for a slower reader).
    /// When false, the link acknowledges each byte as it delivers it.
    fn acks_itself(&self) -> bool {
        false
    }
    /// The holder adopted this terminal ([`HolderLink::adopt`]) and writes
    /// its output to a ring whose newest byte ends at `end` (its
    /// [`Kind::Adopted`] answer): the end of the segment the ADOPT handed
    /// over when the holder continues it, the `resume` offset when it
    /// started a fresh ring instead. Called on the reader thread before
    /// any output of the adopted stream, so a sink can tell where output
    /// the dead holder read was lost before the first new byte arrives.
    fn adopted(&self, _end: u64) {}
}

/// Why a link ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkEnd {
    /// The holder closed the link or died.
    Lost,
    /// Another daemon of the session authenticated and took the holder: do
    /// not take it back (two daemons would take turns forever).
    Superseded,
    /// The holder could not read this daemon's stream on and ended the link
    /// after telling why (the ERROR code: `NO_DESCRIPTORS` when it ran out
    /// of descriptors, `BAD_PAYLOAD` when the bytes were not frames of the
    /// wire). The holder still runs every terminal and counted no crash
    /// against them: connecting again is safe.
    Fault(u16),
}

type SpawnReply = io::Result<Spawned>;
/// The segment a holder writes an adopted terminal to (`None`: private).
type AdoptReply = io::Result<Option<OwnedFd>>;

#[derive(Default)]
struct State {
    sinks: HashMap<u32, Arc<dyn TerminalSink>>,
    spawns: HashMap<u32, SyncSender<SpawnReply>>,
    /// ADOPTs waiting for the holder's [`Kind::Adopted`] (wire version 5).
    adopts: HashMap<u32, SyncSender<AdoptReply>>,
    open: bool,
}

/// A SPAWN that started no terminal: the holder refused it (its ERROR
/// answer), or the link was already lost before it went out.
#[derive(Debug)]
struct NotStarted(String);

impl std::fmt::Display for NotStarted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NotStarted {}

/// Whether a [`HolderLink::spawn`] that failed with `error` may still have
/// left its terminal on the holder: every failure but a refusal or a link
/// lost before the SPAWN went out (a timeout, a link that broke after it,
/// a malformed SPAWNED). The caller ends such a terminal on its next link
/// to the same holder.
pub fn spawn_may_have_started(error: &io::Error) -> bool {
    !error.get_ref().is_some_and(|inner| inner.is::<NotStarted>())
}

/// A holder's answer to an ADOPT, still on its way ([`HolderLink::adopt`]):
/// several ADOPTs go out before the first answer is waited for.
pub struct PendingAdopt(Option<Receiver<AdoptReply>>);

impl PendingAdopt {
    /// The ring segment the new holder writes the terminal's output to: the
    /// one the ADOPT carried when the holder continues it, a fresh one when
    /// it could not, `None` for a private ring or a holder older than wire
    /// version 5 (which does not say). The daemon keeps exactly this as its
    /// custody copy. An error when the holder refused the ADOPT, the link
    /// ended first, or no answer came within the spawn timeout: then nobody
    /// can say which segment the holder writes.
    pub fn wait(self) -> io::Result<Option<OwnedFd>> {
        let Some(answer) = self.0 else { return Ok(None) };
        answer
            .recv_timeout(SPAWN_TIMEOUT)
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "holder did not answer ADOPT"))?
    }
}

/// An authenticated, concurrent link to a holder.
pub struct HolderLink {
    writer: Mutex<UnixStream>,
    state: Mutex<State>,
    /// The holder takes [`Kind::Ack`] (wire version 2).
    credit: bool,
    /// The wire version the holder settled on.
    version: u16,
    /// How long a spawn waits for the holder's SPAWNED.
    spawn_timeout: Duration,
}

/// How long a spawn waits for the holder's answer.
pub const SPAWN_TIMEOUT: Duration = Duration::from_secs(10);

/// The grace a CLOSE gives the shell of a terminal no surface owns (a SPAWN
/// whose answer came too late) before SIGKILL: a shell's usual hang-up grace.
const UNOWNED_CLOSE_GRACE_MS: u32 = 2000;

impl HolderLink {
    /// Connect and authenticate, return the terminals the holder runs, and
    /// start the reader thread. `on_lost` runs on that thread once, when the
    /// link ends (a holder crash, or another daemon took the holder).
    pub fn connect(
        socket: &Path,
        token: &[u8; 32],
        on_lost: Box<dyn FnOnce(LinkEnd) + Send>,
    ) -> io::Result<(Arc<Self>, Vec<Listed>)> {
        Self::connect_with_spawn_timeout(socket, token, on_lost, SPAWN_TIMEOUT)
    }

    /// [`Self::connect`], with a spawn that waits `spawn_timeout` (not
    /// [`SPAWN_TIMEOUT`]) for the holder's answer: the seam a test uses to
    /// see what a SPAWN that timed out leaves behind.
    pub fn connect_with_spawn_timeout(
        socket: &Path,
        token: &[u8; 32],
        on_lost: Box<dyn FnOnce(LinkEnd) + Send>,
        spawn_timeout: Duration,
    ) -> io::Result<(Arc<Self>, Vec<Listed>)> {
        let (client, listed) = crate::client::HolderClient::connect(socket, token)?;
        let (stream, reader, version) = client.into_parts();
        stream.set_read_timeout(None)?;
        let link = Arc::new(Self {
            writer: Mutex::new(stream.try_clone()?),
            state: Mutex::new(State { open: true, ..State::default() }),
            credit: version >= 2,
            version,
            spawn_timeout,
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

    /// The wire version the holder settled on.
    pub fn version(&self) -> u16 {
        self.version
    }

    /// Whether the holder takes ring segments in an ADOPT and says which
    /// ring it writes ([`wire::RING_VERSION`]): a crash of it then loses no
    /// byte it read. A version 4 holder passes layout 1 segments but gets
    /// none (it cannot read layout 2, and does not answer an ADOPT).
    pub fn takes_rings(&self) -> bool {
        self.version >= wire::RING_VERSION
    }

    /// Start `request` on `chan`, streaming its output to `sink` from its
    /// first byte. Returns the child's pid and the caller's custody dups of
    /// the PTY master and (wire version 4) the ring segment.
    ///
    /// A holder that does not answer within the spawn timeout may still
    /// start the terminal: the spawn fails, and the holder is told to end
    /// that terminal (a CLOSE now, and another one when its late SPAWNED
    /// arrives), so no shell keeps running, blocked behind output nobody
    /// acknowledges, for the life of the link. A CLOSE written to a link
    /// that broke is lost: the caller ends such a terminal on its next link
    /// to the same holder ([`spawn_may_have_started`]).
    pub fn spawn(
        &self,
        chan: u32,
        request: &SpawnRequest,
        sink: Arc<dyn TerminalSink>,
    ) -> io::Result<Spawned> {
        let (reply, answered) = sync_channel(1);
        {
            let mut state = self.lock();
            if !state.open {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    NotStarted("holder link lost".to_string()),
                ));
            }
            state.sinks.insert(chan, sink);
            state.spawns.insert(chan, reply);
        }
        let sent = self
            .send(Kind::Spawn, chan, &request.encode(), None)
            .and_then(|()| self.send(Kind::Attach, chan, &Out::default().u64(0).0, None));
        let mut timed_out = false;
        let result = sent.and_then(|()| match answered.recv_timeout(self.spawn_timeout) {
            Ok(reply) => reply,
            Err(_) => {
                timed_out = true;
                Err(io::Error::new(io::ErrorKind::TimedOut, "holder did not spawn"))
            }
        });
        if result.is_err() {
            let mut state = self.lock();
            state.sinks.remove(&chan);
            state.spawns.remove(&chan);
        }
        if timed_out {
            // Best effort: on a link that broke meanwhile the CLOSE is lost,
            // and the caller sends it again on its next link to the holder.
            let _ = self.close(chan, UNOWNED_CLOSE_GRACE_MS);
        }
        result
    }

    /// Hand a running terminal to this holder (after a holder crash): its
    /// custody master, pid, the prologue (a VT replay of its screen at
    /// `base`) and the offset its stream continues from, `resume`. Its
    /// output then streams to `sink` from `resume`.
    ///
    /// With `ring` (the dead holder's segment; only on a link with
    /// [`Self::takes_rings`]) the new holder continues that ring: `base` is
    /// the offset the daemon parsed and confirmed, at or before `resume`,
    /// and the bytes from `resume` the dead holder read but never sent come
    /// first. Without it the new holder starts a fresh ring at `resume`, and
    /// `base` must equal `resume` (the prologue then carries what the daemon
    /// had not parsed). Either way the holder's credit counts from `base`.
    ///
    /// Returns the holder's answer, to wait for once every ADOPT went out:
    /// the segment it really writes ([`PendingAdopt::wait`]).
    pub fn adopt(
        &self,
        chan: u32,
        id: &[u8; 16],
        (pid, base, resume): (i32, u64, u64),
        (master, ring): (&OwnedFd, Option<&OwnedFd>),
        (sink, prologue): (Arc<dyn TerminalSink>, &[u8]),
    ) -> io::Result<PendingAdopt> {
        let (reply, answer) = self.takes_rings().then(|| sync_channel(1)).unzip();
        {
            let mut state = self.lock();
            if !state.open {
                return Err(lost());
            }
            state.sinks.insert(chan, sink);
            if let Some(reply) = reply {
                state.adopts.insert(chan, reply);
            }
        }
        let sent = match ring.filter(|_| self.takes_rings()) {
            Some(ring) => {
                let payload =
                    Out::default().i32(pid).u64(base).bytes(id).u64(resume).bytes(prologue).0;
                let fds = [master.as_raw_fd(), ring.as_raw_fd()];
                let writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
                let fd = writer.as_raw_fd();
                wire::send_frame(fd, Kind::Adopt, wire::FLAG_RING, chan, &payload, &fds)
            }
            None => {
                let payload = Out::default().i32(pid).u64(resume).bytes(id).bytes(prologue).0;
                self.send(Kind::Adopt, chan, &payload, Some(master))
            }
        };
        let attach = Out::default().u64(resume).u64(base).0;
        if let Err(error) = sent.and_then(|()| self.send(Kind::Attach, chan, &attach, None)) {
            self.lock().adopts.remove(&chan);
            return Err(error);
        }
        Ok(PendingAdopt(answer))
    }

    /// Stream a listed terminal's output to `sink` from `from`, after its
    /// prologue if it has one (a restarted daemon re-attaching).
    pub fn attach(&self, chan: u32, from: u64, sink: Arc<dyn TerminalSink>) -> io::Result<()> {
        let payload = Out::default().u64(from).0;
        self.attach_flagged(chan, &payload, sink, wire::FLAG_WITH_PROLOGUE)
    }

    /// Stream a terminal this daemon already shows to `sink` from `from`
    /// (the newest byte it received), without its prologue: the same
    /// holder, after the link dropped. `parsed` is the offset its parser
    /// confirmed: the holder's credit counts from there (wire version 5), so
    /// the bytes still queued stay in the window.
    pub fn resume(
        &self,
        chan: u32,
        (from, parsed): (u64, u64),
        sink: Arc<dyn TerminalSink>,
    ) -> io::Result<()> {
        let payload = Out::default().u64(from).u64(parsed.min(from)).0;
        self.attach_flagged(chan, &payload, sink, 0)
    }

    fn attach_flagged(
        &self,
        chan: u32,
        payload: &[u8],
        sink: Arc<dyn TerminalSink>,
        flags: u16,
    ) -> io::Result<()> {
        self.lock().sinks.insert(chan, sink);
        let writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        wire::send_frame(writer.as_raw_fd(), Kind::Attach, flags, chan, payload, &[])
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
        wire::send_frame(writer.as_raw_fd(), kind, 0, chan, payload, &fds)
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
        for (_, reply) in state.adopts.drain() {
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
                    let mut fds = std::mem::take(&mut frame.fds).into_iter();
                    let reply = match (input.i32(), fds.next()) {
                        (Ok(pid), Some(master)) => Ok(Spawned { pid, master, ring: fds.next() }),
                        _ => Err(io::Error::other("malformed SPAWNED")),
                    };
                    let waiter = link.lock().spawns.remove(&chan);
                    match waiter {
                        Some(waiter) => {
                            let _ = waiter.try_send(reply);
                        }
                        // The spawn gave up waiting: nobody owns this
                        // terminal, so it ends (its dups close here).
                        None => {
                            drop(reply);
                            let _ = link.close(chan, UNOWNED_CLOSE_GRACE_MS);
                        }
                    }
                }
                Some(Kind::Error) => {
                    let request = input.u16().unwrap_or_default();
                    let rest = input.rest();
                    let code = In(rest).u16().unwrap_or_default();
                    let message =
                        String::from_utf8_lossy(rest.get(2..).unwrap_or_default()).into_owned();
                    let refused = Kind::from_u16(request);
                    if chan == 0
                        && refused == Some(Kind::Hello)
                        && code == crate::holder::error_code::SUPERSEDED
                    {
                        ending = LinkEnd::Superseded;
                    } else if chan == 0 && request == wire::STREAM_FAULT {
                        ending = LinkEnd::Fault(code);
                    } else if chan != 0
                        && matches!(refused, Some(Kind::Spawn | Kind::Attach | Kind::Adopt))
                    {
                        // The holder will not start or stream this terminal:
                        // the spawn waiting for it fails (a typed NotStarted:
                        // nothing ran) and its sink stops being routed, an
                        // adoption waiting for its answer fails, else the sink
                        // hears the refusal (errors of other requests leave
                        // the stream as it is). All leave under one lock: the
                        // ATTACH right behind a refused SPAWN is refused too,
                        // and finds nothing, and the spawn's own cleanup finds
                        // nothing left to remove.
                        let (waiter, adoption, sink) = {
                            let mut state = link.lock();
                            let waiter = if refused == Some(Kind::Spawn) {
                                state.spawns.remove(&chan)
                            } else {
                                None
                            };
                            let adoption = if refused == Some(Kind::Adopt) {
                                state.adopts.remove(&chan)
                            } else {
                                None
                            };
                            (waiter, adoption, state.sinks.remove(&chan))
                        };
                        if waiter.is_some() || sink.is_some() {
                            acked.remove(&chan);
                        }
                        if let Some(waiter) = waiter {
                            let _ = waiter.try_send(Err(io::Error::other(NotStarted(message))));
                        } else {
                            if let Some(adoption) = adoption {
                                let _ = adoption.try_send(Err(io::Error::other(message.clone())));
                            }
                            if let Some(sink) = sink {
                                sink.refused(&message);
                            }
                        }
                    }
                }
                Some(Kind::Adopted) => {
                    let segment = std::mem::take(&mut frame.fds).into_iter().next();
                    // The ring the holder writes: `oldest`, then `end`. Before
                    // the answer goes to its waiter and before any DATA of
                    // the channel (the holder queues ADOPTED ahead of them).
                    let _oldest = input.u64();
                    if let Ok(end) = input.u64()
                        && let Some(sink) = link.lock().sinks.get(&chan).cloned()
                    {
                        sink.adopted(end);
                    }
                    if let Some(waiter) = link.lock().adopts.remove(&chan) {
                        let _ = waiter.try_send(Ok(segment));
                    }
                }
                Some(Kind::Data) => {
                    let Ok(offset) = input.u64() else { continue };
                    let sink = link.lock().sinks.get(&chan).cloned();
                    let Some(sink) = sink else {
                        // Nobody parses this terminal (its surface is gone,
                        // or its spawn gave up waiting): its output is
                        // consumed here, so the holder never holds the
                        // shell behind credit nobody would give, and the
                        // terminal can end and be forgotten.
                        if frame.flags & wire::FLAG_PROLOGUE == 0 {
                            let _ = link.ack(chan, offset + input.rest().len() as u64);
                        }
                        continue;
                    };
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
