//! Frame pacing, the same schedule as tuikit.py's Pacer: frame k is due at start + k / fps; a late
//! frame is drawn at once (never skipped: its index is the program frame the analyzer reads); more
//! than 0.25 s behind, the schedule restarts from now.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// One sleep to the due time (on a fleet mini such a sleep woke in bursts: p95 interval 47 ms).
    Sleep,
    /// Sleep to `spin_ms` before the due time, then poll the clock.
    Hybrid,
    /// Poll the clock to the due time (one core; holds 8.33 ms at 120 fps on a mini).
    Spin,
    /// macOS: a time-constraint (real-time) thread that waits with mach_wait_until, as audio and
    /// games pace frames (no timer coalescing, no spinning). The binaries set it up; the Pacer
    /// treats it as a sleep to the due time. Elsewhere: as Spin.
    Rt,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Mode> {
        match text {
            "sleep" => Some(Mode::Sleep),
            "hybrid" => Some(Mode::Hybrid),
            "spin" => Some(Mode::Spin),
            "rt" => Some(Mode::Rt),
            _ => None,
        }
    }
}

pub struct Pacer {
    period: f64,
    mode: Mode,
    spin: f64,
    start: f64,
    base: u64,
    /// How late the last frame already was before its wait (0 when it waited).
    pub before: f64,
}

impl Pacer {
    pub fn new(fps: f64, mode: Mode, spin_ms: f64, now: f64) -> Pacer {
        Pacer {
            period: if fps > 0.0 { 1.0 / fps } else { 0.0 },
            mode,
            spin: spin_ms / 1000.0,
            start: now,
            base: 0,
            before: 0.0,
        }
    }

    /// Waits for frame k; returns how late the frame starts after its wait (seconds).
    pub fn wait(
        &mut self,
        k: u64,
        clock: &mut dyn FnMut() -> f64,
        sleep: &mut dyn FnMut(f64),
    ) -> f64 {
        if self.period <= 0.0 {
            return 0.0;
        }
        let due = self.start + k.saturating_sub(self.base) as f64 * self.period;
        let now = clock();
        if now < due {
            self.before = 0.0;
            match self.mode {
                Mode::Sleep => sleep(due - now),
                Mode::Rt if cfg!(target_os = "macos") => sleep(due - now),
                Mode::Rt => {
                    while clock() < due {
                        std::hint::spin_loop();
                    }
                }
                Mode::Hybrid | Mode::Spin => {
                    if self.mode == Mode::Hybrid && due - now > self.spin {
                        sleep(due - now - self.spin);
                    }
                    while clock() < due {
                        std::hint::spin_loop();
                    }
                }
            }
            return (clock() - due).max(0.0);
        }
        let late = now - due;
        self.before = late;
        if late > 0.25 {
            self.start = now;
            self.base = k;
        }
        late
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    // Ignored in plain `cargo test` (cmux CI never builds this crate anyway): the fleet self-test
    // (scripts/measure/tui-kit-selftest.sh) runs them with `--ignored`.
    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn modes_on_a_fake_clock() {
        for (mode, sleeps, late) in [
            (Mode::Sleep, 1, 0.001),
            (Mode::Hybrid, 1, 0.0),
            (Mode::Spin, 0, 0.0),
        ] {
            let now = Cell::new(100.0_f64);
            let slept = Cell::new(0_u32);
            let mut clock = || {
                now.set(now.get() + 0.0001);
                now.get()
            };
            let mut pacer = Pacer::new(100.0, mode, 2.0, 100.0);
            let mut sleep = |s: f64| {
                slept.set(slept.get() + 1);
                now.set(now.get() + s + 0.001);
            };
            let got = pacer.wait(1, &mut clock, &mut sleep);
            assert_eq!(slept.get(), sleeps, "{mode:?}");
            assert!((got - late).abs() < 0.0003, "{mode:?}: {got}");
        }
    }

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn far_behind_restarts_the_schedule() {
        let mut clock = || 201.0_f64;
        let mut sleep = |_s: f64| {};
        let mut pacer = Pacer::new(100.0, Mode::Sleep, 2.0, 200.0);
        let late = pacer.wait(0, &mut clock, &mut sleep);
        assert!((late - 1.0).abs() < 1e-9);
        assert!((pacer.before - 1.0).abs() < 1e-9);
        assert_eq!(pacer.base, 0);
        assert!((pacer.start - 201.0).abs() < 1e-9);
    }
}
