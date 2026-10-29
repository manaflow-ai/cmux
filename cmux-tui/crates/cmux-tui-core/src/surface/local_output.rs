//! One parser path for local output, including bytes drained by a resize.
//!
//! Lock order: geometry -> local_output -> term -> runtime -> taps/leaves.
//! Event publication happens on the reader after releasing local_output.

use super::*;
use std::io;
#[cfg(unix)]
use std::os::fd::{AsRawFd, OwnedFd};

pub(super) struct LocalOutput {
    #[cfg(unix)]
    pub(super) descriptor: Option<OwnedFd>,
    #[cfg(unix)]
    /// Queues a run of this terminal's reader on the read loop
    /// (`ReadKick`), set once the reader is registered there.
    pub(super) wake: Option<crate::mux::terminal_work::read_loop::ReadKick>,
    pub(super) title_changed: Arc<AtomicBool>,
    pub(super) pending_responses: Arc<Mutex<Vec<u8>>>,
    pub(super) pending_bells: PendingBells,
    #[cfg(unix)]
    pub(super) parsed_sink: Option<Arc<crate::holder_runtime::HolderSink>>,
    shell_marks: crate::prompt_mode_reset::ShellMarks,
    kitty_media: cmux_kitty_media::KittyMediaRewriter,
    kitty_scratch: Vec<u8>,
    pending: Vec<ParsedOutput>,
}

pub(super) struct ParsedOutput {
    generation: u64,
    title_update: Option<String>,
    scroll_changed: Option<(u64, bool)>,
    terminal_notifications: Vec<crate::terminal_metadata::TerminalNotification>,
    finished_commands: Vec<crate::shell_history::FinishedCommand>,
}

pub(super) struct OutputPublisher {
    pending_responses: Arc<Mutex<Vec<u8>>>,
    pending_bells: PendingBells,
}

impl LocalOutput {
    pub(super) fn new(
        title_changed: Arc<AtomicBool>,
        pending_responses: Arc<Mutex<Vec<u8>>>,
        pending_bells: PendingBells,
        #[cfg(unix)] descriptor: Option<OwnedFd>,
        #[cfg(unix)] parsed_sink: Option<Arc<crate::holder_runtime::HolderSink>>,
    ) -> Self {
        Self {
            title_changed,
            pending_responses,
            pending_bells,
            #[cfg(unix)]
            descriptor,
            #[cfg(unix)]
            wake: None,
            #[cfg(unix)]
            parsed_sink,
            shell_marks: Default::default(),
            kitty_media: cmux_kitty_media::KittyMediaRewriter::new(),
            kitty_scratch: Vec::new(),
            pending: Vec::new(),
        }
    }

    /// The key press the read just done echoes (0: none): a holder
    /// terminal's reader took it from the holder's read, a direct PTY's
    /// from the terminal's own slot.
    fn take_echo_flow(&self, pty: &PtySurface) -> u64 {
        #[cfg(unix)]
        if let Some(sink) = self.parsed_sink.as_ref() {
            return sink.take_echo_flow();
        }
        pty.last_input_flow.take()
    }

