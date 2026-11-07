//! A child's stderr cut into lines as it writes them (`ProcessRunner`'s
//! `stderrLine`): bytes in, whole lines out; a line longer than the bound is
//! cut there. The app reads the child's file and hands the bytes over.

/// Longest line kept (progress lines are short).
pub const MAX_LINE: usize = 64 * 1024;

#[derive(Debug, Default)]
pub struct Lines {
    pending: Vec<u8>,
    done: bool,
}

impl Lines {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds bytes and returns every line they complete (lossy UTF-8).
    pub fn push(&mut self, bytes: &[u8]) -> Vec<String> {
        if self.done {
            return Vec::new();
        }
        let mut lines = Vec::new();
        for &byte in bytes {
            if byte == b'\n' {
                lines.push(String::from_utf8_lossy(&self.pending).into_owned());
                self.pending.clear();
            } else if self.pending.len() < MAX_LINE {
                self.pending.push(byte);
            }
        }
        lines
    }

    /// The child exited: the last line with no newline, if any. Nothing is
    /// taken after it.
    pub fn finish(&mut self) -> Vec<String> {
        if self.done {
            return Vec::new();
        }
        self.done = true;
        let last = std::mem::take(&mut self.pending);
        if last.is_empty() { Vec::new() } else { vec![String::from_utf8_lossy(&last).into_owned()] }
    }
}
