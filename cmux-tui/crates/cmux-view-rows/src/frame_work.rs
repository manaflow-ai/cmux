//! Per-frame work of a list view, and the contract that it is flat in the number of items: a
//! frame walks, clones and builds as many rows at 10,000 items as at 100, because only the rows
//! in view (and an overscan) are built. Test support: only a crate's dev-dependencies turn on
//! the `frame-work` feature, so no shipped build holds the counters.
//!
//! A list's draw code counts at its row-building points, under `#[cfg(test)]` in its own crate:
//! [`walked`] for each item it steps over (a filter, a group, a skipped row), [`cloned`] for each
//! item it copies, [`built`] for each row value it makes. The counts are per thread, so parallel
//! tests do not mix (a draw runs on its test's thread; a `#[tokio::test]` is current-thread).
//!
//! A test registers a list with [`contract`]: a fn that sets the list up at N items, draws a
//! warm-up frame, and returns the [`FrameWork`] of the next frame ([`measure`]). The contract
//! draws at N = 100 and N = 10,000. [`Expect::Flat`] fails when any count grows with N;
//! [`Expect::Grows`] records a list known to grow (a baseline) and fails once it is flat, so the
//! lane that fixes it flips the registration.

use std::cell::Cell;
use std::fmt;

/// What one frame did, in items.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct FrameWork {
    /// Items stepped over: filtered, grouped, positioned or skipped.
    pub walked: usize,
    /// Items copied (a clone of an item, or of an item's name).
    pub cloned: usize,
    /// Row values made (an entry, a row struct, a line).
    pub built: usize,
}

impl fmt::Display for FrameWork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "walked {} cloned {} built {}", self.walked, self.cloned, self.built)
    }
}

thread_local! {
    static WORK: Cell<FrameWork> = const { Cell::new(FrameWork { walked: 0, cloned: 0, built: 0 }) };
}

fn add(f: impl FnOnce(&mut FrameWork)) {
    WORK.with(|w| {
        let mut now = w.get();
        f(&mut now);
        w.set(now);
    });
}

/// `n` items stepped over.
pub fn walked(n: usize) {
    add(|w| w.walked = w.walked.saturating_add(n));
}

/// `n` items copied.
pub fn cloned(n: usize) {
    add(|w| w.cloned = w.cloned.saturating_add(n));
}

/// `n` row values made.
pub fn built(n: usize) {
    add(|w| w.built = w.built.saturating_add(n));
}

/// The work `frame` does on this thread.
pub fn measure(frame: impl FnOnce()) -> FrameWork {
    WORK.with(|w| w.set(FrameWork::default()));
    frame();
    WORK.with(|w| w.replace(FrameWork::default()))
}

/// What a registered list is known to do.
#[derive(Debug, Clone, Copy)]
pub enum Expect {
    /// Its per-frame work is flat in N.
    Flat,
    /// A baseline: its work grows with N today. The text says where it is fixed; the contract
    /// fails once the list is flat, so the fixer flips it to [`Expect::Flat`].
    Grows(&'static str),
}

/// The sizes the contract draws at.
pub const SMALL: usize = 100;
pub const LARGE: usize = 10_000;

/// A list's work at [`SMALL`] and [`LARGE`] items.
#[derive(Debug, Clone, Copy)]
pub struct Report {
    pub name: &'static str,
    pub small: FrameWork,
    pub large: FrameWork,
}

impl Report {
    /// Every count at [`LARGE`] is at most its count at [`SMALL`].
    pub fn flat(&self) -> bool {
        self.large.walked <= self.small.walked
            && self.large.cloned <= self.small.cloned
            && self.large.built <= self.small.built
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: N={SMALL}: {}; N={LARGE}: {}", self.name, self.small, self.large)
    }
}

/// Draws the list `name` at [`SMALL`] and [`LARGE`] items (`frame_at(n)` sets it up, draws a
/// warm-up frame, and returns the next frame's [`measure`]) and holds it to `expect`. Err says
/// what broke; the report is printed either way, for the PR's numbers.
pub fn contract(
    name: &'static str,
    expect: Expect,
    mut frame_at: impl FnMut(usize) -> FrameWork,
) -> Result<Report, String> {
    let report = Report { name, small: frame_at(SMALL), large: frame_at(LARGE) };
    eprintln!("frame work: {report}");
    match (expect, report.flat()) {
        (Expect::Flat, true) | (Expect::Grows(_), false) => Ok(report),
        (Expect::Flat, false) => Err(format!(
            "{report}: per-frame work grows with N. Draw only the rows in view: skip/take over \
             the visible range, and keep the model between frames instead of rebuilding it"
        )),
        (Expect::Grows(baseline), true) => Err(format!(
            "{report}: flat now; flip its registration to Expect::Flat (baseline: {baseline})"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn work(n: usize, all: bool) -> FrameWork {
        measure(|| {
            walked(if all { n } else { n.min(40) });
            built(n.min(40));
        })
    }

    #[test]
    fn a_flat_list_passes_and_a_growing_one_is_named() {
        assert!(contract("visible", Expect::Flat, |n| work(n, false)).is_ok());
        let err = contract("whole", Expect::Flat, |n| work(n, true)).unwrap_err();
        assert!(err.contains("walked 10000"), "{err}");
    }

    #[test]
    fn a_baseline_fails_once_its_list_is_flat() {
        assert!(contract("whole", Expect::Grows("lane x"), |n| work(n, true)).is_ok());
        let err = contract("fixed", Expect::Grows("lane x"), |n| work(n, false)).unwrap_err();
        assert!(err.contains("flip"), "{err}");
    }

    #[test]
    fn measure_counts_only_its_frame() {
        cloned(5);
        assert_eq!(measure(|| cloned(2)), FrameWork { cloned: 2, ..FrameWork::default() });
    }
}
