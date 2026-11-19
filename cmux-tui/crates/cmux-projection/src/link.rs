//! The machine's end of the stream to the Mac ([`crate::wire`]): a [`crate::Fetch`] whose asks go
//! to whichever stream the Mac attached last. The Mac opens the stream (the machine never dials
//! it) and opens a new one after a drop; until then an ask waits up to [`Link::away_wait`], then
//! fails as [`crate::FetchError::Away`].
//!
//! A stream can also die without ending: a carrier that keeps the connection open but moves no
//! bytes (a half-open TCP connection, a stalled relay), or a Mac that went to sleep. Neither side
//! is told. So the machine pings an attached stream every [`HEARTBEAT`]; a stream that has heard
//! nothing for [`STALL_WAIT`] since a ping went out is *stalled*: its asks in flight fail over
//! (to a newer stream, else as `Away`) and new asks do not go to it, until a byte arrives on it
//! again (the Mac woke) or the Mac dials anew. The Mac's end ([`answer_asks`]) gives up a stream
//! that brought no ask, pings included, for [`MAC_IDLE`] (the read timeout its caller sets on the
//! stream) and dials again.

use std::collections::HashMap;
use std::io::{BufReader, BufWriter, Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::wire::{self, Ask, Part};
use crate::{Fetch, FetchError};

/// How long an ask waits for the Mac to come back by default (RFD 0007: a reconnect usually lands
/// inside it).
pub const AWAY_WAIT: Duration = Duration::from_secs(5);
/// How long an ask waits for its answer on an attached stream that keeps moving bytes.
const ANSWER_WAIT: Duration = Duration::from_secs(120);
/// How often the machine pings an attached stream.
pub const HEARTBEAT: Duration = Duration::from_secs(5);
/// How long an attached stream may stay silent after a ping before it counts as stalled.
pub const STALL_WAIT: Duration = Duration::from_secs(10);
/// How long the Mac's end waits for any ask (pings come every [`HEARTBEAT`]) before it gives the
/// stream up and dials again: the read timeout the Mac sets on its stream.
pub const MAC_IDLE: Duration = Duration::from_secs(20);

type Writer = Box<dyn Write + Send>;
/// An ask in flight: the attachment it went out on, and where its answer goes (`None` when that
/// stream ended first).
type Waiter = (u64, Sender<Option<Vec<Part>>>);

struct Attached {
    /// Which attachment this is (an old stream's reader never touches a newer one).
    generation: u64,
    writer: Writer,
    /// When a byte last arrived on it (ms since [`Link::epoch`]).
    heard: Arc<AtomicU64>,
    /// When the oldest ping not yet followed by a byte went out (ms since the epoch; 0: none).
    pinged: u64,
    /// No byte since a ping [`Link::stall_wait`] ago: asks do not go to it.
    stalled: bool,
}

#[derive(Default)]
struct State {
    attached: Option<Attached>,
    generation: u64,
    waiting: HashMap<u32, Waiter>,
}

/// The machine's end of the stream to the Mac.
pub struct Link {
    state: Mutex<State>,
    changed: Condvar,
    next: AtomicU32,
    away_wait: Duration,
    heartbeat: Duration,
    stall_wait: Duration,
    epoch: Instant,
}

impl Default for Link {
    fn default() -> Self {
        Self::new(AWAY_WAIT)
    }
}

/// A reader that notes when bytes arrive.
struct Heard<R> {
    inner: R,
    heard: Arc<AtomicU64>,
    epoch: Instant,
}

impl<R: Read> Read for Heard<R> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let count = self.inner.read(out)?;
        if count > 0 {
            self.heard.store(ms_since(self.epoch), Ordering::Release);
        }
        Ok(count)
    }
}

/// Milliseconds since `epoch`, never 0 (0 stands for "no ping out").
fn ms_since(epoch: Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_millis()).unwrap_or(u64::MAX).max(1)
}

