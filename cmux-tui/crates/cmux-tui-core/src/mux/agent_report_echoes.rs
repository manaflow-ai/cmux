//! What keeps an agent's public projection and the agent roster agreeing.
//!
//! The invariant: **a terminal's projection is written from the roster (a
//! reconcile, or a fold's delta), and a guarded send (`expect_agent`) reads
//! the roster, only when no record that projected for that terminal is past
//! the roster's cursor**; the check and the write hold the hook projector's
//! lock (`agent_hook_fences`), under which every such record projects. Two
//! kinds of record project before the roster folds them:
//! - a hook, which the projector applies at ingress: its fence holds its
//!   journal sequence;
//! - a direct report, which commits its row and then appends its journal
//!   echo: tracked here from the commit (under that lock) until its echo is
//!   journaled, then by the echo's journal sequence.
//! A write the check refuses is owed: the roster's owner makes it after a
//! pass whose fold reached every such record (`settle_report_echoes`), and
//! then the row is the reducer's own verdict on them, its source precedence
//! included.
//!
//! Every echo is journaled, in its terminal's commit order, so the reducer
//! folds what base folded. A failed append is tried again by the owner with
//! the same idempotency key after the roster's read backoff, the terminal's
//! later echoes waiting behind it. After [`ECHO_ATTEMPTS`] it is given up:
//! the terminal is unknown (its row stays, guarded sends are refused) until
//! the roster's cursor passed the journal head of the give-up and its entry
//! changed after that.
//!
//! #39830 review, rounds 2 to 5: a fence that kept a report's row whatever
//! the reducer folded, a counter that let go at the append, a failed echo
//! retried forever, skipped echoes, and a check that ignored hooks all broke
//! the invariant on one path; each path is now checked against it here.

use super::*;

/// Appends of one failed echo before it is given up.
#[cfg(not(test))]
const ECHO_ATTEMPTS: u32 = 8;
#[cfg(test)]
const ECHO_ATTEMPTS: u32 = 3;

/// A direct report's journal echo ([`Mux::append_agent_report_echo`]).
#[derive(Clone)]
pub(in crate::mux) struct ReportEcho {
    pub(in crate::mux) terminal_id: TerminalPublicId,
    pub(in crate::mux) state: AgentState,
    pub(in crate::mux) source: AgentSource,
    pub(in crate::mux) session: Option<String>,
    pub(in crate::mux) updated_at_ms: u64,
    /// One key for every append of this echo, so a retry of an append that
    /// did commit is journaled once.
    pub(in crate::mux) idempotency_key: String,
}

impl ReportEcho {
    pub(in crate::mux) fn new(
        terminal_id: TerminalPublicId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
        updated_at_ms: u64,
    ) -> Self {
        let idempotency_key =
            format!("agent-report-echo-{}", crate::workspace_registry::new_uuid_v4());
        Self { terminal_id, state, source, session, updated_at_ms, idempotency_key }
    }
}

#[derive(Default)]
pub(in crate::mux) struct ReportEchoes {
    terminals: HashMap<TerminalPublicId, TerminalEchoes>,
    /// Terminals whose projection write the check refused: the owner makes
    /// it once their records are folded.
    owed: HashSet<TerminalPublicId>,
    /// Terminals whose echo was given up.
    lost: HashMap<TerminalPublicId, LostEcho>,
}

#[derive(Default)]
struct TerminalEchoes {
    /// Echoes committed and not journaled yet, in commit order. The front
    /// stays here while it is appended.
    queue: VecDeque<QueuedEcho>,
    /// The highest journal sequence of the terminal's echoes.
    journaled: u64,
}

struct QueuedEcho {
    echo: ReportEcho,
    /// Failed appends so far.
    attempts: u32,
    /// After a failed append: when the owner tries it again.
    retry_at: Option<Instant>,
}

