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
//!
//! A terminal whose surviving host is being adopted (after an update's handoff or a crash, each
//! host adopts on its own thread after the new owner answers) takes input the same way: it is
//! listed as adopting but has no live surface yet, and its input was refused as `unknown
//! terminal`, so keys typed during an update were lost. Input for it is queued once an adoption
//! of the id runs; the adoption's end ([`Mux::finish_adopting_input`]) writes the queue to the
//! adopted terminal in order, or gives it back (`reason: "failed"`) when no live terminal has
//! the id. The expiry bounds it as for a creation.

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
    /// The queue belongs to the adoption of a surviving host, not to a creation: the adoption's
    /// end writes it or gives it back.
    adopting: bool,
}

/// The creating terminals of one daemon, keyed by host terminal id (32 hex).
#[derive(Default)]
pub(crate) struct CreatingInputs {
    terminals: Mutex<HashMap<String, CreatingTerminal>>,
    /// How many terminals are creating: the map's length, stored under its lock after each change. A key reads it
    /// with no lock and takes the lock only while a terminal is creating (R-DAEMON-STATE stage S1).
    creating: AtomicUsize,
    ended: Condvar,
    next_generation: AtomicU64,
}

impl CreatingInputs {
    /// Adds the creating terminal `terminal_id`; the count follows, under the lock.
    fn insert(
        &self,
        terminals: &mut HashMap<String, CreatingTerminal>,
        terminal_id: &str,
        creating: CreatingTerminal,
    ) {
        terminals.insert(terminal_id.to_string(), creating);
        self.creating.store(terminals.len(), Ordering::Release);
    }

