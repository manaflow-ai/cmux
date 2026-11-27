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
    writer: Mutex<Writer>,
    queued: Arc<AtomicUsize>,
}

/// One batch of answer bytes written against the PTY input.
type WriteFn = Box<dyn Fn(&[u8]) + Send>;

/// Where answers go. Most programs never ask the terminal anything, so the
/// writer thread starts with the first answer, not with the host.
enum Writer {
    /// No answer yet: the PTY write the thread will run.
    Idle(WriteFn),
    /// The writer thread's queue.
    Running(Sender<Vec<u8>>),
    /// The thread could not start: answers are written inline.
    Inline,
}

impl PtyReplies {
    /// Arms the writer for `write`, which runs one batch of answer bytes
    /// against the PTY input (blocking while the program does not read).
    /// The thread (`terminal-host-replies`) starts with the first answer.
    pub(crate) fn start(write: impl Fn(&[u8]) + Send + 'static) -> Self {
        Self {
            writer: Mutex::new(Writer::Idle(Box::new(write))),
            queued: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// The writer thread's queue, starting the thread on the first answer.
    /// `None` when there is no thread: answers are written inline as before.
    fn sender(&self) -> Option<Sender<Vec<u8>>> {
        let mut writer = self.writer.lock().recover_poison();
        match std::mem::replace(&mut *writer, Writer::Inline) {
            Writer::Running(sender) => {
                *writer = Writer::Running(sender.clone());
                Some(sender)
            }
            Writer::Inline => None,
            Writer::Idle(write) => {
                let (sender, receiver) = channel::<Vec<u8>>();
                let worker_queued = self.queued.clone();
                let spawned =
                    thread::Builder::new().name("terminal-host-replies".into()).spawn(move || {
                        while let Ok(bytes) = receiver.recv() {
                            write(&bytes);
                            worker_queued.fetch_sub(bytes.len(), Ordering::AcqRel);
                        }
                    });
                match spawned {
                    Ok(_) => {
                        *writer = Writer::Running(sender.clone());
                        Some(sender)
                    }
                    Err(error) => {
                        eprintln!(
                            "terminal-host: no thread for query answers; writing them inline: {error}"
                        );
                        None
                    }
                }
            }
        }
    }

    /// Queue `bytes` for the program. False when they were dropped: the
    /// queue is over [`MAX_QUEUED_REPLY_BYTES`] or the writer is gone.
    pub(crate) fn send(&self, bytes: Vec<u8>, inline: impl FnOnce(&[u8])) -> bool {
        if bytes.is_empty() {
            return true;
        }
        let Some(sender) = self.sender() else {
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

#[cfg(test)]
#[path = "pty_replies_tests.rs"]
mod tests;
