//! The flight recorder: the newest [`RECENT_EVENTS`] hops of this process, kept in memory whether or
//! not `CMUX_TRACE_FLOWS` is set, so a panic or hang report can say what the process did in its last
//! moments ([`dump_recent`]). A game engine keeps the same ring of recent frames and dumps it on a
//! crash or a hitch.
//!
//! Every [`crate::hop`] and [`crate::hop_id`] lands here; [`crate::hop_on_traced`] (each output
//! transition of every terminal) does not, so busy terminals cannot wash the key-press hops out.
//!
//! A record holds the hop's static name, its flow id, the terminal's hex id, the thread id and the
//! clock: no terminal content, typed text, path or message can reach it.
//!
//! Cost: one `fetch_add` on the shared position, one compare-and-swap on the slot, a clock read and
//! ten relaxed stores; no allocation, no lock, no system call (the thread id is read once per
//! thread). Memory: [`RECENT_EVENTS`] slots of 128 bytes in a static, never more.
//!
//! The ring overwrites its oldest slot. Each slot is a seqlock: a writer claims it by moving its
//! sequence to an odd value with a compare-and-swap (a second writer that laps the ring onto the
//! same slot while the first still writes finds it odd and drops its record instead of mixing two),
//! and publishes it with `2 * position + 2`. A reader keeps a slot only when it reads that exact
//! sequence before and after copying it, so a torn or older record is skipped, never returned.
//! There is no lock to be held: [`dump_recent`] from a panic hook, on a thread that panicked in the
//! middle of a hop, skips the one slot that hop claimed and returns the rest.

use std::cell::Cell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering, fence};
use std::time::Duration;

/// Hops the flight recorder keeps; the oldest is overwritten. A power of two.
pub const RECENT_EVENTS: usize = 256;

#[repr(align(64))]
struct FlightSlot {
    /// 0: never written; odd: a writer is in it; `2 * position + 2`: the record of `position`.
    sequence: AtomicU64,
    name_ptr: AtomicUsize,
    name_len: AtomicUsize,
    flow: AtomicU64,
    terminal: [AtomicU64; 4],
    terminal_len: AtomicU64,
    tid: AtomicU64,
    t_ns: AtomicU64,
}

static SLOTS: [FlightSlot; RECENT_EVENTS] = [const {
    FlightSlot {
        sequence: AtomicU64::new(0),
        name_ptr: AtomicUsize::new(0),
        name_len: AtomicUsize::new(0),
        flow: AtomicU64::new(0),
        terminal: [const { AtomicU64::new(0) }; 4],
        terminal_len: AtomicU64::new(0),
        tid: AtomicU64::new(0),
        t_ns: AtomicU64::new(0),
    }
}; RECENT_EVENTS];

/// The position of the next record (records written so far, overwritten ones included).
static NEXT: AtomicU64 = AtomicU64::new(0);

thread_local! {
    /// The calling thread's id, read once (0: not read yet).
    static TID: Cell<u64> = const { Cell::new(0) };
}

/// One hop as [`dump_recent`] returns it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RecentEvent {
    pub name: &'static str,
    /// The key press's flow id, or 0.
    pub flow: u64,
    terminal: [u8; 32],
    terminal_len: u8,
    /// The system-wide id of the thread that recorded it (0 where the platform has none).
    pub tid: u64,
    /// How long before the dump it was recorded.
    pub age_ns: u64,
}

impl RecentEvent {
    /// An empty event, to fill a caller's buffer before [`dump_recent`].
    pub const EMPTY: Self =
        Self { name: "", flow: 0, terminal: [0; 32], terminal_len: 0, tid: 0, age_ns: 0 };

    /// The terminal's lowercase hex id, or "" for a hop on no terminal.
    pub fn terminal(&self) -> &str {
        let bytes = self.terminal.get(..usize::from(self.terminal_len)).unwrap_or_default();
        std::str::from_utf8(bytes).unwrap_or("")
    }

    /// Appends the event as one JSON object: `hop`, `flow`, `terminal`, `tid`, `ago_ms`. The name
    /// and id keep only `[0-9A-Za-z._-]`, so the object needs no escape.
    pub fn write_json(&self, out: &mut impl std::fmt::Write) -> std::fmt::Result {
        out.write_str("{\"hop\":\"")?;
        write_safe(out, self.name)?;
        write!(out, "\",\"flow\":{},\"terminal\":\"", self.flow)?;
        write_safe(out, self.terminal())?;
        write!(out, "\",\"tid\":{},\"ago_ms\":{:.3}}}", self.tid, self.age_ns as f64 / 1e6)
    }
}

fn write_safe(out: &mut impl std::fmt::Write, text: &str) -> std::fmt::Result {
    for c in text.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        out.write_char(c)?;
    }
    Ok(())
}

/// Appends `events` as a JSON array of [`RecentEvent::write_json`] objects.
pub fn write_json_array(
    out: &mut impl std::fmt::Write,
    events: &[RecentEvent],
) -> std::fmt::Result {
    out.write_char('[')?;
    for (index, event) in events.iter().enumerate() {
        if index > 0 {
            out.write_char(',')?;
        }
        event.write_json(out)?;
    }
    out.write_char(']')
}

