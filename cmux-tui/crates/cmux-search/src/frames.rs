//! Which full-screen (alt screen) frames are worth indexing: a frame is
//! kept when it differs from the terminal's last kept frame in at least
//! three lines, so a redrawing TUI (a spinner, a clock) adds nothing while
//! a new screen of content is indexed once.

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};

/// Lines that must change before a frame is indexed again.
const MIN_CHANGED_LINES: usize = 3;

/// The last kept frame per terminal.
#[derive(Default)]
pub struct ScreenFrames {
    last: HashMap<String, Vec<u64>>,
}

impl ScreenFrames {
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `frame` (the screen text of `terminal`) should be indexed;
    /// when it should, it becomes the terminal's last kept frame.
    pub fn offer(&mut self, terminal: &str, frame: &str) -> bool {
        // Red: dedupe is not written yet.
        let _ = (terminal, frame, &self.last, MIN_CHANGED_LINES, hash);
        false
    }

    /// Forgets `terminal` (closed).
    pub fn forget(&mut self, terminal: &str) {
        self.last.remove(terminal);
    }
}

fn hash(line: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    line.hash(&mut hasher);
    hasher.finish()
}