    /// Reserve journal capture before reading and retain parser state across
    /// chunks, whether the reader or a geometry transaction supplies them.
    pub(super) fn read(
        &mut self,
        pty: &PtySurface,
        read: impl FnOnce(&mut [u8]) -> io::Result<usize>,
    ) -> io::Result<usize> {
        let mux = &pty.mux;
        let journal_target = pty.journal_target();
        let mut journal_update =
            journal_target.as_ref().and_then(|_| pty.begin_terminal_journal_update());
        if journal_target.is_some() && journal_update.is_none() {
            return Ok(0);
        }
        let mut buf = [0u8; 64 * 1024];
        let n = read(&mut buf)?;
        // The key press this read echoes, taken with the read so it stamps no later one.
        let flow = self.take_echo_flow(pty);
        if flow != 0 {
            pty.input_stages.echoed(flow, crate::input_stages::now_ns());
        }
        let read = buf.get(..n).unwrap_or(&buf);
        let output = self.kitty_media.rewrite_borrowed(read, &mut self.kitty_scratch);
        if output.is_empty() {
            return Ok(n);
        }
        let mut scroll_changed = None;
        let mut title_update = None;
        let terminal_notifications;
        let finished_commands;
        let generation = {
            let mut term = pty.term.lock().recover_poison();
            if let Some(update) = journal_update.as_mut()
                && !update.activate()
            {
                return Ok(0);
            }
            let journal_enabled = journal_update.is_some();
            let before = terminal_scroll_position(&term);
            let color_revision = term.color_revision();
            let color_reapply_revision = term.color_reapply_revision();
            #[allow(
                clippy::expect_used,
                reason = "INVARIANT: a live local terminal always reports cursor activity"
            )]
            let cursor_activity = term
                .cursor_activity()
                .expect("INVARIANT: valid local terminals expose cursor activity");
            // Read before the parse confirms these bytes: whether they may
            // be the holder ring's replay to a restarted daemon.
            #[cfg(unix)]
            let replayed = self.parsed_sink.as_ref().is_some_and(|sink| sink.replaying());
            #[cfg(not(unix))]
            let replayed = false;
            let normalized =
                crate::prompt_mode_reset::write_output(&mut term, output, &mut self.shell_marks);
            #[cfg(unix)]
            if let Some(sink) = self.parsed_sink.as_ref() {
                sink.confirm_parsed();
            }
            terminal_notifications = pty.observe_terminal_output_replayed(output, replayed);
            finished_commands = pty.observe_shell_marks(&mut term, || {
                mux.upgrade().is_some_and(|mux| mux.terminal_command_history_enabled())
            });
            #[allow(
                clippy::expect_used,
                reason = "INVARIANT: a live local terminal always reports cursor activity"
            )]
            let cursor_changed = term
                .cursor_activity()
                .expect("INVARIANT: valid local terminals expose cursor activity")
                != cursor_activity;
            pty.mouse_encoders.lock().recover_poison().sync_from_terminal(&term);
            let after = terminal_scroll_position(&term);
            let has_attach_taps = pty.broadcast_attach_output_flow(normalized.as_ref(), flow);
            if has_attach_taps && (term.color_revision() != color_revision || cursor_changed) {
                pty.attach_colors_pending.store(true, Ordering::Release);
                if term.color_reapply_revision() != color_reapply_revision || cursor_changed {
                    pty.attach_colors_force_pending.store(true, Ordering::Release);
                }
            }
            if self.title_changed.swap(false, Ordering::Relaxed) {
                // A program that rewrites the same title (a spinner's
                // resting frame, a prompt redraw) announces nothing.
                let title = crate::terminal_title::read(&term);
                let mut stored = pty.title.lock().recover_poison();
                if *stored != title {
                    *stored = title.clone();
                    title_update = Some(title);
                }
            }
            pty.record_directory(term.pwd());
            if before != after {
                scroll_changed = Some(after);
                broadcast_render_scroll_locked(pty, after);
            }
            // Keep the terminal lock scoped to parser and observer work. A
            // borrowed normalized frame still points into `buf` or Kitty
            // scratch, so journal allocation can happen after releasing term.
            let journal_output = journal_enabled.then_some(normalized);
            let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
            // Advance the output watermark before releasing
            // the parser lock. Screen snapshots take the same
            // lock, so they cannot observe this frame with the
            // previous revision.
            pty.stream_progress.notify();
            (generation, journal_output)
        };
        let (generation, journal_output) = generation;
        if let (Some(journal_target), Some(journal_output)) = (journal_target, journal_output) {
            pty.record_output(journal_target, journal_output.as_ref());
        }
        drop(journal_update);
        self.pending.push(ParsedOutput {
            generation,
            title_update,
            scroll_changed,
            terminal_notifications,
            finished_commands,
        });
        Ok(n)
    }

    /// Drain a snapshot of bytes queued on the direct PTY while the geometry
    /// transaction owns this parser. No other reader can consume them between
    /// the readiness probe and read. A wake publishes the collected events
    /// even when draining makes the PTY no longer readable.
    #[cfg(unix)]
    pub(super) fn drain(&mut self, pty: &PtySurface) -> io::Result<()> {
        let Some(fd) = self.descriptor.as_ref().map(AsRawFd::as_raw_fd) else { return Ok(()) };
        let result = (|| {
            // A finite snapshot keeps a continuously writing child from
            // starving geometry changes. Later output belongs after resize.
            let mut remaining = queued_bytes(fd)?;
            #[cfg(test)]
            pty.run_geometry_test_hook(PtyGeometryTestStep::LocalDrainSnapshot);
            while remaining > 0 && readable(fd, 0)? {
                let count = self.read(pty, |buffer| {
                    // SAFETY: descriptor owns fd, and the initialized buffer
                    // is writable for its full length. local_output serializes reads.
                    let count = unsafe {
                        libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len().min(remaining))
                    };
                    if count >= 0 {
                        return Ok(count as usize);
                    }
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() == Some(libc::EIO) { Ok(0) } else { Err(error) }
                });
                match count {
                    Ok(0) => break,
                    Ok(count) => remaining -= count,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) => return Err(error),
                }
            }
            Ok(())
        })();
        if !self.pending.is_empty()
            && let Some(wake) = self.wake.as_ref()
        {
            // Queues the reader's next run, which publishes them; a run in
            // progress is followed by one more.
            wake.kick();
        }
        result
    }

    /// Queue the event-bus `scroll-changed` of a viewport move a resize made
    /// under this parser, for the reader to publish after the output events
    /// already queued, and wake the reader. The resize sent it to render taps.
    #[cfg(unix)]
    pub(super) fn queue_scroll_changed(&mut self, generation: u64, position: (u64, bool)) {
        self.pending.push(ParsedOutput {
            generation,
            title_update: None,
            scroll_changed: Some(position),
            terminal_notifications: Vec::new(),
            finished_commands: Vec::new(),
        });
        if let Some(wake) = self.wake.as_ref() {
            wake.kick();
        }
    }

    pub(super) fn take_pending(&mut self) -> Vec<ParsedOutput> {
        std::mem::take(&mut self.pending)
    }

    #[cfg(unix)]
    pub(super) fn finish(&mut self) {
        self.descriptor.take();
        self.wake.take();
        self.kitty_media = cmux_kitty_media::KittyMediaRewriter::new();
        self.kitty_scratch = Vec::new();
        self.shell_marks = Default::default();
    }

    pub(super) fn publisher(&self) -> OutputPublisher {
        OutputPublisher {
            pending_responses: self.pending_responses.clone(),
            pending_bells: self.pending_bells.clone(),
        }
    }
}

