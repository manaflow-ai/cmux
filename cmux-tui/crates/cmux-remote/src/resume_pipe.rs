//! Resumable pipes: a byte stream whose two ends outlive the transport between them (RFD 0127
//! cut 4, "Substreams outlive an acpmux restart"). Leo, 2026-11-22: "surely we can improve on
//! ssh/cmux-wg/our remote protocols".
//!
//! A held ssh rides `ssh` -> its ProxyCommand -> this machine's acpmux -> the pair's kept carrier
//! circuit -> the far acpmux -> the far sshd. When either acpmux restarts the circuit goes, and
//! with plain bytes the held ssh went with it: bytes in flight are lost, so nothing can carry on.
//! A resumable pipe runs between the two ends that do not restart (the ProxyCommand process on
//! one side, the far daemon's held sshd socket on the other) and frames its bytes so each end
//! knows what the other has:
//!
//! - DATA: payload bytes. Each end counts the DATA bytes it took in, across every transport.
//! - ACK: `u64` big-endian, the sender's count. The other end drops its copies up to it.
//! - FIN: the sender's local side ended (its read saw EOF), as TCP's half close.
//!
//! Frame: `kind u8`, `len u32` big-endian, payload. Each end keeps every byte it sent and the
//! other has not acked ([`SendLog`], at most [`MAX_UNACKED`]; the local read waits past it). A
//! transport that breaks leaves the pipe whole: the next transport starts with each end telling
//! the other its count (out of band: the service hello and its answer, or the pipe request and
//! its reply), and each end sends again from there. So nothing is lost or doubled however often
//! the transport goes, as long as both ends live.
//!
//! [`ResumablePipe`] is one end: [`ResumablePipe::claim`] stops the transport it runs on now (a
//! resume may come before the old transport's break is seen), and [`Claim::run`] carries the pipe
//! on a new one until the pipe ends ([`Ran::Finished`]), the transport breaks ([`Ran::Broken`],
//! claim it again on the next) or the pipe cannot go on ([`Ran::Failed`]).

use std::collections::VecDeque;
use std::sync::Mutex;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadHalf, WriteHalf};
use tokio::sync::{Notify, mpsc, watch};

pub const DATA: u8 = 1;
pub const ACK: u8 = 2;
pub const FIN: u8 = 3;
const HEADER: usize = 5;
/// The largest DATA payload a frame carries (and the most any frame may claim).
pub const MAX_PAYLOAD: usize = 64 * 1024;
/// Bytes one end keeps for the other, unacked, before its local read waits.
pub const MAX_UNACKED: usize = 4 * 1024 * 1024;
/// Frames queued for the transport beside the one being written.
const QUEUED_FRAMES: usize = 16;

/// One encoded frame.
pub fn frame(kind: u8, payload: &[u8]) -> Bytes {
    let mut out = BytesMut::with_capacity(HEADER + payload.len());
    out.put_u8(kind);
    out.put_u32(u32::try_from(payload.len()).unwrap_or(u32::MAX));
    out.put_slice(payload);
    out.freeze()
}

/// The next whole frame in `buf`, taken out of it; `Ok(None)` while it is still partial.
pub fn next_frame(buf: &mut BytesMut) -> Result<Option<(u8, Bytes)>, String> {
    if buf.len() < HEADER {
        return Ok(None);
    }
    let Some((&[kind, a, b, c, d], _)) = buf.split_first_chunk::<HEADER>() else {
        return Ok(None);
    };
    let len = u32::from_be_bytes([a, b, c, d]) as usize;
    if len > MAX_PAYLOAD {
        return Err(format!("a resumable pipe frame claims {len} bytes"));
    }
    if buf.len() < HEADER + len {
        return Ok(None);
    }
    buf.advance(HEADER);
    Ok(Some((kind, buf.split_to(len).freeze())))
}

/// Every byte one end sent that the other has not acked yet, from offset [`Self::base`].
#[derive(Debug, Default)]
pub struct SendLog {
    base: u64,
    chunks: VecDeque<Bytes>,
    len: usize,
}

impl SendLog {
    /// The offset of the first byte kept (everything before it was acked).
    pub fn base(&self) -> u64 {
        self.base
    }

    /// The offset after the last byte sent.
    pub fn end(&self) -> u64 {
        self.base + self.len as u64
    }

