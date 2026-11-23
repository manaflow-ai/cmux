//! Reconstruct in-flight host work and replay cursors from the durable journal.
//!
//! Each read is a fold of the log's records ([`EnvFold`], [`HostSeqFold`], the seeded
//! [`SubagentTree`], [`WorkFold`]), stepped one head at a time, so an adoption resumes them from
//! the chat's adoption checkpoint (`checkpoint.rs`) and reads only the records after it.

use super::checkpoint::{Checkpoint, FoldInputs, Folds};
use super::*;
use crate::store::RecordHead;
use crate::subagents::SubagentTree;
use std::collections::HashSet;

impl Hub {
    pub(super) fn recovery_work(
        &self,
        session: &Session,
        incarnation: &str,
        resume_after: u64,
    ) -> OpenWork {
        // Every record through it is whole: no append was under way. Read (and the log's tail
        // past the saved meta counted) before the permissions lock, which an append may hold
        // the append lock to take.
        self.catch_up(session);
        let settled = self.settled_seq(session);
        // A withdrawal either precedes this snapshot in the log or waits
        // on this lock until its recovered request has been admitted.
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let (mut work, checkpoint) =
            self.fold_open_work(session, incarnation, Fold::Resume { settled: Some(settled) });
        // Requests after the resume point were replayed into the live
        // inbound loop and are handled there; only earlier ones were the
        // previous daemon's to answer.
        work.requests.retain(|(_, _, _, h)| h.is_none_or(|h| h <= resume_after));
        for (id, kind, _, _) in &work.requests {
            if kind == method::SESSION_REQUEST_PERMISSION {
                state.active_requests.insert(
                    super::super::permission_groups::AgentRequestKey::new(Some(incarnation), id),
                );
            }
        }
        drop(state);
        // The next adoption of this host reads only what follows it.
        if let Some(checkpoint) = checkpoint {
            self.save_adoption_checkpoint(session, checkpoint);
        }
        work
    }

    pub(super) fn remote_host_env_current(&self, session: &Session, incarnation: &str) -> bool {
        let (from, mut fold) = self.resume_fold(session, incarnation, |f| f.env);
        let _ = self.scan_adoption(session, from, &mut |head| {
            fold.step(head, incarnation);
            true
        });
        fold.current
    }

    /// Largest `hostSeq` logged under host `incarnation`.
    pub(super) fn last_host_seq(&self, session: &Session, incarnation: &str) -> u64 {
        let (from, mut fold) = self.resume_fold(session, incarnation, |f| f.host_seq);
        let _ = self.scan_adoption(session, from, &mut |head| {
            fold.step(head, incarnation);
            true
        });
        // And the `seq` of the record that holds it.
        let (last, at) = (fold.last, fold.at);
        if last > 0 && !self.logs_host_seq(session, at, last) {
            return self.last_host_seq_parsed(session, incarnation);
        }
        last
    }

