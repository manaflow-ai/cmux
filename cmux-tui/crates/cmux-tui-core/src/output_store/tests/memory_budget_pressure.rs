//! The scrollback budget under memory pressure: the total
//! from installed RAM, the registered consumer, and the pass at each level.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use cmux_memory::{DaemonBudget, PressureLevel, Retention};

use super::super::PersistencePolicy;
use super::super::snapshot::Writer;
use super::{CONSUMER_NAME, Entry, Limited, MemoryBudget, PassState, ScrollbackLimit, apply};
use crate::memory::DaemonMemory;
use crate::resource::TerminalPublicId;

const MIB: u64 = 1 << 20;
const BUDGET: u64 = 64 * MIB;
/// Each terminal's configured (Ghostty) scrollback limit.
const CONFIGURED: usize = 20 << 20;

/// What the pass did, in order: (terminal, new limit).
type Calls = Rc<RefCell<Vec<(usize, usize)>>>;

/// A terminal whose scrollback shrinks to its new limit at once.
struct Fake {
    index: usize,
    resident: Cell<u64>,
    shrinks: Calls,
    restores: Calls,
}

impl ScrollbackLimit for Fake {
    fn shrink(&self, bytes: usize) -> Option<u64> {
        self.shrinks.borrow_mut().push((self.index, bytes));
        self.resident.set(self.resident.get().min(bytes as u64));
        Some(self.resident.get())
    }

    fn restore(&self, bytes: usize) -> bool {
        self.restores.borrow_mut().push((self.index, bytes));
        true
    }
}

fn id(index: usize) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{:032x}", index + 1)).unwrap()
}

struct Pass {
    entries: Vec<Entry<Fake>>,
    limited: Limited,
    shrinks: Calls,
    restores: Calls,
}

impl Pass {
    /// Terminals 0, 1, 2, ... with these resident bytes; terminal 0 printed
    /// least recently.
    fn new(resident: &[u64]) -> Self {
        let base = Instant::now();
        let shrinks = Calls::default();
        let restores = Calls::default();
        let entries = resident
            .iter()
            .enumerate()
            .map(|(index, &bytes)| Entry {
                terminal_id: id(index),
                scrollback: Fake {
                    index,
                    resident: Cell::new(bytes),
                    shrinks: shrinks.clone(),
                    restores: restores.clone(),
                },
                resident: bytes,
                cold: false,
                last_output: base + Duration::from_secs(index as u64),
            })
            .collect();
        Self { entries, limited: Limited::new(), shrinks, restores }
    }

    fn run(&mut self, level: PressureLevel) -> Option<u64> {
        apply(&mut self.entries, CONFIGURED, BUDGET, level, &mut self.limited)
    }

    /// The next pass sees what this one left resident.
    fn settle(&mut self, resident: &[u64]) {
        self.shrinks.borrow_mut().clear();
        self.restores.borrow_mut().clear();
        for entry in &mut self.entries {
            let bytes = resident[entry.scrollback.index];
            entry.resident = bytes;
            entry.scrollback.resident.set(bytes);
        }
    }
}

#[test]
fn memory_budget_total_defaults_from_installed_ram() {
    let on = MemoryBudget::with_feature(true);
    let off = MemoryBudget::with_feature(false);
    for (installed, total) in
        [(8u64 << 30, 128 * MIB), (16 << 30, 256 * MIB), (64 << 30, 1024 * MIB)]
    {
        let budget = DaemonBudget::for_memory(installed);
        assert_eq!(on.default_total(&budget), total, "{installed} bytes installed");
        // Off: the fixed 256 MiB default of before, whatever the RAM.
        assert_eq!(off.default_total(&budget), 256 * MIB, "{installed} bytes installed");
        for mode in [None, Some("memory"), Some("full")] {
            let policy = PersistencePolicy::resolve(mode, None, None, on.default_total(&budget));
            assert_eq!(policy.memory_total_bytes, total, "{mode:?}");
        }
    }
}

#[test]
fn memory_budget_off_never_registers() {
    let memory = DaemonMemory::without_system_source();
    let writer = Writer::default();
    assert!(!MemoryBudget::with_feature(false).register(&memory, writer.waker()));
    assert!(memory.registry().report().is_empty());
}

