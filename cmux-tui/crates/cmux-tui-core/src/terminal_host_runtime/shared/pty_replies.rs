//! The terminal's answers to queries (DA, XTWINOPS, clipboard reads),
//! written to the PTY input on their own thread, never on the parser's.
//!
//! The parser must keep applying output: the PTY reader waits on its budget
//! and every resize waits on its answer while holding the source order. A
//! program that stops reading its input (ssh blocked writing its own
//! output) fills that input, so a blocking write on the parser thread
//! deadlocked the host: the parser waited on the program, the program on
//! the PTY reader, the reader on the parser. The shell lived on behind a
//! terminal the daemon could never adopt again.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::panic_free::RecoverPoison;

/// Answers queued for a program that does not read them. Past this the
/// program is not waiting for answers, so later ones are dropped rather
/// than grow without bound.
pub(crate) const MAX_QUEUED_REPLY_BYTES: usize = 1 << 20;

/// Hands answers to the writer thread; the parser never blocks on the PTY.
pub(crate) struct PtyReplies {
    sender: Option<Sender<Vec<u8>>>,
    queued: Arc<AtomicUsize>,
}

impl PtyReplies {
    /// Starts the writer thread for `write`, which runs one batch of answer
    /// bytes against the PTY input (blocking while the program does not
    /// read). Without a thread, answers are written inline as before.
    pub(crate) fn start(write: impl Fn(&[u8]) + Send + 'static) -> Self {
        let (sender, receiver) = channel::<Vec<u8>>();
        let queued = Arc::new(AtomicUsize::new(0));
        let worker_queued = queued.clone();
        let spawned =
            thread::Builder::new().name("terminal-host-replies".into()).spawn(move || {
                while let Ok(bytes) = receiver.recv() {
                    write(&bytes);
                    worker_queued.fetch_sub(bytes.len(), Ordering::AcqRel);
                }
            });
        match spawned {
            Ok(_) => Self { sender: Some(sender), queued },
            Err(error) => {
                eprintln!(
                    "terminal-host: no thread for query answers; writing them inline: {error}"
                );
                Self { sender: None, queued }
            }
        }
    }

    /// Queue `bytes` for the program. False when they were dropped: the
    /// queue is over [`MAX_QUEUED_REPLY_BYTES`] or the writer is gone.
    pub(crate) fn send(&self, bytes: Vec<u8>, inline: impl FnOnce(&[u8])) -> bool {
        if bytes.is_empty() {
            return true;
        }
        let Some(sender) = &self.sender else {
            inline(&bytes);
            return true;
        };
        let len = bytes.len();
        let admitted = self
            .queued
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |queued| {
                (queued.saturating_add(len) <= MAX_QUEUED_REPLY_BYTES).then_some(queued + len)
            })
            .is_ok();
        if !admitted {
            return false;
        }
        if sender.send(bytes).is_err() {
            self.queued.fetch_sub(len, Ordering::AcqRel);
            return false;
        }
        true
    }
}

/// Writes `bytes` to the host's PTY input and flushes it.
pub(crate) fn write_to_pty(writer: &Mutex<Box<dyn std::io::Write + Send>>, bytes: &[u8]) {
    let mut writer = writer.lock().recover_poison();
    let _ = writer.write_all(bytes);
    let _ = writer.flush();
}
