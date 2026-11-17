//! The health state machine: one entry per registered part, the signals the
//! host fed it, its repair episode, and one shared deadline min-heap.
//!
//! Constant cost as parts grow. Each armed part has at most one live heap
//! entry `(deadline, generation, slot)`; re-arming bumps the generation and
//! pushes a new entry, so an old one is skipped when it surfaces (lazy
//! invalidation), and the heap is rebuilt once dead entries outnumber live
//! ones four to one (amortized O(1) per change). A tick pops only expired
//! entries, so it costs O(expired · log n), never O(parts). A hidden part
//! has no deadline at all, and the snapshot walks only the non-healthy set.
//!
//! Every op re-evaluates the one part it names ([`Health::refresh`]): the
//! part's condition (`healthy`, `slow` or `stuck`, and why) comes from its
//! signals at `nowMs`, with the next time that condition could change on its
//! own as its deadline. Repairs run only from `tick` and `repairNow`, the
//! two ops that return actions; any other op that makes a repair due arms
//! the part's deadline at `nowMs`, so the host's timer fires at once.
//!
//! The repair episode of a stuck part: attempt 1 at once, then attempt `n+1`
//! when the backoff after attempt `n` passes without the part's signal
//! coming back (a `repairResult` with `ok: false` makes it due at once).
//! Past [`policy::MAX_REPAIRS`] attempts in [`policy::REPAIR_WINDOW_MS`] the
//! part is `failed` and waits for the user's click, which clears the cap and
//! starts again at step 1. The episode ends only when the signal comes back
//! (a beat, `responsive`, `connected`, `loaded`), never on a result alone.

use crate::detail::{self, Cause};
use crate::policy;
use crate::{Action, Kind, Outcome, PartView, PendingView, Receipt, RepairAction, Snapshot, State};
use std::cmp::Reverse;
use std::collections::{BTreeSet, BinaryHeap, HashMap, VecDeque};

/// How a stuck part is repaired.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Mode {
    /// Not repaired (`slow`, or a stuck the model only waits out).
    #[default]
    Wait,
    /// The repair ladder with backoff and the cap.
    Ladder(&'static [RepairAction]),
    /// `holdReplace`, once per daemon process.
    Hold,
}

/// A part's condition at one instant, before its repair episode.
#[derive(Debug, Clone, Copy, Default)]
struct Cond {
    /// `Healthy`, `Slow` or `Stuck`.
    level: State,
    cause: Cause,
    mode: Mode,
    /// When the condition can next change without a new signal.
    next: Option<u64>,
}

impl Cond {
    fn at(level: State, cause: Cause, mode: Mode) -> Self {
        Self { level, cause, mode, next: None }
    }

    /// `self` and `other`: the worse condition (the first on a tie), the
    /// earlier of their next changes.
    fn or(self, other: Cond) -> Cond {
        let next = match (self.next, other.next) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let worse = if other.level > self.level { other } else { self };
        Cond { next, ..worse }
    }

    fn until(mut self, at: u64) -> Self {
        self.next = Some(at);
        self
    }
}

/// What the host told the model about one part.
#[derive(Debug, Default)]
struct Signals {
    /// The last beat (or `loaded`, `connected`, a show).
    last_beat: Option<u64>,
    sent: u64,
    handled: u64,
    /// Since when input is sent but not handled.
    input_since: Option<u64>,
    crashed: bool,
    unresponsive_since: Option<u64>,
    disconnected: bool,
    listener_missing: bool,
    load_failures: VecDeque<u64>,
    /// Two `loadFailed` in the window; cleared by `loaded`.
    host_broken: bool,
    /// `started` times since the last `ready`.
    starts: VecDeque<u64>,
    restoring: bool,
    restore_bytes: u64,
    last_progress: u64,
    size: u64,
    roster_since: Option<u64>,
}

