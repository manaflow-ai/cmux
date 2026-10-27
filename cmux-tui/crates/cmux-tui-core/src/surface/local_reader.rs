//! The reader of a local terminal's output: bytes -> terminal state ->
//! events, one chunk at a time under the parser lock (`local_output`).
//!
//! A direct PTY reads on its owner's one read loop (`TerminalReads`),
//! not on a thread of its own: its descriptor's readiness queues a run, and
//! a resize that drained the readiness kicks one. A holder terminal parses
//! on its owner's VT pool (`crate::vt_pool`, p01-process-120): the
//! holder-link thread wakes its shard when output comes. A byte-backend
//! terminal has no descriptor in this process and keeps its blocking
//! `surface-<id>-reader` thread.

use std::io::Read;
#[cfg(unix)]
use std::os::fd::{AsRawFd, RawFd};
use std::time::Duration;

use super::local_output::{LocalOutput, OutputPublisher};
use super::*;
#[cfg(unix)]
use crate::mux::terminal_work::read_loop::{READS_PER_RUN, ReadFlow, ReadSource, TerminalReads};
#[cfg(unix)]
use crate::vt_pool::{Slice, VtFlow, VtPool, VtSource};

/// One local terminal's reader, on the read loop, the VT pool or its thread.
pub(super) struct LocalReader {
    surface: Arc<Surface>,
    output: Arc<Mutex<LocalOutput>>,
    reader: Box<dyn Read + Send>,
    publisher: OutputPublisher,
    /// The PTY descriptor the parser owns (`LocalOutput::descriptor`);
    /// `None` for a holder or byte-backend terminal.
    #[cfg(unix)]
    fd: Option<RawFd>,
    /// A holder terminal's output queue (`LocalOutput::parsed_sink`): its
    /// reads never wait, and it wakes the terminal's VT pool shard.
    #[cfg(unix)]
    holder_sink: Option<Arc<crate::holder_runtime::HolderSink>>,
    /// Dropped last, after the end is published (or on a panic).
    _completion: ReaderCompletionGuard,
}

/// What one read did.
enum Step {
    /// Parsed a chunk of this many bytes (or was interrupted: 0): read again.
    Read(usize),
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
        #[cfg(unix)]
        let holder_sink = parser.parsed_sink.clone();
        drop(parser);
        Self {
            surface,
            output,
            reader,
            publisher,
            #[cfg(unix)]
            fd,
            #[cfg(unix)]
            holder_sink,
            _completion: completion,
        }
    }

    /// Starts reading: a direct PTY on its owner's read loop and a holder
    /// terminal on its owner's VT pool (with no owner, on a loop or pool of
    /// its own that ends with this terminal), anything else on thread
    /// `surface-<id>-reader`.
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
        #[cfg(unix)]
        if let Some(sink) = self.holder_sink.clone() {
            let owner = self.surface.as_pty().and_then(|pty| pty.mux.upgrade());
            let registered = match owner {
                Some(mux) => mux.vt_pool().register(Box::new(self)),
                // Dropped at once: its shard ends after this terminal's end.
                None => VtPool::for_machine().register(Box::new(self)),
            };
            let Ok(wake) = registered else {
                anyhow::bail!("terminal {id}'s output cannot be parsed on the VT pool");
            };
            // Wakes the shard once for what the sink queued already.
            sink.set_wake(wake);
            return Ok(TerminalReader::Looped);
        }
        let thread =
            crate::echo_thread::spawn(format!("surface-{id}-reader"), move || self.run_blocking())?;
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
            Ok(Some(n)) => Step::Read(n),
            Ok(None) => Step::Idle,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => Step::Read(0),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Step::Idle,
            Err(_) => Step::Ended,
        }
    }

    /// The thread body of a reader with no PTY descriptor: its reads block.
    fn run_blocking(mut self) {
        let mut would_block =
            crate::backoff::Backoff::new(Duration::from_millis(1), Duration::from_millis(50));
        loop {
            match self.step() {
                Step::Read(_) => would_block.reset(),
                // No parser or source lock is held across backoff.
                Step::Idle => would_block.sleep(),
                Step::Ended => break,
            }
        }
        self.end();
    }

    /// The stream ended: release the parser's descriptor, publish the final
    /// frame and, once the far side ended too, the exit.
    fn end(self) {
        #[cfg(unix)]
        {
            let mut output = self.output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            // Dead surfaces can remain visible. Do not keep their
            // duplicated PTY descriptor alive with that placement.
            output.finish();
        }
        if let Some(pty) = self.surface.as_pty() {
            pty.publish_final_frame();
            pty.local_pty_drained.store(true, Ordering::Release);
        }
        post_local_exit_if_ready(&self.surface);
    }

    /// The end runs on the owner's terminal work pool, not on the read
    /// worker or shard; with no owner or a full pool, through `inline`.
    #[cfg(unix)]
    fn end_on_terminal_work(self, inline: fn(Box<dyn FnOnce() + Send>)) {
        let owner = self.surface.as_pty().and_then(|pty| pty.mux.upgrade());
        let Some(owner) = owner else { return inline(Box::new(move || self.end())) };
        if let Err(end) = owner.submit_terminal_work(Box::new(move || self.end())) {
            inline(end);
        }
    }
}

#[cfg(unix)]
impl ReadSource for LocalReader {
    fn run(&mut self) -> ReadFlow {
        for _ in 0..READS_PER_RUN {
            match self.step() {
                Step::Read(_) => {}
                Step::Idle => return ReadFlow::Continue,
                Step::Ended => return ReadFlow::Finished,
            }
        }
        // Yield to the other ready terminals; level readiness queues the rest.
        ReadFlow::Continue
    }

    /// With no owner or a full pool the end runs here: the loop runs
    /// `finish` in `will_block` already.
    fn finish(self: Box<Self>) {
        self.end_on_terminal_work(|end| end());
    }
}

/// A holder terminal on its VT pool shard.
#[cfg(unix)]
impl VtSource for LocalReader {
    fn run(&mut self, slice: &mut Slice) -> VtFlow {
        loop {
            match self.step() {
                Step::Read(n) => {
                    slice.charge(n);
                    // The rest goes after the shard's other terminals.
                    if slice.spent() {
                        return VtFlow::Yield;
                    }
                }
                Step::Idle => return VtFlow::Idle,
                Step::Ended => return VtFlow::Finished,
            }
        }
    }

    /// With no owner or a full pool the end runs in `will_block`, off the
    /// shard's other terminals.
    fn finish(self: Box<Self>) {
        self.end_on_terminal_work(crate::vt_pool::will_block);
    }
}
