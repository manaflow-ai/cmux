//! Clear-history operations on `Surface`: emulator-side history erase with an
//! alternate-screen key fallback, classified by delivery failure.

use super::*;

impl Surface {
    /// Clear retained primary-screen output inside the emulator without
    /// writing to the child process. Complete rows before an OSC 133 prompt are
    /// erased when the cursor can be restored exactly; otherwise the request
    /// fails without changing terminal state. Attached byte frontends receive
    /// the same VT erase sequence. Alternate-screen applications are left
    /// untouched.
    pub fn clear_history(&self) -> anyhow::Result<()> {
        self.clear_history_or_encode_key(None)
    }

    /// Clear primary-screen history, or encode `fallback_key` when the
    /// authoritative terminal is in the alternate screen. The PTY writer
    /// serializes input while the screen decision and keyboard encoding use
    /// one terminal snapshot. The terminal lock is released before PTY I/O.
    pub fn clear_history_or_encode_key(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> anyhow::Result<()> {
        self.clear_history_or_encode_key_classified(fallback_key)
            .map_err(ClearHistoryFailure::into_error)
    }

    pub fn supports_clear_history_key_fallback(&self) -> bool {
        self.as_pty()
            .is_some_and(|pty| pty.supports_clear_history_key_fallback.load(Ordering::Acquire))
    }

    pub fn clear_history_or_encode_key_classified(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> Result<(), ClearHistoryFailure> {
        let Some(pty) = self.as_pty() else {
            return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                "browser surface does not have a VT terminal"
            )));
        };
        #[cfg(unix)]
        {
            {
                let runtime = pty.runtime.lock().unwrap();
                match &*runtime {
                    PtyRuntime::Hosted(host) => {
                        if host.send_clear_history(fallback_key)? {
                            return Ok(());
                        }
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal host does not support clear-history"
                        )));
                    }
                    PtyRuntime::ExitedHosted => {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal host has exited"
                        )));
                    }
                    PtyRuntime::Local { .. } => {}
                }
            }
        }

        // Local resize takes terminal before runtime. Keep the same order for
        // alternate-screen fallback so resize and Command-K cannot deadlock.
        let mut observed_progress = pty.stream_progress.revision();
        let mut stream_wait = None;
        loop {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            let scroll_changed = match apply_clear_history_transition(&mut term, fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?
            {
                ClearHistoryTransition::Blocked => {
                    drop(term);
                    let deadline = stream_wait
                        .get_or_insert_with(|| {
                            pty.stream_progress
                                .begin_clear_history_wait(CLEAR_HISTORY_STREAM_WAIT_TIMEOUT)
                        })
                        .deadline();
                    let Some(progress) =
                        pty.stream_progress.wait_for_change(observed_progress, deadline)
                    else {
                        stream_wait.as_mut().unwrap().mark_timed_out();
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            CLEAR_HISTORY_STREAM_TIMEOUT_ERROR
                        )));
                    };
                    observed_progress = progress;
                    continue;
                }
                ClearHistoryTransition::EncodedFallback(encoded) => {
                    let mut runtime = pty.runtime.lock().unwrap();
                    let PtyRuntime::Local { writer, master, .. } = &mut *runtime else {
                        unreachable!("a local PTY runtime cannot become hosted")
                    };
                    let Some(master) = master.as_deref() else {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal process has exited"
                        )));
                    };
                    drop(term);
                    return write_clear_history_fallback(master, writer.as_mut(), &encoded);
                }
                ClearHistoryTransition::Noop => return Ok(()),
                ClearHistoryTransition::Cleared(clear) => {
                    pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                    pty.broadcast_attach_output(&clear);
                    pty.stream_progress.notify();
                    let after = terminal_scroll_position(&term);
                    if before != after {
                        broadcast_render_scroll_locked(pty, after);
                    }
                    let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                    let _ = pty.build_frame_locked(&mut term, generation, false);
                    (before != after).then_some(after)
                }
            };
            drop(term);
            if let Some((offset, at_bottom)) = scroll_changed
                && let Some(mux) = pty.mux.upgrade()
            {
                mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
            }
            pty.mark_output_dirty();
            return Ok(());
        }
    }
}

pub const CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR: &str =
    "terminal keyboard mode cannot encode clear-history fallback key";