/// The repair episode of a part.
#[derive(Debug, Default)]
struct Repair {
    /// Attempts in this episode (0: none yet).
    attempt: u32,
    /// Attempt times inside the cap's window.
    history: VecDeque<u64>,
    /// When the next step is due.
    next_at: Option<u64>,
    /// The last action sent.
    action: RepairAction,
    /// Actions sent to this part, never reset (each [`Action::token`]).
    sent: u64,
    failed: bool,
    /// `holdReplace` was sent for the current daemon process.
    held: bool,
}

#[derive(Debug)]
struct Part {
    id: String,
    kind: Kind,
    label: String,
    visible: bool,
    signals: Signals,
    repair: Repair,
    mode: Mode,
    state: State,
    since_ms: u64,
    detail: String,
    deadline: Option<u64>,
    generation: u64,
}

/// The whole model. One per app; the host holds it under its own lock.
#[derive(Debug, Default)]
pub struct Health {
    slots: Vec<Option<Part>>,
    free: Vec<usize>,
    ids: HashMap<String, usize>,
    heap: BinaryHeap<Reverse<(u64, u64, usize)>>,
    /// Parts with a deadline (live heap entries).
    armed: usize,
    generation: u64,
    /// Ids of the parts that are not healthy (the snapshot's parts).
    unhealthy: BTreeSet<String>,
    /// Newest first, at most [`policy::RECEIPTS`].
    receipts: VecDeque<Receipt>,
    /// Newest first.
    pending: VecDeque<PendingView>,
    /// Heap entries popped by `tick` (the scale test's counter).
    #[cfg(test)]
    pub(crate) visited: u64,
}

/// A receipt before its time and id: action, outcome, words.
type ReceiptParts = (RepairAction, Outcome, String);

fn prune(times: &mut VecDeque<u64>, window: u64, now: u64) {
    while times.front().is_some_and(|&t| t.saturating_add(window) <= now) {
        times.pop_front();
    }
}

