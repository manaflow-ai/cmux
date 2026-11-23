//! The machine's end of the stream to the Mac ([`crate::wire`]): a [`crate::Fetch`] whose asks go
//! to whichever stream the Mac attached last. The Mac opens the stream (the machine never dials
//! it) and opens a new one after a drop; until then an ask waits up to [`Link::away_wait`], then
//! fails as [`crate::FetchError::Away`].

use std::collections::HashMap;
use std::io::{BufReader, BufWriter, Read, Write};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::wire::{self, Ask, Part};
use crate::{Fetch, FetchError};

/// How long an ask waits for the Mac to come back by default (RFD 0007: a reconnect usually lands
/// inside it).
pub const AWAY_WAIT: Duration = Duration::from_secs(5);
/// How long an ask waits for its answer on an attached stream.
const ANSWER_WAIT: Duration = Duration::from_secs(120);

type Writer = Box<dyn Write + Send>;
/// An ask in flight: the attachment it went out on, and where its answer goes (`None` when that
/// stream ended first).
type Waiter = (u64, Sender<Option<Vec<Part>>>);

struct Attached {
    /// Which attachment this is (an old stream's reader never touches a newer one).
    generation: u64,
    writer: Writer,
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
}

impl Default for Link {
    fn default() -> Self {
        Self::new(AWAY_WAIT)
    }
}

impl Link {
    /// A link with no stream yet, whose asks wait `away_wait` for one.
    #[must_use]
    pub fn new(away_wait: Duration) -> Self {
        Self {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            next: AtomicU32::new(1),
            away_wait,
        }
    }

    /// How long an ask waits for a stream.
    #[must_use]
    pub fn away_wait(&self) -> Duration {
        self.away_wait
    }

    /// Whether a stream is attached now.
    #[must_use]
    pub fn attached(&self) -> bool {
        self.lock().attached.is_some()
    }

    /// Serves asks over `reader` and `writer` (the Mac's new stream) until it ends; asks in flight
    /// on an older stream fail over to this one. Returns when the stream ends.
    pub fn serve(&self, reader: impl Read, writer: impl Write + Send + 'static) {
        let generation = {
            let mut state = self.lock();
            state.generation += 1;
            let generation = state.generation;
            state.attached = Some(Attached {
                generation,
                writer: Box::new(BufWriter::with_capacity(64 * 1024, writer)),
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
        let mut reader = BufReader::with_capacity(256 * 1024, reader);
        while let Ok(Some((ask, parts))) = wire::read_answer(&mut reader) {
            let waiter = {
                let mut state = self.lock();
                state.waiting.remove(&ask).filter(|(of, _)| *of == generation)
            };
            if let Some((_, sender)) = waiter {
                let _ = sender.send(Some(parts));
            }
        }
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
            if let Some(attached) = state.attached.as_mut() {
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

    /// Which files the Mac has put in the store, from the `since`-th it put on: its upload's
    /// epoch (a new one starts again from 0) and `(entry, blob id)` pairs, in the order it put
    /// them. Asked only of a Mac whose store is configured (an older Mac ends a stream on an ask it
    /// does not know).
    pub fn stored(&self, since: u32) -> Result<(u64, Vec<(u32, String)>), FetchError> {
        let parts = self.ask(&|ask| Ask::Stored { ask, since })?;
        let mut parts = parts.into_iter();
        let Some(epoch) = parts.next() else { return Ok((0, Vec::new())) };
        let epoch = <[u8; 8]>::try_from(epoch.bytes.as_slice())
            .map(u64::from_le_bytes)
            .map_err(|_| FetchError::Failed)?;
        let files = parts
            .filter_map(|part| {
                let (entry, oid) = part.bytes.split_at_checked(4)?;
                let entry = u32::from_le_bytes(entry.try_into().ok()?);
                Some((entry, String::from_utf8(oid.to_vec()).ok()?))
            })
            .collect();
        Ok((epoch, files))
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
            Ask::Stored { since, .. } => source.stored(*since),
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
    /// The answer to [`Ask::Stored`]: an epoch part (`u64`) and one part per file put in the store
    /// from the `since`-th on (`entry u32` and its blob id). None when this Mac puts nothing in a
    /// store ([`crate::upload::Uploader`] does).
    fn stored(&self, since: u32) -> Vec<Part> {
        let _ = since;
        Vec::new()
    }
}

#[cfg(test)]
#[path = "link_tests.rs"]
mod tests;