struct LostEcho {
    /// The journal head when the echo was given up.
    head: u64,
    /// The terminal's roster entry once the cursor passed `head`: the guard
    /// clears when the entry differs from it.
    mark: Option<Option<(String, String, u64)>>,
}

/// One append at a time per terminal, so a terminal's echoes reach the
/// journal in the order its reports committed; other terminals' appends do
/// not wait.
#[derive(Default)]
pub(in crate::mux) struct EchoAppends(Mutex<HashMap<TerminalPublicId, Arc<Mutex<()>>>>);

impl EchoAppends {
    fn turn(&self, terminal_id: &TerminalPublicId) -> Arc<Mutex<()>> {
        let mut turns = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        Arc::clone(turns.entry(terminal_id.clone()).or_default())
    }

    /// Forgets the terminal's turn once nobody holds or waits for it.
    fn release(&self, terminal_id: &TerminalPublicId, turn: Arc<Mutex<()>>) {
        let mut turns = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        drop(turn);
        if turns.get(terminal_id).is_some_and(|turn| Arc::strong_count(turn) == 1) {
            turns.remove(terminal_id);
        }
    }
}

impl ReportEchoes {
    /// Whether `terminal_id` has an echo the roster at `cursor` has not
    /// folded: queued (being appended, or failed), or journaled past it.
    fn unfolded(&self, terminal_id: &TerminalPublicId, cursor: u64) -> bool {
        self.terminals
            .get(terminal_id)
            .is_some_and(|terminal| !terminal.queue.is_empty() || terminal.journaled > cursor)
    }

    fn forget_if_folded(&mut self, terminal_id: &TerminalPublicId, cursor: u64) {
        if !self.unfolded(terminal_id, cursor) {
            self.terminals.remove(terminal_id);
        }
    }
}

/// Whether a hook of `terminal_id` projected past the roster at `cursor`.
fn hook_unfolded(
    fences: &HashMap<TerminalPublicId, HookFence>,
    terminal_id: &TerminalPublicId,
    cursor: u64,
) -> bool {
    fences.get(terminal_id).is_some_and(|fence| fence.sequence > cursor)
}

/// What identifies a roster entry's state for a lost echo.
fn entry_mark(
    entry: Option<&crate::journal_reducers::RosterEntry>,
) -> Option<(String, String, u64)> {
    entry.map(|entry| (entry.state.clone(), entry.source.clone(), entry.updated_at_ms))
}

/// How a terminal's queue is written.
#[derive(Clone, Copy, PartialEq)]
enum Writer {
    /// The reporting thread: it stops at an echo that failed before, which
    /// the owner tries again after its backoff.
    Reporter,
    /// The roster's owner, retrying due echoes; it may give one up.
    Owner,
}

