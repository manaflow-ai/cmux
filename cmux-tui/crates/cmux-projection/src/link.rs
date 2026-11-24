//! The machine's end of the stream to the Mac ([`crate::wire`]): a [`crate::Fetch`] whose asks go
//! to whichever stream the Mac attached last. The Mac opens the stream (the machine never dials
//! it) and opens a new one after a drop; until then an ask waits up to [`Link::away_wait`], then
//! fails as [`crate::FetchError::Away`]. Right after a stream drops, an ask waits longer, until
//! [`Link::drop_grace`] past the drop: a machine resumed from a pause gets its stream back only
//! once its carrier reconnects (a Cloud machine's median 8.4 s after the resume, at most 13.7 s
//! seen), and its agent's first reads land in that time.

use std::collections::HashMap;
use std::io::{BufReader, BufWriter, Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel, sync_channel};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::lower::Ext;
use crate::wire::{self, Ask, Part};
use crate::{Fetch, FetchError};

/// How long an ask waits for the Mac to come back by default (RFD 0007: a reconnect usually lands
/// inside it).
pub const AWAY_WAIT: Duration = Duration::from_secs(5);
/// How long after a stream drops an ask still waits for the next one, by default.
pub const DROP_GRACE: Duration = Duration::from_secs(20);
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
    /// The extension this stream's manifest is (the Mac's indices are the full manifest's), or
    /// `None` when the stream speaks the overlay's own ids.
    ext: Option<Arc<Ext>>,
}

#[derive(Default)]
struct State {
    attached: Option<Attached>,
    generation: u64,
    waiting: HashMap<u32, Waiter>,
    /// When the last stream dropped, while no new one has attached (not after a [`Link::detach`]).
    dropped: Option<Instant>,
}

/// The machine's end of the stream to the Mac.
pub struct Link {
    state: Mutex<State>,
    changed: Condvar,
    next: AtomicU32,
    away_wait: Duration,
    drop_grace: Duration,
}

impl Default for Link {
    fn default() -> Self {
        Self::new(AWAY_WAIT)
    }
}

impl Link {
    /// A link with no stream yet, whose asks wait `away_wait` for one ([`DROP_GRACE`] past a
    /// drop).
    #[must_use]
    pub fn new(away_wait: Duration) -> Self {
        Self {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            next: AtomicU32::new(1),
            away_wait,
            drop_grace: DROP_GRACE,
        }
    }

    /// The same link, whose asks wait until `drop_grace` past a stream's drop for the next one.
    #[must_use]
    pub fn with_drop_grace(mut self, drop_grace: Duration) -> Self {
        self.drop_grace = drop_grace;
        self
    }

    /// How long after a stream drops an ask still waits for the next one.
    #[must_use]
    pub fn drop_grace(&self) -> Duration {
        self.drop_grace
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
        self.serve_with(reader, writer, None);
    }

