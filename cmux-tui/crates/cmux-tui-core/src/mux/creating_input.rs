//! Input for a terminal still being created (`terminal-input-while-creating-v1`, cx-wb5.78).
//!
//! A pane or tab creation that names a caller-minted `terminal_id` registers that id as
//! creating when the daemon receives the request, before its host starts and before the commit.
//! Input addressed to the id (`send {terminal_id}`) is then kept in one FIFO per id, in arrival
//! order across connections, up to [`CREATING_INPUT_LIMIT`] bytes. When the creation committed
//! and its terminal is live, the queue is written to it in order. Until that flush ended, input
//! to the id still joins the queue, and every other input path to the new terminal (`send
//! {surface}`, `send-key`, the `terminal.input.*` effects, image paste, `clear-history`) waits
//! for it, or starts it when the commit's flush has not
//! ([`Mux::wait_for_creating_input_flush`]), so queued bytes precede all later input. No
//! daemon-wide lock is held while bytes go to a host. A creation that fails, a closed
//! connection, or no commit within the expiry (from the first queued byte) writes nothing;
//! each sending connection gets its own bytes back in one `terminal-input-unclaimed` notice, so
//! the client can give them to the terminal that has focus. Clients send keys to the new
//! terminal at once and never hold or replay them.

use super::*;

/// The most bytes queued for one creating terminal; more is refused (`input.overflow`).
pub(crate) const CREATING_INPUT_LIMIT: usize = 64 * 1024;
/// A creating terminal whose creation does not end this long after its first queued byte gives
/// its input back (`reason: "expired"`). It also bounds how long other input waits for a flush.
const CREATING_INPUT_EXPIRY: Duration = Duration::from_secs(10);
/// Test hook: a shorter expiry in milliseconds.
const EXPIRY_OVERRIDE_ENV: &str = "CMUX_TUI_TEST_CREATING_INPUT_EXPIRY_MS";
/// Test hook (fault injection): the flush starts this many milliseconds after the commit, so a
/// test can send input by another path inside that window.
const FLUSH_DELAY_ENV: &str = "CMUX_TUI_TEST_CREATING_INPUT_FLUSH_DELAY_MS";

/// Gives one connection its queued bytes back: `(terminal_id, bytes, reason)`.
pub(crate) type UnclaimedNotice = Arc<dyn Fn(&str, &[u8], &str) + Send + Sync>;

struct QueuedInput {
    client: u64,
    bytes: Vec<u8>,
    paste: bool,
    notice: UnclaimedNotice,
}

struct CreatingTerminal {
    generation: u64,
    queued: Vec<QueuedInput>,
    bytes: usize,
    expiry_started: bool,
    /// The creation committed and the queue is being written; the entry stays until it is empty.
    flushing: bool,
}

/// The creating terminals of one daemon, keyed by host terminal id (32 hex).
#[derive(Default)]
pub(crate) struct CreatingInputs {
    terminals: Mutex<HashMap<String, CreatingTerminal>>,
    ended: Condvar,
    next_generation: AtomicU64,
}

/// Where `write_terminal_input` put the bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalInputTarget {
    /// Kept for a creating terminal (or one whose queue is being written).
    Queued,
    /// Written to the live terminal.
    Written,
}

/// `write_terminal_input` refused bytes that would take a creating terminal's queue over
/// [`CREATING_INPUT_LIMIT`]; nothing of the request was queued.
#[derive(Debug)]
pub(crate) struct InputOverflow {
    queued: usize,
}

impl fmt::Display for InputOverflow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the creating terminal already holds {} queued bytes (limit {CREATING_INPUT_LIMIT})",
            self.queued
        )
    }
}

impl std::error::Error for InputOverflow {}

/// The `error_code` of a refused input (`input.overflow`).
pub(crate) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<InputOverflow>().map(|_| "input.overflow".to_string())
}

fn env_millis(name: &str) -> Option<Duration> {
    std::env::var(name).ok().and_then(|ms| ms.parse().ok()).map(Duration::from_millis)
}

