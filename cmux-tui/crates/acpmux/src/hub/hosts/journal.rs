//! Reconstruct in-flight host work and replay cursors from the durable journal.

use super::*;
use crate::store::RecordHead;

impl Hub {
    pub(super) fn recovery_work(
        &self,
        session: &Session,
        incarnation: &str,
        resume_after: u64,
    ) -> OpenWork {
        // A withdrawal either precedes this snapshot in the log or waits
        // on this lock until its recovered request has been admitted.
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let mut work = self.open_work(session, incarnation);
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
        work
    }

    pub(super) fn remote_host_env_current(&self, session: &Session, incarnation: &str) -> bool {
        let mut current = false;
        let _ = self.store.scan_heads(&session.id, &mut |head| {
            if head.dir == "mux"
                && head.kind == "host_started"
                && let Some(event) = head.record()
                && event.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
            {
                current = event.msg.get("remoteEnvPolicy").and_then(Value::as_str)
                    == Some(crate::agent::REMOTE_ENV_POLICY_ID);
            }
            true
        });
        current
    }

    /// Largest `hostSeq` logged under host `incarnation`.
    pub(super) fn last_host_seq(&self, session: &Session, incarnation: &str) -> u64 {
        // And the `seq` of the record that holds it.
        let (mut last, mut at) = (0, 0);
        let mut current = false;
        // Only starts and deferred withdrawals need their incarnation parsed.
        let _ = self.store.scan_heads(&session.id, &mut |head| {
            if head.dir == "mux" && head.kind == "host_started" {
                if let Some(e) = head.record() {
                    current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                    if current {
                        (last, at) = (0, 0);
                    }
                }
            } else if current
                && (head.kind != "permission_withdrawn"
                    || head.record().is_some_and(|e| host_seq_matches(&e, incarnation)))
                && let Some(h) = head.host_seq.filter(|&h| h > last)
            {
                (last, at) = (h, head.seq);
            }
            true
        });
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
    /// `hostSeq`, which a whole-record read skips. Reads from `seq`'s segment, not the log.
    fn logs_host_seq(&self, session: &Session, seq: u64, host_seq: u64) -> bool {
        let mut whole = false;
        let _ = self.store.scan(&session.id, seq.saturating_sub(1), &mut |e: EventRecord| {
            whole = e.seq == seq && e.host_seq == Some(host_seq);
            false
        });
        whole
    }

    /// Scan the log for the work in flight under host `incarnation`. Agent
    /// requests, answers and permission records count only within this
    /// incarnation: every harness restarts its own request ids.
    pub(in crate::hub) fn open_work(&self, session: &Session, incarnation: &str) -> OpenWork {
        self.open_work_reading(session, incarnation, open_work_reads)
    }

    /// `open_work`, parsing the records `reads` asks for (tests: every one).
    pub(super) fn open_work_reading(
        &self,
        session: &Session,
        incarnation: &str,
        reads: fn(&RecordHead<'_>, bool, bool) -> bool,
    ) -> OpenWork {
        let mut work = OpenWork::default();
        let mut current = false;
        let mut requests: Vec<(Value, String, Option<Value>, Option<u64>)> = Vec::new();
        let mut answered: std::collections::HashSet<String> = Default::default();
        let mut asked: HashMap<String, (String, Value, Option<Value>)> = HashMap::new();
        let mut by_permission: HashMap<String, String> = HashMap::new();
        let mut open_request_ids: std::collections::HashSet<String> = Default::default();
        let mut ancestors = std::collections::HashSet::new();
        // permissionId -> the ids of its "allow always" options.
        let mut lasting: HashMap<String, Vec<String>> = HashMap::new();
        let always = |request: Option<&Value>| -> Vec<String> {
            request
                .and_then(|r| r.get("options"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|o| o.get("kind").and_then(Value::as_str) == Some("allow_always"))
                .filter_map(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
                .collect()
        };
        // The canary passes, then the host starts: that host is sandboxed.
        // Only the adopted incarnation's own start counts, with the canary of
        // the current profile right before it; missing: unsandboxed.
        let remote_claude = self.remote_claude(session);
        work.unsandboxed = remote_claude;
        let mut canary_passed = false;
        // Which logged updates are a subagent's, as the tap tells them live: by the subagents
        // the log itself started, never by an update's own `_meta`.
        // The chat's native roots, current and earlier, are never subagents (as the tap seeds them).
        let mut subagents = crate::subagents::SubagentTree::default();
        let meta = session.meta();
        subagents.set_own(meta.agent_session_id.as_deref());
        subagents.set_roots(
            meta.agent_session_id.iter().chain(&meta.retired_agent_session_ids).map(String::as_str),
        );
        // Only the log's last turn can be open when the scan ends: an earlier turn's records
        // (most of a long log) are folded away at its `turn_result`. Found from the end, on the
        // heads of the records after that turn's marker.
        let mut last_turn = 0;
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|dir, kind| dir != b"mux" || !matches!(kind, b"turn_started" | b"turn_result"),
            // A line whose head does not read reaches here unskipped.
            &mut |e| {
                if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "turn_result") {
                    last_turn = e.seq;
                    return false;
                }
                true
            },
        );
        // The `seq` of the record whose head alone gave `last_host_seq`, proven whole at the end.
        let mut host_seq_at: Option<u64> = None;
        let mut started = false;
        let scanned = self.store.scan_heads(&session.id, &mut |head| {
            // A record the fold would leave as it is counts by its head's `hostSeq` alone.
            let last_turn_open = work.turn.as_ref().is_some_and(|t| t.0 >= last_turn);
            if !reads(head, current, last_turn_open) {
                if current
                    && head.kind != "permission_withdrawn"
                    && let Some(h) = head.host_seq.filter(|&h| h > work.last_host_seq)
                {
                    work.last_host_seq = h;
                    host_seq_at = Some(head.seq);
                }
                return true;
            }
            let Some(mut e) = head.record() else {
                // A receipt note that can not be read proves nothing: fail closed.
                work.receipts_unproven |= current
                    && head.dir == "out"
                    && matches!(head.kind, agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD);
                return true;
            };
            let subagents_own = e.dir == "in"
                && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
                && e.msg.get_mut("params").is_some_and(|p| subagents.annotate(p).is_some());
            if e.dir == "mux" {
                let text = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
                match e.kind.as_str() {
                    "host_started" => {
                        lasting.clear();
                        work.harness_grant = false;
                        if text("incarnation").as_deref() == Some(incarnation) {
                            work.unsandboxed = remote_claude && !canary_passed;
                        }
                        canary_passed = false;
                    }
                    "remote_sandbox" => {
                        canary_passed = e.msg.get("canary").and_then(Value::as_str)
                            == Some("passed")
                            && text("profile").as_deref()
                                == Some(super::super::remote_sandbox::profile_id().as_str());
                    }
                    "permission_request" => {
                        if let Some(pid) = text("permissionId") {
                            lasting.insert(pid, always(e.msg.get("request")));
                        }
                    }
                    "permission_decision" => {
                        let chosen = e.msg.pointer("/outcome/optionId").and_then(Value::as_str);
                        if let (Some(pid), Some(o)) = (text("permissionId"), chosen)
                            && lasting.get(&pid).is_some_and(|ids| ids.iter().any(|i| i == o))
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
                        work.last_control = Some(Control::from_recorded(
                            e.msg.get("control").and_then(Value::as_str),
                        ));
                    }
                    "turn_control" => work.last_control = Some(Control::Web),
                    "remote_floor_cancel" => work.floor_cancelled = text("turnId"),
                    _ => {}
                }
            }
            match (e.dir.as_str(), e.kind.as_str()) {
                ("mux", "host_started") => {
                    current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                    started |= current;
                    // A new harness: its ids and answers start over.
                    requests.clear();
                    answered.clear();
                    asked.clear();
                    by_permission.clear();
                    work.withdrawn.clear();
                    work.withdrawn_asks.clear();
                    work.cancelled_permissions.clear();
                    work.unwritten.clear();
                    work.receipts_unproven = false;
                    open_request_ids.clear();
                    work.prompt_request = None;
                    work.prompt_response = None;
                    work.steers.clear();
                    // A new harness runs no carried turn of the old one's.
                    work.carry_next = None;
                    work.turn_carried = false;
                    work.cloud_mobile_turn = false;
                    work.next_raised = false;
                    work.last_host_seq = 0;
                    host_seq_at = None;
                    work.doing = Default::default();
                }
                ("mux", "turn_started") => {
                    let field = |k: &str| {
                        e.msg.get(k).and_then(Value::as_str).unwrap_or_default().to_owned()
                    };
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
                    work.turn_line =
                        e.msg.get("promptLine").and_then(Value::as_str).map(str::to_owned);
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
                            t.5 = Control::from_recorded(
                                e.msg.get("control").and_then(Value::as_str),
                            );
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
                        let from = from.or_else(|| {
                            e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned)
                        });
                        (from.unwrap_or_default(), c.clone())
                    });
                    work.turn = None;
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
                        asked.insert(aid.to_string(), (pid.to_owned(), request, decided));
                        by_permission.insert(pid.to_owned(), aid.to_string());
                        let turn = e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                        work.asked_at.insert(pid.to_owned(), (e.at, turn));
                    }
                }
                ("mux", "permission_withdrawn")
                    if current
                        && e.msg.get("incarnation").and_then(Value::as_str)
                            == Some(incarnation) =>
                {
                    if let Some(aid) = e.msg.get("agentRequestId")
                        && open_request_ids.contains(&aid.to_string())
                    {
                        if let Some(entry) = asked.get_mut(&aid.to_string()) {
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
                        .and_then(|pid| by_permission.get(pid))
                        && let Some(entry) = asked.get_mut(aid)
                    {
                        entry.2 = e.msg.get("outcome").cloned();
                        work.cancelled_permissions.remove(aid);
                        // Beside the outcome, or inside it as a re-asked prompt's answer was
                        // logged before review 84 of #23322.
                        let inside = format!("/outcome/{ANSWERED_BY_SLOT}/session");
                        if e.msg.pointer("/answeredBy/session").is_some()
                            || e.msg.pointer(&inside).is_some()
                        {
                            ancestors.insert(aid.clone());
                        } else {
                            ancestors.remove(aid);
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
                        let prompt =
                            e.msg.pointer("/params/_meta/promptId").and_then(Value::as_str);
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
                        answered.insert(id.to_string());
                        open_request_ids.remove(&id.to_string());
                    }
                }
                ("in", kind)
                    if current && e.msg.get("id").is_some() && e.msg.get("method").is_some() =>
                {
                    let id = e.msg["id"].clone();
                    open_request_ids.insert(id.to_string());
                    let params = e.msg.get("params").cloned();
                    requests.push((id, kind.to_owned(), params, e.host_seq));
                }
                _ => {}
            }
            if current
                && host_seq_matches(&e, incarnation)
                && let Some(h) = e.host_seq.filter(|&h| h > work.last_host_seq)
            {
                work.last_host_seq = h;
                host_seq_at = None;
            }
            if work.turn.is_some() && super::super::tap::logged_from_the_model(&e) {
                work.heard_at = e.at;
                if let Some(update) = e.msg.pointer("/params/update") {
                    super::super::stalled_turn::track_tool(&mut work.open_tools, update);
                }
            }
            true
        });
        work.receipts_unproven |= scanned.is_err() || !started;
        // A line cut short showed it: the whole records decide, as before.
        if let Some(seq) = host_seq_at
            && !self.logs_host_seq(session, seq, work.last_host_seq)
        {
            return self.open_work_reading(session, incarnation, |_, _, _| true);
        }
        work.requests = requests
            .into_iter()
            .filter(|(id, _, _, _)| !answered.contains(&id.to_string()))
            .collect();
        work.permissions = asked;
        work.ancestor_answers = ancestors;
        work
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
fn open_work_reads(head: &RecordHead<'_>, current: bool, turn_open: bool) -> bool {
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
