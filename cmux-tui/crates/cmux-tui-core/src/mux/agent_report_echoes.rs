//! The journal echoes of direct agent reports, from a report's commit until
//! the roster folded its echo.
//!
//! A direct report commits its projection under the hook projector's lock
//! (`agent_hook_fences`) and appends its echo, the record the roster folds,
//! after releasing it; the roster's owner folds the echo later. Until the
//! roster's cursor reached the echo, the roster holds the agent's state from
//! before the report, so for that terminal:
//! - a guarded send (`expect_agent`) is refused;
//! - a projection reconcile does not write the roster's entry over the
//!   report's row: it leaves the terminal to the owner, which reconciles it
//!   once the echo is folded, and then the entry is the reducer's own
//!   verdict on the report (its source precedence included);
//! - an echo whose append failed is appended again by the owner, with the
//!   same idempotency key, after the roster's read backoff, unless a later
//!   report of the terminal supersedes it. After [`ECHO_ATTEMPTS`] it is
//!   given up: the terminal's roster entry is unknown, its projection stays
//!   as the report left it, and its guarded sends stay refused until the
//!   roster's entry for it changes.
//!
//! #39830 review, rounds 2 to 4: a fence that kept a report's row whatever
//! the reducer folded, a counter that let go at the append, not the fold,
//! and a failed echo retried forever all disagreed with the reducer. Every
//! check here asks where the roster's cursor is.

use super::*;

/// Appends of one failed echo before it is given up.
#[cfg(not(test))]
const ECHO_ATTEMPTS: u32 = 8;
#[cfg(test)]
const ECHO_ATTEMPTS: u32 = 3;

/// A direct report's journal echo ([`Mux::append_agent_report_echo`]).
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
    /// Numbers the reports of every terminal, in commit order.
    numbered: u64,
    /// Echoes whose append failed, oldest first.
    failed: Vec<FailedEcho>,
    /// Terminals whose projection a reconcile left while their echo was not
    /// folded: the owner reconciles each once it is.
    owed: HashSet<TerminalPublicId>,
    /// Terminals whose echo was given up, with their roster entry then
    /// (`entry_mark`): unknown until that entry changes.
    lost: HashMap<TerminalPublicId, Option<(String, String, u64)>>,
}

#[derive(Default)]
struct TerminalEchoes {
    /// The terminal's last committed direct report.
    latest: u64,
    /// Its echoes being appended now.
    appending: usize,
    /// The highest journal sequence of its echoes the roster may not have
    /// folded yet.
    journaled: u64,
}

struct FailedEcho {
    number: u64,
    echo: ReportEcho,
    attempts: u32,
    retry_at: Instant,
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
    /// folded: being appended, failed, or journaled past the cursor.
    fn unfolded(&self, terminal_id: &TerminalPublicId, cursor: u64) -> bool {
        self.terminals.get(terminal_id).is_some_and(|terminal| {
            terminal.appending > 0
                || terminal.journaled > cursor
                || self.failed.iter().any(|failed| &failed.echo.terminal_id == terminal_id)
        })
    }

    fn forget_if_folded(&mut self, terminal_id: &TerminalPublicId, cursor: u64) {
        if !self.unfolded(terminal_id, cursor) {
            self.terminals.remove(terminal_id);
        }
    }
}

/// What identifies a roster entry's state for a lost echo: it is known again
/// once this changes.
fn entry_mark(
    entry: Option<&crate::journal_reducers::RosterEntry>,
) -> Option<(String, String, u64)> {
    entry.map(|entry| (entry.state.clone(), entry.source.clone(), entry.updated_at_ms))
}

