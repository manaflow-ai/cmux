//! Part of the chat inbox (`inbox.rs`): whether a prompt goes into the inbox, its admission,
//! and the review that delivers the inbox when it may or arms its wake timer.

use super::*;

/// Whether `session` runs Codex and its model has said nothing since the running turn's prompt
/// went out (`Session::prompt_heard`). codex-acp takes a steer that comes before the model's
/// first output as a new prompt: the running prompt answers `cancelled` and the steer's text
/// replaces it, so the chat's task is lost to the notice (acp-chief-issues 2026-11-27: an
/// "expired undelivered" FYI steered into three Codex turns of one chat cancelled each, and the
/// chat went `ready` on a status line). A steer after the model's first output goes in as one:
/// the model's first sign wakes the inbox ([`Hub::model_answered`]).
pub(in crate::hub) fn codex_unanswered(session: &Session, meta: &SessionMeta) -> bool {
    super::stop_condition::is_codex(meta)
        && session.heard.load(Ordering::SeqCst) == session.prompt_heard.load(Ordering::SeqCst)
}

impl Hub {
    /// The running turn's model gave its first sign since its prompt went out (`tap.rs`): a
    /// notice held back for it ([`codex_unanswered`]) goes in now, off the tap's path. Only a
    /// Codex chat with something new in its inbox, and only on a runtime (a test's tap runs on
    /// none).
    pub(in crate::hub) fn model_answered(self: &Arc<Self>, session: &Arc<Session>) {
        let held = session.read_meta(super::stop_condition::is_codex)
            && session.inbox().items.iter().any(|i| !i.noticed);
        if !held || tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("inbox-answered", async move {
            hub.inbox_review(&session);
        });
    }

    /// Whether a prompt goes into the inbox ([`takes`]): its sender and class when it does. Out
    /// of line, so the prompt's future holds no sender lookup.
    #[inline(never)]
    #[allow(clippy::too_many_arguments)]
    pub(in crate::hub) fn inbox_route(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        blocks: &[Value],
        control: Control,
        send_now: bool,
        class: Option<PromptClass>,
        provenance: Option<&Value>,
        agent: Option<&str>,
        plain: bool,
    ) -> Route {
        // A chat closing or closed takes a message as it did before the inbox: none waits in
        // the inbox of a chat that will not wake. A review box has no inbox, nor a chat whose
        // agent cannot read one (module docs).
        if !plain
            || !plain_kind(provenance)
            || super::super::queue::closing(session)
            || review_box(session)
            || !reads_inbox(session)
        {
            return Route::Plain;
        }
        let Some(agent) = super::super::digest::agent_sender(provenance, agent) else {
            return Route::Plain;
        };
        if !takes(true, send_now, control, blocks, provenance) {
            return Route::Plain;
        }
        // A chat's first work runs as its prompt, not as a notice of it (module docs). Its sender
        // is the delegator once its turn starts (`turns.rs`), not before: a refused one is not.
        if let Some(first) = first_work(session, prompt_id) {
            return Route::First(first);
        }
        // The session that started the chat or first gave it work sends its next step as a
        // prompt, as its first one went: the send that waits prints that turn's reply. In the
        // inbox, every send after the first became a notice the receiver answered with apologies
        // (round-2 orchestration eval, A3). Everyone else's message still goes to the inbox.
        if controls(&session.meta(), sender_session(provenance).as_deref()) {
            return Route::Plain;
        }
        let class = default_notice_class(class);
        Route::Inbox(agent, class)
    }

