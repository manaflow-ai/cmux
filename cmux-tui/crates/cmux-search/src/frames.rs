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
        let lines: Vec<u64> = frame.lines().map(|line| hash(line.trim_end())).collect();
        if lines.iter().all(|&line| line == hash("")) {
            return false;
        }
        let keep = match self.last.get(terminal) {
            None => true,
            Some(previous) => {
                let longest = previous.len().max(lines.len());
                let changed =
                    (0..longest).filter(|&index| previous.get(index) != lines.get(index)).count();
                changed >= MIN_CHANGED_LINES
            }
        };
        if keep {
            self.last.insert(terminal.to_owned(), lines);
        }
        keep
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