impl OutputPublisher {
    pub(super) fn publish(&self, surface: &Arc<Surface>, events: Vec<ParsedOutput>) {
        let Some(pty) = surface.as_pty() else { return };
        let mux = &pty.mux;
        if !events.is_empty() {
            // The registry publication (cwd, progress, program status) goes
            // to the terminal's publication sequence, as a hosted
            // terminal's does: never here, at any load.
            surface.post_pending_publications();
        }
        for ParsedOutput {
            generation,
            title_update,
            scroll_changed,
            terminal_notifications,
            finished_commands,
        } in events
        {
            pty.stream_progress.notify();
            pty.request_frame(generation);
            // Mux events take `Mux::state`; publish them only after
            // the terminal lock is released (see PtyTerminalRuntime).
            self.pending_bells.publish(mux, surface.id);
            if let Some(title) = title_update
                && let Some(mux) = mux.upgrade()
            {
                mux.emit_terminal_title(surface.id, title.into());
            }
            if let Some((offset, at_bottom)) = scroll_changed
                && let Some(mux) = mux.upgrade()
            {
                mux.emit_terminal_scroll(surface.id, offset, at_bottom);
            }
            if !terminal_notifications.is_empty() {
                surface.post_output_notifications(terminal_notifications);
            }
            if !finished_commands.is_empty()
                && let Some(mux) = mux.upgrade()
                && let Some(terminal) = surface.terminal_public_id()
            {
                mux.append_shell_commands(terminal.clone(), finished_commands);
            }
            let responses = std::mem::take(
                &mut *self
                    .pending_responses
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner),
            );
            if !responses.is_empty() {
                // Waits while the child does not read its input.
                let _ = will_block(|| surface.write_terminal_reply(&responses));
            }
        }
    }
}

/// A query response write that may wait on the child (one that does not
/// read its input). On a read-loop worker it frees the worker's slot while
/// it runs (`read_loop::will_block`); a reader thread of its own just runs it.
fn will_block<R>(f: impl FnOnce() -> R) -> R {
    #[cfg(unix)]
    {
        crate::mux::terminal_work::read_loop::will_block(f)
    }
    #[cfg(not(unix))]
    {
        f()
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn queued_bytes(fd: std::os::fd::RawFd) -> io::Result<usize> {
    let mut count: libc::c_int = 0;
    // SAFETY: count is a writable integer and the parser owns fd across ioctl.
    if unsafe { libc::ioctl(fd, libc::FIONREAD, &mut count) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(usize::try_from(count).unwrap_or(0))
}

#[cfg(target_os = "macos")]
fn queued_bytes(fd: std::os::fd::RawFd) -> io::Result<usize> {
    use std::os::fd::FromRawFd;
    // Darwin's master FIONREAD reports input queued for the child. The read
    // filter instead reports output available to the master in event.data.
    // SAFETY: kqueue takes no arguments and returns a fresh descriptor.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful kqueue returned a descriptor owned by this function.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    let change = libc::kevent {
        ident: fd as usize,
        filter: libc::EVFILT_READ,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    let mut event = change;
    let timeout = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    loop {
        // SAFETY: both descriptors and all event/timeout pointers are valid
        // across this nonblocking call; the parser serializes PTY reads.
        let ready = unsafe { libc::kevent(queue.as_raw_fd(), &change, 1, &mut event, 1, &timeout) };
        if ready >= 0 {
            if ready > 0 && event.flags & libc::EV_ERROR != 0 {
                return Err(io::Error::from_raw_os_error(event.data as i32));
            }
            return Ok(if ready == 0 { 0 } else { usize::try_from(event.data).unwrap_or(0) });
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(unix)]
pub(super) fn readable(fd: std::os::fd::RawFd, timeout: i32) -> io::Result<bool> {
    let mut descriptor = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    loop {
        // SAFETY: descriptor is initialized; the caller owns fd across poll.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout) };
        if ready >= 0 {
            if descriptor.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "local PTY closed"));
            }
            return Ok(ready > 0);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