    /// Removes the creating terminal `terminal_id` (its queue was written or given back); the count follows, under
    /// the lock, after every byte of the queue went to the terminal.
    fn remove(
        &self,
        terminals: &mut HashMap<String, CreatingTerminal>,
        terminal_id: &str,
    ) -> Option<CreatingTerminal> {
        let removed = terminals.remove(terminal_id);
        self.creating.store(terminals.len(), Ordering::Release);
        removed
    }
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
        // The live check and the insert are one step under the creating lock. The check reads the
        // session state (lane off, or a poisoned state; lock order: creating, then state) or, on the
        // input lane, the published routes of the last finished change: a commit still in progress has
        // not made the id live, as when the old path takes the state before that commit, so every
        // answer is one the old path can give. On both arms the read ends before the insert, so a
        // commit can make the id live in between; the entry is then written to the live terminal in
        // order, by the creation's finish or by the next input on another path
        // (`wait_for_creating_input_flush`), or given back, as any queue.
        let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        if terminals.contains_key(terminal_id)
            || self.live_surface_for_terminal(terminal_id).is_some()
        {
            return None;
        }
        let generation = inputs.next_generation.fetch_add(1, Ordering::Relaxed);
        inputs.insert(
            &mut terminals,
            terminal_id,
            CreatingTerminal {
                generation,
                queued: Vec::new(),
                bytes: 0,
                expiry_started: false,
                flushing: false,
                adopting: false,
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
                return self.queue_input(terminal_id, creating, client, bytes, paste, notice);
            }
        }
        // Live, and no flush is pending: written outside the creating lock. Not live: queued
        // while the terminal's host adopts.
        let surface = match self.live_surface_for_terminal(terminal_id) {
            Some(surface) => surface,
            None => match self.queue_adopting_input(terminal_id, client, bytes, paste, notice)? {
                Some(surface) => surface,
                None => return Ok(TerminalInputTarget::Queued),
            },
        };
        if paste {
            surface.write_paste(bytes)?;
        } else {
            surface.write_bytes(bytes)?;
        }
        self.note_terminal_input(&surface, client);
        Ok(TerminalInputTarget::Written)
    }

    /// Queue input in `creating`'s FIFO (the caller holds the creating lock), or refuse it whole
    /// past [`CREATING_INPUT_LIMIT`]. The first queued byte starts the expiry.
    fn queue_input(
        self: &Arc<Self>,
        terminal_id: &str,
        creating: &mut CreatingTerminal,
        client: u64,
        bytes: &[u8],
        paste: bool,
        notice: UnclaimedNotice,
    ) -> anyhow::Result<TerminalInputTarget> {
        if creating.bytes + bytes.len() > CREATING_INPUT_LIMIT {
            return Err(InputOverflow { queued: creating.bytes }.into());
        }
        creating.bytes += bytes.len();
        creating.queued.push(QueuedInput { client, bytes: bytes.to_vec(), paste, notice });
        if !creating.expiry_started && !creating.flushing {
            creating.expiry_started = true;
            self.start_creating_input_expiry(terminal_id, creating.generation);
        }
        Ok(TerminalInputTarget::Queued)
    }

    /// Input for `terminal_id`, which had no live surface: queued (`None`) while an adoption of
    /// its surviving host runs, the surface to write when it went live meanwhile, else refused.
    /// The adoption set is read under the creating lock, and an adoption leaves the set before
    /// its end takes that lock ([`Mux::finish_adopting_input`]), so a queue added here is always
    /// written or given back. Lock order: creating, then the adoption set.
    fn queue_adopting_input(
        self: &Arc<Self>,
        terminal_id: &str,
        client: u64,
        bytes: &[u8],
        paste: bool,
        notice: UnclaimedNotice,
    ) -> anyhow::Result<Option<Arc<Surface>>> {
        let inputs = &self.creating_inputs;
        let mut terminals = inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        if !terminals.contains_key(terminal_id) {
            if let Some(surface) = self.live_surface_for_terminal(terminal_id) {
                return Ok(Some(surface));
            }
            if !self.terminal_adoption_runs(terminal_id) {
                anyhow::bail!("unknown terminal {terminal_id}");
            }
            let generation = inputs.next_generation.fetch_add(1, Ordering::Relaxed);
            inputs.insert(
                &mut terminals,
                terminal_id,
                CreatingTerminal {
                    generation,
                    queued: Vec::new(),
                    bytes: 0,
                    expiry_started: false,
                    flushing: false,
                    adopting: true,
                },
            );
        }
        let Some(creating) = terminals.get_mut(terminal_id) else {
            anyhow::bail!("unknown terminal {terminal_id}");
        };
        self.queue_input(terminal_id, creating, client, bytes, paste, notice).map(|_| None)
    }

    /// Whether an adoption thread of `terminal_id`'s surviving host runs.
    fn terminal_adoption_runs(&self, terminal_id: &str) -> bool {
        self.terminal_adoptions.lock().unwrap_or_else(PoisonError::into_inner).contains(terminal_id)
    }

    /// The adoption of `terminal_id` ended and the id left the adoption set: input queued while
    /// it adopted goes to the adopted terminal in order, or back to its senders when no live
    /// terminal has the id (the host was lost, the terminal ended or closed).
    pub(super) fn finish_adopting_input(&self, terminal_id: &str) {
        let generation = {
            let terminals =
                self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
            match terminals.get(terminal_id) {
                Some(creating) if creating.adopting => creating.generation,
                _ => return,
            }
        };
        self.finish_creating_input(terminal_id, generation, None);
    }

    /// Whether `terminal_id` names a live, creating or adopting terminal.
    pub(crate) fn knows_terminal_input_target(&self, terminal_id: &str) -> bool {
        let terminals =
            self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        terminals.contains_key(terminal_id)
            || self.live_surface_for_terminal(terminal_id).is_some()
            || self.terminal_adoption_runs(terminal_id)
    }

    /// Make sure no queue of live `surface`'s terminal is pending or being written, so input sent
    /// by another path follows the queued bytes. A queue that is not being written yet (the
    /// commit made the surface live but its flush has not started, or a creation that never
    /// ended left it) is written now, on this thread: the surface is live, so its creation
    /// committed. A queue being written is waited for, bounded by the expiry. Returns at once
    /// when no terminal is creating. The caller holds no mux lock.
    pub(crate) fn wait_for_creating_input_flush(&self, surface: &Surface) {
        let inputs = &self.creating_inputs;
        // No terminal is creating, so no queue can be ahead of this input: the count says so with no lock
        // (R-DAEMON-STATE stage S1). A queue of this surface's terminal was added before the terminal went live,
        // and the count drops to zero only after the last queue was written (Release, read here with Acquire).
        if self.control_clients.input_lane.on() && inputs.creating.load(Ordering::Acquire) == 0 {
            return;
        }
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
            let queued = inputs.remove(&mut terminals, terminal_id).map(|creating| creating.queued);
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
                    inputs.remove(&mut terminals, terminal_id);
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
                    // back to their senders. Bytes whose write may still reach the program (its
                    // wait ended during the write) are not given back: that would type them twice.
                    eprintln!(
                        "cmux-tui: queued input for terminal {terminal_id} not written: {error}"
                    );
                    let later = {
                        let mut terminals =
                            inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
                        let creating = inputs.remove(&mut terminals, terminal_id);
                        inputs.ended.notify_all();
                        creating.map(|creating| creating.queued).unwrap_or_default()
                    };
                    let first_given_back = if crate::surface::input_may_be_written(&error) {
                        index.saturating_add(1)
                    } else {
                        index
                    };
                    let mut rest: Vec<_> = batch.into_iter().skip(first_given_back).collect();
                    rest.extend(later);
                    return give_back(terminal_id, rest, "write-failed");
                }
                if !clients.contains(&input.client) {
                    clients.push(input.client);
                }
            }
        }
        for client in clients {
            self.note_terminal_input(&surface, client);
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

    /// Runs `hold` while this thread holds the creating-input lock (tests: a person's key must not wait for it).
    #[cfg(test)]
    pub(crate) fn hold_creating_inputs_for_test(&self, hold: &dyn Fn()) {
        let _held = self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        hold();
    }

    /// Whether a thread holds the creating-input lock now (tests).
    #[cfg(test)]
    pub(crate) fn creating_inputs_held_for_test(&self) -> bool {
        matches!(
            self.creating_inputs.terminals.try_lock(),
            Err(std::sync::TryLockError::WouldBlock)
        )
    }

    /// The live terminal surface whose host id is `terminal_id`. The creating-input lock's holders call it under
    /// that lock; on the input lane (R-DAEMON-STATE stage S1) it reads the routes of the last finished change, so no
    /// holder waits for the session lock under it and a key that takes it never waits behind one. A commit publishes
    /// its routes before it releases the session lock, and a queue is removed only after its terminal is live, so the
    /// creation checks give the answers they gave under the session lock.
    ///
    /// On the lane, the creating-input lock is a leaf only while the state is not poisoned: on a poisoned state this
    /// takes the session lock under it (creating, then state), as the old path always does. So no code may take the
    /// creating-input lock while it holds the session lock.
    #[track_caller]
    fn live_surface_for_terminal(&self, terminal_id: &str) -> Option<Arc<Surface>> {
        // As `Mux::surface`: the routes are loaded before the poison check (poison never clears), so routes used here
        // come from a change that finished before any panic, and a poisoned state takes the old read. Unlike
        // `Mux::surface`'s, this old read recovers the poison: the creation checks answer from the state, as the old
        // path did (a create whose commit panicked has its terminal in the state, and the routes lack it until a later
        // change that recovers the poison publishes them).
        if self.control_clients.input_lane.on() {
            let routes = self.state.routes();
            if !self.state.is_poisoned() {
                return routes.live_terminal(terminal_id);
            }
        }
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        crate::route_table::live_terminal(
            &state.surfaces,
            &state.terminal_catalog,
            &state.terminal_catalog_by_host,
            terminal_id,
        )
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
