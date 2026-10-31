//! A lane result its authenticated parent already consumed does not become another task.
//! Only successful local reads and explicit completion waits count; each mark names one turn.

use super::*;
use std::collections::BTreeMap;
use std::sync::Weak;

/// Recent result receipts per lane. The lane link owns their lifetime.
#[derive(Default)]
pub(super) struct LaneReportReads {
    lanes: StdMutex<BTreeMap<String, Reads>>,
}

#[derive(Default)]
struct Reads {
    parent: String,
    turns: BTreeMap<u64, Receipt>,
    waits: BTreeMap<String, usize>,
}

#[derive(Default)]
struct Receipt {
    turn_id: String,
    start_seq: u64,
    ended: bool,
    read: bool,
}

impl Reads {
    fn trim(&mut self) {
        while self.turns.len() > 64 {
            let Some(turn) = self
                .turns
                .iter()
                .find(|(_, r)| !self.waits.contains_key(&r.turn_id))
                .map(|(t, _)| *t)
            else {
                break;
            };
            self.turns.remove(&turn);
        }
    }
}

/// Cancels a caller's completion subscriptions when the wait returns, times out or is dropped.
pub(crate) struct LaneReportWait {
    hub: Weak<Hub>,
    turns: Vec<(String, String)>,
}

impl Drop for LaneReportWait {
    fn drop(&mut self) {
        let Some(hub) = self.hub.upgrade() else { return };
        let mut lanes = hub.lane_report_reads.lanes.lock().unwrap_or_else(|e| e.into_inner());
        for (lane, turn) in &self.turns {
            if let Some(reads) = lanes.get_mut(lane) {
                if let Some(count) = reads.waits.get_mut(turn) {
                    *count = count.saturating_sub(1);
                    if *count == 0 {
                        reads.waits.remove(turn);
                    }
                }
                reads.trim();
            }
        }
    }
}

impl Hub {
    /// Register only the parent's named local lanes and the turn running at registration.
    pub(crate) fn lane_report_wait(
        self: &Arc<Self>,
        caller: Option<&str>,
        ids: &[String],
    ) -> LaneReportWait {
        let mut guard = LaneReportWait { hub: Arc::downgrade(self), turns: Vec::new() };
        let Some(caller) = caller else { return guard };
        for id in ids {
            if self.lane_report_parent(id).as_deref() != Some(caller) {
                continue;
            }
            let Ok(session) = self.resolve(id) else { continue };
            let Some(running) = session.turn() else { continue };
            let mut lanes = self.lane_report_reads.lanes.lock().unwrap_or_else(|e| e.into_inner());
            let reads = lanes.entry(id.clone()).or_default();
            reads.parent = caller.to_owned();
            *reads.waits.entry(running.turn_id.clone()).or_default() += 1;
            // The result can have arrived between reading the running turn and taking this lock.
            for receipt in
                reads.turns.values_mut().filter(|r| r.turn_id == running.turn_id && r.ended)
            {
                receipt.read = true;
            }
            guard.turns.push((id.clone(), running.turn_id));
        }
        guard
    }

    /// Record one completed turn. Called before report delivery and by reads racing that hook.
    pub(super) fn lane_report_ended(&self, lane: &str, turn: u64) {
        let Ok(session) = self.resolve(lane) else { return };
        let Some(last) = session.meta().last_turn else { return };
        // Never attribute the next turn's result to this turn if its end hooks run out of order.
        if last.get("turnCount").and_then(Value::as_u64) != Some(turn) {
            return;
        }
        self.lane_report_record_result(lane, &last);
    }

    /// A result names the count captured before its turn released the queue, never the count
    /// of a successor which may already be running when this result is written.
    pub(super) fn lane_report_record_result(&self, lane: &str, result: &Value) {
        let Some(parent) = self.lane_report_parent(lane) else { return };
        let Some(turn) = result.get("turnCount").and_then(Value::as_u64) else { return };
        let mut lanes = self.lane_report_reads.lanes.lock().unwrap_or_else(|e| e.into_inner());
        let reads = lanes.entry(lane.to_owned()).or_default();
        reads.parent = parent;
        let receipt = reads.turns.entry(turn).or_default();
        receipt.turn_id =
            result.get("turnId").and_then(Value::as_str).unwrap_or_default().to_owned();
        receipt.start_seq = result.get("turnSeq").and_then(Value::as_u64).unwrap_or(0);
        receipt.ended = true;
        receipt.read |= reads.waits.contains_key(&receipt.turn_id);
        reads.trim();
    }

    fn lane_report_sync(&self, lane: &str) {
        if let Ok(session) = self.resolve(lane)
            && let Some(turn) = session
                .meta()
                .last_turn
                .as_ref()
                .and_then(|v| v.get("turnCount"))
                .and_then(Value::as_u64)
        {
            self.lane_report_ended(lane, turn);
        }
    }

    pub(super) fn lane_report_was_read(&self, lane: &str, turn: u64) -> bool {
        self.lane_report_sync(lane);
        self.lane_report_reads
            .lanes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(lane)
            .and_then(|r| r.turns.get(&turn))
            .is_some_and(|r| r.read)
    }