/// The condition of `part` at `now` (the daemon's start list is pruned).
fn evaluate(part: &mut Part, now: u64) -> Cond {
    let healthy = Cond::default();
    if !part.visible {
        return healthy;
    }
    let s = &mut part.signals;
    let stuck = |cause, mode| Cond::at(State::Stuck, cause, mode);
    let slow = |cause| Cond::at(State::Slow, cause, Mode::Wait);
    match part.kind {
        Kind::Page => {
            let ladder = Mode::Ladder(policy::PAGE_LADDER);
            if s.crashed {
                return stuck(Cause::PageCrashed, ladder);
            }
            let silence = s.last_beat.map_or(healthy, |beat| {
                let ms = now.saturating_sub(beat);
                if ms >= policy::PAGE_STUCK_MS {
                    stuck(Cause::PageSilent { ms }, ladder)
                } else if ms >= policy::PAGE_SLOW_SILENT_MS {
                    slow(Cause::PageSilent { ms }).until(beat + policy::PAGE_STUCK_MS)
                } else {
                    healthy.until(beat + policy::PAGE_SLOW_SILENT_MS)
                }
            });
            let input = s.input_since.map_or(healthy, |since| {
                let ms = now.saturating_sub(since);
                if ms >= policy::PAGE_STUCK_MS {
                    stuck(Cause::PageInput { ms }, ladder)
                } else if ms >= policy::PAGE_SLOW_INPUT_MS {
                    slow(Cause::PageInput { ms }).until(since + policy::PAGE_STUCK_MS)
                } else {
                    healthy.until(since + policy::PAGE_SLOW_INPUT_MS)
                }
            });
            silence.or(input)
        }
        Kind::Renderer => {
            let ladder = Mode::Ladder(policy::RENDERER_LADDER);
            if s.crashed {
                return stuck(Cause::RendererCrashed, ladder);
            }
            s.unresponsive_since.map_or(healthy, |since| {
                let ms = now.saturating_sub(since);
                if ms >= policy::RENDERER_STUCK_MS {
                    stuck(Cause::RendererUnresponsive { ms }, ladder)
                } else {
                    healthy.until(since + policy::RENDERER_STUCK_MS)
                }
            })
        }
        Kind::Acpmux => {
            let ladder = Mode::Ladder(policy::ACPMUX_LADDER);
            if s.disconnected {
                return stuck(Cause::AcpmuxDisconnected, ladder);
            }
            s.last_beat.map_or(healthy, |beat| {
                let ms = now.saturating_sub(beat);
                if ms >= policy::ACPMUX_SILENT_MS {
                    stuck(Cause::AcpmuxSilent { ms }, ladder)
                } else {
                    healthy.until(beat + policy::ACPMUX_SILENT_MS)
                }
            })
        }
        Kind::PageHost => {
            let ladder = Mode::Ladder(policy::PAGE_HOST_LADDER);
            if s.listener_missing {
                stuck(Cause::HostListenerMissing, ladder)
            } else if s.host_broken {
                stuck(Cause::HostLoadFailed, ladder)
            } else {
                healthy
            }
        }
        Kind::SessionDaemon => {
            prune(&mut s.starts, policy::DAEMON_LOOP_WINDOW_MS, now);
            let starts = s.starts.len();
            let loop_starts = starts.checked_sub(policy::DAEMON_LOOP_STARTS).and_then(|third| {
                Some((*s.starts.front()?, *s.starts.back()?, *s.starts.get(third)?))
            });
            let looping = if let Some((first, last, third)) = loop_starts {
                let span_ms = last - first;
                // Ends when the third newest start leaves the window.
                let ends = third + policy::DAEMON_LOOP_WINDOW_MS;
                stuck(Cause::DaemonLoop { starts, span_ms }, Mode::Hold).until(ends)
            } else {
                healthy
            };
            let restore = if s.restoring {
                let ms = now.saturating_sub(s.last_progress);
                let bytes = s.restore_bytes;
                if ms >= policy::DAEMON_STALL_MS {
                    stuck(Cause::DaemonStalled { bytes, ms }, Mode::Wait)
                } else {
                    slow(Cause::DaemonRestoring { bytes, total: s.size })
                        .until(s.last_progress + policy::DAEMON_STALL_MS)
                }
            } else {
                healthy
            };
            let size = if s.size > policy::DAEMON_OVERSIZE_BYTES {
                slow(Cause::DaemonOversize { bytes: s.size })
            } else {
                healthy
            };
            looping.or(restore).or(size)
        }
        Kind::Roster => s.roster_since.map_or(healthy, |since| {
            let ms = now.saturating_sub(since);
            if ms >= policy::ROSTER_STUCK_MS {
                stuck(Cause::RosterStuck { ms }, Mode::Wait)
            } else if ms >= policy::ROSTER_SLOW_MS {
                slow(Cause::RosterSlow { ms }).until(since + policy::ROSTER_STUCK_MS)
            } else {
                healthy.until(since + policy::ROSTER_SLOW_MS)
            }
        }),
    }
}

fn earliest(a: Option<u64>, b: Option<u64>) -> Option<u64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

impl Health {
    pub fn new() -> Self {
        Self::default()
    }

    fn slot(&self, id: &str) -> Option<usize> {
        self.ids.get(id).copied()
    }

    /// Whether `slot` still holds the part whose deadline carried `generation`.
    fn is_live(&self, slot: usize, generation: u64) -> bool {
        self.slots.get(slot).and_then(Option::as_ref).is_some_and(|p| p.generation == generation)
    }

    /// The live part in `slot`; `None` only for a slot freed by `unregister`.
    fn part(&mut self, slot: usize) -> Option<&mut Part> {
        self.slots.get_mut(slot)?.as_mut()
    }