/// The real wiring: `OutputStore::start` registers the budget in the Mux's
/// registry, beside the standby host, and a level change with no output
/// runs one budget pass on the writer's path.
#[cfg(unix)]
#[test]
fn memory_budget_store_start_registers_and_a_level_change_runs_a_pass() {
    use std::sync::Arc;
    use std::sync::atomic::Ordering;

    let root = std::env::temp_dir()
        .join(format!("cmux-scrollback-pressure-{}", crate::workspace_registry::new_uuid_v4()));
    let memory = Arc::new(DaemonMemory::without_system_source());
    let setup = crate::memory::MemorySetup {
        memory: memory.clone(),
        scrollback_pressure: true,
        kitty_share: false,
    };
    let mux = crate::Mux::open_persistent_with_memory_for_test(
        "scrollback-pressure",
        crate::SurfaceOptions::default(),
        &root,
        setup,
    )
    .unwrap();
    assert!(Arc::ptr_eq(&mux.memory, &memory));
    let mut names: Vec<_> =
        mux.memory.registry().report().into_iter().map(|line| line.name).collect();
    names.sort_unstable();
    assert_eq!(names, [CONSUMER_NAME, "terminal.standby-host"]);

    let store = &mux.output_store;
    let enforced = || store.memory_budget.enforced.load(Ordering::Relaxed);
    // Idle at normal: a pass with no output runs no budget pass.
    super::super::snapshot::write_pass(&mux, store);
    assert_eq!(enforced(), 0);

    // No terminal printed. The level change woke the writer; this pass
    // either runs the budget pass or waits for the writer's (the pass lock).
    let voter = memory.registry().voter();
    voter.set_level(PressureLevel::Warning);
    assert_eq!(store.memory_budget.level(), PressureLevel::Warning);
    super::super::snapshot::write_pass(&mux, store);
    assert_eq!(enforced(), 1, "one budget pass per level change");
    super::super::snapshot::write_pass(&mux, store);
    assert_eq!(enforced(), 1, "the same level asks for nothing more");

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn memory_budget_registers_a_lossy_consumer_that_wakes_the_writer() {
    let memory = DaemonMemory::without_system_source();
    let writer = Writer::default();
    let budget = MemoryBudget::with_feature(true);
    assert!(budget.register(&memory, writer.waker()));
    budget.register(&memory, writer.waker());
    let report = memory.registry().report();
    assert_eq!(report.len(), 1, "registers once");
    assert_eq!(report[0].name, CONSUMER_NAME);
    assert_eq!(report[0].retention, Retention::Lossy);
    assert_eq!(budget.level(), PressureLevel::Normal);
    assert!(!budget.take_pressure_pass());
    assert!(writer.due().is_none(), "registering at normal wakes nothing");

    let voter = memory.registry().voter();
    voter.set_level(PressureLevel::Warning);
    assert_eq!(budget.level(), PressureLevel::Warning);
    assert!(writer.due().is_some_and(|due| due <= Instant::now()), "a pass is due now");
    assert!(budget.take_pressure_pass());
    assert!(!budget.take_pressure_pass(), "one pass per level change");

    voter.set_level(PressureLevel::Warning);
    assert!(!budget.take_pressure_pass(), "a repeated level asks for nothing");
    voter.set_level(PressureLevel::Critical);
    assert_eq!(budget.level(), PressureLevel::Critical);
    assert!(budget.take_pressure_pass());
    voter.set_level(PressureLevel::Normal);
    assert_eq!(budget.level(), PressureLevel::Normal);
    assert!(budget.take_pressure_pass());
}

#[test]
fn memory_budget_registered_under_pressure_hears_the_level_at_once() {
    let memory = DaemonMemory::without_system_source();
    let voter = memory.registry().voter();
    voter.set_level(PressureLevel::Critical);
    let writer = Writer::default();
    let budget = MemoryBudget::with_feature(true);
    assert!(budget.register(&memory, writer.waker()));
    assert_eq!(budget.level(), PressureLevel::Critical);
    assert!(budget.take_pressure_pass());
    assert!(writer.due().is_some());
}

#[test]
fn memory_budget_normal_under_the_total_changes_nothing() {
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    assert_eq!(pass.run(PressureLevel::Normal), None);
    assert!(pass.shrinks.borrow().is_empty());
    assert!(pass.limited.is_empty());
}

#[test]
fn memory_budget_warning_halves_the_total_least_recent_first() {
    // 36 MiB resident, under the 64 MiB budget but over its 32 MiB half.
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    assert_eq!(pass.run(PressureLevel::Warning), None);
    assert_eq!(*pass.shrinks.borrow(), [(0, (8 * MIB) as usize)], "only the least recent");
    assert_eq!(pass.limited.get(&id(0)), Some(&(CONFIGURED, (8 * MIB) as usize)));
    assert_eq!(pass.limited.len(), 1);
    assert!(pass.restores.borrow().is_empty());
}

#[test]
fn memory_budget_critical_goes_to_the_floor_least_recent_first() {
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    assert_eq!(pass.run(PressureLevel::Critical), None);
    // 36 -> 16 MiB: terminal 0 to the 1 MiB terminal minimum (25 left),
    // then terminal 1 gives the last 9 MiB; the most recent keeps all.
    assert_eq!(*pass.shrinks.borrow(), [(0, MIB as usize), (1, (3 * MIB) as usize)]);
    assert!(!pass.limited.contains_key(&id(2)));
}

#[test]
fn memory_budget_reports_what_stays_over_the_floor() {
    // Every terminal already at the 1 MiB minimum keeps it: 20 MiB stays.
    let mut pass = Pass::new(&[MIB; 20]);
    assert_eq!(pass.run(PressureLevel::Critical), Some(20 * MIB));
}

#[test]
fn memory_budget_logs_staying_over_once_per_level() {
    // 20 terminals at the 1 MiB minimum stay over the 16 MiB critical floor.
    let mut pass = Pass::new(&[MIB; 20]);
    let mut state = PassState::default();
    let (critical, _) = super::applied_total(BUDGET, PressureLevel::Critical);
    let over = pass.run(PressureLevel::Critical);
    assert!(state.report_over(PressureLevel::Critical, critical, over), "the first pass logs");
    let over = pass.run(PressureLevel::Critical);
    assert_eq!(over, Some(20 * MIB));
    assert!(!state.report_over(PressureLevel::Critical, critical, over), "the next does not");
    // Under the warning total: nothing to log, and the next stretch over logs again.
    let (warning, _) = super::applied_total(BUDGET, PressureLevel::Warning);
    let over = pass.run(PressureLevel::Warning);
    assert!(!state.report_over(PressureLevel::Warning, warning, over));
    let over = pass.run(PressureLevel::Critical);
    assert!(state.report_over(PressureLevel::Critical, critical, over));
    // Over at a new level or total logs at once.
    assert!(state.report_over(PressureLevel::Warning, warning, Some(40 * MIB)));
    assert!(state.report_over(PressureLevel::Warning, warning / 2, Some(40 * MIB)));
}

#[test]
fn memory_budget_pressure_never_gives_limits_back() {
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    pass.run(PressureLevel::Warning);
    // Far under the halved total, but still at warning.
    pass.settle(&[MIB, MIB, MIB]);
    pass.run(PressureLevel::Warning);
    assert!(pass.restores.borrow().is_empty());
    assert_eq!(pass.limited.len(), 1);
}

#[test]
fn memory_budget_normal_restores_only_under_80_percent() {
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    pass.run(PressureLevel::Warning);
    // Back at normal at 85 % of the budget: under it, but no restore.
    pass.settle(&[8 * MIB, 23 * MIB, 23 * MIB]);
    assert_eq!(pass.run(PressureLevel::Normal), None);
    assert!(pass.restores.borrow().is_empty());
    assert_eq!(pass.limited.len(), 1);
    // At 50 %: the configured limit comes back.
    pass.settle(&[8 * MIB, 12 * MIB, 12 * MIB]);
    pass.run(PressureLevel::Normal);
    assert_eq!(*pass.restores.borrow(), [(0, CONFIGURED)]);
    assert!(pass.limited.is_empty());
}

#[test]
fn memory_budget_normal_restores_most_recent_first_while_room_lasts() {
    let mut pass = Pass::new(&[12 * MIB, 12 * MIB, 12 * MIB]);
    pass.run(PressureLevel::Critical);
    assert_eq!(pass.limited.len(), 2);
    // 80 % of 64 MiB is 51.2 MiB; 45 MiB resident leaves 6.2 MiB of room,
    // all for terminal 1 (more recent than terminal 0).
    pass.settle(&[MIB, 3 * MIB, 41 * MIB]);
    pass.run(PressureLevel::Normal);
    let room = (BUDGET * 80 / 100 - 45 * MIB) as usize;
    assert_eq!(*pass.restores.borrow(), [(1, (3 * MIB) as usize + room)]);
    assert_eq!(pass.limited.get(&id(0)), Some(&(CONFIGURED, MIB as usize)));
    assert_eq!(pass.limited.get(&id(1)), Some(&(CONFIGURED, (3 * MIB) as usize + room)));
}

#[test]
fn memory_budget_applied_total_by_level() {
    use super::{MIN_MEMORY_TOTAL_BYTES, applied_total};
    assert_eq!(applied_total(BUDGET, PressureLevel::Normal), (BUDGET, true));
    assert_eq!(applied_total(BUDGET, PressureLevel::Warning), (BUDGET / 2, false));
    assert_eq!(applied_total(BUDGET, PressureLevel::Critical), (MIN_MEMORY_TOTAL_BYTES, false));
    // Never under the floor, whatever the setting says.
    assert_eq!(applied_total(MIB, PressureLevel::Normal), (MIN_MEMORY_TOTAL_BYTES, true));
    assert_eq!(applied_total(20 * MIB, PressureLevel::Warning), (MIN_MEMORY_TOTAL_BYTES, false));
}
