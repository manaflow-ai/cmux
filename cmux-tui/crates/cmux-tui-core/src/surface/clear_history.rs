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
        self.clear_history_in_terminal(fallback_key)?;
        // What the person cleared must not come back from disk: the output
        // store drops this terminal's stored output and rewrites its
        // snapshot at once.
        if let Some(pty) = self.as_pty()
            && let (Some(terminal_id), Some(mux)) =
                (pty.terminal_public_id.as_ref(), pty.mux.upgrade())
        {
            mux.output_store.history_cleared(terminal_id);
        }
        Ok(())
    }

    fn clear_history_in_terminal(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> Result<(), ClearHistoryFailure> {
        let Some(pty) = self.as_pty() else {
            return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                "browser surface does not have a VT terminal"
            )));
        };
        // Send under the runtime lock, wait for the acknowledgement after
        // releasing it: the surface's reader delivers that acknowledgement,
        // and after a reconnect it takes the runtime lock before it reads
        // the new stream.
        // The host may type the fallback key: the request is sent in an
        // input turn, so it never lands inside another input.
        #[cfg(any(unix, windows))]
        {
            let turn = pty.input_fifo.enter();
            let pending = match &*pty.runtime.lock().recover_poison() {
                PtyRuntime::Hosted(host) => Some(host.begin_clear_history(fallback_key)?),
                PtyRuntime::ExitedHosted => {
                    return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "terminal host has exited"
                    )));
                }
                PtyRuntime::Local { .. } => None,
            };
            drop(turn);
            match pending {
                Some(Some(pending)) => return pending.wait(),
                Some(None) => {
                    return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "terminal host does not support clear-history"
                    )));
                }
                None => {}
            }
        }

        // Local resize takes terminal before runtime. Keep the same order for
        // alternate-screen fallback so resize and Command-K cannot deadlock.
        let mut observed_progress = pty.stream_progress.revision();
        let mut stream_wait = None;
        loop {
            // The fallback key is input: it is written in a turn of the
            // input FIFO, taken before the terminal lock (crate::lock_rank).
            let turn = pty.input_fifo.enter();
            let mut term = pty.term.lock().recover_poison();
            let before = terminal_scroll_position(&term);
            let scroll_changed = match apply_clear_history_transition(&mut term, fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?
            {
                ClearHistoryTransition::Blocked => {
                    drop(term);
                    drop(turn);
                    let wait = stream_wait.get_or_insert_with(|| {
                        pty.stream_progress
                            .begin_clear_history_wait(CLEAR_HISTORY_STREAM_WAIT_TIMEOUT)
                    });
                    let Some(progress) =
                        pty.stream_progress.wait_for_change(observed_progress, wait.deadline())
                    else {
                        wait.mark_timed_out();
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            CLEAR_HISTORY_STREAM_TIMEOUT_ERROR
                        )));
                    };
                    observed_progress = progress;
                    continue;
                }
                ClearHistoryTransition::EncodedFallback(encoded) => {
                    let mut runtime = pty.runtime.lock().recover_poison();
                    #[allow(
                        clippy::unreachable,
                        reason = "INVARIANT: the hosted runtimes returned above, and a runtime \
                                  never changes between local and hosted after construction"
                    )]
                    let PtyRuntime::Local {
                        writer,
                        master,
                        #[cfg(unix)]
                        holder,
                        ..
                    } = &mut *runtime
                    else {
                        unreachable!("a local PTY runtime cannot become hosted")
                    };
                    let Some(master) = master.as_deref() else {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal process has exited"
                        )));
                    };
                    drop(term);
                    // A holder terminal's keys go through its `pty-writer`
                    // queue, so the fallback key follows them in order. The
                    // wait for its delivery runs after the runtime lock is
                    // released.
                    #[cfg(unix)]
                    if let Some(input) = holder.as_ref().and_then(|holder| holder.input()) {
                        let receipt = queue_clear_history_fallback(input, &encoded)?;
                        drop(runtime);
                        drop(turn);
                        return crate::request_path::will_block(|| {
                            wait_clear_history_fallback(receipt)
                        });
                    }
                    return write_clear_history_fallback(master, writer.as_mut(), &encoded);
                }
                ClearHistoryTransition::Noop => return Ok(()),
                ClearHistoryTransition::Cleared(clear) => {
                    pty.mouse_encoders.lock().recover_poison().sync_from_terminal(&term);
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
            drop(turn);
            if let Some((offset, at_bottom)) = scroll_changed
                && let Some(mux) = pty.mux.upgrade()
            {
                mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
            }
            // What the person cleared never comes back: the journal records
            // the clear, and a holder gets the cleared screen as the
            // prologue a restarted daemon starts from (its older snapshot
            // still held the history).
            if let Some(mux) = pty.mux.upgrade() {
                pty.journal_clear_gap(&mux);
            }
            #[cfg(unix)]
            {
                let holder = match &*pty.runtime.lock().recover_poison() {
                    PtyRuntime::Local { holder, .. } => holder.clone(),
                    _ => None,
                };
                if let Some(holder) = holder {
                    holder.resnapshot();
                }
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

fn check_clear_history_fallback_size(bytes: &[u8]) -> Result<(), ClearHistoryFailure> {
    if bytes.len() > CLEAR_HISTORY_FALLBACK_MAX_BYTES {
        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            "encoded clear-history fallback exceeds {CLEAR_HISTORY_FALLBACK_MAX_BYTES} bytes"
        )));
    }
    Ok(())
}

/// [`write_clear_history_fallback`] for a holder terminal: queued in the
/// key lane of its `pty-writer` queue. A queue that refuses it (full or
/// closed) took none of it.
#[cfg(unix)]
fn queue_clear_history_fallback(
    input: &crate::pty_write::PtyInputQueue,
    bytes: &[u8],
) -> Result<crate::pty_write::InputReceipt, ClearHistoryFailure> {
    check_clear_history_fallback_size(bytes)?;
    input
        .send_receipted(bytes, crate::pty_write::InputLane::Key)
        .map_err(|error| ClearHistoryFailure::known_not_delivered(error.into()))
}

/// Waits, as long as the bounded write of other terminals, until the PTY
/// took the queued fallback key. One that timed out before the PTY took a
/// byte of it is taken back, so it is known not delivered.
#[cfg(unix)]
fn wait_clear_history_fallback(
    receipt: crate::pty_write::InputReceipt,
) -> Result<(), ClearHistoryFailure> {
    use crate::pty_write::DeliveryFailure;
    let deadline = Instant::now() + CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT;
    receipt.wait_until(deadline, CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR).map_err(|failure| {
        match failure {
            DeliveryFailure::NotDelivered(error) => {
                ClearHistoryFailure::known_not_delivered(error.into())
            }
            DeliveryFailure::Partial(error) => ClearHistoryFailure::ambiguous(error.into()),
        }
    })
}

pub(crate) fn write_clear_history_fallback(
    master: &dyn MasterPty,
    writer: &mut dyn Write,
    bytes: &[u8],
) -> Result<(), ClearHistoryFailure> {
    check_clear_history_fallback_size(bytes)?;

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
