//! Input for a terminal still being created (`terminal-input-while-creating-v1`, cx-wb5.78).
//!
//! A pane or tab creation that names a caller-minted `terminal_id` registers that id as
//! creating when the daemon receives the request, before its host starts and before the commit.
//! Input addressed to the id (`send {terminal_id}`) is then kept in one
//! FIFO per id, in arrival order across connections, up to [`CREATING_INPUT_LIMIT`] bytes. When
//! the creation committed and its terminal is live, the queue is written to it in order, under
//! the same lock as later input to the id, so queued bytes always precede live ones. A creation
//! that fails, a closed connection, or no commit within the expiry (from the first queued byte)
//! writes nothing; each sending connection gets its own bytes back in one
//! `terminal-input-unclaimed` notice, so the client can give them to the terminal that has
//! focus. Clients send keys to the new terminal at once and never hold or replay them.

use super::*;

/// The most bytes queued for one creating terminal; more is refused (`input.overflow`).
pub(crate) const CREATING_INPUT_LIMIT: usize = 64 * 1024;
/// A creating terminal whose creation does not end this long after its first queued byte gives
/// its input back (`reason: "expired"`).
const CREATING_INPUT_EXPIRY: Duration = Duration::from_secs(10);
/// Test hook: a shorter expiry in milliseconds.
const EXPIRY_OVERRIDE_ENV: &str = "CMUX_TUI_TEST_CREATING_INPUT_EXPIRY_MS";

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
    /// Kept for a creating terminal.
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

impl Mux {
    /// A creation that names `terminal_id` was received: input for the id is queued from now on.
    pub(crate) fn begin_creating_input(&self, terminal_id: &str) {
        // A live terminal already has the id (a refused or replayed create): input goes to it.
        if self.live_surface_for_terminal(terminal_id).is_some() {
            return;
        }
        let inputs = &self.creating_inputs;
        let generation = inputs.next_generation.fetch_add(1, Ordering::Relaxed);
        inputs
            .terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(terminal_id.to_string())
            .or_insert(CreatingTerminal {
                generation,
                queued: Vec::new(),
                bytes: 0,
                expiry_started: false,
            });
    }

    /// Write input to the terminal with host id `terminal_id`: queued while it is being created,
    /// written at once when it is live.
    pub(crate) fn write_terminal_input(
        self: &Arc<Self>,
        terminal_id: &str,
        client: u64,
        bytes: &[u8],
        paste: bool,
        notice: UnclaimedNotice,
    ) -> anyhow::Result<TerminalInputTarget> {
        let mut terminals =
            self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(creating) = terminals.get_mut(terminal_id) {
            if creating.bytes + bytes.len() > CREATING_INPUT_LIMIT {
                return Err(InputOverflow { queued: creating.bytes }.into());
            }
            creating.bytes += bytes.len();
            creating.queued.push(QueuedInput { client, bytes: bytes.to_vec(), paste, notice });
            if !creating.expiry_started {
                creating.expiry_started = true;
                self.start_creating_input_expiry(terminal_id, creating.generation);
            }
            return Ok(TerminalInputTarget::Queued);
        }
        // Live: written under the same lock, so it follows a flush of queued bytes.
        let surface = self
            .live_surface_for_terminal(terminal_id)
            .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
        if paste {
            surface.write_paste(bytes)?;
        } else {
            surface.write_bytes(bytes)?;
        }
        drop(terminals);
        self.note_terminal_input(surface.id, client);
        Ok(TerminalInputTarget::Written)
    }

    /// The creation of `terminal_id` ended. Its queue goes to the live terminal in order, or back
    /// to its senders (`failure` names why; also when no live terminal has the id).
    pub(crate) fn finish_creating_input(&self, terminal_id: &str, failure: Option<&str>) {
        let mut terminals =
            self.creating_inputs.terminals.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(creating) = terminals.remove(terminal_id) else { return };
        self.creating_inputs.ended.notify_all();
        let live =
            if failure.is_none() { self.live_surface_for_terminal(terminal_id) } else { None };
        let Some(surface) = live else {
            drop(terminals);
            return give_back(terminal_id, creating.queued, failure.unwrap_or("failed"));
        };
        // Test hook (fault injection): the flush starts this long after the commit.
        if let Some(delay) = std::env::var("CMUX_TUI_TEST_CREATING_INPUT_FLUSH_DELAY_MS")
            .ok()
            .and_then(|ms| ms.parse().ok())
            .map(Duration::from_millis)
        {
            std::thread::sleep(delay);
        }
        let mut clients = Vec::new();
        for (index, input) in creating.queued.iter().enumerate() {
            let written = if input.paste {
                surface.write_paste(&input.bytes)
            } else {
                surface.write_bytes(&input.bytes)
            };
            if let Err(error) = written {
                // The terminal took the earlier bytes; the rest go back to their senders.
                drop(terminals);
                eprintln!("cmux-tui: queued input for terminal {terminal_id} not written: {error}");
                let rest = creating.queued.into_iter().skip(index).collect();
                return give_back(terminal_id, rest, "write-failed");
            }
            if !clients.contains(&input.client) {
                clients.push(input.client);
            }
        }
        drop(terminals);
        for client in clients {
            self.note_terminal_input(surface.id, client);
        }
    }

    /// Give a creating terminal's input back when its creation has not ended by the expiry.
    fn start_creating_input_expiry(self: &Arc<Self>, terminal_id: &str, generation: u64) {
        let expiry = std::env::var(EXPIRY_OVERRIDE_ENV)
            .ok()
            .and_then(|ms| ms.parse().ok())
            .map_or(CREATING_INPUT_EXPIRY, Duration::from_millis);
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
                    if terminals
                        .get(&terminal_id)
                        .is_none_or(|creating| creating.generation != generation)
                    {
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
                mux.finish_creating_input(&terminal_id, Some("expired"));
            });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no expiry for creating terminal input: {error}");
        }
    }

    /// The live terminal surface whose host id is `terminal_id`.
    fn live_surface_for_terminal(&self, terminal_id: &str) -> Option<Arc<Surface>> {
        let state = self.state.lock().unwrap();
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
