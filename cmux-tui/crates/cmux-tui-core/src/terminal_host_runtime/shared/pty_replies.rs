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
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, TryRecvError, channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::panic_free::RecoverPoison;

/// Answers queued for a program that does not read them. Past this the
/// program is not waiting for answers, so later ones are dropped rather
/// than grow without bound.
pub(crate) const MAX_QUEUED_REPLY_BYTES: usize = 1 << 20;

/// A writer thread with no answer to write for this long ends and hands its
/// PTY write back; the next answer starts a new one. Programs ask in bursts
/// (a shell's startup DA, a TUI's launch), so an idle terminal holds no
/// thread (goal infinite-items-flat: per-host threads cost stack and arena
/// pages in every one of a thousand hosts).
pub(crate) const REPLY_WRITER_IDLE: Duration = Duration::from_secs(10);

/// The writer thread's stack: it only copies answer bytes to the PTY.
const REPLY_WRITER_STACK_BYTES: usize = 256 * 1024;

/// Hands answers to the writer thread; the parser never blocks on the PTY.
pub(crate) struct PtyReplies {
    writer: Arc<Mutex<Writer>>,
    queued: Arc<AtomicUsize>,
    idle: Duration,
}

/// One batch of answer bytes written against the PTY input.
type WriteFn = Box<dyn Fn(&[u8]) + Send>;

/// Where answers go. Most programs never ask the terminal anything, so the
/// writer thread starts with the first answer, not with the host.
enum Writer {
    /// No answer yet (or the last thread retired idle): the PTY write the
    /// next thread will run.
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
        Self::start_with_idle(write, REPLY_WRITER_IDLE)
    }

    fn start_with_idle(write: impl Fn(&[u8]) + Send + 'static, idle: Duration) -> Self {
        Self {
            writer: Arc::new(Mutex::new(Writer::Idle(Box::new(write)))),
            queued: Arc::new(AtomicUsize::new(0)),
            idle,
        }
    }

    /// Queue `bytes` for the program. False when they were dropped: the
    /// queue is over [`MAX_QUEUED_REPLY_BYTES`] or the writer is gone.
    ///
    /// The queue is fed under the writer lock, the lock the idle thread
    /// retires under, so an answer never lands in a queue nobody reads.
    pub(crate) fn send(&self, bytes: Vec<u8>, inline: impl FnOnce(&[u8])) -> bool {
        if bytes.is_empty() {
            return true;
        }
        let mut writer = self.writer.lock().recover_poison();
        if matches!(*writer, Writer::Idle(_)) {
            self.spawn_writer(&mut writer);
        }
        let Writer::Running(sender) = &*writer else {
            drop(writer);
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

    /// Start the writer thread on `writer` (which holds `Idle`). Leaves
    /// `Running`, or `Inline` when no thread could start.
    fn spawn_writer(&self, writer: &mut Writer) {
        let Writer::Idle(write) = std::mem::replace(writer, Writer::Inline) else { return };
        let (sender, receiver) = channel::<Vec<u8>>();
        let slot = self.writer.clone();
        let queued = self.queued.clone();
        let idle = self.idle;
        let spawned = thread::Builder::new()
            .name("terminal-host-replies".into())
            .stack_size(REPLY_WRITER_STACK_BYTES)
            .spawn(move || run_writer(write, receiver, &slot, &queued, idle));
        match spawned {
            Ok(_) => *writer = Writer::Running(sender),
            Err(error) => {
                eprintln!(
                    "terminal-host: no thread for query answers; writing them inline: {error}"
                );
            }
        }
    }
}

/// The writer thread: writes queued answers until none came for `idle`,
/// then puts `write` back in `slot` and ends.
fn run_writer(
    write: WriteFn,
    receiver: Receiver<Vec<u8>>,
    slot: &Mutex<Writer>,
    queued: &AtomicUsize,
    idle: Duration,
) {
    let write_one = |bytes: Vec<u8>| {
        write(&bytes);
        queued.fetch_sub(bytes.len(), Ordering::AcqRel);
    };
    loop {
        match receiver.recv_timeout(idle) {
            Ok(bytes) => write_one(bytes),
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                let mut writer = slot.lock().recover_poison();
                match receiver.try_recv() {
                    // Queued in the meantime: write it (lock released) and
                    // wait again.
                    Ok(bytes) => {
                        drop(writer);
                        write_one(bytes);
                    }
                    Err(TryRecvError::Disconnected) => return,
                    Err(TryRecvError::Empty) => {
                        *writer = Writer::Idle(write);
                        return;
                    }
                }
            }
        }
    }
}

/// Writes `bytes` to the host's PTY input and flushes it.
pub(crate) fn write_to_pty(writer: &Mutex<Box<dyn std::io::Write + Send>>, bytes: &[u8]) {
    let mut writer = writer.lock().recover_poison();
    let _ = writer.write_all(bytes);
    let _ = writer.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;
    use std::time::Duration;

    #[test]
    fn the_writer_thread_starts_with_the_first_answer() {
        let (written, received) = channel::<(Vec<u8>, Option<String>)>();
        let replies = PtyReplies::start(move |bytes| {
            let name = thread::current().name().map(str::to_owned);
            let _ = written.send((bytes.to_vec(), name));
        });
        assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Idle(_)));

        // An empty answer is nothing to write and starts nothing.
        assert!(replies.send(Vec::new(), |_| panic!("an empty answer was written inline")));
        assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Idle(_)));

        for answer in [b"one".to_vec(), b"two".to_vec()] {
            assert!(replies.send(answer, |_| panic!("the answer was written inline")));
        }
        assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Running(_)));
        for expected in [b"one".to_vec(), b"two".to_vec()] {
            let (bytes, name) = received.recv_timeout(Duration::from_secs(10)).unwrap();
            assert_eq!(bytes, expected);
            assert_eq!(name.as_deref(), Some("terminal-host-replies"));
        }
    }

    #[test]
    fn an_idle_writer_thread_ends_and_the_next_answer_restarts_it() {
        let (written, received) = channel::<Vec<u8>>();
        let replies = PtyReplies::start_with_idle(
            move |bytes| {
                let _ = written.send(bytes.to_vec());
            },
            Duration::from_millis(20),
        );
        assert!(replies.send(b"one".to_vec(), |_| panic!("written inline")));
        assert_eq!(received.recv_timeout(Duration::from_secs(10)).unwrap(), b"one");
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !matches!(*replies.writer.lock().recover_poison(), Writer::Idle(_)) {
            assert!(std::time::Instant::now() < deadline, "the idle writer never retired");
            thread::sleep(Duration::from_millis(5));
        }
        for answer in [b"two".to_vec(), b"three".to_vec()] {
            assert!(replies.send(answer, |_| panic!("written inline")));
        }
        assert_eq!(received.recv_timeout(Duration::from_secs(10)).unwrap(), b"two");
        assert_eq!(received.recv_timeout(Duration::from_secs(10)).unwrap(), b"three");
        assert_eq!(replies.queued.load(Ordering::Acquire), 0);
    }
}
