//! `projfs.upper`'s answer: the helper's one JSON line, read within a time bound and kept within
//! a size bound ([`super::Mounter::upper`]).
//!
//! The line is read on a thread of its own, at most [`MAX_UPPER_BYTES`] kept. Past that bound the
//! rest is read only to count the changes it holds (objects outside strings, never stored), and
//! the request is refused `projfs.too_many_changes` with that count: the Mac learns how far over
//! it is and pulls nothing, never half a list.

use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

use cmux_process::Child;
use serde_json::Value;

use super::{end, end_later, failed, helper_answer, timed_out};
use crate::projfs_rendezvous::Refusal;

/// How long the helper's `upper` may take (a walk of the upper layer only, never the lower).
pub const UPPER_WAIT: Duration = Duration::from_secs(30);
/// The longest `upper` line answered: 12 MiB, as `fs.write`'s largest part, so the answer stays
/// under the daemon's 16 MiB line limit (`REMOTE_CLIENT_MESSAGE_MAX_BYTES`) with room for the
/// envelope. At about 100 bytes a change that is some 125,000 changes.
pub const MAX_UPPER_BYTES: usize = 12 << 20;
/// Bytes read from the helper at a time.
const READ_PART: usize = 64 * 1024;

/// What the reader thread saw of the helper's output.
struct Seen {
    /// The line's first bytes, at most the bound plus one.
    kept: Vec<u8>,
    /// Every byte of the line (up to its newline or the end of the output).
    total: usize,
    /// Objects opened outside strings in the whole line.
    objects: u64,
}

/// Counts `{` outside JSON strings across parts of one line.
#[derive(Default)]
struct Objects {
    in_string: bool,
    escaped: bool,
    count: u64,
}

impl Objects {
    fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes {
            if self.in_string {
                match (self.escaped, b) {
                    (true, _) => self.escaped = false,
                    (false, b'\\') => self.escaped = true,
                    (false, b'"') => self.in_string = false,
                    _ => {}
                }
            } else if b == b'"' {
                self.in_string = true;
            } else if b == b'{' {
                self.count = self.count.saturating_add(1);
            }
        }
    }
}

/// Reads `source` up to its first newline (or its end), keeping at most `max + 1` bytes.
fn read_line(mut source: impl std::io::Read, max: usize) -> std::io::Result<Seen> {
    let mut kept = Vec::new();
    let mut objects = Objects::default();
    let mut total = 0usize;
    let mut part = vec![0u8; READ_PART];
    loop {
        let n = source.read(&mut part)?;
        let Some(read) = part.get(..n).filter(|read| !read.is_empty()) else { break };
        let line =
            read.iter().position(|b| *b == b'\n').map_or(read, |at| read.get(..at).unwrap_or(read));
        objects.feed(line);
        total = total.saturating_add(line.len());
        let room = max.saturating_add(1).saturating_sub(kept.len());
        kept.extend(line.iter().take(room));
        if line.len() < read.len() {
            break;
        }
    }
    Ok(Seen { kept, total, objects: objects.count })
}

/// The helper's `upper` answer from `child`, within `wait` and `max` bytes.
pub(super) fn answer(mut child: Child, wait: Duration, max: usize) -> Result<Value, Refusal> {
    let Some(stdout) = child.stdout.take() else {
        end(&mut child);
        return Err(failed("the upper layer's reader has no output"));
    };
    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::Builder::new().name("projfs-upper-line".into()).spawn(move || {
        let _ = sender.send(read_line(stdout, max));
    });
    if reader.is_err() {
        end(&mut child);
        return Err(failed("cannot read the upper layer's answer"));
    }
    let read = match receiver.recv_timeout(wait) {
        Ok(Ok(read)) => read,
        Ok(Err(_)) | Err(RecvTimeoutError::Disconnected) => {
            let status = end(&mut child);
            return Err(failed(format!("the upper layer's reader failed ({status})")));
        }
        Err(RecvTimeoutError::Timeout) => {
            end(&mut child);
            return Err(timed_out("upper", wait));
        }
    };
    end_later(child);
    if read.total > max {
        // The outer object is one; every other is a change.
        let changes = read.objects.saturating_sub(1);
        return Err(Refusal {
            code: "projfs.too_many_changes",
            message: format!(
                "the machine changed {changes} paths in this folder, more than one answer carries \
                 ({} bytes of {max}); nothing was answered",
                read.total
            ),
        });
    }
    let text = String::from_utf8_lossy(&read.kept);
    if text.trim().is_empty() {
        return Err(failed("the upper layer's reader exited without an answer"));
    }
    helper_answer(&text).ok_or_else(|| failed("the upper layer's reader printed something else"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn objects_inside_strings_are_not_counted() {
        let mut objects = Objects::default();
        let line =
            br#"{"ok":true,"changes":[{"kind":"file","path":"a{b"},{"kind":"dir","path":"q\"{"}]}"#;
        let (left, right) = line.split_at(30);
        objects.feed(left);
        objects.feed(right);
        assert_eq!(objects.count, 3);
    }

    #[test]
    fn a_line_is_read_to_its_newline_and_kept_within_the_bound() {
        let read = read_line(&b"{\"a\":1}\nmore"[..], 100).unwrap();
        assert_eq!(read.kept, b"{\"a\":1}");
        assert_eq!(read.total, 7);
        let long = format!("{}\n", "{}".repeat(100_000));
        let read = read_line(long.as_bytes(), 10).unwrap();
        assert_eq!(read.kept.len(), 11);
        assert_eq!(read.total, 200_000);
        assert_eq!(read.objects, 100_000);
    }
}
