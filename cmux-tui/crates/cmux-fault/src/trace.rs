//! The fault trace of one run: each fault the harness injected and each step the scenario noted,
//! with the time since the run started. A failing run prints it beside its seed.

use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Cheap to clone: every part of a run (the proxy, the mint, the scenario) notes into one trace.
#[derive(Clone)]
pub struct Trace {
    started: Instant,
    lines: Arc<Mutex<Vec<String>>>,
}

impl Default for Trace {
    fn default() -> Self {
        Self::new()
    }
}

impl Trace {
    pub fn new() -> Self {
        Self { started: Instant::now(), lines: Arc::default() }
    }

    /// Notes one line, stamped with the milliseconds since the run started.
    pub fn note(&self, line: impl fmt::Display) {
        let at = self.started.elapsed().as_millis();
        self.lines.lock().unwrap_or_else(|e| e.into_inner()).push(format!("{at:>7} ms  {line}"));
    }

    pub fn lines(&self) -> Vec<String> {
        self.lines.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl fmt::Display for Trace {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for line in self.lines() {
            writeln!(f, "  {line}")?;
        }
        Ok(())
    }
}
