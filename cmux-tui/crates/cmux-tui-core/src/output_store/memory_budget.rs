//! The total RAM budget for terminal scrollback
//! (`terminal.scrollback.maxTotalMemoryBytes`; its default is the daemon
//! budget's `scrollback_total`, sized from installed RAM: 256 MiB at 16 GB,
//! see `cmux_memory::budget`).
//!
//! Each terminal's own cap is Ghostty's `scrollback-limit` (cmux adds no key
//! for it). Past the total, the terminals that printed least recently give
//! back scrollback first: their Ghostty scrollback limit is lowered, which
//! drops their oldest pages at once. When the total falls well under the
//! budget again, the most recently active terminals get their configured
//! limit back (history that was dropped does not return; full mode still has
//! it in its segment files, the cold store).
//!
//! The budget is a consumer in the daemon's memory registry
//! (`crate::memory`, Chrome's `base/memory_coordinator` consumer with a
//! memory limit, `memory_consumer.h`): at warning the total is half the
//! budget, at critical the [`MIN_MEMORY_TOTAL_BYTES`] floor; limits come back
//! only at normal and only below [`RESTORE_BELOW_PERCENT`] of the budget.
//! Each terminal keeps at least [`MIN_TERMINAL_SCROLLBACK_BYTES`], so many
//! terminals can stay over the floor; the log says so once per level and
//! total, not on every pass.
//!
//! Every pass runs on the output store's writer thread: after output (memory
//! only grows when a terminal prints) and once per pressure level change (the
//! registry's callback only records the level and wakes the writer). An idle
//! session runs nothing, and there is no thread or timer of its own.
//!
//! A cold terminal (mux/cold_scrollback.rs) counts with its compressed size
//! and its limit is left alone: changing it would restore the terminal.
//!
//! The default from RAM and the pressure response are behind the default-off
//! daemon feature [`FEATURE`]
//! (schemas/features/features.d/memoryScrollbackPressure.json). With it off
//! the default is the 16 GB row (256 MiB) on every machine and the budget
//! does not register, as before.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Instant;

use cmux_memory::{DaemonBudget, MemoryConsumer, PressureLevel, Registration, Retention};

use super::snapshot::WriterWaker;
use super::{OutputStore, TerminalLog};
use crate::Mux;
use crate::memory::DaemonMemory;
use crate::resource::TerminalPublicId;
use crate::surface::ScrollbackMemory;

/// `cmux-next.json` key: total scrollback RAM across terminals in bytes.
pub(crate) const MEMORY_TOTAL_SETTING: &str = "terminal.scrollback.maxTotalMemoryBytes";
/// Process override of the budget (tests). Bytes.
pub(super) const MEMORY_TOTAL_ENV: &str = "CMUX_TUI_TERMINAL_SCROLLBACK_MEMORY_BYTES";
/// The smallest total, and the total under critical pressure.
const MIN_MEMORY_TOTAL_BYTES: u64 = 16 * 1024 * 1024;
/// The least scrollback a shrunk terminal keeps.
const MIN_TERMINAL_SCROLLBACK_BYTES: usize = 1024 * 1024;
/// Limits are given back only below this share of the budget (no flapping).
const RESTORE_BELOW_PERCENT: u64 = 80;
/// The registry name of the budget's consumer.
const CONSUMER_NAME: &str = "terminal.scrollback";
/// The registry name of the feature that sizes the total from RAM and lets
/// memory pressure lower it.
pub(crate) const FEATURE: &str = "memoryScrollbackPressure";

/// Limits this budget set, by terminal: (configured limit, applied limit).
type Limited = HashMap<TerminalPublicId, (usize, usize)>;

/// The budget's state in the output store.
#[derive(Default)]
pub(super) struct MemoryBudget {
    passes: Mutex<PassState>,
    pressure: Arc<PressureInbox>,
    /// The consumer in the owner's memory registry, set at store start.
    registration: OnceLock<Registration>,
    /// [`FEATURE`] is on.
    from_ram: bool,
    /// This machine's budget, its RAM read once, on the first default
    /// with [`FEATURE`] on.
    host: OnceLock<DaemonBudget>,
    /// Passes [`enforce`] ran (tests).
    #[cfg(test)]
    enforced: std::sync::atomic::AtomicUsize,
}

/// What one pass leaves for the next.
#[derive(Default)]
struct PassState {
    limited: Limited,
    /// The level and applied total the last over-budget line named, `None`
    /// once a pass is under the total again.
    reported_over: Option<(PressureLevel, u64)>,
}

impl PassState {
    /// Whether this pass logs that `over` bytes stay above `applied` at
    /// `level`: only when that differs from the last line. At critical
    /// pressure every terminal at its minimum can stay over the floor for
    /// as long as the pressure lasts; that is said once, not every pass.
    fn report_over(&mut self, level: PressureLevel, applied: u64, over: Option<u64>) -> bool {
        let reported = over.map(|_| (level, applied));
        let changed = reported.is_some() && reported != self.reported_over;
        self.reported_over = reported;
        changed
    }
}

