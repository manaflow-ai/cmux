//! Part of the queue (`queue.rs`): a new daemon rebuilds every session's queue from its log
//! (`restore_queue`), so queued prompts survive a crash, an update relaunch, a quit and a
//! reboot; `resume_queues` then runs them.

use super::*;

impl Hub {
    pub(in crate::hub) fn restore_queue(&self, session: &Arc<Session>) {
        self.restore_queue_only(session, None);
    }

    /// [`Self::restore_queue`]; with `only`, a live chat takes back just that logged prompt and
    /// nothing else is rebuilt (its inbox, agent pairs, branch and move state are live already).
    pub(in crate::hub) fn restore_queue_only(&self, session: &Arc<Session>, only: Option<&str>) {
        // Other agents' messages are in its inbox, apart from the queue (`inbox.rs`); a closed
        // chat's threads stay readable. A log load reads it apart (`Session::inbox`); an import
        // or a move takes what this log has that it does not hold now.
        if only.is_none() {
            self.restore_inbox(session);
            session.inbox_loaded.store(true, Ordering::Release);
        }
        self.restore_queue_after(session, only, None);
    }

    /// [`Self::restore_queue`] of the records past a restore point's seq, from what the point
    /// carries (`restore_point.rs`); none: the whole log. Returns what a restore point at the end
    /// of this read carries, when the read ended quiet: nothing waits, no prompt left the queue
    /// for a turn that has not started, no inbox digest holds messages, no move or agent pair is
    /// under way. Then a later record depends on nothing else this read learned.
    pub(in crate::hub) fn restore_queue_after(
        &self,
        session: &Arc<Session>,
        only: Option<&str>,
        from: Option<(u64, &QueueCarry)>,
    ) -> Option<QueueCarry> {
        if session.meta().status == SessionStatus::Closed {
            return None;
        }
        let after = from.map_or(0, |(seq, _)| seq);
        let carried = from.map(|(_, carry)| carry);
        let mut waiting = queue_waiting::Waiting::default();
        let mut order: queue_waiting::Order =
            carried.and_then(|c| serde_json::from_value(c.order.clone()).ok()).unwrap_or_default();
        let mut held: std::collections::HashSet<String> =
            carried.map(|c| c.held.iter().cloned().collect()).unwrap_or_default();
        // Of those, the ones whose hold let them go by themselves (`queue_paused` `retrying`): a
        // record without the field, from an older daemon, held every prompt for Resume.
        let mut retrying: std::collections::HashSet<String> =
            carried.map(|c| c.retrying.iter().cloned().collect()).unwrap_or_default();
        // The revision the owner approved, by the queued prompt's turn id (`queue_approve.rs`):
        // its incarnation, never its client-chosen prompt id, which a later prompt may reuse.
        let mut approved: HashMap<String, Value> = Default::default();
        // A begun move not yet ended (`transfer_out.rs` `restored_moving`), until `imported`.
        let mut moving: Option<String> = None;
        // What a paused agent pair held here, what its releases took, its pauses and resumes,
        // and the prompt ids that reached the session (`agent_pairs.rs`).
        let mut pair_records: Vec<EventRecord> = Vec::new();
        let mut recorded: std::collections::HashSet<String> = Default::default();
        let mut unstarted = lost_start::Unstarted::default();
        let mut direct = unstarted_prompt::Unstarted::default();
        let mut digests = queue_waiting::Digests::default();
        let mut branch = match carried {
            Some(c) => c.git_branch.clone(),
            None => session.meta().git_branch,
        };
        // Past the restore point, and what was changed here but is not in the journal yet
        // (`kept_unstored`).
        let scanned =
            self.scan_kinds_after_and_kept(session, after, Self::QUEUE_KINDS, &mut |e: EventRecord| {
                for (prompt_id, turn_id) in unstarted.read(&e, &waiting, &mut order) {
                    waiting.remove_turn(Some(&turn_id));
                    order.remove(&prompt_id);
                }
                digests.read(&e);
                direct.read(&e);
                let turn_id = e.msg.get("turnId");
                // Queued or run again under another turn id (a daemon that had not restored it
                // took its id as new): that copy is the prompt's, so this one does not run too.
                if matches!(e.kind.as_str(), "queued" | "user_message" | "turn_started") {
                    if let Some(id) = e.msg.get("promptId") {
                        waiting.remove_other_turns(id, turn_id);
                    }
                }
                if matches!(e.kind.as_str(), "queued" | "user_message") {
                    if let Some(id) = e.msg.get("promptId").and_then(Value::as_str) {
                        recorded.insert(id.to_owned());
                    }
                }
                match e.kind.as_str() {
                    "git" if e.dir == "mux" => {
                        branch = e.msg.get("gitBranch").and_then(Value::as_str).map(str::to_owned);
                    }
                    "queued" => {
                        // A restart's or a move's continuation of a cut turn goes ahead of what
                        // waited behind that turn, also when the daemon stopped before its
                        // `queue_order` (`restart_resume.rs`); a later reorder still holds.
                        if super::auto_resume::Cut::queued(
                            e.msg.pointer("/_meta/provenance/reason").and_then(Value::as_str),
                        ) && let Some(id) = e.msg.get("promptId")
                        {
                            order.prioritize_restart(id);
                        }
                        // An accepted prompt a restart put back (`unstarted_prompt.rs`) stays at
                        // the head across a second restart before it ran.
                        if e.msg.get("restored").and_then(Value::as_str) == Some("unstarted")
                            && let Some(id) = e.msg.get("promptId")
                        {
                            order.prioritize_restart(id);
                        }
                        // An inbox digest holds the queue's order with it in it, as its
                        // `queue_order` record does.
                        if super::digest::inbox_digest::is_digest_record(&e.msg)
                            && let Some(ids) = e.msg.get("order").and_then(Value::as_array)
                        {
                            order.set(ids.iter());
                            unstarted.lead(&mut order);
                        }
                        // Put back after a failed turn (`requeue_joined`): this copy replaces
                        // the one the turn took (an inbox digest's message is still waiting).
                        if e.msg.get("requeued") == Some(&Value::Bool(true)) {
                            waiting.remove_turn(turn_id);
                        }
                        waiting.push(e);
                    }
                    "agent_pair_held"
                    | "agent_pair_released"
                    | "agent_pair_dropped"
                    | "agent_pair_paused"
                    | "agent_pair_resumed" => pair_records.push(e),
                    // The daemon's own records only: an agent's update may carry any kind.
                    "transfer_out" if e.dir == "mux" => {
                        moving = e.msg.get("transferId").and_then(Value::as_str).map(str::to_owned)
                    }
                    "transfer_aborted" | "imported" if e.dir == "mux" => moving = None,
                    // Left the queue for a turn that has not started (`lost_start.rs`): its
                    // `queued` record stays waiting, so later records apply to it, and it goes
                    // back ahead of the queue.
                    "dequeued" | "user_message" if unstarted.holds(turn_id) => {
                        unstarted.lead(&mut order);
                    }
                    // Taken into an inbox digest: it waits until that digest's turn starts
                    // (`queue_waiting.rs` `Digests`).
                    "dequeued" if e.msg.get("digestPromptId").is_some() => {}
                    "dequeued" | "queue_removed" | "queue_declined" | "user_message"
                    | "turn_started" => {
                        waiting.remove_turn(turn_id);
                    }
                    "queue_approved" => {
                        if let Some(turn) = turn_id.and_then(Value::as_str) {
                            approved.insert(turn.to_owned(), e.msg.clone());
                        }
                    }
                    // An edit (`queue_edit.rs`): the prompt and its rules replace the queued ones;
                    // its `_meta.provenance` keeps its sender and names its editor (`editedBy`).
                    "queue_updated" => {
                        // A revision never goes back: a log from before edits were logged under
                        // the queue lock may hold an older edit after a newer one, and the newer
                        // one is the words the queue had (and an approval may name).
                        let revision = e.msg.get("revision").and_then(Value::as_u64);
                        let stale = |had: Option<&Value>| {
                            matches!((revision, had.and_then(Value::as_u64)), (Some(new), Some(had)) if new < had)
                        };
                        if let Some(q) =
                            waiting.first_of_turn(turn_id).filter(|q| !stale(q.msg.get("revision")))
                        {
                            for k in [
                                "text",
                                "prompt",
                                "control",
                                "trustGate",
                                "inlineParts",
                                "displayParts",
                                "images",
                                "pasted",
                                // An edit of a prompt that waits for the owner waits again.
                                "awaitingOwner",
                                "revision",
                            ] {
                                if let Some(value) = e.msg.get(k) {
                                    q.msg[k] = value.clone();
                                } else if let Some(fields) = q.msg.as_object_mut() {
                                    fields.remove(k);
                                }
                            }
                            if let Some(meta) =
                                q.msg.get_mut("_meta").and_then(Value::as_object_mut)
                            {
                                meta.remove("provenance");
                                // The person rewrote it: no longer another session's message.
                                meta.remove(crate::prompt_provenance::MESSAGE_META);
                            }
                            if let Some(p) = e.msg.pointer("/_meta/provenance") {
                                let kept = json!({"provenance": p});
                                crate::no_panic::JsonExt::set(&mut q.msg, "_meta", kept);
                            }
                            // The person's now (`digest.rs`), and no sender's to replace.
                            if let Some(fields) = q.msg.as_object_mut() {
                                fields.remove("fromAgent");
                                fields.remove("class");
                                fields.remove("supersede");
                            }
                        }
                    }
                    "queue_paused" => {
                        let ids = |k: &str| {
                            let ids = e.msg.get(k).and_then(Value::as_array).into_iter().flatten();
                            ids.filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>()
                        };
                        let (now_held, now_retrying) = (ids("held"), ids("retrying"));
                        // The newest hold of each says whether it retries.
                        for id in &now_held {
                            retrying.remove(id);
                        }
                        held.extend(now_held);
                        retrying.extend(now_retrying);
                    }
                    // `resume_held` names the prompts it resumed; `resume_queue` resumes them all.
                    "queue_resumed" => match e.msg.get("promptIds").and_then(Value::as_array) {
                        Some(ids) => ids.iter().filter_map(Value::as_str).for_each(|id| {
                            held.remove(id);
                        }),
                        None => held.clear(),
                    },
                    "queue_order" => {
                        // Sent now (`put_next`): no longer held.
                        if e.msg.get("next") == Some(&Value::Bool(true)) {
                            if let Some(id) = e.msg.get("promptId").and_then(Value::as_str) {
                                held.remove(id);
                            }
                        }
                        let ids = e.msg.get("order").and_then(Value::as_array);
                        order.set(ids.into_iter().flatten());
                        unstarted.lead(&mut order);
                    }
                    _ => {}
                }
                true
            });
        let mut quiet = only.is_none()
            && scanned.is_ok()
            && pair_records.is_empty()
            && moving.is_none()
            && unstarted.settled()
            && digests.settled();
        let carry_branch = branch.clone();
        if only.is_none() {
            if scanned.is_ok() {
                self.restore_git_branch(session, branch);
            }
            self.restore_agent_pairs(&session.id, pair_records, &recorded);
            let restored = transfer_out::restored_moving(scanned.is_ok(), moving);
            let mut mark = session.moving.lock().unwrap_or_else(|e| e.into_inner());
            // Auto's hold (`auto_hold.rs`) on a chat being restored is not the log's to end: only
            // the holder loop frees it, when the store says the chat is this machine's.
            let held = mark.as_deref() == Some(crate::hub::AUTO_AWAY);
            *mark = if held && restored.is_none() { mark.take() } else { restored };
        }
        // Accepted direct prompts whose turn never started go back first (`unstarted_prompt.rs`).
        if scanned.is_ok() && only.is_none() {
            let left = direct.finish();
            quiet &= left.is_empty();
            for e in self.requeue_unstarted(session, left) {
                order.prioritize_restart(e.msg.get("promptId").unwrap_or(&Value::Null));
                waiting.push(e);
            }
        }
        // An inbox digest whose turn never started gives its messages back in its place.
        digests.finish(&mut waiting, &mut order, |id, order| {
            unstarted.key(Some(&json!(id)), order).unwrap_or_else(|| order.key(Some(&json!(id))))
        });
        let mut waiting = waiting.into_records();
        if scanned.is_err() || waiting.is_empty() {
            return (quiet && waiting.is_empty()).then(|| QueueCarry {
                git_branch: carry_branch,
                held: held.into_iter().collect(),
                retrying: retrying.into_iter().collect(),
                order: serde_json::to_value(&order).unwrap_or_default(),
            });
        }
        // The last reorder holds (a prompt that left the queue for its turn went back ahead of
        // it); a prompt queued after it keeps its place at the end.
        // An inbox digest's messages share its place, in their order (`Digests::rank`).
        waiting.sort_by_key(|q| {
            let id = q.msg.get("promptId");
            (unstarted.key(id, &order).unwrap_or_else(|| order.key(id)), digests.rank(id))
        });
        // A prompt that left the queue for its turn runs first, as it would have.
        for id in unstarted.prompts() {
            held.remove(id);
        }
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let mut restored = session.restored.lock().unwrap_or_else(|e| e.into_inner());
        let mut restored_any = false;
        for e in waiting {
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let (prompt_id, turn_id, text) = (field("promptId"), field("turnId"), field("text"));
            // Restored already: a second pass (a chat settled after adoption, `log_load.rs`)
            // adds only what the first did not see.
            if prompt_id.is_empty()
                || turn_id.is_empty()
                || only.is_some_and(|only| only != prompt_id)
                || queue.iter().any(|q| q.prompt_id == prompt_id)
            {
                continue;
            }
            // A record from before the prompt was logged has its text only.
            let blocks = match e.msg.get("prompt").and_then(Value::as_array) {
                Some(blocks) => blocks.clone(),
                None => vec![json!({"type": "text", "text": text})],
            };
            let control = Control::from_recorded(e.msg.get("control").and_then(Value::as_str));
            let trust_gate = e.msg.get("trustGate").and_then(Value::as_bool).unwrap_or(false);
            let cloud_mobile = e.msg.get("cloudMobile").and_then(Value::as_bool).unwrap_or(false);
            let provenance = crate::prompt_provenance::recorded(&e.msg).filter(|p| p.is_object());
            // An inbox notice is never run again: what it carried is new again (`inbox.rs`).
            if super::inbox::is_notice(provenance.as_ref()) {
                continue;
            }
            let mut restored_message_opts = PromptOptions::default();
            super::message_events::restore_message_options(
                &mut restored_message_opts,
                provenance.as_ref(),
            );
            // A record from before `fromAgent` names an agent by its provenance (`digest.rs`).
            let from_agent = e.msg.get("fromAgent").and_then(Value::as_str);
            let agent = super::digest::agent_sender(provenance.as_ref(), from_agent);
            // A record from before classes: an agent's message is a result (`prompt_class.rs`).
            let class = crate::prompt_class::of_message(
                crate::prompt_class::recorded(&e.msg),
                agent.is_some(),
            );
            let supersede = crate::author::restored_supersede(&e.msg).map(str::to_owned);
            // Its approval counts for this incarnation at the revision the owner saw, which an
            // edit since replaced.
            // A record from before revisions is revision 0.
            let revision = e.msg.get("revision").and_then(Value::as_u64).unwrap_or(0);
            let approval = approved
                .get(&turn_id)
                .filter(|a| a.get("revision").and_then(Value::as_u64) == Some(revision));
            // A link guest's prompt waits whatever its record says (`author::awaits_owner`): one
            // an older writer recorded unmarked never runs unapproved after a restart.
            let awaiting_owner = (e.msg.get("awaitingOwner") == Some(&Value::Bool(true))
                || crate::author::awaits_owner(provenance.as_ref()))
                && approval.is_none();
            restored.push((prompt_id.clone(), turn_id.clone()));
            let display_parts = e.msg.get("displayParts").cloned();
            let size = super::queue_admission::content_bytes(&blocks, display_parts.as_ref());
            // The person's prompt a hold kept for Resume waits for it again (`waits_for_resume`); an
            // older daemon's hold names none that retry, and its agent messages and notices still do.
            let waits_for_resume = held.contains(&prompt_id)
                && !retrying.contains(&prompt_id)
                && agent.is_none()
                && !super::inbox::is_notice(provenance.as_ref());
            queue.push(QueuedPrompt {
                prompt_id: prompt_id.clone(),
                turn_id,
                client: field("client"),
                preview: short_text(super::inbox::relay_body(&text), 200),
                queued_at: e.at,
                withdraw: Arc::new(Notify::new()),
                run: Arc::new(approved_rules(
                    PromptRun {
                        size: size.into(),
                        blocks,
                        display_parts,
                        control,
                        trust_gate,
                        cloud_mobile,
                        provenance,
                        agent,
                        class,
                        supersede,
                        // A restored prompt names no machine: it does not run a chat out of its
                        // policy's mode (`Hub::full_access_hold`).
                        full_access_device: None,
                        message_id: restored_message_opts.message_id,
                        message_sender: restored_message_opts.message_sender,
                    },
                    approval,
                )),
                restored: true,
                resume: true,
                steer: false,
                steer_on_start: false,
                retries: if waits_for_resume { PERSON_RETRIES } else { 0 },
                held: held.contains(&prompt_id),
                awaiting_owner,
                revision,
                declined: Default::default(),
                sent_now: false,
                joined: Arc::new(StdMutex::new(None)),
                requeued: e.msg.get("requeued") == Some(&Value::Bool(true)),
            });
            restored_any = true;
            session.queued.fetch_add(1, Ordering::SeqCst);
            ledger.push_back((prompt_id, Arc::new(tokio::sync::watch::channel(None).0)));
        }
        let restored_count = queue.len();
        drop(restored);
        drop(ledger);
        drop(queue);
        // A visible attach may have answered before this background log restore. Publish one
        // durable change notice so session_changed publishes the current queue summary. It must
        // not persist an order captured before dropping the lock: a concurrent enqueue may have
        // already written a newer order. This notice has no replay effect. A second restore adds
        // no prompt and emits nothing.
        if restored_any {
            self.append(session, "mux", "queue_restored", json!({}));
        }
        tracing::info!(session = %session.id, queued = restored_count, "restored queued prompts");
        None
    }
}