    /// Adds a part (or renames one already known). With `now` it is armed
    /// from then; without, from its first signal. `visible: false` registers
    /// it hidden, never timed.
    pub fn register(&mut self, id: &str, kind: Kind, label: &str, now: Option<u64>, visible: bool) {
        if let Some(slot) = self.slot(id) {
            if let Some(part) = self.part(slot) {
                part.label = label.to_string();
            }
            return;
        }
        let part = Part {
            id: id.to_string(),
            kind,
            label: label.to_string(),
            visible,
            signals: Signals { last_beat: now, ..Signals::default() },
            repair: Repair::default(),
            mode: Mode::Wait,
            state: State::Healthy,
            since_ms: now.unwrap_or(0),
            detail: String::new(),
            deadline: None,
            generation: 0,
        };
        let slot = match self.free.pop() {
            Some(slot) => match self.slots.get_mut(slot) {
                Some(free) => {
                    *free = Some(part);
                    slot
                }
                None => {
                    self.slots.push(Some(part));
                    self.slots.len() - 1
                }
            },
            None => {
                self.slots.push(Some(part));
                self.slots.len() - 1
            }
        };
        self.ids.insert(id.to_string(), slot);
        if let Some(now) = now {
            self.refresh(slot, now, None);
        }
    }

    pub fn unregister(&mut self, id: &str) {
        let Some(slot) = self.ids.remove(id) else { return };
        self.set_deadline(slot, None);
        if let Some(freed) = self.slots.get_mut(slot) {
            *freed = None;
            self.free.push(slot);
        }
        self.unhealthy.remove(id);
    }

    /// Changes `id`'s signals with `change`, then re-evaluates it.
    fn signal(&mut self, id: &str, now: u64, change: impl FnOnce(&mut Part)) {
        let Some(slot) = self.slot(id) else { return };
        let Some(part) = self.part(slot) else { return };
        change(part);
        self.refresh(slot, now, None);
    }

    pub fn beat(&mut self, id: &str, now: u64) {
        self.signal(id, now, |part| {
            let s = &mut part.signals;
            s.last_beat = Some(now);
            s.crashed = false;
            s.disconnected = false;
        });
    }

    /// The host's input counters (monotonic): sent and handled.
    pub fn input(&mut self, id: &str, sent: u64, handled: u64, now: u64) {
        self.signal(id, now, |part| {
            let s = &mut part.signals;
            s.sent = sent;
            s.handled = handled;
            if handled >= sent {
                s.input_since = None;
            } else if s.input_since.is_none() {
                s.input_since = Some(now);
            }
        });
    }

    /// Hidden: never timed, and its episode is dropped (a hidden page is not
    /// judged). Shown: armed from `now`.
    pub fn visibility(&mut self, id: &str, visible: bool, now: u64) {
        self.signal(id, now, |part| {
            if part.visible == visible {
                return;
            }
            part.visible = visible;
            let r = &mut part.repair;
            (r.attempt, r.next_at, r.failed, r.action) = (0, None, false, RepairAction::None);
            if visible {
                let s = &mut part.signals;
                s.last_beat = Some(now);
                s.input_since = s.input_since.map(|_| now);
                s.unresponsive_since = s.unresponsive_since.map(|_| now);
            }
        });
    }