/// Keeps one hop. `terminal` is at most 32 bytes (the caller cut it).
pub(crate) fn record(name: &'static str, flow: u64, terminal: &[u8], t_ns: u64) {
    let position = NEXT.fetch_add(1, Ordering::Relaxed);
    let Some(slot) = SLOTS.get(position as usize & (RECENT_EVENTS - 1)) else { return };
    let current = slot.sequence.load(Ordering::Relaxed);
    if current & 1 == 1
        || slot
            .sequence
            .compare_exchange(current, current | 1, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
    {
        return; // a writer a lap behind still holds this slot: drop this record rather than mix them
    }
    slot.name_ptr.store(name.as_ptr() as usize, Ordering::Relaxed);
    slot.name_len.store(name.len(), Ordering::Relaxed);
    slot.flow.store(flow, Ordering::Relaxed);
    let mut words = [0u64; 4];
    for (index, byte) in terminal.iter().take(32).enumerate() {
        if let Some(word) = words.get_mut(index / 8) {
            *word |= u64::from(*byte) << ((index % 8) * 8);
        }
    }
    for (into, word) in slot.terminal.iter().zip(words) {
        into.store(word, Ordering::Relaxed);
    }
    slot.terminal_len.store(terminal.len().min(32) as u64, Ordering::Relaxed);
    slot.tid.store(cached_thread_id(), Ordering::Relaxed);
    slot.t_ns.store(t_ns, Ordering::Relaxed);
    slot.sequence.store(position.wrapping_mul(2).wrapping_add(2), Ordering::Release);
}

fn cached_thread_id() -> u64 {
    TID.try_with(|cell| {
        let mut id = cell.get();
        if id == 0 {
            id = crate::thread_id();
            cell.set(id);
        }
        id
    })
    .unwrap_or(0)
}

/// Copies the newest hops into `out`, oldest first, and returns how many it wrote: at most
/// `out.len()` and [`RECENT_EVENTS`], and none older than `max_age` when given. No allocation, no
/// lock, no wait: a slot a writer is in (on another thread, or this one if it panicked mid-hop) is
/// skipped. Safe to call from a panic hook or a signal-free hang reporter on any thread.
pub fn dump_recent(out: &mut [RecentEvent], max_age: Option<Duration>) -> usize {
    let now = crate::now_ns();
    let max_age_ns =
        max_age.map_or(u64::MAX, |age| u64::try_from(age.as_nanos()).unwrap_or(u64::MAX));
    let end = NEXT.load(Ordering::Acquire);
    let want = out.len().min(RECENT_EVENTS) as u64;
    let mut written = 0;
    // Newest first, so a full `out` keeps the newest; reversed at the end.
    let mut position = end;
    while position > end.saturating_sub(RECENT_EVENTS as u64) && (written as u64) < want {
        position -= 1;
        let Some(event) = read(position, now) else { continue };
        if event.age_ns > max_age_ns {
            break;
        }
        if let Some(into) = out.get_mut(written) {
            *into = event;
            written += 1;
        }
    }
    if let Some(filled) = out.get_mut(..written) {
        filled.reverse();
    }
    written
}

/// The record of `position`, if its slot still holds it whole.
fn read(position: u64, now: u64) -> Option<RecentEvent> {
    let slot = SLOTS.get(position as usize & (RECENT_EVENTS - 1))?;
    let expected = position.wrapping_mul(2).wrapping_add(2);
    if slot.sequence.load(Ordering::Acquire) != expected {
        return None;
    }
    let name_ptr = slot.name_ptr.load(Ordering::Relaxed);
    let name_len = slot.name_len.load(Ordering::Relaxed);
    let flow = slot.flow.load(Ordering::Relaxed);
    let words: [u64; 4] = std::array::from_fn(|index| {
        slot.terminal.get(index).map_or(0, |word| word.load(Ordering::Relaxed))
    });
    let terminal_len = slot.terminal_len.load(Ordering::Relaxed).min(32) as u8;
    let tid = slot.tid.load(Ordering::Relaxed);
    let t_ns = slot.t_ns.load(Ordering::Relaxed);
    fence(Ordering::Acquire);
    if slot.sequence.load(Ordering::Relaxed) != expected {
        return None;
    }
    // SAFETY: the sequence was `expected` before and after the copy, and a writer moves it to odd
    // before its first store, so the pointer and length are the pair one `record` call stored from
    // one `&'static str`.
    let name = unsafe {
        std::str::from_utf8_unchecked(std::slice::from_raw_parts(name_ptr as *const u8, name_len))
    };
    let mut terminal = [0u8; 32];
    for (index, byte) in terminal.iter_mut().enumerate() {
        *byte = words.get(index / 8).map_or(0, |word| (word >> ((index % 8) * 8)) as u8);
    }
    Some(RecentEvent { name, flow, terminal, terminal_len, tid, age_ns: now.saturating_sub(t_ns) })
}

/// Marks the slot of the next position as mid-write, as a hop that stopped between its claim and its
/// publish (a panic mid-hop, a preempted thread) leaves it. Returns the position and the old sequence.
#[cfg(test)]
pub(crate) fn hold_next_slot() -> (u64, u64) {
    let position = NEXT.fetch_add(1, Ordering::Relaxed);
    let slot = &SLOTS[position as usize & (RECENT_EVENTS - 1)];
    let old = slot.sequence.load(Ordering::Relaxed);
    slot.sequence.store(old | 1, Ordering::Relaxed);
    (position, old)
}

/// The sequence of the slot of `position`, to release a slot [`hold_next_slot`] held.
#[cfg(test)]
pub(crate) fn sequence_for_test(position: u64) -> &'static AtomicU64 {
    &SLOTS[position as usize & (RECENT_EVENTS - 1)].sequence
}