pub const CLEAR_HISTORY_PRESERVATION_ERROR: &str =
    "active terminal input extends into retained history";
pub const CLEAR_HISTORY_STREAM_TIMEOUT_ERROR: &str =
    "terminal output did not reach a safe clear-history boundary";
pub const CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR: &str =
    "terminal input did not accept clear-history fallback before timeout";
pub(crate) const CLEAR_HISTORY_STREAM_WAIT_TIMEOUT: Duration = Duration::from_millis(250);
pub(crate) const CLEAR_HISTORY_KEY_TEXT_MAX_BYTES: usize = 4 * 1024;
const CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT: Duration = Duration::from_millis(250);
pub(super) const LOCAL_PASTE_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
// Kitty associated-text encoding can expand each ASCII input byte to a
// three-digit codepoint plus one separator. The extra key-text budget covers
// the fixed CSI-u fields without making fallback writes unbounded.
const CLEAR_HISTORY_FALLBACK_MAX_BYTES: usize = CLEAR_HISTORY_KEY_TEXT_MAX_BYTES * 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClearHistoryDelivery {
    KnownNotDelivered,
    Ambiguous,
}

#[derive(Debug)]
pub struct ClearHistoryFailure {
    error: anyhow::Error,
    delivery: ClearHistoryDelivery,
}

impl ClearHistoryFailure {
    pub fn known_not_delivered(error: anyhow::Error) -> Self {
        Self { error, delivery: ClearHistoryDelivery::KnownNotDelivered }
    }

    pub fn ambiguous(error: anyhow::Error) -> Self {
        Self { error, delivery: ClearHistoryDelivery::Ambiguous }
    }

    pub fn delivery(&self) -> ClearHistoryDelivery {
        self.delivery
    }

    pub fn error(&self) -> &anyhow::Error {
        &self.error
    }

    pub fn into_error(self) -> anyhow::Error {
        self.error
    }
}

#[cfg(unix)]
fn clear_history_write_failure(error: std::io::Error, delivered: usize) -> ClearHistoryFailure {
    let error = anyhow::Error::from(error);
    if delivered == 0 {
        ClearHistoryFailure::known_not_delivered(error)
    } else {
        ClearHistoryFailure::ambiguous(error)
    }
}

pub(crate) fn write_clear_history_fallback(
    master: &dyn MasterPty,
    writer: &mut dyn Write,
    bytes: &[u8],
) -> Result<(), ClearHistoryFailure> {
    if bytes.len() > CLEAR_HISTORY_FALLBACK_MAX_BYTES {
        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            "encoded clear-history fallback exceeds {CLEAR_HISTORY_FALLBACK_MAX_BYTES} bytes"
        )));
    }

    #[cfg(unix)]
    if let Some(fd) = master.as_raw_fd() {
        return crate::pty_write::write_bounded(
            fd,
            bytes,
            CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT,
            CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
        )
        .map_err(|failure| clear_history_write_failure(failure.error, failure.delivered));
    }

    #[cfg(test)]
    {
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(anyhow::Error::from)
            .map_err(ClearHistoryFailure::ambiguous)
    }

    #[cfg(not(test))]
    {
        let _ = writer;
        Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            "bounded clear-history fallback writes are unavailable for this PTY"
        )))
    }
}

pub(crate) enum ClearHistoryTransition {
    Cleared(Vec<u8>),
    Blocked,
    EncodedFallback(Vec<u8>),
    Noop,
}

pub(crate) fn apply_clear_history_transition(
    term: &mut Terminal,
    fallback_key: Option<&KeyInput>,
) -> anyhow::Result<ClearHistoryTransition> {
    if term.active_screen() != Screen::Alternate {
        return Ok(match term.clear_history_preserving_prompt() {
            ClearHistoryOutcome::Cleared(clear) => ClearHistoryTransition::Cleared(clear),
            ClearHistoryOutcome::Blocked => ClearHistoryTransition::Blocked,
            ClearHistoryOutcome::Unchanged => {
                anyhow::bail!(CLEAR_HISTORY_PRESERVATION_ERROR)
            }
        });
    }
    let Some(input) = fallback_key else {
        return Ok(ClearHistoryTransition::Noop);
    };
    let encoded = encode_key_from_terminal(term, input)?;
    Ok(ClearHistoryTransition::EncodedFallback(encoded))
}