    /// One event; an unknown name is ignored (a newer host).
    pub fn event(&mut self, id: &str, event: &str, now: u64, value: Option<u64>) {
        self.signal(id, now, |part| {
            let s = &mut part.signals;
            match event {
                "crashed" => s.crashed = true,
                "loaded" => {
                    // A page that loaded answers; its old input died with it.
                    s.crashed = false;
                    s.last_beat = Some(now);
                    s.handled = s.sent;
                    s.input_since = None;
                    s.listener_missing = false;
                    s.host_broken = false;
                    s.load_failures.clear();
                }
                "unresponsive" => {
                    s.unresponsive_since.get_or_insert(now);
                }
                "responsive" => {
                    s.unresponsive_since = None;
                    s.crashed = false;
                }
                "connected" => {
                    s.disconnected = false;
                    s.last_beat = Some(now);
                }
                "disconnected" => s.disconnected = true,
                "loadFailed" => {
                    prune(&mut s.load_failures, policy::PAGE_HOST_FAIL_WINDOW_MS, now);
                    s.load_failures.push_back(now);
                    if s.load_failures.len() >= policy::PAGE_HOST_FAILS {
                        s.host_broken = true;
                    }
                }
                "listenerMissing" => s.listener_missing = true,
                "started" => {
                    s.starts.push_back(now);
                    // Bounded: only the newest few matter to the loop rule.
                    while s.starts.len() > 4 * policy::DAEMON_LOOP_STARTS {
                        s.starts.pop_front();
                    }
                    (s.restoring, s.restore_bytes) = (false, 0);
                    // A new process: tell the launcher again if it loops.
                    part.repair.held = false;
                }
                "ready" => {
                    s.starts.clear();
                    s.restoring = false;
                }
                "exited" => s.restoring = false,
                // With bytes read, only more bytes is progress. Without (a daemon whose progress
                // line has no work counters yet), each line says the owner is still restoring;
                // its own no-work bound ends a stuck one.
                "restoreProgress" => match value {
                    Some(bytes) if s.restoring && bytes <= s.restore_bytes => {}
                    Some(bytes) => {
                        s.restoring = true;
                        s.restore_bytes = bytes;
                        s.last_progress = now;
                    }
                    None => {
                        s.restoring = true;
                        s.last_progress = now;
                    }
                },
                "restoreStarted" => {
                    s.roster_since.get_or_insert(now);
                }
                "restoreFinished" => s.roster_since = None,
                _ => {}
            }
        });
    }

    /// Bytes on disk (the daemon's registry + WAL + output cleanup).
    pub fn size(&mut self, id: &str, bytes: u64, now: u64) {
        self.signal(id, now, |part| part.signals.size = bytes);
    }

    /// The host ran `action` for `id`. A result for an older step is ignored:
    /// with `token` (the action's own) exactly, without by its action alone.
    /// `ok` alone never heals a part; `ok: false` makes the next step due now.
    pub fn repair_result(
        &mut self,
        id: &str,
        action: RepairAction,
        token: Option<u64>,
        ok: bool,
        now: u64,
    ) {
        let Some(slot) = self.slot(id) else { return };
        let Some(part) = self.part(slot) else { return };
        let stale = token.is_some_and(|token| token != part.repair.sent);
        if part.repair.attempt == 0 || part.repair.action != action || stale {
            return;
        }
        if !ok && part.repair.next_at.is_some() {
            part.repair.next_at = Some(now);
        }
        let outcome = if ok { Outcome::Ok } else { Outcome::Failed };
        let receipt = (action, outcome, detail::receipt_result(ok));
        self.receipt(id.to_string(), now, receipt);
        self.refresh(slot, now, None);
    }

    /// The user's one click: clears the cap and starts the ladder at step 1.
    /// Only a part the ladder repairs, while stuck, repairing or failed.
    pub fn repair_now(&mut self, id: &str, now: u64) -> Vec<Action> {
        let mut actions = Vec::new();
        let Some(slot) = self.slot(id) else { return actions };
        let Some(part) = self.part(slot) else { return actions };
        let repairable = matches!(part.mode, Mode::Ladder(_))
            && matches!(part.state, State::Stuck | State::Repairing | State::Failed);
        if repairable {
            // `sent` never resets: a result for the action still out cannot match the click's.
            part.repair =
                Repair { held: part.repair.held, sent: part.repair.sent, ..Repair::default() };
            self.refresh(slot, now, Some(&mut actions));
        }
        actions
    }

    /// Runs every expired deadline; the actions for the host.
    pub fn tick(&mut self, now: u64) -> Vec<Action> {
        let mut due = Vec::new();
        while let Some(&Reverse((deadline, generation, slot))) = self.heap.peek() {
            if deadline > now {
                break;
            }
            self.heap.pop();
            #[cfg(test)]
            {
                self.visited += 1;
            }
            let live = self.is_live(slot, generation);
            if live {
                due.push(slot);
            }
        }
        // Disarm all of them first, so a heap rebuild while one is refreshed
        // cannot bring back another's expired entry.
        for &slot in &due {
            self.set_deadline(slot, None);
        }
        let mut actions = Vec::new();
        for slot in due {
            self.refresh(slot, now, Some(&mut actions));
        }
        actions
    }