    /// [`Link::serve`] for a stream whose Mac holds the full manifest of `ext` (the overlay's ids
    /// are turned into its indices as each ask goes out, so an ask that fails over from an older
    /// stream is still the right file).
    pub fn serve_with(
        &self,
        reader: impl Read,
        writer: impl Write + Send + 'static,
        ext: Option<Arc<Ext>>,
    ) {
        let generation = {
            let mut state = self.lock();
            state.generation += 1;
            let generation = state.generation;
            state.dropped = None;
            state.attached = Some(Attached {
                generation,
                writer: Box::new(BufWriter::with_capacity(64 * 1024, writer)),
                ext,
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
            state.dropped = Some(Instant::now());
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
        state.dropped = None;
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
                let ask = match &attached.ext {
                    Some(ext) => make(number).remap(|id| ext.wire_of(id)),
                    None => make(number),
                };
                let sent = ask.write(&mut attached.writer).and_then(|()| attached.writer.flush());
                if sent.is_err() {
                    state.attached = None;
                    state.dropped = Some(Instant::now());
                    continue;
                }
                let (sender, receiver) = channel();
                state.waiting.insert(number, (generation, sender));
                return Ok(receiver);
            }
            // A stream that just dropped is likely back soon (a resumed machine's carrier).
            let deadline =
                state.dropped.map_or(deadline, |dropped| deadline.max(dropped + self.drop_grace));
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

/// How many asks the Mac answers at once (RFD 0065 piece 9). Served one at a time, 30,039 asks
/// took 308 s: the 16 FUSE workers on the machine each waited on the one before them on the Mac.
/// Answers go back as each is ready; asks are numbered, so the machine takes them in any order
/// ([`crate::wire`]). At most this many answers are held in memory at once.
pub const ANSWER_WORKERS: usize = 8;

/// The Mac's end: answers every ask read from `reader` with `source`, until the stream ends, up
/// to [`ANSWER_WORKERS`] at once.
pub fn answer_asks(
    reader: impl Read,
    writer: impl Write + Send,
    source: &(dyn Source + Sync),
) -> std::io::Result<()> {
    answer_asks_as(reader, writer, source, false)
}

/// [`answer_asks`] with packed answers ([`wire::write_packed_answer`]): only for a machine that
/// said it reads them.
pub fn answer_asks_packed(
    reader: impl Read,
    writer: impl Write + Send,
    source: &(dyn Source + Sync),
) -> std::io::Result<()> {
    answer_asks_as(reader, writer, source, true)
}

/// The parts that answer `ask`.
fn answer_of(source: &(dyn Source + Sync), ask: &Ask) -> Vec<Part> {
    match ask {
        Ask::Read { entry, offset, len, .. } => vec![source.read(*entry, *offset, *len)],
        Ask::Batch { entries, .. } => entries.iter().map(|entry| source.whole(*entry)).collect(),
        Ask::Ping { .. } => Vec::new(),
        Ask::Stored { since, .. } => source.stored(*since),
    }
}

/// Reads asks on this thread and answers them on [`ANSWER_WORKERS`] others, each answer written
/// whole under one lock as soon as it is ready. A failed write ends the stream: no further ask
/// is answered, and the read loop stops at its next ask.
fn answer_asks_as(
    reader: impl Read,
    writer: impl Write + Send,
    source: &(dyn Source + Sync),
    packed: bool,
) -> std::io::Result<()> {
    let mut reader = BufReader::with_capacity(64 * 1024, reader);
    let writer = Mutex::new(BufWriter::with_capacity(1024 * 1024, writer));
    let write_error: Mutex<Option<std::io::Error>> = Mutex::new(None);
    let failed = AtomicBool::new(false);
    let (asks, queue) = sync_channel::<Ask>(ANSWER_WORKERS);
    let queue = Mutex::new(queue);
    let read = std::thread::scope(|scope| {
        for _ in 0..ANSWER_WORKERS {
            scope.spawn(|| {
                loop {
                    let next = queue.lock().unwrap_or_else(PoisonError::into_inner).recv();
                    let Ok(ask) = next else { return };
                    if failed.load(Ordering::Relaxed) {
                        continue;
                    }
                    let parts = answer_of(source, &ask);
                    let mut out = writer.lock().unwrap_or_else(PoisonError::into_inner);
                    let written = if packed {
                        wire::write_packed_answer(&mut *out, ask.number(), &parts)
                    } else {
                        wire::write_answer(&mut *out, ask.number(), &parts)
                    }
                    .and_then(|()| out.flush());
                    if let Err(error) = written {
                        failed.store(true, Ordering::Relaxed);
                        write_error
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .get_or_insert(error);
                    }
                }
            });
        }
        let read = loop {
            if failed.load(Ordering::Relaxed) {
                break Ok(());
            }
            match Ask::read(&mut reader) {
                Ok(Some(ask)) => {
                    if asks.send(ask).is_err() {
                        break Ok(());
                    }
                }
                Ok(None) => break Ok(()),
                Err(error) => break Err(error),
            }
        };
        // The workers answer what was queued, then end.
        drop(asks);
        read
    });
    if let Some(error) = write_error.into_inner().unwrap_or_else(PoisonError::into_inner) {
        return Err(error);
    }
    read
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
