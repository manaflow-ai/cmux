//! The reader of a local terminal's output: bytes -> terminal state ->
//! events, one chunk at a time under the parser lock (`local_output`).
//!
//! A direct PTY reads on its owner's one read loop (`TerminalReads`),
//! not on a thread of its own: its descriptor's readiness queues a run, and
//! a resize that drained the readiness kicks one. A holder or byte-backend
//! terminal has no PTY descriptor in this process and keeps its blocking
//! `surface-<id>-reader` thread, which follows the terminal's class
//! (`surface/thread_qos.rs`); the shared read loop does not.

use std::io::Read;
#[cfg(unix)]
use std::os::fd::{AsRawFd, RawFd};
use std::time::Duration;

use super::local_output::{LocalOutput, OutputPublisher};
use super::*;
#[cfg(unix)]
use crate::mux::terminal_work::read_loop::{READS_PER_RUN, ReadFlow, ReadSource, TerminalReads};

/// One local terminal's reader, on the read loop or on its thread.
pub(super) struct LocalReader {
    surface: Arc<Surface>,
    output: Arc<Mutex<LocalOutput>>,
    reader: Box<dyn Read + Send>,
    publisher: OutputPublisher,
    /// The PTY descriptor the parser owns (`LocalOutput::descriptor`);
    /// `None` for a holder or byte-backend terminal.
    #[cfg(unix)]
    fd: Option<RawFd>,
    /// Dropped last, after the end is published (or on a panic).
    _completion: ReaderCompletionGuard,
}

/// What one read did.
enum Step {
    /// Parsed a chunk (or was interrupted): read again.
    Read,
    /// Nothing to read now.
    Idle,
    /// End of stream or a read error.
    Ended,
}

impl LocalReader {
    pub(super) fn new(
        surface: Arc<Surface>,
        output: Arc<Mutex<LocalOutput>>,
        reader: Box<dyn Read + Send>,
        reader_completion: Arc<ReaderCompletion>,
    ) -> Self {
        // The caller hands over its runtime's completion, so the reader
        // needs no `as_pty` lookup that could fail.
        let completion = ReaderCompletionGuard(reader_completion);
        let parser = output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let publisher = parser.publisher();
        #[cfg(unix)]
        let fd = parser.descriptor.as_ref().map(AsRawFd::as_raw_fd);
        drop(parser);
        Self {
            surface,
            output,
            reader,
            publisher,
            #[cfg(unix)]
            fd,
            _completion: completion,
        }
    }

    /// Starts reading: a direct PTY on its owner's read loop (with no owner,
    /// on a loop of its own that ends with this terminal), anything else on
    /// thread `surface-<id>-reader`.
    pub(super) fn start(self, id: SurfaceId) -> anyhow::Result<TerminalReader> {
        #[cfg(unix)]
        if let Some(fd) = self.fd {
            let output = self.output.clone();
            let owner = self.surface.as_pty().and_then(|pty| pty.mux.upgrade());
            let registered = match owner {
                Some(mux) => mux.terminal_reads().register(fd, Box::new(self)),
                // Dropped at once: its loop ends after this terminal's end.
                None => TerminalReads::new().register(fd, Box::new(self)),
            };
            let Ok(kick) = registered else {
                anyhow::bail!("terminal {id}'s output cannot be watched on the read loop");
            };
            // One run after the wake is in place: it publishes what a resize
            // drained before the parser had a wake to kick.
            output.lock().unwrap_or_else(std::sync::PoisonError::into_inner).wake =
                Some(kick.clone());
            kick.kick();
            return Ok(TerminalReader::Looped);
        }
        // Its own thread follows the terminal's class (surface/thread_qos.rs).
        let thread_qos = match self.surface.as_pty() {
            Some(pty) => pty.thread_qos.clone(),
            None => cmux_threads::DesiredQos::new(crate::echo_thread::ECHO_PATH_QOS),
        };
        let thread = crate::echo_thread::spawn_following(
            format!("surface-{id}-reader"),
            thread_qos,
            move || self.run_blocking(),
        )?;
        Ok(TerminalReader::Thread(thread))
    }