    pub(super) fn lane_report_forget(&self, id: &str) {
        self.lane_report_reads
            .lanes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|lane, reads| lane != id && reads.parent != id);
    }

    /// A successful completion wait returned this ended result. Running/permission hits do not count.
    pub(crate) fn lane_report_wait_read(self: &Arc<Self>, caller: Option<&str>, rows: &[Value]) {
        for row in rows {
            let Some(lane) = row.get("sessionId").and_then(Value::as_str) else { continue };
            let ended = row.get("matched").and_then(Value::as_array).is_some_and(|a| {
                a.iter().any(|v| matches!(v.as_str(), Some("ready" | "done" | "turnEnded")))
            });
            if !ended {
                continue;
            }
            let turn_id = row.pointer("/lastTurn/turnId").and_then(Value::as_str);
            self.lane_report_read_where(caller, lane, |r| {
                turn_id.is_some_and(|id| id == r.turn_id)
            });
        }
    }

    /// History includes exact ended turn ids, not just the newest turn's current state.
    pub(crate) fn lane_report_history_read(
        self: &Arc<Self>,
        caller: Option<&str>,
        lane: &str,
        turns: &[Value],
    ) {
        self.lane_report_read_where(caller, lane, |r| {
            turns.iter().any(|t| {
                t.get("endedAt").is_some()
                    && t.get("turnId").and_then(Value::as_str) == Some(r.turn_id.as_str())
            })
        });
    }

    /// `last` reads transcript events. Count only a returned result together with its reply,
    /// never a filtered state-only read or a page of an older turn.
    pub(crate) fn lane_report_events_read(
        self: &Arc<Self>,
        caller: Option<&str>,
        lane: &str,
        events: &[EventRecord],
    ) {
        self.lane_report_read_where(caller, lane, |r| {
            events.iter().any(|e| {
                r.start_seq > 0
                    && e.kind == "turn_result"
                    && e.msg.get("turnId").and_then(Value::as_str) == Some(r.turn_id.as_str())
                    && events.iter().any(|reply| {
                        reply.seq > r.start_seq
                            && reply.seq < e.seq
                            && reply
                                .msg
                                .pointer("/params/update/sessionUpdate")
                                .and_then(Value::as_str)
                                == Some("agent_message_chunk")
                    })
            })
        });
    }

    fn lane_report_read_where(
        self: &Arc<Self>,
        caller: Option<&str>,
        lane: &str,
        observed: impl Fn(&Receipt) -> bool,
    ) {
        let Some(caller) =
            caller.filter(|caller| self.lane_report_parent(lane).as_deref() == Some(*caller))
        else {
            return;
        };
        self.lane_report_sync(lane);
        let turns = {
            let mut lanes = self.lane_report_reads.lanes.lock().unwrap_or_else(|e| e.into_inner());
            let Some(reads) = lanes.get_mut(lane) else { return };
            reads
                .turns
                .iter_mut()
                .filter_map(|(turn, receipt)| {
                    if !receipt.ended || !observed(receipt) {
                        return None;
                    }
                    receipt.read = true;
                    Some(*turn)
                })
                .collect::<Vec<_>>()
        };
        for turn in turns {
            self.lane_report_reconcile_read(caller, lane, turn);
        }
    }

    /// If the result was read after admission, remove only its still-waiting report. An already
    /// started turn is never cancelled. Repeated reads and the admission race are idempotent.
    pub(super) fn lane_report_reconcile_read(
        self: &Arc<Self>,
        parent: &str,
        lane: &str,
        turn: u64,
    ) {
        if !self.lane_report_was_read(lane, turn) {
            return;
        }
        let Ok(session) = self.resolve(parent) else { return };
        // Validate provenance and remove under the same lock: a person's edit must never
        // disappear because an earlier snapshot still called the prompt a lane report.
        let (removed, mut ledger) = {
            let mut queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
            let indices: Vec<usize> = queue
                .iter()
                .enumerate()
                .filter_map(|(index, q)| {
                    let p = q.run.provenance.as_ref()?;
                    (p.get("kind").and_then(Value::as_str) == Some(super::lane_reports::KIND)
                        && p.get("from").and_then(Value::as_str) == Some(lane)
                        && p.get("turn").and_then(Value::as_u64) == Some(turn))
                    .then_some(index)
                })
                .collect();
            let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            let removed: Vec<_> =
                indices.into_iter().rev().map(|index| queue.remove(index)).collect();
            session.queued.fetch_sub(removed.len() as u64, Ordering::SeqCst);
            (removed, ledger)
        };
        let archived: Vec<_> = removed
            .into_iter()
            .map(|removed| {
                let id = removed.prompt_id.clone();
                let text = prompt_text(&removed.run.blocks);
                let provenance = removed.run.provenance.clone().unwrap_or(Value::Null);
                self.settle_removed(
                    &session,
                    removed,
                    &mut ledger,
                    json!({"reason": "lane-result-read"}),
                );
                (id, text, provenance)
            })
            .collect();
        drop(ledger);
        for (id, text, provenance) in archived {
            self.lane_report_delivered_read(&session, lane, &id, &text, &provenance);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipts_are_exact_turns_and_bounded_without_dropping_live_waits() {
        let mut reads = Reads::default();
        reads.waits.insert("live".into(), 1);
        reads.turns.insert(1, Receipt { turn_id: "live".into(), ..Default::default() });
        for turn in 2..100 {
            reads
                .turns
                .insert(turn, Receipt { ended: true, read: turn == 98, ..Default::default() });
            reads.trim();
        }
        assert_eq!(reads.turns.len(), 64);
        assert!(reads.turns.contains_key(&1));
        assert!(reads.turns.get(&98).unwrap().read);
        assert!(!reads.turns.get(&99).unwrap().read);
    }
}
