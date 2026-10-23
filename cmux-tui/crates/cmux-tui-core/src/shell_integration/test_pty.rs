//! A shell on a pty for the shell-integration tests. Its output arrives on a
//! channel, and it gets the one terminal reply a shell may block on: fish 4
//! asks for the Primary Device Attributes (`CSI c`) at startup and waits up
//! to 10 s for the answer ("could not read response to Primary Device
//! Attribute query"), so a pty without a terminal behind it costs every fish
//! start 10 s. The reader thread answers each query the moment it arrives,
//! as Ghostty does.

use std::io::{Read, Write};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};

/// The Primary Device Attributes queries a shell sends.
const DA1_QUERIES: [&[u8]; 2] = [b"\x1b[c", b"\x1b[0c"];
/// A VT220-class answer with ANSI color, Ghostty's reply.
const DA1_REPLY: &[u8] = b"\x1b[?62;22c";
/// Bytes of one read kept for the next, so a query split across two reads
/// is still seen (one less than the longest query).
const CARRY: usize = 3;

/// A spawned shell, its output stream, and its input.
pub(super) struct TestPty {
    pub(super) spawned: cmux_pty::SpawnedPty,
    pub(super) received: Receiver<Vec<u8>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
}

impl TestPty {
    /// Opens a pty of `size`, spawns `command` on it and starts the reader.
    pub(super) fn spawn(size: cmux_pty::PtySize, command: cmux_pty::PtyCommand) -> Self {
        let spawned = cmux_pty::open(size).unwrap().spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let writer = Arc::new(Mutex::new(spawned.master.take_writer().unwrap()));
        let replies = Arc::clone(&writer);
        let (chunks, received) = channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            let mut window = Vec::new();
            // EOF, or EIO once the child side closes (Linux).
            while let Ok(n) = reader.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                let carried = window.len();
                window.extend_from_slice(&chunk[..n]);
                for _ in 0..da1_queries_ending_after(&window, carried) {
                    let mut writer =
                        replies.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    let _ = writer.write_all(DA1_REPLY).and_then(|()| writer.flush());
                }
                let answered = window.len().saturating_sub(CARRY);
                window.drain(..answered);
                if chunks.send(chunk[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self { spawned, received, writer }
    }

    /// Types `bytes` into the shell.
    pub(super) fn write(&self, bytes: &[u8]) {
        let mut writer = self.writer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        writer.write_all(bytes).unwrap();
        writer.flush().unwrap();
    }

    /// Types `bytes` and ignores a closed pty (for teardown).
    pub(super) fn write_quietly(&self, bytes: &[u8]) {
        let mut writer = self.writer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _ = writer.write_all(bytes).and_then(|()| writer.flush());
    }
}

/// The DA1 queries in `window` that end past its first `start` bytes (the
/// bytes carried from the previous read, already answered).
fn da1_queries_ending_after(window: &[u8], start: usize) -> usize {
    DA1_QUERIES
        .iter()
        .map(|query| {
            window
                .windows(query.len())
                .enumerate()
                .filter(|(at, bytes)| bytes == query && at + query.len() > start)
                .count()
        })
        .sum()
}

#[test]
fn a_da1_query_split_across_reads_is_answered_once() {
    // "\x1b[" ends one read, "c" starts the next.
    let first = b"prompt\x1b[".to_vec();
    assert_eq!(da1_queries_ending_after(&first, 0), 0);
    let carried = first[first.len() - CARRY..].to_vec();
    let mut window = carried.clone();
    window.extend_from_slice(b"c\x1b[0c");
    assert_eq!(da1_queries_ending_after(&window, carried.len()), 2);
    // A query wholly inside the carried bytes was answered with its read.
    assert_eq!(da1_queries_ending_after(b"\x1b[c", CARRY), 0);
}