/// What the registry's callback leaves for the writer: the level and
/// whether a pass for it is still due. Atomics only, so the pressure
/// source's thread never waits on the writer.
#[derive(Default)]
struct PressureInbox {
    level: AtomicU8,
    pass_due: AtomicBool,
}

impl PressureInbox {
    fn record(&self, level: PressureLevel) {
        self.level.store(level_code(level), Ordering::Release);
        self.pass_due.store(true, Ordering::Release);
    }

    fn level(&self) -> PressureLevel {
        match self.level.load(Ordering::Acquire) {
            0 => PressureLevel::Normal,
            1 => PressureLevel::Warning,
            _ => PressureLevel::Critical,
        }
    }
}

fn level_code(level: PressureLevel) -> u8 {
    match level {
        PressureLevel::Normal => 0,
        PressureLevel::Warning => 1,
        PressureLevel::Critical => 2,
    }
}

impl MemoryBudget {
    /// `from_ram`: [`FEATURE`] is on (the owner reads it once at start,
    /// `crate::memory::MemorySetup`).
    pub(super) fn with_feature(from_ram: bool) -> Self {
        Self { from_ram, ..Self::default() }
    }

    /// The total when no setting names one: with [`FEATURE`] on the
    /// budget's `scrollback_total` for this machine's RAM, else the fixed
    /// 16 GB row.
    pub(super) fn default_total(&self, budget: &DaemonBudget) -> u64 {
        if self.from_ram {
            budget.scrollback_total
        } else {
            DaemonBudget::default().scrollback_total
        }
    }

    /// [`Self::default_total`] for this machine; the RAM is read only with
    /// [`FEATURE`] on, and once.
    pub(super) fn host_default_total(&self) -> u64 {
        if self.from_ram {
            self.default_total(self.host.get_or_init(DaemonBudget::for_host))
        } else {
            self.default_total(&DaemonBudget::default())
        }
    }

    pub(super) fn forget(&self, terminal_id: &TerminalPublicId) {
        self.passes.lock().unwrap_or_else(PoisonError::into_inner).limited.remove(terminal_id);
    }

    /// Registers the budget in `memory` once, with [`FEATURE`] on; returns
    /// whether it is registered. A level change records the level and wakes
    /// `writer` for one pass; the pass itself runs on the writer thread.
    /// Releasing drops history the person may scroll back to (full mode keeps
    /// it on disk), so the consumer is lossy and hears the level after the
    /// lossless ones.
    pub(super) fn register(&self, memory: &DaemonMemory, writer: WriterWaker) -> bool {
        if !self.from_ram {
            return false;
        }
        self.registration.get_or_init(|| {
            let pressure = self.pressure.clone();
            let consumer = MemoryConsumer::new(
                CONSUMER_NAME,
                Retention::Lossy,
                // Resident bytes are measured by the pass, under each
                // terminal's lock; the report does not take them.
                || None,
                move |level| {
                    pressure.record(level);
                    writer.wake_now();
                },
            );
            memory.registry().register(consumer)
        });
        true
    }

    /// The level the last pressure callback recorded.
    pub(super) fn level(&self) -> PressureLevel {
        self.pressure.level()
    }

    /// True once after each level change: the writer runs a pass even when
    /// no terminal printed.
    pub(super) fn take_pressure_pass(&self) -> bool {
        self.pressure.pass_due.swap(false, Ordering::AcqRel)
    }
}

/// The total the pass enforces at `level` for a budget of `budget` bytes,
/// and whether limits may be given back.
fn applied_total(budget: u64, level: PressureLevel) -> (u64, bool) {
    let budget = budget.max(MIN_MEMORY_TOTAL_BYTES);
    match level {
        PressureLevel::Normal => (budget, true),
        PressureLevel::Warning => ((budget / 2).max(MIN_MEMORY_TOTAL_BYTES), false),
        PressureLevel::Critical => (MIN_MEMORY_TOTAL_BYTES, false),
    }
}

/// One terminal's scrollback limit, as the pass changes it.
trait ScrollbackLimit {
    /// Lowers the limit to `bytes`; the bytes resident after, or `None` when
    /// the terminal could not be changed or measured.
    fn shrink(&self, bytes: usize) -> Option<u64>;
    /// Raises the limit to `bytes`; whether it was applied.
    fn restore(&self, bytes: usize) -> bool;
}

/// A live terminal's Ghostty scrollback.
struct SurfaceScrollback(Arc<crate::Surface>);

impl ScrollbackLimit for SurfaceScrollback {
    fn shrink(&self, bytes: usize) -> Option<u64> {
        self.0
            .try_with_terminal(|terminal| {
                terminal.set_scrollback_max_bytes(bytes).ok()?;
                terminal.primary_resident_bytes()
            })
            .ok()
            .flatten()
    }