    fn step(&mut self) -> Step {
        let Some(pty) = self.surface.as_pty() else { return Step::Ended };
        // A direct PTY reads only what is there: with nothing, the run still
        // takes the parser once to publish what a resize drained.
        #[cfg(unix)]
        let ready = self.fd.map_or(Ok(true), |fd| local_output::readable(fd, 0));
        #[cfg(not(unix))]
        let ready = std::io::Result::Ok(true);
        #[cfg(all(test, unix))]
        if matches!(ready, Ok(true)) {
            pty.run_geometry_test_hook(PtyGeometryTestStep::LocalReaderReady);
        }
        let (result, events) = {
            let mut output = self.output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            // A resize may have drained the readiness that queued this read.
            // Recheck under the parser lock, then parse on that same boundary.
            #[cfg(unix)]
            let ready = match (ready, self.fd) {
                (Ok(true), Some(fd)) => local_output::readable(fd, 0),
                (ready, _) => ready,
            };
            let reader = &mut self.reader;
            let result = match ready {
                Ok(true) => output.read(pty, |buf| reader.read(buf)).map(Some),
                Ok(false) => Ok(None),
                Err(error) => Err(error),
            };
            (result, output.take_pending())
        };
        self.publisher.publish(&self.surface, events);
        match result {
            Ok(Some(0)) => Step::Ended,
            Ok(Some(_)) => Step::Read,
            Ok(None) => Step::Idle,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => Step::Read,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Step::Idle,
            Err(_) => Step::Ended,
        }
    }

    /// The thread body of a reader with no PTY descriptor: its reads block.
    fn run_blocking(mut self) {
        let mut would_block =
            crate::backoff::Backoff::new(Duration::from_millis(1), Duration::from_millis(50));
        loop {
            // The class a view change asked for, applied after each wake.
            cmux_threads::apply_pending_qos();
            match self.step() {
                Step::Read => would_block.reset(),
                // No parser or source lock is held across backoff.
                Step::Idle => would_block.sleep(),
                Step::Ended => break,
            }
        }
        self.end();
    }

    /// The stream ended. The reader releases the parser's descriptor and
    /// publishes the final frame here, at once (memory only, from both
    /// readers and at every load), so the last frame never waits behind
    /// other terminals' commits. The exit, a registry commit a reader may
    /// not make, goes to the terminal's publication sequence (Files lane,
    /// may block): after every publication the terminal's output queued, so
    /// it follows the last cwd and progress. No inline path for it. An exit
    /// item that never runs (shutdown) publishes nothing, and the reaper
    /// publishes the exit if it ends later.
    fn end(self) {
        #[cfg(unix)]
        {
            let mut output = self.output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            // Dead surfaces can remain visible. Do not keep their
            // duplicated PTY descriptor alive with that placement.
            output.finish();
        }
        let Some(pty) = self.surface.as_pty() else { return };
        pty.publish_final_frame();
        pty.local_pty_drained.store(true, Ordering::Release);
        let Some(owner) = pty.mux.upgrade() else { return };
        let surface = self.surface.clone();
        owner.post_terminal_end(&pty.publications, move || {
            // R3 (Debug): the exit commit never runs where blocking is disallowed.
            debug_assert!(
                !cmux_threads::blocking::is_blocking_disallowed(),
                "a terminal's exit ran on a thread that disallows blocking"
            );
            publish_local_exit_if_ready(&surface);
        });
        // The reader's completion drops here, after the descriptor is
        // released and the exit is queued, as before this change.
    }
}

#[cfg(unix)]
impl ReadSource for LocalReader {
    fn run(&mut self) -> ReadFlow {
        for _ in 0..READS_PER_RUN {
            match self.step() {
                Step::Read => {}
                Step::Idle => return ReadFlow::Continue,
                Step::Ended => return ReadFlow::Finished,
            }
        }
        // Yield to the other ready terminals; level readiness queues the rest.
        ReadFlow::Continue
    }

    /// The end runs on the terminal's publication sequence ([`LocalReader::end`]).
    fn finish(self: Box<Self>) {
        (*self).end();
    }
}
