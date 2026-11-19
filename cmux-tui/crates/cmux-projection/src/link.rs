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
use crate::{Fetch, FetchError, Fetched};

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
            if state.attached.is_some() {
                let number = self.next.fetch_add(1, Ordering::Relaxed);
                let generation = state.attached.as_ref().map_or(0, |attached| attached.generation);
                let (sender, receiver) = channel();
                state.waiting.insert(number, (generation, sender));
                let sent = {
                    let Some(attached) = state.attached.as_mut() else {
                        state.waiting.remove(&number);
                        continue;
                    };
                    make(number).write(&mut attached.writer).and_then(|()| attached.writer.flush())
                };
                if sent.is_err() {
                    state.waiting.remove(&number);
                    state.attached = None;
                    continue;
                }
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

fn part_fresh(part: Option<Part>) -> Result<Fetched, FetchError> {
    if let Some((stat, bytes)) = part.as_ref().and_then(Part::restat) {
        return Ok(Fetched::Restated(stat, bytes.to_vec()));
    }
    part_result(part).map(Fetched::Same)
}

impl Fetch for Link {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        match self.read_fresh(entry, offset, len)? {
            Fetched::Same(bytes) => Ok(bytes),
            Fetched::Restated(..) => Err(FetchError::Changed),
        }
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        self.batch_fresh(entries)
            .into_iter()
            .map(|answer| match answer? {
                Fetched::Same(bytes) => Ok(bytes),
                Fetched::Restated(..) => Err(FetchError::Changed),
            })
            .collect()
    }

    fn read_fresh(&self, entry: u32, offset: u64, len: u32) -> Result<Fetched, FetchError> {
        let parts = self.ask(&|ask| Ask::Read { ask, entry, offset, len })?;
        part_fresh(parts.into_iter().next())
    }

    fn batch_fresh(&self, entries: &[u32]) -> Vec<Result<Fetched, FetchError>> {
        match self.ask(&|ask| Ask::Batch { ask, entries: entries.to_vec() }) {
            Ok(parts) => {
                let mut parts = parts.into_iter();
                entries.iter().map(|_| part_fresh(parts.next())).collect()
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
        let mut parts = match &ask {
            Ask::Read { entry, offset, len, .. } => vec![source.read(*entry, *offset, *len)],
            Ask::Batch { entries, .. } => {
                entries.iter().map(|entry| source.whole(*entry)).collect()
            }
            Ask::Ping { .. } => Vec::new(),
        };
        // A file re-listed after a change may have grown past what one answer carries: such a
        // part keeps only its stat, and the machine asks for its bytes again.
        let mut total = 0u64;
        for part in &mut parts {
            if total + part.bytes.len() as u64 > wire::MAX_ANSWER {
                part.keep_stat_only();
            }
            total += part.bytes.len() as u64;
        }
        wire::write_answer(&mut writer, ask.number(), &parts)?;
        writer.flush()?;
    }
    Ok(())
}

/// What the Mac serves a projection's bytes from.
pub trait Source {
    /// `len` bytes of file `entry` at `offset` (fewer at its end). A file that changed since the
    /// manifest is re-listed and answered [`wire::RESTATED`] ([`Part::restated`]): its stat now,
    /// then the range as it is now.
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part;
    /// All of file `entry` (a batch asks only for small files), [`wire::RESTATED`] as for `read`.
    fn whole(&self, entry: u32) -> Part;
}

#[cfg(test)]
#[path = "link_tests.rs"]
mod tests;