    /// Bytes kept, unacked.
    pub fn unacked(&self) -> usize {
        self.len
    }

    pub fn push(&mut self, bytes: Bytes) {
        if !bytes.is_empty() {
            self.len += bytes.len();
            self.chunks.push_back(bytes);
        }
    }

    /// The other end took in `total` bytes: drop them. A stale ack (below what was acked before)
    /// is no news; one past what was sent is a broken peer.
    pub fn ack(&mut self, total: u64) -> Result<(), String> {
        if total > self.end() {
            return Err(format!("acked {total} bytes, past the {} sent", self.end()));
        }
        while total > self.base {
            let Some(front) = self.chunks.front_mut() else { break };
            let drop = usize::try_from(total - self.base).unwrap_or(usize::MAX).min(front.len());
            front.advance(drop);
            self.base += drop as u64;
            self.len -= drop;
            if front.is_empty() {
                self.chunks.pop_front();
            }
        }
        Ok(())
    }

    /// The bytes from offset `from` on, to send again on a new transport. A `from` below what was
    /// acked, or past what was sent, is a peer that lost track: the pipe cannot go on.
    pub fn replay(&self, from: u64) -> Result<Vec<Bytes>, String> {
        if from < self.base || from > self.end() {
            return Err(format!(
                "the other end has {from} bytes; this end kept {}..{}",
                self.base,
                self.end()
            ));
        }
        let mut skip = usize::try_from(from - self.base).unwrap_or(usize::MAX);
        let mut out = Vec::new();
        for chunk in &self.chunks {
            if skip >= chunk.len() {
                skip -= chunk.len();
                continue;
            }
            out.push(chunk.slice(skip..));
            skip = 0;
        }
        Ok(out)
    }
}

#[derive(Debug, Default)]
struct State {
    log: SendLog,
    /// DATA bytes taken in, across every transport.
    received: u64,
    /// The highest count an ACK carried out on the current transport (reset per transport: the
    /// count also goes out of band at each resume).
    ack_written: u64,
    /// The local read saw EOF (a FIN goes on every transport from then on).
    fin_sent: bool,
    /// The current transport carried this end's FIN.
    fin_written: bool,
    /// The other end's FIN came: the local write side is shut.
    fin_received: bool,
}

impl State {
    fn done(&self) -> bool {
        self.fin_sent
            && self.fin_written
            && self.fin_received
            && self.log.unacked() == 0
            && self.ack_written == self.received
    }

    /// Both sides ended and the other end has every byte of ours: what an end-of-transport
    /// from a finished other end leaves.
    fn peer_finished(&self) -> bool {
        self.fin_sent && self.fin_received && self.log.unacked() == 0
    }
}

struct Local<L> {
    read: ReadHalf<L>,
    write: WriteHalf<L>,
}

/// How one transport's run of a pipe ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Ran {
    /// Both ends' bytes arrived and were acked, and both sides ended: drop the pipe.
    Finished,
    /// The transport broke (or a newer claim took the pipe): keep the pipe for a resume.
    Broken(String),
    /// The pipe cannot go on (its local side failed, or the other end broke the protocol).
    Failed(String),
}

/// One end of a resumable pipe, over local io `L` (the far sshd's socket, or the ProxyCommand's
/// stdio).
pub struct ResumablePipe<L> {
    state: Mutex<State>,
    local: tokio::sync::Mutex<Local<L>>,
    /// Bumped by each claim; a run ends when it moves past the claim it runs under.
    claims: watch::Sender<u64>,
    /// Fired on every ack, FIN and write of an ack or a FIN: what a waiting local read or the
    /// finish check waits on.
    progress: Notify,
    /// Fired when an ack is due on the transport.
    ack_due: Notify,
}

