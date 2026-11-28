//! Per-phase timing of one connect, for measuring where a cold `cmux remote exec` spends its
//! time (gap 10 in cmuxterm-hq `docs/remote-agent-gaps.md`). Off unless
//! `CMUX_REMOTE_TIMINGS=1`; then each [`mark`] prints one `cmux-remote-timing PHASE +MS` line to
//! stderr, MS counted from the first mark in the process. Nothing else changes.

use std::sync::OnceLock;
use std::time::Instant;

/// The environment variable that turns the marks on.
pub const TIMINGS_ENV: &str = "CMUX_REMOTE_TIMINGS";

fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os(TIMINGS_ENV).is_some_and(|value| value == "1"))
}

fn origin() -> Instant {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    *ORIGIN.get_or_init(Instant::now)
}

/// The line [`mark`] prints for `phase` at `millis`.
pub fn line(phase: &str, millis: f64) -> String {
    format!("cmux-remote-timing {phase} +{millis:.1}ms")
}

/// Marks `phase` as reached now, when timings are on.
pub fn mark(phase: &str) {
    if !enabled() {
        return;
    }
    let millis = origin().elapsed().as_secs_f64() * 1000.0;
    eprintln!("{}", line(phase, millis));
}

/// [`mark`] with `detail` (computed only when timings are on) after the offset.
pub fn mark_with(phase: &str, detail: impl FnOnce() -> String) {
    if !enabled() {
        return;
    }
    let millis = origin().elapsed().as_secs_f64() * 1000.0;
    eprintln!("{} {}", line(phase, millis), detail());
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_mark_line_names_its_phase_and_offset() {
        assert_eq!(super::line("pipe-open", 12.345), "cmux-remote-timing pipe-open +12.3ms");
    }
}