impl Mux {
    fn report_echoes(&self) -> MutexGuard<'_, ReportEchoes> {
        self.agent_roster_worker.report_echoes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn agent_roster_cursor(&self) -> u64 {
        self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner).cursor
    }

    /// A direct report of `terminal_id` committed, under the hook projector's
    /// lock: its echo is unfolded until the roster's cursor passed it.
    pub(in crate::mux) fn note_report_echo(&self, terminal_id: &TerminalPublicId) -> u64 {
        let mut echoes = self.report_echoes();
        echoes.numbered += 1;
        let number = echoes.numbered;
        let terminal = echoes.terminals.entry(terminal_id.clone()).or_default();
        terminal.latest = number;
        terminal.appending += 1;
        number
    }

    /// Appends report `number`'s echo in its terminal's turn, unless a later
    /// report of the terminal committed since (its echo carries the newer
    /// state, and an older one must not fold after it). A failed append is
    /// kept for the owner to try again after the roster's read backoff.
    pub(in crate::mux) fn write_report_echo(&self, number: u64, echo: ReportEcho) {
        let appends = &self.agent_roster_worker.echo_appends;
        let turn = appends.turn(&echo.terminal_id);
        let held = turn.lock().unwrap_or_else(PoisonError::into_inner);
        let latest = self.report_echoes().terminals.get(&echo.terminal_id).map(|t| t.latest);
        let journaled = if latest == Some(number) {
            self.append_agent_report_echo(&echo).map(Some).ok_or(())
        } else {
            Ok(None)
        };
        let terminal_id = echo.terminal_id.clone();
        let retry = {
            let mut echoes = self.report_echoes();
            if let Some(terminal) = echoes.terminals.get_mut(&terminal_id) {
                terminal.appending = terminal.appending.saturating_sub(1);
                if let Ok(Some(sequence)) = journaled {
                    terminal.journaled = terminal.journaled.max(sequence);
                }
            }
            match journaled {
                Ok(_) => {
                    echoes.failed.retain(|failed| {
                        failed.echo.terminal_id != terminal_id || failed.number > number
                    });
                    None
                }
                Err(()) => {
                    let delay = agent_roster_rebuild::roster_read_retry_delay(1);
                    let retry_at = Instant::now() + delay;
                    echoes.failed.push(FailedEcho { number, echo, attempts: 1, retry_at });
                    Some(delay)
                }
            }
        };
        drop(held);
        appends.release(&terminal_id, turn);
        // Read after the record: the owner moves the cursor before it looks
        // at the echoes, so one of the two sees the other.
        let cursor = self.agent_roster_cursor();
        self.report_echoes().forget_if_folded(&terminal_id, cursor);
        match retry {
            Some(delay) => self.retry_agent_roster_replay_after(delay),
            None => self.continue_agent_roster_replay_later(),
        }
    }

    /// Whether `terminal_id`'s roster state is not the reducer's verdict on
    /// its last direct report yet: an echo not folded, a reconcile owed, or
    /// an echo given up. A guarded send to it is refused.
    pub(crate) fn agent_report_unsettled(&self, terminal_id: &TerminalPublicId) -> bool {
        let cursor = self.agent_roster_cursor();
        let echoes = self.report_echoes();
        echoes.unfolded(terminal_id, cursor)
            || echoes.owed.contains(terminal_id)
            || echoes.lost.contains_key(terminal_id)
    }

    /// For a projection reconcile under the hook projector's lock, with the
    /// roster at `cursor`: whether it may write `terminal_id`'s roster entry
    /// now. A terminal whose echo is not folded is left for the owner
    /// (`settle_report_echoes`), and one whose echo was given up keeps its
    /// projection.
    pub(in crate::mux) fn reconcile_may_write(
        &self,
        terminal_id: &TerminalPublicId,
        cursor: u64,
    ) -> bool {
        let mut echoes = self.report_echoes();
        if echoes.lost.contains_key(terminal_id) {
            return false;
        }
        if echoes.unfolded(terminal_id, cursor) {
            echoes.owed.insert(terminal_id.clone());
            drop(echoes);
            self.continue_agent_roster_replay_later();
            return false;
        }
        true
    }

    /// The owner, after each pass: forgets the echoes the roster folded,
    /// a lost echo's terminal whose entry changed, and reconciles the owed
    /// terminals whose echoes are folded now, under the hook projector's
    /// lock (no report commits meanwhile).
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
                if echoes.lost.get(&terminal_id).is_some_and(|lost| *lost != mark) {
                    echoes.lost.remove(&terminal_id);
                }
            }
            // A stale roster's rebuild, and a replay's own reconcile, write
            // every terminal when they are done.
            let stale = self.agent_roster_stale() || self.agent_roster_replaying();
            let mut settled = Vec::new();
            for (terminal_id, entry) in entries {
                if stale || echoes.unfolded(&terminal_id, cursor) {
                    continue;
                }
                echoes.owed.remove(&terminal_id);
                if !echoes.lost.contains_key(&terminal_id) {
                    settled.extend(entry.map(|entry| (terminal_id, entry)));
                }
            }
            settled
        };
        for (terminal_id, entry) in settled {
            self.reconcile_agent_roster_projection_held(&terminal_id, entry);
        }
        drop(fences);
    }

    /// The owner appends the failed echoes whose retry is due, oldest first,
    /// each in its terminal's turn and only while it is still the terminal's
    /// last report. One that failed [`ECHO_ATTEMPTS`] times is given up.
    /// No lock but the terminal's turn is held across an append.
    pub(in crate::mux) fn retry_failed_report_echoes(&self) {
        let now = Instant::now();
        let due = {
            let mut echoes = self.report_echoes();
            let (due, later) = std::mem::take(&mut echoes.failed)
                .into_iter()
                .partition::<Vec<_>, _>(|failed| failed.retry_at <= now);
            echoes.failed = later;
            // Out of the failed list until its append ends, so it counts as
            // being appended: its terminal never looks folded in between.
            for failed in &due {
                echoes.terminals.entry(failed.echo.terminal_id.clone()).or_default().appending += 1;
            }
            due
        };
        let appends = &self.agent_roster_worker.echo_appends;
        for mut failed in due {
            let terminal_id = failed.echo.terminal_id.clone();
            let turn = appends.turn(&terminal_id);
            let held = turn.lock().unwrap_or_else(PoisonError::into_inner);
            let latest = self.report_echoes().terminals.get(&terminal_id).map(|t| t.latest);
            let journaled = if latest == Some(failed.number) {
                self.append_agent_report_echo(&failed.echo).map(Some).ok_or(())
            } else {
                Ok(None)
            };
            let lost_mark =
                (journaled.is_err() && failed.attempts + 1 >= ECHO_ATTEMPTS).then(|| {
                    let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
                    entry_mark(host.roster.entries.get(terminal_id.as_str()))
                });
            {
                let mut echoes = self.report_echoes();
                if let Some(terminal) = echoes.terminals.get_mut(&terminal_id) {
                    terminal.appending = terminal.appending.saturating_sub(1);
                }
                match journaled {
                    Ok(sequence) => {
                        if let (Some(sequence), Some(terminal)) =
                            (sequence, echoes.terminals.get_mut(&terminal_id))
                        {
                            terminal.journaled = terminal.journaled.max(sequence);
                        }
                    }
                    Err(()) => match lost_mark {
                        Some(mark) => {
                            eprintln!(
                                "cmux-tui: gave up journaling an agent report for {terminal_id} \
                                 after {ECHO_ATTEMPTS} attempts; its roster entry is unknown \
                                 until it changes"
                            );
                            echoes.lost.insert(terminal_id.clone(), mark);
                            echoes.owed.remove(&terminal_id);
                        }
                        None => {
                            failed.attempts += 1;
                            failed.retry_at = Instant::now()
                                + agent_roster_rebuild::roster_read_retry_delay(failed.attempts);
                            echoes.failed.push(failed);
                        }
                    },
                }
            }
            drop(held);
            appends.release(&terminal_id, turn);
            let cursor = self.agent_roster_cursor();
            self.report_echoes().forget_if_folded(&terminal_id, cursor);
        }
        let next = self.report_echoes().failed.iter().map(|failed| failed.retry_at).min();
        if let Some(next) = next {
            self.retry_agent_roster_replay_after(next.saturating_duration_since(Instant::now()));
        }
    }
}