impl<L: AsyncRead + AsyncWrite + Send> ResumablePipe<L> {
    pub fn new(local: L) -> Self {
        let (read, write) = tokio::io::split(local);
        Self {
            state: Mutex::new(State::default()),
            local: tokio::sync::Mutex::new(Local { read, write }),
            claims: watch::channel(0).0,
            progress: Notify::new(),
            ack_due: Notify::new(),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// DATA bytes this end took in so far: the count a resume tells the other end.
    pub fn received(&self) -> u64 {
        self.state().received
    }

    /// Both sides ended and the other end has every byte of this end's: nothing is left to
    /// carry, so an other end that no longer holds the pipe finished it.
    pub fn peer_finished(&self) -> bool {
        self.state().peer_finished()
    }

    /// Take the pipe for a new transport: the run on the old one (if any) ends as
    /// [`Ran::Broken`], and the claim's [`Claim::received`] is final until [`Claim::run`].
    pub async fn claim(&self) -> Claim<'_, L> {
        let mut generation = 0;
        self.claims.send_modify(|claims| {
            *claims += 1;
            generation = *claims;
        });
        let local = self.local.lock().await;
        Claim { pipe: self, local, generation }
    }
}

/// A pipe taken for one transport ([`ResumablePipe::claim`]).
pub struct Claim<'a, L> {
    pipe: &'a ResumablePipe<L>,
    local: tokio::sync::MutexGuard<'a, Local<L>>,
    generation: u64,
}

