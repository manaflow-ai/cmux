//! The total RAM budget for terminal scrollback
//! (`terminal.scrollback.maxTotalMemoryBytes`, default 256 MiB).
//!
//! Each terminal's own cap is Ghostty's `scrollback-limit` (cmux adds no key
//! for it). Past the total, the terminals that printed least recently give
//! back scrollback first: their Ghostty scrollback limit is lowered, which
//! drops their oldest pages at once. When the total falls well under the
//! budget again, the most recently active terminals get their configured
//! limit back (history that was dropped does not return; full mode still has
//! it in its segment files).
//!
//! The pass runs on the output store's writer thread, after output (memory
//! only grows when a terminal prints), so an idle session runs nothing.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use super::{OutputStore, TerminalLog};
use crate::Mux;
use crate::resource::TerminalPublicId;

/// `cmux-next.json` key: total scrollback RAM across terminals in bytes.
pub(crate) const MEMORY_TOTAL_SETTING: &str = "terminal.scrollback.maxTotalMemoryBytes";
/// Process override of the budget (tests). Bytes.
pub(super) const MEMORY_TOTAL_ENV: &str = "CMUX_TUI_TERMINAL_SCROLLBACK_MEMORY_BYTES";
pub(crate) const DEFAULT_MEMORY_TOTAL_BYTES: u64 = 256 * 1024 * 1024;
const MIN_MEMORY_TOTAL_BYTES: u64 = 16 * 1024 * 1024;
/// The least scrollback a shrunk terminal keeps.
const MIN_TERMINAL_SCROLLBACK_BYTES: usize = 1024 * 1024;
/// Limits are given back only below this share of the budget (no flapping).
const RESTORE_BELOW_PERCENT: u64 = 80;

/// Limits this budget set, by terminal: (configured limit, applied limit).
#[derive(Default)]
pub(super) struct MemoryBudget {
    limited: Mutex<HashMap<TerminalPublicId, (usize, usize)>>,
}

impl MemoryBudget {
    pub(super) fn forget(&self, terminal_id: &TerminalPublicId) {
        self.limited.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
    }
}

/// One terminal's place in the pass.
struct Entry {
    terminal_id: TerminalPublicId,
    surface: Arc<crate::Surface>,
    resident: u64,
    last_output: Instant,
}

/// Keep the terminals' scrollback RAM under `budget` bytes.
pub(super) fn enforce(mux: &Mux, store: &OutputStore, budget: u64) {
    let budget = budget.max(MIN_MEMORY_TOTAL_BYTES);
    let logs: Vec<Arc<TerminalLog>> =
        store.logs.lock().unwrap_or_else(PoisonError::into_inner).values().cloned().collect();
    let mut entries = logs
        .into_iter()
        .filter_map(|log| {
            let surface = mux.terminal_resource_surface(&log.terminal_id)?;
            let resident = surface
                .try_with_terminal(|terminal| terminal.primary_resident_bytes())
                .ok()
                .flatten()?;
            let last_output = log.state.lock().unwrap_or_else(PoisonError::into_inner).last_output;
            Some(Entry { terminal_id: log.terminal_id.clone(), surface, resident, last_output })
        })
        .collect::<Vec<_>>();
    let mut total = entries.iter().map(|entry| entry.resident).sum::<u64>();
    // Ghostty's `scrollback-limit`, the per-terminal cap.
    let configured = mux.surface_options.lock().unwrap_or_else(PoisonError::into_inner).scrollback;
    let mut limited = store.memory_budget.limited.lock().unwrap_or_else(PoisonError::into_inner);
    if total > budget {
        // Least recently active first.
        entries.sort_by_key(|entry| entry.last_output);
        for entry in &entries {
            if total <= budget {
                break;
            }
            let excess = total - budget;
            let keep = usize::try_from(entry.resident.saturating_sub(excess))
                .unwrap_or(usize::MAX)
                .max(MIN_TERMINAL_SCROLLBACK_BYTES);
            let current =
                limited.get(&entry.terminal_id).map_or(configured, |(_, applied)| *applied);
            if keep >= current {
                continue;
            }
            let after = entry
                .surface
                .try_with_terminal(|terminal| {
                    terminal.set_scrollback_max_bytes(keep).ok()?;
                    terminal.primary_resident_bytes()
                })
                .ok()
                .flatten();
            let Some(after) = after else { continue };
            total = total.saturating_sub(entry.resident.saturating_sub(after));
            limited.insert(entry.terminal_id.clone(), (configured, keep));
        }
        if total > budget {
            eprintln!(
                "cmux-tui: terminal scrollback uses {total} bytes, over the {budget} byte budget \
                 after shrinking idle terminals"
            );
        }
        return;
    }
    if limited.is_empty() || total * 100 >= budget * RESTORE_BELOW_PERCENT {
        return;
    }
    // Room again: the most recently active terminals get their limit back
    // while the room lasts (a limit only bounds growth).
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.last_output));
    let mut room = budget * RESTORE_BELOW_PERCENT / 100 - total;
    for entry in &entries {
        let Some((configured, applied)) = limited.get(&entry.terminal_id).copied() else {
            continue;
        };
        let growth = u64::try_from(configured.saturating_sub(applied)).unwrap_or(u64::MAX);
        let restored =
            if growth <= room { configured } else { applied + usize::try_from(room).unwrap_or(0) };
        if entry
            .surface
            .try_with_terminal(|terminal| terminal.set_scrollback_max_bytes(restored).is_ok())
            .unwrap_or(false)
        {
            room = room.saturating_sub(
                u64::try_from(restored.saturating_sub(applied)).unwrap_or(u64::MAX),
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
}