impl Mux {
    /// A creation that names `terminal_id` was received: input for the id is queued from now on.
    /// Returns the generation the creation must end, or `None` when it does not own the id's
    /// queue: a live terminal already has the id (a refused or replayed create: input goes to
    /// it), or an earlier creation of the id is still in flight and owns it.
    pub(crate) fn begin_creating_input(&self, terminal_id: &str) -> Option<u64> {
        let inputs = &self.creating_inputs;
        // The live check and the insert are one step under the creating lock (lock order:
        // creating, then state), so a commit cannot make the id live in between.
        let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        if terminals.contains_key(terminal_id)
            || self.live_surface_for_terminal(terminal_id).is_some()
        {
            return None;
        }
        let generation = inputs.next_generation.fetch_add(1, Ordering::Relaxed);
        terminals.insert(
            terminal_id.to_string(),
            CreatingTerminal {
                generation,
                queued: Vec::new(),
                bytes: 0,
                expiry_started: false,
                flushing: false,
            },
        );
        Some(generation)
    }

    /// Write input to the terminal with host id `terminal_id`: queued while it is being created
    /// or its queue is being written, written at once when it is live.
    pub(crate) fn write_terminal_input(
        self: &Arc<Self>,
        terminal_id: &str,
        client: u64,
        bytes: &[u8],
        paste: bool,
        notice: UnclaimedNotice,
    ) -> anyhow::Result<TerminalInputTarget> {
        {
            let mut terminals =
                self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(creating) = terminals.get_mut(terminal_id) {
                if creating.bytes + bytes.len() > CREATING_INPUT_LIMIT {
                    return Err(InputOverflow { queued: creating.bytes }.into());
                }
                creating.bytes += bytes.len();
                creating.queued.push(QueuedInput { client, bytes: bytes.to_vec(), paste, notice });
                if !creating.expiry_started && !creating.flushing {
                    creating.expiry_started = true;
                    self.start_creating_input_expiry(terminal_id, creating.generation);
                }
                return Ok(TerminalInputTarget::Queued);
            }
        }
        // Live, and no flush is pending: written outside the creating lock.
        let surface = self
            .live_surface_for_terminal(terminal_id)
            .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
        if paste {
            surface.write_paste(bytes)?;
        } else {
            surface.write_bytes(bytes)?;
        }
        self.note_terminal_input(surface.id, client);
        Ok(TerminalInputTarget::Written)
    }

    /// Whether `terminal_id` names a live or creating terminal.
    pub(crate) fn knows_terminal_input_target(&self, terminal_id: &str) -> bool {
        let terminals =
            self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        terminals.contains_key(terminal_id) || self.live_surface_for_terminal(terminal_id).is_some()
    }