    /// `last_host_seq` from whole records only.
    pub(super) fn last_host_seq_parsed(&self, session: &Session, incarnation: &str) -> u64 {
        let mut last = 0;
        let mut current = false;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            if e.dir == "mux" && e.kind == "host_started" {
                current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                if current {
                    last = 0;
                }
            } else if current
                && host_seq_matches(&e, incarnation)
                && let Some(h) = e.host_seq
            {
                last = last.max(h);
            }
            true
        });
        last
    }

    /// Whether record `seq` is whole and logs host entry `host_seq`. A head is read from the
    /// line's bytes; a line a crash cut short reads none of its own, or another record's
    /// `hostSeq`, which a whole-record read skips. Reads back from the end of the records
    /// through `seq` (`record_at`), not `seq`'s segment from its start: a resumed adoption reads
    /// what follows its checkpoint, and up to a segment more here.
    fn logs_host_seq(&self, session: &Session, seq: u64, host_seq: u64) -> bool {
        seq > 0 && self.record_at(session, seq).is_some_and(|e| e.host_seq == Some(host_seq))
    }

    /// The subagents `session`'s log started and which of them still run, as the tap followed
    /// them live (`work_below.rs` `seed_subagents`).
    pub(in crate::hub) fn subagents_from_log(
        &self,
        session: &Session,
        incarnation: &str,
    ) -> SubagentTree {
        let (from, mut tree) = self.resume_fold(session, incarnation, |f| f.subagents);
        let _ = self.scan_adoption(session, from, &mut |head| {
            seed_step(&mut tree, head);
            true
        });
        tree
    }

    /// Fold `F` of `session`'s adoption checkpoint for `incarnation` and the seq to read on
    /// from; a new fold and 0 without one.
    fn resume_fold<F>(
        &self,
        session: &Session,
        incarnation: &str,
        fold: impl FnOnce(Folds) -> F,
    ) -> ((u64, Option<crate::store::LinePos>), F) {
        // A checkpoint past the seq the chat knows is not used: its log ran ahead of its saved
        // meta after a hard stop, counted once here as the first append would.
        self.catch_up(session);
        let inputs = self.fold_inputs(session);
        match self.adoption_checkpoint(session, incarnation, &inputs) {
            Some(Checkpoint { seq, next, folds, .. }) => ((seq + 1, next), fold(folds)),
            None => ((0, None), fold(Folds::new(&inputs))),
        }
    }

    /// The heads of `session`'s records from `from.0` on (its line at `from.1` when known).
    fn scan_adoption(
        &self,
        session: &Session,
        from: (u64, Option<crate::store::LinePos>),
        visit: &mut dyn FnMut(&RecordHead<'_>) -> bool,
    ) -> anyhow::Result<()> {
        self.store.scan_heads_from(&session.id, from.0, from.1, &mut |head, _| visit(head))
    }

    /// Scan the log for the work in flight under host `incarnation`. Agent
    /// requests, answers and permission records count only within this
    /// incarnation: every harness restarts its own request ids.
    #[cfg(test)]
    pub(in crate::hub) fn open_work(&self, session: &Session, incarnation: &str) -> OpenWork {
        self.fold_open_work(session, incarnation, Fold::Resume { settled: None }).0
    }

    /// `open_work`, parsing the records `reads` asks for (tests: every one), from the start.
    pub(super) fn open_work_reading(
        &self,
        session: &Session,
        incarnation: &str,
        reads: fn(&RecordHead<'_>, bool, bool) -> bool,
    ) -> OpenWork {
        self.fold_open_work(session, incarnation, Fold::Whole(reads)).0
    }

    /// `open_work` as `fold` says, and with `Fold::Resume { settled: Some(_) }` the checkpoint the
    /// next adoption may resume from: every fold of the adoption (`Folds`) at the last record
    /// that is sure to be whole and that no later read parses otherwise.
    fn fold_open_work(
        &self,
        session: &Session,
        incarnation: &str,
        fold: Fold,
    ) -> (OpenWork, Option<Checkpoint>) {
        let stamp = self.store.log_stamp(&session.id).ok();
        let (reads, resume, settled) = match fold {
            Fold::Whole(reads) => (reads, false, None),
            Fold::Resume { settled } => (open_work_reads as Reads, true, settled),
        };
        // Only the log's last turn can be open when the scan ends: an earlier turn's records
        // (most of a long log) are folded away at its `turn_result`. Found from the end, on the
        // heads of the records after that turn's marker.
        let (mut last_turn, mut last_turn_starts) = (0, false);
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|dir, kind| dir != b"mux" || !matches!(kind, b"turn_started" | b"turn_result"),
            // A line whose head does not read reaches here unskipped.
            &mut |e| {
                if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "turn_result") {
                    (last_turn, last_turn_starts) = (e.seq, e.kind == "turn_started");
                    return false;
                }
                true
            },
        );
        let inputs = self.fold_inputs(session);
        // A record of the last turn is parsed while it is open, and was not by a fold that
        // knew a later last turn: a checkpoint ends before an open last turn's start, so each
        // record it holds was read as every later fold reads it.
        let turn_bound = if last_turn_starts { last_turn - 1 } else { u64::MAX };
        let resumed = resume
            .then(|| self.adoption_checkpoint(session, incarnation, &inputs))
            .flatten()
            .filter(|c| c.seq <= turn_bound);
        let ((from, next), mut folds) = match resumed {
            Some(c) => ((c.seq + 1, c.next), c.folds),
            None => ((0, None), Folds::new(&inputs)),
        };
        // The last record a checkpoint may hold.
        let bound = settled.map(|settled| settled.min(turn_bound));
        let mut folded = from.saturating_sub(1);
        let mut kept: Option<(u64, Option<crate::store::LinePos>, Folds)> = None;
        let scanned = self.store.scan_heads_from(&session.id, from, next, &mut |head, at| {
            if let Some(bound) = bound
                && kept.is_none()
                && head.seq > bound
            {
                kept = Some((folded, at, folds.clone()));
            }
            folds.env.step(head, incarnation);
            folds.host_seq.step(head, incarnation);
            seed_step(&mut folds.subagents, head);
            folds.work.step(head, incarnation, &inputs, reads, last_turn);
            folded = folded.max(head.seq);
            true
        });
        if bound.is_some() && kept.is_none() {
            kept = Some((folded, None, folds.clone()));
        }
        let (work, host_seq_at) = folds.work.finish(scanned.is_err());
        // A line cut short showed it: the whole records decide, as before.
        if let Some(seq) = host_seq_at
            && !self.logs_host_seq(session, seq, work.last_host_seq)
        {
            return (self.open_work_reading(session, incarnation, |_, _, _| true), None);
        }
        // None when the log could not be read to its end, or when it is the one resumed from.
        let checkpoint = kept
            .filter(|(seq, ..)| *seq > 0 && *seq >= from && scanned.is_ok())
            .and_then(|(seq, next, folds)| {
                Some(Checkpoint::new(seq, next, incarnation, inputs, folds, stamp?))
            });
        (work, checkpoint)
    }
}