impl Mux {
    fn report_echoes(&self) -> MutexGuard<'_, ReportEchoes> {
        self.agent_roster_worker.report_echoes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn agent_roster_cursor(&self) -> u64 {
        self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner).cursor
    }

    /// A direct report committed its row, under the hook projector's lock:
    /// its echo goes behind the terminal's earlier ones.
    pub(in crate::mux) fn note_report_echo(&self, echo: ReportEcho) {
        let mut echoes = self.report_echoes();
        let terminal = echoes.terminals.entry(echo.terminal_id.clone()).or_default();
        terminal.queue.push_back(QueuedEcho { echo, attempts: 0, retry_at: None });
    }

    /// The reporting thread appends its terminal's queued echoes, its own
    /// among them, then asks the owner to fold them.
    pub(in crate::mux) fn write_report_echoes(&self, terminal_id: &TerminalPublicId) {
        self.drain_report_echoes(terminal_id, Writer::Reporter);
        self.continue_agent_roster_replay_later();
    }

    /// Appends `terminal_id`'s queued echoes in order, in its turn, each
    /// while it stays at the front, so the terminal never looks folded in
    /// between. No other lock is held across an append.
    fn drain_report_echoes(&self, terminal_id: &TerminalPublicId, writer: Writer) {
        let appends = &self.agent_roster_worker.echo_appends;
        let turn = appends.turn(terminal_id);
        let held = turn.lock().unwrap_or_else(PoisonError::into_inner);
        let mut retry = None;
        loop {
            let now = Instant::now();
            let front = {
                let echoes = self.report_echoes();
                let Some(queued) =
                    echoes.terminals.get(terminal_id).and_then(|terminal| terminal.queue.front())
                else {
                    break;
                };
                let waiting =
                    queued.retry_at.is_some_and(|at| writer == Writer::Reporter || at > now);
                if waiting {
                    break;
                }
                (queued.echo.clone(), queued.attempts)
            };
            let (echo, attempts) = front;
            let journaled = self.append_agent_report_echo(&echo);
            let give_up_head =
                (journaled.is_none() && writer == Writer::Owner && attempts + 1 >= ECHO_ATTEMPTS)
                    .then(|| self.session_journal_head().ok())
                    .flatten();
            let mut echoes = self.report_echoes();
            let Some(terminal) = echoes.terminals.get_mut(terminal_id) else { break };
            match (journaled, give_up_head) {
                (Some(sequence), _) => {
                    terminal.queue.pop_front();
                    terminal.journaled = terminal.journaled.max(sequence);
                }
                (None, Some(head)) => {
                    terminal.queue.pop_front();
                    eprintln!(
                        "cmux-tui: gave up journaling an agent report for {terminal_id} after \
                         {ECHO_ATTEMPTS} attempts; its roster entry is unknown until it changes"
                    );
                    echoes.lost.insert(terminal_id.clone(), LostEcho { head, mark: None });
                }
                (None, None) => {
                    let Some(queued) = terminal.queue.front_mut() else { break };
                    queued.attempts += 1;
                    let delay = agent_roster_rebuild::roster_read_retry_delay(queued.attempts);
                    queued.retry_at = Some(Instant::now() + delay);
                    retry = Some(delay);
                    break;
                }
            }
        }
        drop(held);
        appends.release(terminal_id, turn);
        // Read after the record: the owner moves the cursor before it looks
        // at the echoes, so one of the two sees the other.
        let cursor = self.agent_roster_cursor();
        self.report_echoes().forget_if_folded(terminal_id, cursor);
        if let Some(delay) = retry {
            self.retry_agent_roster_replay_after(delay);
        }
    }

    /// Whether `terminal_id`'s roster state may be older than its projected
    /// records: a hook or an echo not folded, a write owed, or an echo given
    /// up. A guarded send to it is refused.
    pub(crate) fn agent_report_unsettled(&self, terminal_id: &TerminalPublicId) -> bool {
        let cursor = self.agent_roster_cursor();
        let fences = self.agent_hook_fences.lock().unwrap_or_else(PoisonError::into_inner);
        if hook_unfolded(&fences, terminal_id, cursor) {
            return true;
        }
        let echoes = self.report_echoes();
        echoes.unfolded(terminal_id, cursor)
            || echoes.owed.contains(terminal_id)
            || echoes.lost.contains_key(terminal_id)
    }

    /// The invariant's check, for a write of `terminal_id`'s projection from
    /// the roster at `cursor`, with the hook projector's lock held (`fences`):
    /// true when it may write now. Otherwise the write is owed to the owner.
    pub(in crate::mux) fn reconcile_may_write(
        &self,
        fences: &HashMap<TerminalPublicId, HookFence>,
        terminal_id: &TerminalPublicId,
        cursor: u64,
    ) -> bool {
        let mut echoes = self.report_echoes();
        if !hook_unfolded(fences, terminal_id, cursor)
            && !echoes.unfolded(terminal_id, cursor)
            && !echoes.lost.contains_key(terminal_id)
        {
            return true;
        }
        echoes.owed.insert(terminal_id.clone());
        drop(echoes);
        self.continue_agent_roster_replay_later();
        false
    }

    /// The owner, after each pass: forgets the echoes the roster folded,
    /// clears a lost echo's guard once a change after its give-up is folded,
    /// and makes the owed writes whose terminals are folded now, under the
    /// hook projector's lock.
    pub(in crate::mux) fn settle_report_echoes(&self) {
        {
            let echoes = self.report_echoes();
            if echoes.terminals.is_empty() && echoes.owed.is_empty() && echoes.lost.is_empty() {
                return;
            }
        }
        // Only the owner moves the cursor, so it stays as read.
        let (cursor, marks, entries) = {
            let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            let echoes = self.report_echoes();
            let marks = echoes
                .lost
                .keys()
                .map(|terminal| {
                    (terminal.clone(), entry_mark(host.roster.entries.get(terminal.as_str())))
                })
                .collect::<Vec<_>>();
            let entries = echoes
                .owed
                .iter()
                .map(|terminal| {
                    let entry = host
                        .roster
                        .entries
                        .get(terminal.as_str())
                        .filter(|entry| reducer_owned(entry))
                        .cloned();
                    (terminal.clone(), entry)
                })
                .collect::<Vec<_>>();
            (host.cursor, marks, entries)
        };
        #[cfg(test)]
        if let Some(seam) = self
            .agent_roster_worker
            .settle_seam
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            seam();
        }
        let fences = self.agent_hook_fences.lock().unwrap_or_else(PoisonError::into_inner);
        let settled = {
            let mut echoes = self.report_echoes();
            let terminals = echoes.terminals.keys().cloned().collect::<Vec<_>>();
            for terminal_id in terminals {
                echoes.forget_if_folded(&terminal_id, cursor);
            }
            for (terminal_id, mark) in marks {
                let Some(lost) = echoes.lost.get_mut(&terminal_id) else { continue };
                if cursor < lost.head {
                    continue;
                }
                match &lost.mark {
                    None => lost.mark = Some(mark),
                    Some(at_head) if *at_head != mark => {
                        echoes.lost.remove(&terminal_id);
                    }
                    Some(_) => {}
                }
            }
            // A stale roster's rebuild, and a replay's own reconcile, write
            // every terminal when they are done.
            let stale = self.agent_roster_stale() || self.agent_roster_replaying();
            let mut settled = Vec::new();
            for (terminal_id, entry) in entries {
                if stale
                    || hook_unfolded(&fences, &terminal_id, cursor)
                    || echoes.unfolded(&terminal_id, cursor)
                    || echoes.lost.contains_key(&terminal_id)
                {
                    continue;
                }
                echoes.owed.remove(&terminal_id);
                settled.extend(entry.map(|entry| (terminal_id, entry)));
            }
            settled
        };
        for (terminal_id, entry) in settled {
            self.reconcile_agent_roster_projection_held(&terminal_id, entry);
        }
        drop(fences);
    }

    /// The owner appends the failed echoes whose retry is due, each terminal
    /// in its turn, then asks for a pass when the next one is due.
    pub(in crate::mux) fn retry_failed_report_echoes(&self) {
        let now = Instant::now();
        let due = {
            let echoes = self.report_echoes();
            echoes
                .terminals
                .iter()
                .filter(|(_, terminal)| {
                    terminal
                        .queue
                        .front()
                        .and_then(|queued| queued.retry_at)
                        .is_some_and(|at| at <= now)
                })
                .map(|(terminal_id, _)| terminal_id.clone())
                .collect::<Vec<_>>()
        };
        for terminal_id in &due {
            self.drain_report_echoes(terminal_id, Writer::Owner);
        }
        let next = self
            .report_echoes()
            .terminals
            .values()
            .filter_map(|terminal| terminal.queue.front().and_then(|queued| queued.retry_at))
            .min();
        if let Some(next) = next {
            self.retry_agent_roster_replay_after(next.saturating_duration_since(Instant::now()));
        }
        if !due.is_empty() {
            self.continue_agent_roster_replay_later();
        }
    }
}