    /// The earliest live deadline: the host's one timer. `None`: no timer.
    pub fn next_tick_ms(&mut self) -> Option<u64> {
        while let Some(&Reverse((deadline, generation, slot))) = self.heap.peek() {
            if self.is_live(slot, generation) {
                return Some(deadline);
            }
            self.heap.pop();
        }
        None
    }

    /// A user action the host queued (newest first).
    pub fn pending(&mut self, id: &str, label: &str, now: u64) {
        self.pending.retain(|p| p.id != id);
        self.pending.push_front(PendingView { id: id.into(), label: label.into(), since_ms: now });
    }

    pub fn pending_done(&mut self, id: &str) {
        self.pending.retain(|p| p.id != id);
    }

    pub fn snapshot(&self) -> Snapshot {
        let parts: Vec<PartView> = self
            .unhealthy
            .iter()
            .filter_map(|id| self.slots.get(*self.ids.get(id)?)?.as_ref())
            .map(|p| PartView {
                id: p.id.clone(),
                kind: p.kind,
                label: p.label.clone(),
                state: p.state,
                since_ms: p.since_ms,
                detail: p.detail.clone(),
                action: match (p.state, p.mode) {
                    (State::Repairing | State::Failed, _) => p.repair.action,
                    (State::Stuck, Mode::Hold) => RepairAction::HoldReplace,
                    _ => RepairAction::None,
                },
                attempt: p.repair.attempt,
                max_attempts: if matches!(p.mode, Mode::Ladder(_)) {
                    policy::MAX_REPAIRS
                } else {
                    0
                },
                next_at_ms: if p.state == State::Repairing { p.repair.next_at } else { None },
                can_repair: matches!(p.mode, Mode::Ladder(_))
                    && matches!(p.state, State::Stuck | State::Repairing | State::Failed),
            })
            .collect();
        Snapshot {
            worst: parts.iter().map(|p| p.state).max().unwrap_or_default(),
            parts,
            receipts: self.receipts.iter().cloned().collect(),
            pending: self.pending.iter().take(policy::PENDING_SHOWN).cloned().collect(),
            pending_more: self.pending.len().saturating_sub(policy::PENDING_SHOWN),
        }
    }

    fn receipt(&mut self, id: String, at_ms: u64, receipt: ReceiptParts) {
        let (action, outcome, detail) = receipt;
        self.receipts.push_front(Receipt { at_ms, id, action, outcome, detail });
        self.receipts.truncate(policy::RECEIPTS);
    }