/// `open_work_reads`, or a reader that parses more (tests).
type Reads = fn(&RecordHead<'_>, bool, bool) -> bool;

/// How `fold_open_work` reads the log.
enum Fold {
    /// From the start, parsing what `Reads` asks for.
    Whole(Reads),
    /// From the adoption checkpoint, parsing what `open_work_reads` asks for; with `settled`
    /// (the log's last seq while no append was under way), the checkpoint to save.
    Resume { settled: Option<u64> },
}

/// `remote_host_env_current`'s fold: whether the adopted incarnation's last start ran under
/// the remote env policy of this build.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub(super) struct EnvFold {
    current: bool,
}

impl EnvFold {
    fn step(&mut self, head: &RecordHead<'_>, incarnation: &str) {
        if head.dir == "mux"
            && head.kind == "host_started"
            && let Some(event) = head.record()
            && event.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
        {
            self.current = event.msg.get("remoteEnvPolicy").and_then(Value::as_str)
                == Some(crate::agent::REMOTE_ENV_POLICY_ID);
        }
    }
}

/// `last_host_seq`'s fold: the largest `hostSeq` under the adopted incarnation and the `seq`
/// of the record that holds it.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub(super) struct HostSeqFold {
    last: u64,
    at: u64,
    current: bool,
}

impl HostSeqFold {
    fn step(&mut self, head: &RecordHead<'_>, incarnation: &str) {
        // Only starts and deferred withdrawals need their incarnation parsed.
        if head.dir == "mux" && head.kind == "host_started" {
            if let Some(e) = head.record() {
                self.current =
                    e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                if self.current {
                    (self.last, self.at) = (0, 0);
                }
            }
        } else if self.current
            && (head.kind != "permission_withdrawn"
                || head.record().is_some_and(|e| host_seq_matches(&e, incarnation)))
            && let Some(h) = head.host_seq.filter(|&h| h > self.last)
        {
            (self.last, self.at) = (h, head.seq);
        }
    }
}

/// `subagents_from_log`'s fold of one head. A harness start ends the background subagents of
/// the one before, and a turn start the foreground ones, as live.
fn seed_step(tree: &mut SubagentTree, head: &RecordHead<'_>) {
    // Expiry ages each subagent from its logged stamp (`subagents::expiry`).
    tree.set_clock(head.at);
    if head.dir == "mux" {
        match head.kind {
            "host_started" | "stopped" | "exited" => tree.end_background(),
            "turn_started" => tree.end_foreground(),
            _ => {}
        }
        return;
    }
    if head.dir != "in" || !super::super::work_below::names_subagents(head) {
        return;
    }
    let replay = head.kind.ends_with(".replay");
    if let Some(mut e) = head.record()
        && let Some(params) = e.msg.get_mut("params")
    {
        tree.annotate_live(params, !replay);
    }
}