impl<L: AsyncRead + AsyncWrite + Send> Claim<'_, L> {
    /// DATA bytes this end took in: tell the other end, so it sends again from there.
    pub fn received(&self) -> u64 {
        self.pipe.received()
    }

    /// Carry the pipe on `transport`, the other end having taken in `peer_received` bytes, until
    /// the pipe finishes, the transport breaks or a newer claim takes the pipe.
    pub async fn run<T>(mut self, transport: T, peer_received: u64) -> Ran
    where
        T: AsyncRead + AsyncWrite + Send,
    {
        let pipe = self.pipe;
        let replay = {
            let mut state = pipe.state();
            state.ack_written = 0;
            state.fin_written = false;
            // The other end's count acks everything below it, as an ACK would.
            if let Err(e) = state.log.ack(peer_received) {
                return Ran::Failed(e);
            }
            match state.log.replay(peer_received) {
                Ok(replay) => (replay, state.fin_sent),
                Err(e) => return Ran::Failed(e),
            }
        };
        let (mut from_peer, mut to_peer) = tokio::io::split(transport);
        let Local { read: local_read, write: local_write } = &mut *self.local;
        let (frames, mut queued) = mpsc::channel::<(u8, Bytes)>(QUEUED_FRAMES);
        let mut claims = pipe.claims.subscribe();
        let generation = self.generation;

        // The one writer of the transport: the replay first, then queued DATA and FIN frames and
        // the ack whenever one is due, so taking in DATA never waits on this end's own sends.
        let write = async {
            let (replay, fin) = replay;
            for chunk in replay {
                for piece in chunk.chunks(MAX_PAYLOAD) {
                    if let Err(e) = write_frame(&mut to_peer, DATA, piece).await {
                        return e;
                    }
                }
            }
            if fin {
                if let Err(e) = write_frame(&mut to_peer, FIN, &[]).await {
                    return e;
                }
                pipe.state().fin_written = true;
                pipe.progress.notify_waiters();
            }
            let received = pipe.received();
            if let Err(e) = write_frame(&mut to_peer, ACK, &received.to_be_bytes()).await {
                return e;
            }
            pipe.state().ack_written = received;
            pipe.progress.notify_waiters();
            loop {
                tokio::select! {
                    biased;
                    () = pipe.ack_due.notified() => {
                        let received = pipe.received();
                        if received > pipe.state().ack_written {
                            if let Err(e) = write_frame(&mut to_peer, ACK, &received.to_be_bytes()).await {
                                return e;
                            }
                            pipe.state().ack_written = received;
                            pipe.progress.notify_waiters();
                        }
                    }
                    Some((kind, bytes)) = queued.recv() => {
                        if let Err(e) = write_frame(&mut to_peer, kind, &bytes).await {
                            return e;
                        }
                        if kind == FIN {
                            pipe.state().fin_written = true;
                            pipe.progress.notify_waiters();
                        }
                    }
                }
            }
        };

        // The local read: into the log, then onto the transport. Waits while the log is full.
        let up = async {
            if pipe.state().fin_sent {
                return std::future::pending::<Ran>().await;
            }
            let mut buf = vec![0u8; MAX_PAYLOAD];
            loop {
                loop {
                    let wait = pipe.progress.notified();
                    if pipe.state().log.unacked() < MAX_UNACKED {
                        break;
                    }
                    wait.await;
                }
                let n = match local_read.read(&mut buf).await {
                    Ok(n) => n,
                    Err(e) => return Ran::Failed(format!("the local side failed: {e}")),
                };
                if n == 0 {
                    pipe.state().fin_sent = true;
                    let _ = frames.send((FIN, Bytes::new())).await;
                    return std::future::pending().await;
                }
                let bytes = Bytes::copy_from_slice(buf.get(..n).unwrap_or_default());
                pipe.state().log.push(bytes.clone());
                // Already in the log: a transport that breaks here sends it again on the next.
                if frames.send((DATA, bytes)).await.is_err() {
                    return std::future::pending().await;
                }
            }
        };

        // The transport's frames: DATA to the local write side, ACKs to the log, the FIN.
        let down = async {
            let mut buf = BytesMut::with_capacity(2 * MAX_PAYLOAD);
            loop {
                loop {
                    let (kind, payload) = match next_frame(&mut buf) {
                        Ok(Some(next)) => next,
                        Ok(None) => break,
                        Err(e) => return Ran::Failed(e),
                    };
                    match kind {
                        DATA => {
                            if pipe.state().fin_received {
                                return Ran::Failed("DATA after the other end's FIN".into());
                            }
                            // Counted per write, not per frame: a run that ends inside the
                            // frame (a cut, a newer claim) has its written part counted, so
                            // the resume sends only the rest and no byte arrives twice.
                            let mut rest = &payload[..];
                            while !rest.is_empty() {
                                let n = match local_write.write(rest).await {
                                    Ok(0) => {
                                        return Ran::Failed("the local side took no bytes".into());
                                    }
                                    Ok(n) => n,
                                    Err(e) => {
                                        return Ran::Failed(format!("the local side failed: {e}"));
                                    }
                                };
                                pipe.state().received += n as u64;
                                rest = rest.get(n..).unwrap_or_default();
                            }
                            pipe.ack_due.notify_one();
                        }
                        ACK => {
                            let Some(total) = payload
                                .get(..8)
                                .and_then(|b| b.try_into().ok())
                                .map(u64::from_be_bytes)
                            else {
                                return Ran::Failed("a short ACK".into());
                            };
                            let acked = pipe.state().log.ack(total);
                            if let Err(e) = acked {
                                return Ran::Failed(e);
                            }
                            pipe.progress.notify_waiters();
                        }
                        FIN => {
                            let first = !std::mem::replace(&mut pipe.state().fin_received, true);
                            if first {
                                let _ = local_write.shutdown().await;
                            }
                            pipe.progress.notify_waiters();
                        }
                        other => return Ran::Failed(format!("an unknown frame kind {other}")),
                    }
                }
                match from_peer.read_buf(&mut buf).await {
                    // The other end shuts its side only when it finished; with both FINs in
                    // and every byte of ours acked, nothing is left for this end either (its
                    // own last ACK is moot: the other end already has every byte).
                    Ok(0) if pipe.state().peer_finished() => return Ran::Finished,
                    Ok(0) => return Ran::Broken("the transport ended".into()),
                    Ok(_) => {}
                    Err(e) => return Ran::Broken(format!("the transport failed: {e}")),
                }
            }
        };

        let finished = async {
            loop {
                let wait = pipe.progress.notified();
                if pipe.state().done() {
                    return;
                }
                wait.await;
            }
        };

        let preempted = async {
            while claims.changed().await.is_ok() {
                if *claims.borrow() != generation {
                    return;
                }
            }
            std::future::pending::<()>().await;
        };

        let ran = tokio::select! {
            () = finished => Ran::Finished,
            ran = up => ran,
            ran = down => ran,
            e = write => Ran::Broken(format!("the transport failed: {e}")),
            () = preempted => Ran::Broken("a newer transport took the pipe".into()),
        };
        if ran == Ran::Finished {
            let _ = to_peer.shutdown().await;
        }
        ran
    }
}

async fn write_frame<W: AsyncWrite + Unpin>(
    to: &mut W,
    kind: u8,
    payload: &[u8],
) -> Result<(), String> {
    to.write_all(&frame(kind, payload)).await.map_err(|e| e.to_string())?;
    to.flush().await.map_err(|e| e.to_string())
}

#[cfg(test)]
#[path = "resume_pipe_tests.rs"]
mod tests;