    /// Re-evaluates one part at `now`: its state, detail and deadline. With
    /// `actions` (tick, repairNow) a due repair runs; without, it is armed at
    /// `now` for the host's next tick.
    fn refresh(&mut self, slot: usize, now: u64, mut actions: Option<&mut Vec<Action>>) {
        let mut receipts: Vec<ReceiptParts> = Vec::new();
        let Some(part) = self.part(slot) else { return };
        let cond = evaluate(part, now);
        let mut deadline = cond.next;
        let kind = part.kind;
        let r = &mut part.repair;
        let state = match (cond.level, cond.mode) {
            (State::Stuck, Mode::Ladder(ladder)) => {
                let due = r.attempt == 0 || r.next_at.is_some_and(|at| at <= now);
                if r.failed {
                    State::Failed
                } else if !due {
                    State::Repairing
                } else if let Some(out) = actions.as_deref_mut() {
                    prune(&mut r.history, policy::REPAIR_WINDOW_MS, now);
                    if r.history.len() >= policy::MAX_REPAIRS as usize {
                        (r.failed, r.next_at) = (true, None);
                        let words = detail::receipt_gave_up(policy::MAX_REPAIRS);
                        receipts.push((r.action, Outcome::GaveUp, words));
                        State::Failed
                    } else {
                        r.attempt += 1;
                        r.history.push_back(now);
                        r.action = policy::step(ladder, r.attempt);
                        r.next_at = Some(now + policy::backoff(r.attempt));
                        r.sent += 1;
                        let (action, attempt, token) = (r.action, r.attempt, r.sent);
                        out.push(Action { id: part.id.clone(), kind, action, attempt, token });
                        let words =
                            detail::receipt_started(kind, action, attempt, policy::MAX_REPAIRS);
                        receipts.push((action, Outcome::Started, words));
                        State::Repairing
                    }
                } else {
                    deadline = Some(now);
                    if r.attempt == 0 { State::Stuck } else { State::Repairing }
                }
            }
            (State::Stuck, Mode::Hold) => {
                if !r.held {
                    if let Some(out) = actions {
                        r.held = true;
                        r.attempt += 1;
                        r.action = RepairAction::HoldReplace;
                        r.sent += 1;
                        let (id, token) = (part.id.clone(), r.sent);
                        out.push(Action { id, kind, action: r.action, attempt: r.attempt, token });
                        let words = detail::receipt_started(kind, r.action, r.attempt, 0);
                        receipts.push((r.action, Outcome::Started, words));
                    } else {
                        deadline = Some(now);
                    }
                }
                State::Stuck
            }
            (level, _) => {
                // Not a stuck the model repairs: any episode is over.
                if r.attempt > 0 || r.failed {
                    if level == State::Healthy {
                        receipts.push((r.action, Outcome::Ok, detail::receipt_recovered(kind)));
                    }
                    (r.attempt, r.next_at, r.failed) = (0, None, false);
                    r.action = RepairAction::None;
                }
                level
            }
        };
        if state == State::Repairing {
            deadline = earliest(deadline, r.next_at);
        }
        part.detail = match state {
            State::Healthy => String::new(),
            State::Repairing => {
                detail::repairing(kind, cond.cause, r.action, r.attempt, policy::MAX_REPAIRS)
            }
            State::Failed => detail::failed(kind, cond.cause, policy::MAX_REPAIRS),
            State::Slow | State::Stuck => detail::cause(cond.cause),
        };
        part.mode = cond.mode;
        if part.state != state {
            part.state = state;
            part.since_ms = now;
        }
        let id = part.id.clone();
        if state == State::Healthy {
            self.unhealthy.remove(&id);
        } else if !self.unhealthy.contains(&id) {
            self.unhealthy.insert(id.clone());
        }
        for receipt in receipts {
            self.receipt(id.clone(), now, receipt);
        }
        self.set_deadline(slot, deadline);
    }

    fn set_deadline(&mut self, slot: usize, deadline: Option<u64>) {
        self.generation += 1;
        let generation = self.generation;
        let Some(part) = self.part(slot) else { return };
        if part.deadline == deadline {
            return;
        }
        let was_armed = part.deadline.is_some();
        part.deadline = deadline;
        part.generation = generation;
        if was_armed {
            self.armed -= 1;
        }
        if let Some(at) = deadline {
            self.armed += 1;
            self.heap.push(Reverse((at, generation, slot)));
        }
        // Dead entries past four to one: rebuild from the live deadlines.
        if self.heap.len() > 64 && self.heap.len() > 4 * self.armed {
            let live = self.slots.iter().enumerate().filter_map(|(slot, part)| {
                let part = part.as_ref()?;
                Some(Reverse((part.deadline?, part.generation, slot)))
            });
            self.heap = live.collect();
        }
    }

    /// Parts with a live deadline, and heap entries (tests).
    #[cfg(test)]
    pub(crate) fn heap_sizes(&self) -> (usize, usize) {
        (self.armed, self.heap.len())
    }
}