    fn restore(&self, bytes: usize) -> bool {
        self.0
            .try_with_terminal(|terminal| terminal.set_scrollback_max_bytes(bytes).is_ok())
            .unwrap_or(false)
    }
}

/// One terminal's place in the pass.
struct Entry<S> {
    terminal_id: TerminalPublicId,
    scrollback: S,
    resident: u64,
    cold: bool,
    last_output: Instant,
}

/// Keep the terminals' scrollback RAM under `budget` bytes, or under the
/// lower total the current pressure level sets.
pub(super) fn enforce(mux: &Mux, store: &OutputStore, budget: u64) {
    let logs: Vec<Arc<TerminalLog>> =
        store.logs.lock().unwrap_or_else(PoisonError::into_inner).values().cloned().collect();
    let mut entries = logs
        .into_iter()
        .filter_map(|log| {
            let surface = mux.terminal_resource_surface(&log.terminal_id)?;
            let (resident, cold) = match surface.scrollback_memory()? {
                ScrollbackMemory::Hot(bytes) => (bytes, false),
                ScrollbackMemory::Cold(bytes) => (bytes, true),
            };
            let last_output = log.state.lock().unwrap_or_else(PoisonError::into_inner).last_output;
            Some(Entry {
                terminal_id: log.terminal_id.clone(),
                scrollback: SurfaceScrollback(surface),
                resident,
                cold,
                last_output,
            })
        })
        .collect::<Vec<_>>();
    // Ghostty's `scrollback-limit`, the per-terminal cap.
    let configured = mux.surface_options.lock().unwrap_or_else(PoisonError::into_inner).scrollback;
    let level = store.memory_budget.level();
    #[cfg(test)]
    store.memory_budget.enforced.fetch_add(1, Ordering::Relaxed);
    let mut passes = store.memory_budget.passes.lock().unwrap_or_else(PoisonError::into_inner);
    let over = apply(&mut entries, configured, budget, level, &mut passes.limited);
    let (applied, _) = applied_total(budget, level);
    let report = passes.report_over(level, applied, over);
    if let Some(over) = over.filter(|_| report) {
        eprintln!(
            "cmux-tui: terminal scrollback uses {over} bytes, over the {applied} byte budget \
             ({level:?} memory pressure) after shrinking idle terminals"
        );
    }
}

/// One pass over `entries`: over the applied total, lower limits of the
/// least recently active terminals first; at normal pressure and below
/// [`RESTORE_BELOW_PERCENT`] of `budget`, give the most recently active ones
/// their `configured` limit back. Returns the resident total when it is
/// still over the applied total.
fn apply<S: ScrollbackLimit>(
    entries: &mut [Entry<S>],
    configured: usize,
    budget: u64,
    level: PressureLevel,
    limited: &mut Limited,
) -> Option<u64> {
    let (applied, may_restore) = applied_total(budget, level);
    let mut total = entries.iter().map(|entry| entry.resident).sum::<u64>();
    if total > applied {
        // Least recently active first.
        entries.sort_by_key(|entry| entry.last_output);
        for entry in entries.iter().filter(|entry| !entry.cold) {
            if total <= applied {
                break;
            }
            let excess = total - applied;
            let keep = usize::try_from(entry.resident.saturating_sub(excess))
                .unwrap_or(usize::MAX)
                .max(MIN_TERMINAL_SCROLLBACK_BYTES);
            let current =
                limited.get(&entry.terminal_id).map_or(configured, |(_, applied)| *applied);
            if keep >= current {
                continue;
            }
            let Some(after) = entry.scrollback.shrink(keep) else { continue };
            total = total.saturating_sub(entry.resident.saturating_sub(after));
            limited.insert(entry.terminal_id.clone(), (configured, keep));
        }
        return (total > applied).then_some(total);
    }
    let restore_below = applied * RESTORE_BELOW_PERCENT / 100;
    if !may_restore || limited.is_empty() || total >= restore_below {
        return None;
    }
    // Room again: the most recently active terminals get their limit back
    // while the room lasts (a limit only bounds growth).
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.last_output));
    let mut room = restore_below - total;
    for entry in entries.iter().filter(|entry| !entry.cold) {
        let Some((configured, current)) = limited.get(&entry.terminal_id).copied() else {
            continue;
        };
        let growth = u64::try_from(configured.saturating_sub(current)).unwrap_or(u64::MAX);
        let restored =
            if growth <= room { configured } else { current + usize::try_from(room).unwrap_or(0) };
        if entry.scrollback.restore(restored) {
            room = room.saturating_sub(
                u64::try_from(restored.saturating_sub(current)).unwrap_or(u64::MAX),
            );
            if restored == configured {
                limited.remove(&entry.terminal_id);
            } else {
                limited.insert(entry.terminal_id.clone(), (configured, restored));
            }
        }
        if room == 0 {
            break;
        }
    }
    None
}

#[cfg(test)]
#[path = "tests/memory_budget_pressure.rs"]
mod pressure_tests;