    /// `session/prompt` of another agent's message the inbox takes (`turns.rs`): logged, put in
    /// its thread, and answered by the notice that carries it.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::hub) async fn inbox_accept(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        prompt_id: &str,
        sender: &str,
        class: PromptClass,
        explicit: Option<&str>,
        provenance: Option<&Value>,
        human_authenticated: bool,
        wake_or_fail: bool,
        reader: Option<tokio::sync::watch::Receiver<bool>>,
        accept: &mut impl FnMut(Value),
    ) -> Result<Value, RpcError> {
        let text = prompt_text(blocks);
        let sender_session = sender_session(provenance);
        // Read before the inbox's lock, as `inbox_review` reads them.
        let meta_now = session.meta();
        let waited = crate::prompt_provenance::waited(provenance);
        let surge_on = self.surge_inbox_on();
        let wakes_before_rule = (surge_on && fire_notice(provenance.and_then(|p| p.get("notice"))))
            || wakes_as(&meta_now, class, is_report(provenance), waited, sender_session.as_deref());
        // A chat on the coordinator list wakes only for a page (`inbox_page_rule.rs`).
        // Read the catalog snapshot. Reload publishes page-rule names while holding the config
        // writer, so inbox admission never guesses during a write and never waits on it.
        let page_rule_on = self.page_rule_lists(&meta_now.name);
        let continuing = self.continuation_pending(session);
        // It would sit in an idle chat's inbox until a flush: said in its acceptance, and a
        // sender that waits for it is refused at once (`not_woken`).
        let mut held = false;
        let mut refused = false;
        let stamped_session =
            provenance.and_then(|p| crate::prompt_provenance::sender_of(Some(p)).0);
        let sender_meta = stamped_session
            .as_deref()
            .and_then(|id| self.resolve(id).ok().map(|session| session.meta()));
        let sender_identity = crate::prompt_provenance::sender_record_with_auth(
            provenance,
            sender_session.as_deref(),
            sender_meta.as_ref(),
            human_authenticated,
        );
        let thread_sender = thread_sender(provenance, sender);
        let tool_notice = notice_of(provenance, &text);
        let notice_title = tool_notice
            .as_ref()
            .and_then(|n| n.get("title"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let page_message = page_rule_on.then(|| page_rule::Message {
            class,
            from: sender,
            has_session: sender_session.is_some() || stamped_session.is_some(),
            human: human_authenticated
                || sender_identity.get("actorKind").and_then(Value::as_str)
                    == Some("authenticated_human"),
            fire: fire_notice(tool_notice.as_ref()) || page_rule::fire_text(&text),
            title: notice_title.as_deref(),
            text: &text,
        });
        let thread = match &tool_notice {
            Some(notice) => surge_topic(explicit, &text, Some(notice), &thread_sender),
            None => thread_key(explicit, &thread_sender, &text),
        };
        let (tx, mut rx) = tokio::sync::watch::channel(None);
        let mut resent: Option<Option<super::super::queue::Answer>> = None;
        let mut withdrawn = false;
        let mut from_log = false;
        let fresh = {
            let mut inbox = session.inbox();
            // Read under the inbox's lock: `kill` marks the chat closed before `inbox_closed`
            // takes it, so a message either sees the close or is answered by it.
            if session.meta().status == SessionStatus::Closed {
                return Err(super::super::queue::closing_error());
            }
            let now = now_ms();
            let verdict =
                page_message.as_ref().and_then(|m| page_rule::judge(&inbox.folds, m, now));
            let wakes_now = verdict.map_or(wakes_before_rule, |v| v == page_rule::Verdict::Page);
            // A continuation that may still fire brings a turn, but no sooner notice for FYIs
            // alone (router review of #38603 at 8991049, F1).
            let strands = !wakes_now
                && if continuing {
                    fyis_alone_wait(&inbox, class)
                } else {
                    would_strand(session, &inbox, &meta_now, class)
                };
            let carry = inbox.carrying.iter_mut().find(|c| c.ids.iter().any(|id| id == prompt_id));
            if let Some(carry) = carry {
                // A resend of one a notice carries now: answered with that notice.
                match carry.waiters.iter().find(|(id, _)| id == prompt_id) {
                    Some((_, waiter)) => rx = waiter.subscribe(),
                    None => carry.waiters.push((prompt_id.to_owned(), tx.clone())),
                }
                false
            } else if inbox.removed.contains(prompt_id) {
                // A resend of one withdrawn before a notice carried it: never back in.
                withdrawn = true;
                false
            } else if inbox.trimmed.contains(prompt_id) {
                // A resend of one answered and let go of: answered from the log.
                from_log = true;
                false
            } else {
                match inbox.items.iter_mut().find(|i| i.prompt_id == prompt_id) {
                    // A resend of one it holds: answered with it.
                    Some(item) if !item.noticed || item.answer.is_some() => {
                        rx = item.answer.get_or_insert_with(|| tx.clone()).subscribe();
                        // A resend that waits for the reply reads it.
                        if reader.is_some() {
                            item.reader = reader.clone();
                        }
                        false
                    }
                    // A resend of one a notice carried and answered already (or before a restart):
                    // answered with that notice's answer, as a resend of a logged prompt is
                    // (`logged_prompt`).
                    Some(item) => {
                        resent = Some(item.answered.clone());
                        false
                    }
                    None if wake_or_fail && strands => {
                        refused = true;
                        false
                    }
                    None => {
                        held = strands;
                        if let (Some(m), Some(v)) = (page_message.as_ref(), verdict) {
                            page_rule::record(&mut inbox.folds, m, v, now);
                        }
                        inbox.items.push(Item {
                            surge_held: false,
                            verdict,
                            prompt_id: prompt_id.to_owned(),
                            notice: None,
                            answered: None,
                            thread: thread.clone(),
                            from: sender.to_owned(),
                            from_session: sender_session.clone(),
                            asker: super::super::question_replies::asker_of(provenance),
                            sender: sender_identity.clone(),
                            class,
                            report: is_report(provenance),
                            waited,
                            gather: super::super::cold_wake::requested(provenance),
                            at: now,
                            within: crate::prompt_provenance::within(provenance),
                            text: text.clone(),
                            details: provenance.and_then(|p| p.get("details")).cloned(),
                            fire: surge_on && fire_notice(tool_notice.as_ref()),
                            tool_notice,
                            noticed: false,
                            read: false,
                            answer: Some(tx.clone()),
                            reader: reader.clone(),
                        });
                        trim(&mut inbox);
                        true
                    }
                }
            }
        };
        if refused {
            return Err(not_woken(&meta_now.name, sender, class));
        }
        if from_log {
            let answer = self.logged_inbox_answer(session, prompt_id);
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "inbox": true, "duplicate": true}),
            );
            return answer.unwrap_or_else(|| Ok(interrupted(prompt_id)));
        }
        if withdrawn {
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "inbox": true, "withdrawn": true}),
            );
            return Ok(super::super::queue::withdrawn_reply(prompt_id, ""));
        }
        if let Some(answered) = resent {
            // Noticed, carried by no notice now and with no answer: a notice of the daemon before
            // a restart carried it and never ended, as `logged_inbox` answers.
            let answer = answered.unwrap_or_else(|| Ok(interrupted(prompt_id)));
            let answer = answer.map(|mut done| {
                merge_mux_meta(&mut done, json!({"duplicate": true, "noticed": true}));
                done
            });
            tx.send_replace(Some(answer));
        }
        if fresh {
            let mut msg = json!({"promptId": prompt_id, "threadId": thread, "from": sender, "class": class, "kind": kind_of(class), "client": client, "text": text, "prompt": blocks, "sender": sender_identity});
            if let Some(from) = sender_session {
                msg.set("fromSession", json!(from));
            }
            if is_report(provenance) {
                msg.set("report", json!(true));
            }
            if waited {
                msg.set(crate::prompt_provenance::WAITED, json!(true));
            }
            let msg = crate::prompt_provenance::marked(msg, provenance);
            self.append(session, "mux", "inbox", msg);
            self.note_delegator(session, provenance);
            let fire = surge_on && fire_notice(provenance.and_then(|p| p.get("notice")));
            self.inbox_reader_prefetch(session, prompt_id, sender, class, fire, &text);
        }
        // `resent`: a resend of one it holds or a notice carries, not a message kept now
        // (`sender_harness::on_kept` writes no claim for it).
        let mut accepted = json!({"sessionId": session.id, "promptId": prompt_id, "queued": true, "inbox": true, "threadId": thread});
        if !fresh {
            accepted.set("resent", json!(true));
        }
        if held {
            accepted.set(crate::cli::output::HELD_IN_INBOX, json!(true));
        }
        // When the receiver is woken for it at the latest (module docs, "Deadlines"):
        // `acpmux send` and `send --status` print it.
        let within = crate::prompt_provenance::within(provenance);
        accepted.set("dueAt", json!(crate::prompt_class::due_at(class, now_ms(), within)));
        accept(accepted);
        self.inbox_review(session);
        let answer = match rx.wait_for(Option::is_some).await {
            Ok(answer) => answer.clone().unwrap_or_else(|| Err(RpcError::internal("no answer"))),
            Err(_) => Err(super::super::queue::closing_error()),
        };
        answer.map(|mut v| {
            merge_mux_meta(
                &mut v,
                json!({"promptId": prompt_id, "inbox": true, "threadId": thread}),
            );
            v
        })
    }

    /// Archive a lane result the parent already consumed through a wait or transcript read.
    /// It is durable and available in its thread, but has no notice, queued turn or waiter.
    pub(in crate::hub) fn lane_report_delivered_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        lane: &str,
        prompt_id: &str,
        text: &str,
        provenance: &Value,
    ) {
        let from = provenance.get("fromName").and_then(Value::as_str).unwrap_or(lane);
        let thread = thread_key(None, &thread_sender(Some(provenance), from), text);
        let at = now_ms();
        let mut opts = PromptOptions {
            provenance: Some(provenance.clone()),
            agent: Some(from.to_owned()),
            message_id: Some(prompt_id.to_owned()),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        // Rebuild the projection before deriving the sender record: embedding adds the durable
        // author/forwarder context to the provenance used by the inbox projection.
        let message =
            super::super::message_events::message_context(self, session, &blocks, &opts, prompt_id);
        super::super::message_events::embed_message_context(
            &mut opts,
            message.as_ref(),
            &session.id,
        );
        let sender_identity =
            crate::prompt_provenance::sender_record(opts.provenance.as_ref(), Some(lane), None);
        let fresh = {
            let mut inbox = session.inbox();
            if inbox.items.iter().any(|i| i.prompt_id == prompt_id)
                || inbox.trimmed.contains(prompt_id)
            {
                false
            } else {
                inbox.items.push(Item {
                    surge_held: false,
                    verdict: None,
                    prompt_id: prompt_id.to_owned(),
                    notice: None,
                    answered: None,
                    thread: thread.clone(),
                    from: from.to_owned(),
                    from_session: Some(lane.to_owned()),
                    asker: None,
                    sender: sender_identity.clone(),
                    class: PromptClass::Result,
                    report: true,
                    waited: false,
                    gather: false,
                    at,
                    within: None,
                    text: text.to_owned(),
                    details: provenance.get("details").cloned(),
                    tool_notice: None,
                    fire: false,
                    noticed: true,
                    read: true,
                    answer: None,
                    reader: None,
                });
                trim(&mut inbox);
                true
            }
        };
        if !fresh {
            return;
        }
        let msg = json!({
            "promptId": prompt_id, "threadId": thread, "from": from, "fromSession": lane,
            "sender": sender_identity,
            "class": "result", "kind": kind_of(PromptClass::Result), "client": "acpmux", "text": text,
            "prompt": [{"type": "text", "text": text}], "report": true, "deliveredRead": true,
        });
        self.append(
            session,
            "mux",
            "inbox",
            crate::prompt_provenance::marked(msg, opts.provenance.as_ref()),
        );
        if let Some(message) = message.as_ref() {
            super::super::message_events::record_message_context(
                self,
                &session.id,
                message,
                &Value::Null,
            );
        }
        // Existing readers can replay these marks without knowing the new deliveredRead flag.
        self.append(
            session,
            "mux",
            "inbox_read",
            json!({"threadId": thread, "promptIds": [prompt_id]}),
        );
        self.append(
            session,
            "mux",
            "inbox_noticed",
            json!({"promptIds": [prompt_id], "noticePromptId": prompt_id}),
        );
    }

    /// The first message to a chat that never ran a turn names its delegator: its later actions
    /// wake the chat too.
    fn note_delegator(&self, session: &Arc<Session>, provenance: Option<&Value>) {
        let Some(from) = sender_session(provenance) else { return };
        let set = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let set = meta.turn_count == 0 && meta.delegator.is_none() && from != meta.id;
            if set {
                meta.delegator = Some(from);
            }
            set
        };
        if set {
            self.save_meta(session);
        }
    }

    /// Whether a turn is still coming for session `id` with nothing more sent: a prompt queued
    /// behind its turn that is not held aside (between a turn's end and the next one's start no
    /// turn runs), a message this daemon's outbox has not delivered to it yet, or its inbox's
    /// ([`turn_coming`]). A wait for its turn's end does not answer with the idle state from
    /// before (`server/wait.rs`).
    pub(crate) fn work_coming(&self, id: &str) -> bool {
        let Ok(session) = self.resolve(id) else { return false };
        if session.id != id {
            return false;
        }
        if session.meta().status != SessionStatus::Closed
            && super::super::queue::queue_waits(&session)
        {
            return true;
        }
        let name = session.meta().name;
        let named = |target: &str| {
            target == id
                || (!name.is_empty() && target == name)
                || (target.len() >= 8 && id.starts_with(target))
        };
        turn_coming(&session) || self.outbox.pending_to(named)
    }

    /// Delivers the inbox when it may (module docs), else arms the wake timer.
    pub(in crate::hub) fn inbox_review(self: &Arc<Self>, session: &Arc<Session>) {
        let meta = session.meta();
        let now = now_ms();
        // Read before the inbox's lock: the retry's own lock is never taken under it.
        // Taken first: a continuation let go after `continuing` is read still wakes the timer.
        let released = session.auto_resume.released();
        let continuing = self.continuation_pending(session);
        let next = {
            let mut inbox = session.inbox();
            // Set once `new` lets go of the inbox (below).
            let mut held_by_person = false;
            let next = {
                let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
                let oldest = new.iter().map(|i| i.at).min().unwrap_or(now);
                // Nothing new but FYIs: they go with the next notice, or once the oldest is
                // `FLUSH_MS` old (module docs).
                // A folded repeat (`inbox_page_rule.rs`) waits as an FYI does.
                let fyi_only = new.iter().all(|i| ordinary_fyi(i) || folded(i));
                // Read before a Stop's `due_now` below takes the inbox mutably.
                let urgent = new.iter().any(|i| steers_at_once(&meta, i));
                // The soonest deadline (module docs, "Deadlines"), read here for the same reason.
                let due = earliest_due(&new);
                let coalesced = new
                    .iter()
                    .filter(|i| !ordinary_fyi(i) && !folded(i))
                    .map(|i| i.at)
                    .min()
                    .unwrap_or(oldest)
                    .saturating_add(STEER_COALESCE_MS);
                if new.is_empty()
                    || inbox.in_flight.is_some()
                    || meta.status == SessionStatus::Closed
                {
                    Next::Nothing
                } else {
                    match session.turn() {
                        Some(turn) => {
                            let steers = session.steering.load(Ordering::SeqCst);
                            let retry = match inbox.refused_at {
                                0 => 0,
                                at => at.saturating_add(REFUSED_RETRY_MS),
                            };
                            // A review box's turn takes no notice: what its inbox held before
                            // it became one waits for the turn's end (module docs). Nor does
                            // the person's own: the notice goes in as a turn after it, never
                            // into a turn carried on from it (`carried_turn.rs`).
                            held_by_person = turn.persons;
                            // Nor does a turn a Stop is ending: what is new goes in as the next
                            // turn, at once (`cancel.rs` module docs).
                            let stopping =
                                super::super::cancel::is_stopping(session, &turn.turn_id);
                            if stopping {
                                inbox.due_now = true;
                            }
                            if stopping
                                || !steers
                                || turn
                                    .prompt_id
                                    .starts_with(super::super::cold_wake::COMPACT_ID_PREFIX)
                                || turn.persons
                                || inbox.held_by_person
                                || capped(&meta, turn.started_at, now)
                                || prompt_waits(session)
                                || crate::review_box::of_meta(&meta)
                            {
                                Next::Nothing
                            } else if codex_unanswered(session, &meta) {
                                // The model's first sign looks again (`model_answered`).
                                Next::Nothing
                            } else {
                                // A refused steer is tried again no sooner than the backoff: no
                                // loop of refusals within a turn. An FYI-only batch steers in at
                                // its flush, unless a message that is no FYI brings it sooner; a
                                // Stop's `due_now` still lets it in at once.
                                // Results alone wait [`STEER_COALESCE_MS`] after the oldest that
                                // is no FYI, so a burst is one steer (module docs).
                                let flush = if inbox.due_now || urgent {
                                    0
                                } else if fyi_only {
                                    oldest.saturating_add(FLUSH_MS).min(due)
                                } else {
                                    coalesced.min(due)
                                };
                                let at = retry.max(flush);
                                if at > now { Next::WakeAt(at) } else { Next::Steer }
                            }
                        }
                        // A first work holds the chat, or waits in its queue (a restart rebuilds
                        // it with no hold), and has no turn yet: no notice goes ahead of it.
                        // Looked at again after the debounce, until its turn takes the notice,
                        // its hold is let go, or it leaves the queue.
                        None if inbox.first.is_some() || first_work_waits(session) => {
                            Next::WakeAt(now.saturating_add(WAKE_DEBOUNCE_MS))
                        }
                        // While the person's Stop holds the other agents' messages (`cancel.rs`
                        // `hold_agent_messages`), none starts a turn: they wait until the
                        // person's next turn or a resume of the queue ends the hold, which
                        // reviews the inbox again (`release_held_agent_messages`,
                        // `queue_edit.rs` `resume`). A message a Stop sent back included.
                        None if session.stop_hold.load(Ordering::SeqCst) != 0 => Next::Nothing,
                        None => {
                            // A waking message after the debounce; anything after the flush, so no
                            // message is stranded in an idle chat.
                            // Messages the person's own turn held back are due now: they would
                            // have gone into that turn. FYIs alone are not: they would have
                            // waited there too, so the hold lets go of them and they wait for the
                            // flush or the next notice.
                            let lapsed = super::super::cold_wake::coldness(&meta, now).is_some();
                            let quiet = |i: &Item| quiet(&session.id, &meta, lapsed, i);
                            let mut waking_items =
                                new.iter().copied().filter(|i| wakes(&meta, i) && !quiet(i));
                            let waking = waking_items.clone().map(|i| i.at).min();
                            // Every waking message may wait for company (`WARM_HOLD_MS`).
                            let holds = waking_items.all(|i| holds_wake(&meta, i));
                            // No flush sooner than a message's deadline (module docs, "Deadlines")
                            // in an idle chat off the coordinator list. Each flush was a
                            // turn of its own [`FLUSH_MS`] on, past a 5-minute prompt cache, so a
                            // full cache write to carry FYIs and results nobody asked to wake for
                            // (one lane VM, 24 h: 191 `[inbox]` notice turns, 91 of them
                            // more than 5 minutes after the chat's last reply). Leo, 2026-11-25:
                            // "let's continue while not doing bad cache writes!". A coordinator's
                            // held status (`inbox_page_rule.rs`, judged) keeps its 20-minute
                            // ceiling. Then nothing waited at all, which stranded a result for
                            // hours behind a hung background wait: Leo, 2026-11-25, "can't ci
                            // sometimes go indefinitely? or is there a timeout where it can always
                            // check again at some point". So each message has a deadline by class,
                            // and one notice carries everything due or not.
                            let judged = new
                                .iter()
                                .filter(|i| !folded(i) && i.verdict.is_some())
                                .map(|i| i.at)
                                .min()
                                .map_or(u64::MAX, |at| at.saturating_add(FLUSH_MS));
                            // Every held message's deadline (module docs, "Deadlines"): the
                            // oldest due one wakes the chat, and its notice carries every new
                            // message, so a quiet chat takes one turn per deadline at most.
                            let flush = judged.min(if lapsed {
                                new.iter()
                                    .filter(|i| !folded(i))
                                    .map(|i| due_for(i, quiet(i)))
                                    .min()
                                    .unwrap_or(u64::MAX)
                            } else {
                                due
                            });
                            // A blocker or a fire notice wakes after the burst window; anything
                            // else that wakes a chat whose prompt cache lapsed waits for its cold
                            // batch (`cold_wake.rs`), and goes in with what else came meanwhile.
                            let blocker = new.iter().any(|i| {
                                i.fire
                                    || matches!(i.class, PromptClass::Block | PromptClass::Question)
                            });
                            let gather = new.iter().any(|i| {
                                i.gather && !i.surge_held && i.verdict.is_none() && !quiet(i)
                            });
                            if fyi_only {
                                inbox.held_by_person = false;
                            }
                            // Every waking message may wait for company (`WARM_HOLD_MS`): the
                            // burst window grows from 2 s to 5 minutes, ending no later than the
                            // prompt cache does (a hold never turns a warm wake into a cold one).
                            let hold_end = |at: u64| {
                                let end = at.saturating_add(WARM_HOLD_MS);
                                let burst = at.saturating_add(WAKE_DEBOUNCE_MS);
                                match super::super::cold_wake::cache_expires_at(&meta) {
                                    Some(expires) => end.min(expires.max(burst)),
                                    None => end,
                                }
                            };
                            // A bridge can explicitly join the cold batch even when its class
                            // alone would wait for the inbox deadline. Keep page and reader holds.
                            // An open batch keeps its deadline after compaction warms the cache;
                            // cold_batch_due rejects warm chats only when no batch exists.
                            let cold = if !blocker && (waking.is_some() || gather) {
                                self.cold_batch_due(session, &meta, now)
                            } else {
                                None
                            };
                            let due = if inbox.held_by_person || inbox.due_now {
                                now
                            } else {
                                cold.or_else(|| {
                                    waking.map(|at| {
                                        if holds {
                                            hold_end(at)
                                        } else {
                                            at.saturating_add(WAKE_DEBOUNCE_MS)
                                        }
                                    })
                                })
                                .unwrap_or(flush)
                                .min(flush)
                            };
                            let retry = match inbox.refused_at {
                                0 => 0,
                                at => at.saturating_add(REFUSED_RETRY_MS),
                            };
                            let at = due.max(retry);
                            if at == u64::MAX {
                                // Only folded repeats are new: they go with the next notice.
                                Next::Nothing
                            } else if continuing {
                                // The cut turn's continuation may still fire (`auto_resume.rs`):
                                // a turn of its own now would supersede it. Looked at again
                                // later; a continuation that runs ends its timer when its turn
                                // starts (`inbox_turn_started`) and reviews it as it ends.
                                Next::WakeAt(at.max(now.saturating_add(REFUSED_RETRY_MS)))
                            } else if at <= now {
                                Next::Wake
                            } else {
                                Next::WakeAt(at)
                            }
                        }
                    }
                }
            };
            if held_by_person {
                inbox.held_by_person = true;
            }
            match next {
                Next::Nothing => {
                    if let Some(timer) = inbox.timer.take() {
                        timer.abort();
                    }
                }
                Next::WakeAt(at) => self.arm_locked(&mut inbox, session, at, now, released),
                Next::Steer | Next::Wake => {}
            }
            next
        };
        match next {
            // Disarmed and armed under the lock the decision was made under (above), so a review
            // that decided earlier never aborts a timer a later one armed.
            Next::Nothing | Next::WakeAt(_) => {}
            Next::Steer => self.deliver_notice(session, true),
            Next::Wake => self.deliver_notice(session, false),
        }
    }
}
