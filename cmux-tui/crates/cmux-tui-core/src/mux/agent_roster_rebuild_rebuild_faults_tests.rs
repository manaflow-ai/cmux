use std::collections::BTreeMap;
use std::sync::{Mutex, PoisonError};

#[derive(Default)]
struct Faults {
    held: bool,
    failing_reads: u32,
    failing_replay_reads: u32,
    failing_reconcile_reads: u32,
    failing_report_echoes: u32,
}

static FAULTS: Mutex<BTreeMap<String, Faults>> = Mutex::new(BTreeMap::new());

fn with<T>(session: &str, edit: impl FnOnce(&mut Faults) -> T) -> T {
    let mut faults = FAULTS.lock().unwrap_or_else(PoisonError::into_inner);
    edit(faults.entry(session.to_owned()).or_default())
}

pub(in crate::mux) fn hold(session: &str, held: bool) {
    with(session, |faults| faults.held = held);
}

pub(in crate::mux) fn fail_reads(session: &str, reads: u32) {
    with(session, |faults| faults.failing_reads = reads);
}

pub(super) fn held(session: &str) -> bool {
    with(session, |faults| faults.held)
}

/// The start's background replay fails its next `reads` slices.
pub(in crate::mux) fn fail_replay_reads(session: &str, reads: u32) {
    with(session, |faults| faults.failing_replay_reads = reads);
}

pub(in crate::mux) fn take_failing_replay_read(session: &str) -> bool {
    with(session, |faults| {
        let failing = faults.failing_replay_reads > 0;
        faults.failing_replay_reads = faults.failing_replay_reads.saturating_sub(1);
        failing
    })
}

/// The reconcile a background replay owes fails its next `reads` checks.
pub(in crate::mux) fn fail_reconcile_reads(session: &str, reads: u32) {
    with(session, |faults| faults.failing_reconcile_reads = reads);
}

pub(in crate::mux) fn take_failing_reconcile_read(session: &str) -> bool {
    with(session, |faults| {
        let failing = faults.failing_reconcile_reads > 0;
        faults.failing_reconcile_reads = faults.failing_reconcile_reads.saturating_sub(1);
        failing
    })
}

/// The next `echoes` direct agent reports' journal echoes are not written.
pub(in crate::mux) fn fail_report_echoes(session: &str, echoes: u32) {
    with(session, |faults| faults.failing_report_echoes = echoes);
}

pub(in crate::mux) fn report_echo_failures_left(session: &str) -> u32 {
    with(session, |faults| faults.failing_report_echoes)
}

pub(in crate::mux) fn take_failing_report_echo(session: &str) -> bool {
    with(session, |faults| {
        let failing = faults.failing_report_echoes > 0;
        faults.failing_report_echoes = faults.failing_report_echoes.saturating_sub(1);
        failing
    })
}

pub(super) fn take_failing_read(session: &str) -> bool {
    with(session, |faults| {
        let failing = faults.failing_reads > 0;
        faults.failing_reads = faults.failing_reads.saturating_sub(1);
        failing
    })
}
