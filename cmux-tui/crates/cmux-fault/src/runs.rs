//! Seeded, repeatable runs of one scenario.
//!
//! - `CMUX_FAULT_RUNS` (default [`DEFAULT_RUNS`]): how many seeds a scenario runs.
//! - `CMUX_FAULT_SEED_BASE` (default 0): the first seed, so a sweep can run new seeds.
//! - `CMUX_FAULT_SEED`: run only this seed (a replay); its trace is printed even when it passes.
//! - `CMUX_FAULT_PARALLEL` (default: the cores, at most 8): runs at once. Scenarios on real time
//!   wait more than they compute, so their runs overlap.
//!
//! A failing run prints its seed, its fault trace and the command that replays it, and the
//! scenario fails naming every failing seed.

use std::sync::Mutex;
use std::time::Instant;

use crate::trace::Trace;

pub const DEFAULT_RUNS: u64 = 20;

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|value| value.trim().parse().ok())
}

pub struct Runs {
    name: &'static str,
    replay: String,
    runs: u64,
    parallel: usize,
}

/// One run's result: what broke, or nothing.
pub type Outcome = Result<(), String>;

impl Runs {
    /// `replay` is the command that runs this scenario alone (from `cmux-tui/`), for example
    /// `cargo test -p cmux-remote --test rc_faults ticket_expire`; the seed goes in front of it.
    pub fn new(name: &'static str, replay: impl Into<String>) -> Self {
        let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
        Self {
            name,
            replay: replay.into(),
            runs: env_u64("CMUX_FAULT_RUNS").unwrap_or(DEFAULT_RUNS),
            parallel: env_u64("CMUX_FAULT_PARALLEL").map_or(cores.min(8), |n| n as usize).max(1),
        }
    }

    /// At most this many runs at once (a scenario whose runs share a scarce resource).
    pub fn at_most_parallel(mut self, parallel: usize) -> Self {
        self.parallel = self.parallel.min(parallel.max(1));
        self
    }

    /// The seeds this invocation runs.
    pub fn seeds(&self) -> Vec<u64> {
        if let Some(seed) = env_u64("CMUX_FAULT_SEED") {
            return vec![seed];
        }
        let base = env_u64("CMUX_FAULT_SEED_BASE").unwrap_or(0);
        (base..base + self.runs).collect()
    }

    fn replay_command(&self, seed: u64) -> String {
        format!(
            "(cd cmux-tui && CMUX_FAULT_SEED={seed} {} -- --nocapture --include-ignored)",
            self.replay
        )
    }

    /// Runs `scenario` once per seed; `Err` names every seed that failed. A run that panics
    /// fails with its panic message; the rest still run.
    pub fn run<F>(&self, scenario: F) -> Result<(), Failed>
    where
        F: Fn(u64, &Trace) -> Outcome + Sync,
    {
        let seeds = self.seeds();
        let single = std::env::var_os("CMUX_FAULT_SEED").is_some();
        let started = Instant::now();
        let next = Mutex::new(seeds.iter().copied());
        let results: Mutex<Vec<(u64, Trace, Outcome)>> = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for _ in 0..self.parallel.min(seeds.len()) {
                scope.spawn(|| {
                    loop {
                        let Some(seed) = next.lock().unwrap_or_else(|e| e.into_inner()).next()
                        else {
                            return;
                        };
                        let trace = Trace::new();
                        let outcome =
                            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                scenario(seed, &trace)
                            }))
                            .unwrap_or_else(|panic| Err(panic_text(panic)));
                        results
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .push((seed, trace, outcome));
                    }
                });
            }
        });
        let mut results = results.into_inner().unwrap_or_else(|e| e.into_inner());
        results.sort_by_key(|(seed, _, _)| *seed);
        let failed: Vec<&(u64, Trace, Outcome)> =
            results.iter().filter(|(_, _, outcome)| outcome.is_err()).collect();
        eprintln!(
            "fault: {}: {} runs in {:.1} s ({} at once), {} failed",
            self.name,
            results.len(),
            started.elapsed().as_secs_f64(),
            self.parallel.min(seeds.len()),
            failed.len()
        );
        if single && let Some((seed, trace, Ok(()))) = results.first() {
            eprintln!("fault: {} seed {seed} held; its trace:\n{trace}", self.name);
        }
        for (seed, trace, outcome) in failed.iter().take(5) {
            if let Err(why) = outcome {
                eprintln!(
                    "fault: {} seed {seed} FAILED: {why}\n  fault trace:\n{trace}  replay: {}",
                    self.name,
                    self.replay_command(*seed)
                );
            }
        }
        match failed.first() {
            None => Ok(()),
            Some((first_seed, _, first)) => {
                let seeds: Vec<String> =
                    failed.iter().map(|(seed, _, _)| seed.to_string()).collect();
                Err(Failed(format!(
                    "{}: {} of {} runs failed (seeds {}); first: {}\nreplay: {}",
                    self.name,
                    failed.len(),
                    results.len(),
                    seeds.join(", "),
                    first.as_ref().err().cloned().unwrap_or_default(),
                    self.replay_command(*first_seed)
                )))
            }
        }
    }
}

/// A scenario whose runs failed: its seeds, the first failure and its replay. A `#[test]` that
/// returns it fails with that text as written (its `Debug` is the text, not a quoted string).
pub struct Failed(pub String);

impl std::fmt::Debug for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::fmt::Display for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

fn panic_text(panic: Box<dyn std::any::Any + Send>) -> String {
    match panic.downcast::<String>() {
        Ok(text) => format!("panicked: {text}"),
        Err(panic) => match panic.downcast::<&str>() {
            Ok(text) => format!("panicked: {text}"),
            Err(_) => "panicked".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::Runs;

    #[test]
    fn every_seed_runs_and_a_failure_names_its_seed() {
        let ran = std::sync::Mutex::new(Vec::new());
        let passed = Runs::new("all pass", "true").run(|seed, trace| {
            trace.note(format!("seed {seed}"));
            ran.lock().unwrap().push(seed);
            Ok(())
        });
        assert!(passed.is_ok());
        let mut ran = ran.into_inner().unwrap();
        ran.sort_unstable();
        assert_eq!(ran, Runs::new("all pass", "true").seeds());

        let failed = Runs::new("seed 3 fails", "true")
            .run(|seed, _| {
                if seed == 3 {
                    panic!("broke");
                }
                Ok(())
            })
            .unwrap_err()
            .0;
        assert!(failed.contains("(seeds 3)") && failed.contains("CMUX_FAULT_SEED=3"), "{failed}");
        assert!(failed.contains("panicked: broke"), "{failed}");
    }
}