fn whole_ms(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

impl Link {
    /// A link with no stream yet, whose asks wait `away_wait` for one.
    #[must_use]
    pub fn new(away_wait: Duration) -> Self {
        Self::with_heartbeat(away_wait, HEARTBEAT, STALL_WAIT)
    }

    /// [`Link::new`] with its own heartbeat and stall wait (tests).
    #[must_use]
    pub fn with_heartbeat(away_wait: Duration, heartbeat: Duration, stall_wait: Duration) -> Self {
        Self {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            next: AtomicU32::new(1),
            away_wait,
            heartbeat,
            stall_wait,
            epoch: Instant::now(),
        }
    }

    /// How long an ask waits for a stream.
    #[must_use]
    pub fn away_wait(&self) -> Duration {
        self.away_wait
    }

    /// Whether a stream is attached now (stalled or not).
    #[must_use]
    pub fn attached(&self) -> bool {
        self.lock().attached.is_some()
    }

    /// Whether the attached stream is stalled (see the module's docs).
    #[must_use]
    pub fn stalled(&self) -> bool {
        self.lock().attached.as_ref().is_some_and(|attached| attached.stalled)
    }

    /// Pings stream `generation` every heartbeat and marks it stalled when a ping goes unheard
    /// for the stall wait, until `ended`. A wait that overran by far (this process was paused)
    /// only pings again: that silence was this side's.
    fn watch(&self, generation: u64, ended: &AtomicBool) {
        let stall_ms = whole_ms(self.stall_wait);
        let mut state = self.lock();
        let mut beat = Instant::now() + self.heartbeat;
        loop {
            if ended.load(Ordering::Acquire) {
                return;
            }
            let at = Instant::now();
            if at < beat {
                state = self
                    .changed
                    .wait_timeout(state, beat - at)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
                continue;
            }
            let paused = at > beat + self.heartbeat + Duration::from_secs(1);
            beat = at + self.heartbeat;
            let now = ms_since(self.epoch);
            let Some(attached) =
                state.attached.as_mut().filter(|attached| attached.generation == generation)
            else {
                return;
            };
            let heard = attached.heard.load(Ordering::Acquire);
            if paused || (attached.pinged != 0 && heard >= attached.pinged) {
                attached.pinged = 0;
            }
            let silent = attached.pinged != 0 && now.saturating_sub(attached.pinged) >= stall_ms;
            if silent && !attached.stalled {
                attached.stalled = true;
                // Its asks in flight fail over: to a newer stream, else as `Away`.
                state.waiting.retain(|_, (of, sender)| {
                    if *of == generation {
                        let _ = sender.send(None);
                        false
                    } else {
                        true
                    }
                });
                self.changed.notify_all();
                continue;
            }
            let number = self.next.fetch_add(1, Ordering::Relaxed);
            let sent = Ask::Ping { ask: number }
                .write(&mut attached.writer)
                .and_then(|()| attached.writer.flush());
            if sent.is_err() {
                state.attached = None;
                self.changed.notify_all();
                return;
            }
            if attached.pinged == 0 {
                attached.pinged = ms_since(self.epoch);
            }
        }
    }

    /// Serves asks over `reader` and `writer` (the Mac's new stream) until it ends; asks in flight
    /// on an older stream fail over to this one. Returns when the stream ends.
    pub fn serve(&self, reader: impl Read, writer: impl Write + Send + 'static) {
        let heard = Arc::new(AtomicU64::new(ms_since(self.epoch)));
        let generation = {
            let mut state = self.lock();
            state.generation += 1;
            let generation = state.generation;
            state.attached = Some(Attached {
                generation,
                writer: Box::new(BufWriter::with_capacity(64 * 1024, writer)),
                heard: heard.clone(),
                pinged: 0,
                stalled: false,
            });
            // Asks of an older stream are answered with nothing: the asker asks again here.
            state.waiting.retain(|_, (of, sender)| {
                if *of == generation {
                    true
                } else {
                    let _ = sender.send(None);
                    false
                }
            });
            generation
        };
        self.changed.notify_all();
        let reader = Heard { inner: reader, heard, epoch: self.epoch };
        let mut reader = BufReader::with_capacity(256 * 1024, reader);
        let ended = AtomicBool::new(false);
        std::thread::scope(|scope| {
            scope.spawn(|| self.watch(generation, &ended));
            while let Ok(Some((ask, parts))) = wire::read_answer(&mut reader) {
                let waiter =
                    {
                        let mut state = self.lock();
                        // A stalled stream that speaks again is back (the Mac woke up).
                        if let Some(attached) = state.attached.as_mut().filter(|attached| {
                            attached.generation == generation && attached.stalled
                        }) {
                            attached.stalled = false;
                            attached.pinged = 0;
                            self.changed.notify_all();
                        }
                        state.waiting.remove(&ask).filter(|(of, _)| *of == generation)
                    };
                if let Some((_, sender)) = waiter {
                    let _ = sender.send(Some(parts));
                }
            }
            let _state = self.lock();
            ended.store(true, Ordering::Release);
            self.changed.notify_all();
        });
        let mut state = self.lock();
        if state.attached.as_ref().is_some_and(|attached| attached.generation == generation) {
            state.attached = None;
        }
        state.waiting.retain(|_, (of, sender)| {
            if *of == generation {
                let _ = sender.send(None);
                false
            } else {
                true
            }
        });
        drop(state);
        self.changed.notify_all();
    }

    /// Drops the attached stream's writer (the Mac's stream ends from this side too once its
    /// reader sees the close) and fails every ask in flight.
    pub fn detach(&self) {
        let mut state = self.lock();
        state.attached = None;
        for (_, (_, sender)) in state.waiting.drain() {
            let _ = sender.send(None);
        }
        drop(state);
        self.changed.notify_all();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sends one ask (made by `make` from its number) and waits for its answer, over whichever
    /// stream is attached, asking again on a newer stream when one replaces it.
    fn ask(&self, make: &dyn Fn(u32) -> Ask) -> Result<Vec<Part>, FetchError> {
        let deadline = Instant::now() + self.away_wait;
        loop {
            let receiver = self.send(make, deadline)?;
            match receiver.recv_timeout(ANSWER_WAIT) {
                Ok(Some(parts)) => return Ok(parts),
                // The stream ended (or was replaced) before the answer: ask again on the next.
                Ok(None) | Err(RecvTimeoutError::Disconnected) => {}
                // An attached Mac that never answers: the read fails rather than hangs.
                Err(RecvTimeoutError::Timeout) => return Err(FetchError::Failed),
            }
        }
    }

    fn send(
        &self,
        make: &dyn Fn(u32) -> Ask,
        deadline: Instant,
    ) -> Result<Receiver<Option<Vec<Part>>>, FetchError> {
        let mut state = self.lock();
        loop {
            if let Some(attached) = state.attached.as_mut().filter(|attached| !attached.stalled) {
                let number = self.next.fetch_add(1, Ordering::Relaxed);
                let generation = attached.generation;
                let sent =
                    make(number).write(&mut attached.writer).and_then(|()| attached.writer.flush());
                if sent.is_err() {
                    state.attached = None;
                    continue;
                }
                let (sender, receiver) = channel();
                state.waiting.insert(number, (generation, sender));
                return Ok(receiver);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(FetchError::Away);
            }
            state = self
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Asks the Mac whether it is there; true on an answer.
    pub fn ping(&self) -> bool {
        self.ask(&|ask| Ask::Ping { ask }).is_ok()
    }
}

fn part_result(part: Option<Part>) -> Result<Vec<u8>, FetchError> {
    match part {
        Some(Part { status: wire::OK, bytes }) => Ok(bytes),
        Some(Part { status: wire::CHANGED, .. }) => Err(FetchError::Changed),
        Some(Part { status: wire::REFUSED, .. }) => Err(FetchError::Refused),
        _ => Err(FetchError::Failed),
    }
}

impl Fetch for Link {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let parts = self.ask(&|ask| Ask::Read { ask, entry, offset, len })?;
        part_result(parts.into_iter().next())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        match self.ask(&|ask| Ask::Batch { ask, entries: entries.to_vec() }) {
            Ok(parts) => {
                let mut parts = parts.into_iter();
                entries.iter().map(|_| part_result(parts.next())).collect()
            }
            Err(error) => entries.iter().map(|_| Err(error)).collect(),
        }
    }
}

/// The Mac's end: answers every ask read from `reader` with `source`, until the stream ends.
pub fn answer_asks(
    reader: impl Read,
    writer: impl Write,
    source: &(dyn Source + Sync),
) -> std::io::Result<()> {
    let mut reader = BufReader::with_capacity(64 * 1024, reader);
    let mut writer = BufWriter::with_capacity(1024 * 1024, writer);
    while let Some(ask) = Ask::read(&mut reader)? {
        let parts = match &ask {
            Ask::Read { entry, offset, len, .. } => vec![source.read(*entry, *offset, *len)],
            Ask::Batch { entries, .. } => {
                entries.iter().map(|entry| source.whole(*entry)).collect()
            }
            Ask::Ping { .. } => Vec::new(),
        };
        wire::write_answer(&mut writer, ask.number(), &parts)?;
        writer.flush()?;
    }
    Ok(())
}

/// What the Mac serves a projection's bytes from.
pub trait Source {
    /// `len` bytes of file `entry` at `offset` (fewer at its end).
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part;
    /// All of file `entry` (a batch asks only for small files).
    fn whole(&self, entry: u32) -> Part;
}

#[cfg(test)]
#[path = "link_tests.rs"]
mod tests;