    /// Make sure no queue of live `surface`'s terminal is pending or being written, so input sent
    /// by another path follows the queued bytes. A queue that is not being written yet (the
    /// commit made the surface live but its flush has not started, or a creation that never
    /// ended left it) is written now, on this thread: the surface is live, so its creation
    /// committed. A queue being written is waited for, bounded by the expiry. Returns at once
    /// when no terminal is creating. The caller holds no mux lock.
    pub(crate) fn wait_for_creating_input_flush(&self, surface: &Surface) {
        let inputs = &self.creating_inputs;
        let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        if terminals.is_empty() {
            return;
        }
        let Some(identity) = surface.terminal_host_identity() else { return };
        let deadline = Instant::now() + CREATING_INPUT_EXPIRY;
        while let Some(creating) = terminals.get(&identity.terminal_id) {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            if !creating.flushing {
                let generation = creating.generation;
                drop(terminals);
                self.finish_creating_input(&identity.terminal_id, generation, None);
                terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
                continue;
            }
            terminals = inputs
                .ended
                .wait_timeout(terminals, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// The creation of `terminal_id` (generation `generation`) ended. Its queue goes to the live
    /// terminal in order, or back to its senders (`failure` names why; also when no live
    /// terminal has the id). A stale generation, or a flush already running, does nothing.
    pub(crate) fn finish_creating_input(
        &self,
        terminal_id: &str,
        generation: u64,
        failure: Option<&str>,
    ) {
        let inputs = &self.creating_inputs;
        let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(creating) = terminals.get_mut(terminal_id) else { return };
        if creating.generation != generation || creating.flushing {
            return;
        }
        let live =
            if failure.is_none() { self.live_surface_for_terminal(terminal_id) } else { None };
        let Some(surface) = live else {
            let queued = terminals.remove(terminal_id).map(|creating| creating.queued);
            inputs.ended.notify_all();
            drop(terminals);
            return give_back(terminal_id, queued.unwrap_or_default(), failure.unwrap_or("failed"));
        };
        creating.flushing = true;
        drop(terminals);
        if let Some(delay) = env_millis(FLUSH_DELAY_ENV) {
            std::thread::sleep(delay);
        }
        let mut clients = Vec::new();
        loop {
            let batch = {
                let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
                // A flushing entry stays until this loop removes it.
                let Some(creating) = terminals.get_mut(terminal_id) else { break };
                if creating.queued.is_empty() {
                    terminals.remove(terminal_id);
                    inputs.ended.notify_all();
                    break;
                }
                creating.bytes = 0;
                std::mem::take(&mut creating.queued)
            };
            for (index, input) in batch.iter().enumerate() {
                let written = if input.paste {
                    surface.write_paste(&input.bytes)
                } else {
                    surface.write_bytes(&input.bytes)
                };
                if let Err(error) = written {
                    // The terminal took the earlier bytes; the rest, and all queued since, go
                    // back to their senders.
                    eprintln!(
                        "cmux-tui: queued input for terminal {terminal_id} not written: {error}"
                    );
                    let later = {
                        let mut terminals =
                            inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
                        let creating = terminals.remove(terminal_id);
                        inputs.ended.notify_all();
                        creating.map(|creating| creating.queued).unwrap_or_default()
                    };
                    let mut rest: Vec<_> = batch.into_iter().skip(index).collect();
                    rest.extend(later);
                    return give_back(terminal_id, rest, "write-failed");
                }
                if !clients.contains(&input.client) {
                    clients.push(input.client);
                }
            }
        }
        for client in clients {
            self.note_terminal_input(surface.id, client);
        }
    }

    /// Give a creating terminal's input back when its creation has not ended by the expiry.
    fn start_creating_input_expiry(self: &Arc<Self>, terminal_id: &str, generation: u64) {
        let expiry = env_millis(EXPIRY_OVERRIDE_ENV).unwrap_or(CREATING_INPUT_EXPIRY);
        let deadline = Instant::now() + expiry;
        let mux = Arc::downgrade(self);
        let terminal_id = terminal_id.to_string();
        let spawned =
            std::thread::Builder::new().name("creating-input-expiry".into()).spawn(move || {
                let Some(mux) = mux.upgrade() else { return };
                let inputs = &mux.creating_inputs;
                let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
                // Wakes when any creation ends, or at the deadline: a bounded wait, not a poll.
                loop {
                    if terminals.get(&terminal_id).is_none_or(|creating| {
                        creating.generation != generation || creating.flushing
                    }) {
                        return;
                    }
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    terminals = inputs
                        .ended
                        .wait_timeout(terminals, deadline - now)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
                drop(terminals);
                mux.finish_creating_input(&terminal_id, generation, Some("expired"));
            });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no expiry for creating terminal input: {error}");
        }
    }

    /// The live terminal surface whose host id is `terminal_id`.
    #[track_caller]
    fn live_surface_for_terminal(&self, terminal_id: &str) -> Option<Arc<Surface>> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(surface) = state.indexed_catalog_terminal(terminal_id)
            && state.surfaces.contains_key(&surface.id)
        {
            return Some(surface.clone());
        }
        state
            .surfaces
            .values()
            .find(|surface| {
                surface
                    .terminal_host_identity()
                    .is_some_and(|identity| identity.terminal_id == terminal_id)
            })
            .cloned()
    }
}

/// One give-back per sending connection, with its own bytes in order.
fn give_back(terminal_id: &str, queued: Vec<QueuedInput>, reason: &str) {
    let mut senders: Vec<(u64, UnclaimedNotice, Vec<u8>)> = Vec::new();
    for input in queued {
        match senders.iter_mut().find(|(client, _, _)| *client == input.client) {
            Some((_, _, bytes)) => bytes.extend_from_slice(&input.bytes),
            None => senders.push((input.client, input.notice, input.bytes)),
        }
    }
    for (_, notice, bytes) in senders {
        notice(terminal_id, &bytes, reason);
    }
}