/// `open_work`'s fold: the work it recovers so far and what it keeps to decide the rest.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub(super) struct WorkFold {
    work: OpenWork,
    current: bool,
    requests: Vec<(Value, String, Option<Value>, Option<u64>)>,
    answered: HashSet<String>,
    asked: HashMap<String, (String, Value, Option<Value>)>,
    by_permission: HashMap<String, String>,
    open_request_ids: HashSet<String>,
    ancestors: HashSet<String>,
    /// permissionId -> the ids of its "allow always" options.
    lasting: HashMap<String, Vec<String>>,
    /// The canary passes, then the host starts: that host is sandboxed.
    /// Only the adopted incarnation's own start counts, with the canary of
    /// the current profile right before it; missing: unsandboxed.
    canary_passed: bool,
    /// Which logged updates are a subagent's, as the tap tells them live: by the subagents
    /// the log itself started, never by an update's own `_meta`.
    subagents: SubagentTree,
    /// The `seq` of the record whose head alone gave `last_host_seq`, proven whole at the end.
    host_seq_at: Option<u64>,
    started: bool,
}

/// The ids of the "allow always" options of a permission request.
fn always(request: Option<&Value>) -> Vec<String> {
    request
        .and_then(|r| r.get("options"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|o| o.get("kind").and_then(Value::as_str) == Some("allow_always"))
        .filter_map(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

impl WorkFold {
    pub(super) fn new(inputs: &FoldInputs) -> Self {
        let mut fold = Self::default();
        fold.work.unsandboxed = inputs.remote_claude;
        // The chat's native roots, current and earlier, are never subagents (as the tap seeds
        // them).
        fold.subagents = inputs.tree();
        fold
    }

    fn step(
        &mut self,
        head: &RecordHead<'_>,
        incarnation: &str,
        inputs: &FoldInputs,
        reads: fn(&RecordHead<'_>, bool, bool) -> bool,
        last_turn: u64,
    ) {
        let work = &mut self.work;
        // A record the fold would leave as it is counts by its head's `hostSeq` alone.
        let last_turn_open = work.turn.as_ref().is_some_and(|t| t.0 >= last_turn);
        if !reads(head, self.current, last_turn_open) {
            if self.current
                && head.kind != "permission_withdrawn"
                && let Some(h) = head.host_seq.filter(|&h| h > work.last_host_seq)
            {
                work.last_host_seq = h;
                self.host_seq_at = Some(head.seq);
            }
            return;
        }
        let Some(mut e) = head.record() else {
            // A receipt note that can not be read proves nothing: fail closed.
            work.receipts_unproven |= self.current
                && head.dir == "out"
                && matches!(head.kind, agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD);
            return;
        };
        let subagents_own = e.dir == "in"
            && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
            && e.msg.get_mut("params").is_some_and(|p| self.subagents.annotate(p).is_some());
        if e.dir == "mux" {
            let text = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
            match e.kind.as_str() {
                "host_started" => {
                    self.lasting.clear();
                    work.harness_grant = false;
                    if text("incarnation").as_deref() == Some(incarnation) {
                        work.unsandboxed = inputs.remote_claude && !self.canary_passed;
                    }
                    self.canary_passed = false;
                }
                "remote_sandbox" => {
                    self.canary_passed = e.msg.get("canary").and_then(Value::as_str)
                        == Some("passed")
                        && text("profile").as_deref() == Some(inputs.sandbox_profile.as_str());
                }
                "permission_request" => {
                    if let Some(pid) = text("permissionId") {
                        self.lasting.insert(pid, always(e.msg.get("request")));
                    }
                }
                "permission_decision" => {
                    let chosen = e.msg.pointer("/outcome/optionId").and_then(Value::as_str);
                    if let (Some(pid), Some(o)) = (text("permissionId"), chosen)
                        && self.lasting.get(&pid).is_some_and(|ids| ids.iter().any(|i| i == o))
                    {
                        work.harness_grant = true;
                    }
                }
                "permission_auto" => {
                    if let Some(o) = text("optionId")
                        && always(e.msg.get("request")).contains(&o)
                    {
                        work.harness_grant = true;
                    }
                }
                "turn_started" => {
                    work.last_control =
                        Some(Control::from_recorded(e.msg.get("control").and_then(Value::as_str)));
                    work.last_device = text("device");
                }
                "turn_control" => {
                    work.last_control = Some(Control::Web);
                    work.last_device = text("device");
                }
                "remote_floor_cancel" => work.floor_cancelled = text("turnId"),
                _ => {}
            }
        }
        let current = self.current;
        match (e.dir.as_str(), e.kind.as_str()) {
            ("mux", "host_started") => {
                self.current =
                    e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                self.started |= self.current;
                // A new harness: its ids and answers start over.
                self.requests.clear();
                self.answered.clear();
                self.asked.clear();
                self.by_permission.clear();
                work.withdrawn.clear();
                work.withdrawn_asks.clear();
                work.cancelled_permissions.clear();
                work.unwritten.clear();
                work.receipts_unproven = false;
                self.open_request_ids.clear();
                work.prompt_request = None;
                work.prompt_response = None;
                work.steers.clear();
                // A new harness runs no carried turn of the old one's.
                work.carry_next = None;
                work.turn_carried = false;
                work.cloud_mobile_turn = false;
                work.next_raised = false;
                work.last_host_seq = 0;
                self.host_seq_at = None;
                work.doing = Default::default();
            }
            ("mux", "turn_started") => {
                let field =
                    |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
                // A carried turn raised to Web before its start was logged keeps it.
                let raised = work.carry_next.as_ref().is_some_and(|(_, next)| {
                    next.get("turnId") == e.msg.get("turnId")
                        && next.get("control").and_then(Value::as_str) == Some("web")
                });
                work.cloud_mobile_turn =
                    e.msg.get("cloudMobile").and_then(Value::as_bool).unwrap_or(false);
                work.turn = Some((
                    e.seq,
                    field("turnId"),
                    field("promptId"),
                    field("prompt"),
                    field("client"),
                    if raised {
                        Control::Web
                    } else {
                        Control::from_recorded(e.msg.get("control").and_then(Value::as_str))
                    },
                ));
                work.turn_line = e.msg.get("promptLine").and_then(Value::as_str).map(str::to_owned);
                work.turn_device = e.msg.get("device").and_then(Value::as_str).map(str::to_owned);
                work.turn_trigger = e.msg.get("trigger") == Some(&Value::Bool(true));
                work.turn_persons = e.msg.get("persons") == Some(&Value::Bool(true));
                work.turn_at = e.at;
                work.turn_carried = e.msg.get("carried").is_some_and(|c| !c.is_null());
                work.carry_next = None;
                work.next_raised = false;
                work.heard_at = 0;
                work.open_tools.clear();
                work.prompt_request = None;
                work.prompt_response = None;
                work.steers.clear();
                work.doing = Default::default();
            }
            ("mux", "turn_control") => {
                if let Some(t) = work.turn.as_mut() {
                    if e.msg.get("turnId").and_then(Value::as_str) == Some(t.1.as_str()) {
                        t.5 = Control::from_recorded(e.msg.get("control").and_then(Value::as_str));
                        work.turn_device =
                            e.msg.get("device").and_then(Value::as_str).map(str::to_owned);
                    } else {
                        // The turn it carried into, put in place before its end was logged.
                        work.next_raised = true;
                    }
                }
                // A Web steer into a carried turn not started yet (`carried_turn.rs`).
                if let Some((_, next)) = work.carry_next.as_mut()
                    && e.msg.get("turnId") == next.get("turnId")
                {
                    next.set("control", json!(Control::Web.as_str()));
                }
            }
            ("mux", "turn_result") => {
                work.carry_next = e.msg.get("carriedTo").filter(|c| !c.is_null()).map(|c| {
                    let from = work.turn.as_ref().map(|t| t.1.clone());
                    let from = from
                        .or_else(|| e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned));
                    (from.unwrap_or_default(), c.clone())
                });
                work.turn = None;
                work.turn_device = None;
                work.turn_line = None;
                work.turn_carried = false;
                work.turn_persons = false;
                work.next_raised = false;
                work.compacting = false;
                // No turn, no turn state: an ended turn's records are not read
                // (`open_work_reads`), so none of them may outlive it here.
                work.heard_at = 0;
                work.open_tools.clear();
                work.prompt_request = None;
                work.prompt_response = None;
                work.steers.clear();
                work.doing = Default::default();
            }
            // A subagent's updates are not the turn's own (`permissions.rs` `on_update`).
            ("in", "tool_call" | "tool_call_update" | "plan")
                if current && work.turn.is_some() && !subagents_own =>
            {
                work.doing.note(&e.msg["params"]["update"]);
            }
            ("in", "compaction") if current && work.turn.is_some() && !subagents_own => {
                match e.msg.pointer("/params/update/state").and_then(Value::as_str) {
                    Some("running") => work.compacting = true,
                    Some("completed") | Some("failed") => work.compacting = false,
                    _ => {}
                }
            }
            ("mux", "permission_request") if current => {
                if let (Some(pid), Some(aid)) = (
                    e.msg.get("permissionId").and_then(Value::as_str),
                    e.msg.get("agentRequestId").filter(|v| !v.is_null()),
                ) {
                    let request = e.msg.get("request").cloned().unwrap_or(Value::Null);
                    let key = aid.to_string();
                    let decided = work.withdrawn.remove(&key).then(|| {
                        work.withdrawn_asks.insert(key.clone());
                        work.cancelled_permissions.insert(key.clone());
                        json!({"outcome": "cancelled"})
                    });
                    self.asked.insert(aid.to_string(), (pid.to_owned(), request, decided));
                    self.by_permission.insert(pid.to_owned(), aid.to_string());
                    let turn = e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    work.asked_at.insert(pid.to_owned(), (e.at, turn));
                }
            }
            ("mux", "permission_withdrawn")
                if current
                    && e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation) =>
            {
                if let Some(aid) = e.msg.get("agentRequestId")
                    && self.open_request_ids.contains(&aid.to_string())
                {
                    if let Some(entry) = self.asked.get_mut(&aid.to_string()) {
                        work.withdrawn_asks.insert(aid.to_string());
                        // A decision already logged won the race before
                        // the withdrawal reached the hub.
                        if entry.2.is_none() {
                            entry.2 = Some(json!({"outcome": "cancelled"}));
                            work.cancelled_permissions.insert(aid.to_string());
                        }
                    } else {
                        work.withdrawn.insert(aid.to_string());
                    }
                }
            }
            ("mux", "permission_decision") if current => {
                if let Some(aid) = e
                    .msg
                    .get("permissionId")
                    .and_then(Value::as_str)
                    .and_then(|pid| self.by_permission.get(pid))
                    && let Some(entry) = self.asked.get_mut(aid)
                {
                    entry.2 = e.msg.get("outcome").cloned();
                    work.cancelled_permissions.remove(aid);
                    // Beside the outcome, or inside it as a re-asked prompt's answer was
                    // logged before review 84 of #23322.
                    let inside = format!("/outcome/{ANSWERED_BY_SLOT}/session");
                    if e.msg.pointer("/answeredBy/session").is_some()
                        || e.msg.pointer(&inside).is_some()
                    {
                        self.ancestors.insert(aid.clone());
                    } else {
                        self.ancestors.remove(aid);
                    }
                }
            }
            ("out", method::SESSION_PROMPT) if current && work.turn.is_some() => {
                let id = e.msg.get("id").cloned();
                // A steer into the running turn is not the turn's prompt: its
                // answer (Claude Code's `steered`) does not end the turn.
                let steer =
                    e.msg.pointer("/params/_meta/steer").and_then(Value::as_bool) == Some(true);
                if steer && (work.prompt_request.is_some() || work.turn_carried) {
                    let prompt = e.msg.pointer("/params/_meta/promptId").and_then(Value::as_str);
                    if let (Some(id), Some(prompt)) = (&id, prompt) {
                        work.steer_prompts.insert(id.to_string(), prompt.to_owned());
                    }
                    work.steers.extend(id.map(|id| (id, None)));
                } else {
                    work.prompt_request = id;
                    // A carried turn's steers may go in before its prompt.
                    if !work.turn_carried {
                        work.steers.clear();
                    }
                }
            }
            ("in", "response") if current => {
                let id = e.msg.get("id");
                if work.prompt_request.is_some() && id == work.prompt_request.as_ref() {
                    work.prompt_response = Some(e.msg.clone());
                } else if let Some(steer) =
                    work.steers.iter_mut().find(|(steer, _)| id == Some(steer))
                {
                    steer.1 = Some(e.msg.clone());
                }
            }
            ("out", agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD) if current => {
                match e.msg.pointer("/params/receipt").and_then(Value::as_u64) {
                    Some(r) if e.kind == agent_host::QUEUED_METHOD => {
                        work.unwritten.insert(r);
                    }
                    Some(r) => {
                        work.unwritten.remove(&r);
                    }
                    None => work.receipts_unproven = true,
                }
            }
            ("out", "response") if current => {
                if let Some(id) = e.msg.get("id") {
                    self.answered.insert(id.to_string());
                    self.open_request_ids.remove(&id.to_string());
                }
            }
            ("in", kind)
                if current && e.msg.get("id").is_some() && e.msg.get("method").is_some() =>
            {
                let id = e.msg["id"].clone();
                self.open_request_ids.insert(id.to_string());
                let params = e.msg.get("params").cloned();
                self.requests.push((id, kind.to_owned(), params, e.host_seq));
            }
            _ => {}
        }
        if self.current
            && host_seq_matches(&e, incarnation)
            && let Some(h) = e.host_seq.filter(|&h| h > work.last_host_seq)
        {
            work.last_host_seq = h;
            self.host_seq_at = None;
        }
        if work.turn.is_some() && super::super::tap::logged_from_the_model(&e) {
            work.heard_at = e.at;
            if let Some(update) = e.msg.pointer("/params/update") {
                super::super::stalled_turn::track_tool(&mut work.open_tools, update);
            }
        }
    }

    /// The work recovered, once every record is folded (`scan_failed`: the log could not be read
    /// to its end), and the `seq` of the record whose head alone gave its `last_host_seq`, which
    /// the caller proves whole.
    fn finish(self, scan_failed: bool) -> (OpenWork, Option<u64>) {
        let mut work = self.work;
        work.receipts_unproven |= scan_failed || !self.started;
        work.requests = self
            .requests
            .into_iter()
            .filter(|(id, _, _, _)| !self.answered.contains(&id.to_string()))
            .collect();
        work.permissions = self.asked;
        work.ancestor_answers = self.ancestors;
        (work, self.host_seq_at)
    }
}

/// The `mux` kinds `open_work` folds.
const OPEN_WORK_MUX_KINDS: [&str; 10] = [
    "host_started",
    "remote_sandbox",
    "permission_request",
    "permission_decision",
    "permission_withdrawn",
    "permission_auto",
    "turn_started",
    "turn_control",
    "turn_result",
    "remote_floor_cancel",
];

/// A deferred withdrawal may be logged after its host was replaced. Its
/// checkpoint belongs only to the incarnation named in the durable marker.
fn host_seq_matches(e: &crate::store::EventRecord, incarnation: &str) -> bool {
    e.kind != "permission_withdrawn"
        || e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
}

/// Whether `open_work` must parse a record to fold it, judged from its head and the scan so far:
/// whether the adopted incarnation is current and the log's last turn is open (`turn_open`; an
/// earlier turn's records are folded away when it ends). A record it passes is one the fold would
/// leave as it is but for its `hostSeq`, which the head holds; one it cannot rule out is read.
/// Most of a long log is closed turns' agent output, which is passed unparsed.
pub(super) fn open_work_reads(head: &RecordHead<'_>, current: bool, turn_open: bool) -> bool {
    match head.dir {
        "mux" => OPEN_WORK_MUX_KINDS.contains(&head.kind),
        "out" => {
            current
                && (matches!(
                    head.kind,
                    "response" | agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD
                ) || (turn_open && head.kind == method::SESSION_PROMPT))
        }
        "in" => {
            // An open turn's records: the model's signs of work, its tools, steers' answers.
            turn_open
                // Every subagent the log starts, which a later turn's update may belong to.
                || super::super::work_below::names_subagents(head)
                // An agent request (an `id` and a `method`), answered or not.
                || (current && head.may_contain(b"\"id\":") && head.may_contain(b"\"method\":"))
        }
        _ => true,
    }
}
