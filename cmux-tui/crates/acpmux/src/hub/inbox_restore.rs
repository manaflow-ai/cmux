//! Part of the chat inbox (`inbox.rs`): the inbox restored from a session's log, a withdraw
//! of an inbox item, the answers the log holds, and the `_acpmux/inbox_threads` and
//! `_acpmux/inbox_thread` reads.

use super::*;

impl Hub {
    /// The record kinds `restore_inbox` reads (a log load's, so `store/kind_index.rs` copies them).
    pub(crate) const INBOX_KINDS: &[&str] = &[
        "inbox",
        "inbox_triaged",
        "inbox_noticed",
        "inbox_returned",
        "inbox_answered",
        "inbox_read",
        "inbox_removed",
    ];

    /// The inbox from the session's log (`restore_queue`): every message, read and noticed as
    /// the log says. Run again, it adds only what it does not hold.
    pub(in crate::hub) fn restore_inbox(&self, session: &Session) {
        let surge_on = self.surge_inbox_on();
        let mut counts = surge::Counts::default();
        let mut recent_held = std::collections::VecDeque::new();
        // The messages the scan holds, in log order; a slot empties when its message is
        // withdrawn (`inbox_removed`), so a long inbox of handled messages is never held whole.
        let mut items: Vec<Option<Item>> = Vec::new();
        let mut slots: std::collections::HashMap<String, Vec<usize>> = Default::default();
        // The ids of the messages withdrawn while the scan held them (or after it read their
        // withdrawal): each is marked removed below, as a held one was.
        let mut removed_held: Vec<String> = Vec::new();
        // Whether the log holds any message the scan did not hold apart (a surge-held one).
        let mut any_item = false;
        let mut noticed: std::collections::HashMap<String, String> = Default::default();
        let mut read: std::collections::HashSet<String> = Default::default();
        let mut removed: std::collections::HashSet<String> = Default::default();
        let mut answered: std::collections::HashMap<String, super::super::queue::Answer> =
            Default::default();
        let kinds = Self::INBOX_KINDS;
        // And what was changed here but is not in the journal yet (`scan_for_rebuild`).
        let scanned = self.scan_for_rebuild(session, kinds, &mut |e: EventRecord| {
            counts.restore(&e);
            let ids = || {
                let ids = e.msg.get("promptIds").and_then(Value::as_array).cloned();
                ids.unwrap_or_default().into_iter().filter_map(|v| v.as_str().map(str::to_owned))
            };
            match e.kind.as_str() {
                "inbox" => {
                    let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("");
                    let class =
                        crate::prompt_class::recorded(&e.msg).unwrap_or(PromptClass::Result);
                    let provenance = crate::prompt_provenance::recorded(&e.msg);
                    let from_session =
                        e.msg.get("fromSession").and_then(Value::as_str).map(str::to_owned);
                    let stored_sender = e.msg.get("sender");
                    let sender = stored_sender.cloned().unwrap_or_else(|| {
                        crate::prompt_provenance::sender_record(
                            provenance.as_ref(),
                            from_session.as_deref(),
                            None,
                        )
                    });
                    let thread = field("threadId").to_owned();
                    let thread = if stored_sender.is_none() {
                        legacy_thread_key(provenance.as_ref(), field("from"), thread)
                    } else {
                        thread
                    };
                    // A notice journaled under a thread of its pull request folds as a new one does.
                    let thread = fold::refolded(thread, field("text"));
                    let item = Item {
                        surge_held: e.msg.get("surgeHeld") == Some(&Value::Bool(true)),
                        verdict: None,
                        prompt_id: field("promptId").to_owned(),
                        notice: None,
                        answered: None,
                        thread,
                        from: field("from").to_owned(),
                        from_session,
                        asker: super::super::question_replies::asker_of(provenance.as_ref()),
                        sender,
                        class,
                        report: e.msg.get("report") == Some(&Value::Bool(true)),
                        waited: e.msg.get(crate::prompt_provenance::WAITED)
                            == Some(&Value::Bool(true)),
                        at: e.at,
                        within: crate::prompt_provenance::within(provenance.as_ref()),
                        text: field("text").to_owned(),
                        details: provenance.as_ref().and_then(|p| p.get("details").cloned()),
                        fire: surge_on
                            && fire_notice(notice_of(provenance.as_ref(), field("text")).as_ref()),
                        tool_notice: notice_of(provenance.as_ref(), field("text")),
                        noticed: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
                        read: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
                        answer: None,
                        reader: None,
                    };
                    if item.surge_held {
                        if recent_held.len() == KEEP {
                            recent_held.pop_front();
                        }
                        recent_held.push_back(item);
                    } else {
                        any_item = true;
                        if removed.contains(&item.prompt_id) {
                            removed_held.push(item.prompt_id);
                        } else {
                            slots.entry(item.prompt_id.clone()).or_default().push(items.len());
                            items.push(Some(item));
                        }
                    }
                }
                "inbox_noticed" => {
                    let notice = e.msg.get("noticePromptId").and_then(Value::as_str);
                    let notice = notice.unwrap_or_default().to_owned();
                    noticed.extend(ids().map(|id| (id, notice.clone())));
                }
                // Taken back by a Stop unread (`inbox_notice_unwritten`): new again.
                "inbox_returned" => {
                    for id in ids() {
                        noticed.remove(&id);
                    }
                }
                "inbox_answered" => {
                    if let Some((notice, answer)) = answered_record(&e.msg) {
                        answered.insert(notice, answer);
                    }
                }
                "inbox_read" => read.extend(ids()),
                "inbox_removed" => {
                    let id = e.msg.get("promptId").and_then(Value::as_str).unwrap_or_default();
                    for slot in slots.remove(id).unwrap_or_default() {
                        if let Some(item) = items.get_mut(slot).and_then(Option::take) {
                            removed_held.push(item.prompt_id);
                        }
                    }
                    removed.insert(id.to_owned());
                }
                _ => {}
            }
            true
        });
        drop(slots);
        let mut items: Vec<Item> = items.into_iter().flatten().collect();
        any_item |= !recent_held.is_empty();
        items.extend(recent_held);
        if scanned.is_err() || (!any_item && counts.seq == 0) {
            return;
        }
        // The state itself: `Session::inbox` calls this to fill it.
        let mut surge_held = false;
        let mut inbox = session.inbox_state.lock().unwrap_or_else(|e| e.into_inner());
        {
            let mut live = inbox.surge_counts.lock().unwrap_or_else(|e| e.into_inner());
            if counts.seq > live.seq {
                *live = counts;
            }
        }
        inbox.removed.extend(removed_held);
        // The ids the inbox holds: a set, not a walk of the inbox for each restored message.
        let mut held: std::collections::HashSet<String> =
            inbox.items.iter().map(|i| i.prompt_id.clone()).collect();
        for mut item in items {
            if removed.contains(&item.prompt_id) {
                inbox.removed.insert(item.prompt_id.clone());
            }
            // One taken out here since is out too, its record maybe not in the log yet (it
            // waits while a restore owns the chat: review of #37284 at 07f76930, F1).
            if item.prompt_id.is_empty()
                || removed.contains(&item.prompt_id)
                || inbox.removed.contains(&item.prompt_id)
                || inbox.trimmed.contains(&item.prompt_id)
                || held.contains(&item.prompt_id)
            {
                continue;
            }
            item.notice = noticed.get(&item.prompt_id).cloned().filter(|n| !n.is_empty());
            item.answered = item.notice.as_ref().and_then(|n| answered.get(n).cloned());
            item.noticed |= noticed.contains_key(&item.prompt_id);
            if item.surge_held {
                item.noticed = true;
                inbox.surge_rate.restore(item.at);
                surge_held = true;
            }
            item.read |= read.contains(&item.prompt_id);
            held.insert(item.prompt_id.clone());
            inbox.items.push(item);
        }
        fold::fold_all(&mut inbox);
        trim(&mut inbox);
        // What an earlier run archived stays readable from the archive file.
        if let Some(dir) = self.store.session_path(&session.id).filter(|p| p.is_dir()) {
            let (held, _) = fold::archive_threads(&dir);
            inbox.archived_threads.extend(held);
        }
        // A needYou journaled before a restart is counted again by the pass (a rule may have
        // changed what counts: program notices are fyi now).
        surge_held |= inbox.surge_counts_need_you() > 0;
        // New messages came back with no timer: the review arms their deadline wake again
        // (`inbox_deadline.rs`), else they wait for a turn nothing starts.
        let any_new = inbox.items.iter().any(|i| !i.noticed && !folded(i));
        drop(inbox);
        self.archive_aged_inbox(session);
        if any_new {
            deadline::review_after_restore(session);
        }
        // A restart resumes the held backlog's triage with no new arrival (`surge_triage.rs`).
        if surge_held {
            super::super::surge_triage::resume_after_restore(session);
        }
    }

    /// `_acpmux/prompt_withdraw` of an inbox item (`withdraw.rs`): one no notice carried yet
    /// leaves the inbox, with an `inbox_removed` record (so a restart drops it too), and its
    /// sender's `session/prompt` answers withdrawn; one a notice carried stays, and the withdraw
    /// sends a notice into its thread.
    pub(in crate::hub) fn inbox_unsend(&self, session: &Arc<Session>, prompt_id: &str) -> Unsend {
        let removed = {
            let mut inbox = session.inbox();
            let found = inbox.items.iter().enumerate().find(|(_, i)| i.prompt_id == prompt_id);
            match found.map(|(at, i)| (at, i.noticed, i.notice.is_none())) {
                None => return Unsend::Gone,
                Some((_, true, true)) => return Unsend::Carried,
                Some((_, true, false)) => return Unsend::Noticed,
                Some((i, false, _)) => {
                    inbox.removed.insert(prompt_id.to_owned());
                    inbox.items.remove(i)
                }
            }
        };
        let why = json!({"promptId": prompt_id, "threadId": removed.thread, "reason": "withdrawn"});
        self.append(session, "mux", "inbox_removed", why);
        if let Some(answer) = removed.answer {
            answer.send_replace(Some(Ok(super::super::queue::withdrawn_reply(prompt_id, ""))));
        }
        Unsend::Unsent
    }

    /// Waits until no notice that is not written yet carries `prompt_id` (`Unsend::Carried`):
    /// it was written (the message went in) or it ended (the message is new again).
    pub(in crate::hub) async fn inbox_settled(&self, session: &Session, prompt_id: &str) {
        loop {
            let settled = session.inbox().settled.clone();
            let woken = settled.notified();
            tokio::pin!(woken);
            woken.as_mut().enable();
            let carried = {
                let inbox = session.inbox();
                let item = inbox.items.iter().find(|i| i.prompt_id == prompt_id);
                item.is_some_and(|i| i.noticed && i.notice.is_none())
                    && inbox.carrying.iter().any(|c| c.ids.iter().any(|id| id == prompt_id))
            };
            if !carried || super::super::queue::closing(session) {
                return;
            }
            woken.await;
        }
    }

    /// A resent inbox message the log holds (`logged_prompt`), as the prompt ledger answers a
    /// logged prompt: [`Hub::logged_inbox_answer`], a failure as `status: "failed"`.
    pub(in crate::hub) fn logged_inbox(&self, session: &Session, prompt_id: &str) -> Option<Value> {
        Some(match self.logged_inbox_answer(session, prompt_id)? {
            Ok(v) => v,
            Err(e) => json!({
                "stopReason": Value::Null,
                "_meta": {"acpmux": {"promptId": prompt_id, "inbox": true, "duplicate": true, "status": "failed", "error": e}},
            }),
        })
    }

    /// The answer of a resent inbox message the log holds: withdrawn, its notice's answer (an
    /// error too), or `interrupted` when a notice carried it and the daemon stopped before it
    /// ended. None while the inbox still holds it unanswered (`inbox_accept` answers then), or
    /// when the log has no such message.
    pub(in crate::hub) fn logged_inbox_answer(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<super::super::queue::Answer> {
        let names = |m: &Value| {
            let ids = m.get("promptIds").and_then(Value::as_array);
            ids.is_some_and(|ids| ids.iter().any(|v| v.as_str() == Some(prompt_id)))
        };
        let (mut found, mut removed, mut noticed) = (false, false, false);
        let mut surge_thread = None;
        let mut answer: Option<super::super::queue::Answer> = None;
        let kinds = INBOX_ANSWER_KINDS;
        // Only the records naming it are read whole: by `promptId`, or in a list of prompts
        // (`promptIds`, which the head holds: a coordinator's every resend read all its notices).
        let keep = &mut |h: &crate::store::KindHead<'_>| -> bool {
            h.unread || h.prompt_id == Some(prompt_id) || h.names(|p| p == prompt_id)
        };
        let _ = self.scan_for_rebuild_keyed(session, kinds, keep, &mut |e: EventRecord| {
            let own = e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id);
            match e.kind.as_str() {
                "inbox" if own => {
                    found = true;
                    if e.msg.get("surgeHeld") == Some(&Value::Bool(true)) {
                        surge_thread = e.msg.get("threadId").cloned();
                    }
                }
                "inbox_removed" if own => removed = true,
                "inbox_noticed" if names(&e.msg) => noticed = true,
                "inbox_answered" if names(&e.msg) => answer = answered_record(&e.msg).map(|a| a.1),
                _ => {}
            }
            true
        });
        if !found {
            return None;
        }
        if removed {
            return Some(Ok(super::super::queue::withdrawn_reply(prompt_id, "")));
        }
        if let Some(thread) = surge_thread {
            return Some(Ok(json!({"stopReason":"end_turn","_meta":{"acpmux":{
                "promptId":prompt_id,"threadId":thread,"inbox":true,"duplicate":true,"surgeHeld":true
            }}})));
        }
        let meta = json!({"promptId": prompt_id, "inbox": true, "duplicate": true});
        match answer {
            Some(answer) => Some(answer.map(|mut v| {
                merge_mux_meta(&mut v, meta);
                v
            })),
            None => {
                let held = session.inbox();
                if !noticed || held.items.iter().any(|i| i.prompt_id == prompt_id) {
                    return None;
                }
                Some(Ok(interrupted(prompt_id)))
            }
        }
    }

    /// `_acpmux/inbox_threads`: the chat's threads, the one with the newest message first.
    pub fn inbox_threads(&self, session: &Session) -> Value {
        self.inbox_threads_page(session, None, None)
    }

    /// [`Self::inbox_threads`], a page of it: at most `limit` threads, those whose newest
    /// message is older than `before` (unix ms) when given. `more` names the `before` of the next
    /// page, null on the last. With no `limit`, every thread.
    pub fn inbox_threads_page(
        &self,
        session: &Session,
        limit: Option<usize>,
        before: Option<u64>,
    ) -> Value {
        // Old read messages leave memory first, so the list is of what is live.
        self.archive_aged_inbox(session);
        // Read before the inbox lock: the journal's read pruning takes it.
        let held_now = self.surge_held_now(session);
        let inbox = session.inbox();
        // One pass, one map: a thread is found by its key, not by a walk of the threads so far.
        let mut at: std::collections::HashMap<&str, usize> =
            std::collections::HashMap::with_capacity(inbox.items.len() / 2 + 1);
        let mut threads: Vec<(&str, Vec<&Item>)> = Vec::new();
        for item in &inbox.items {
            match at.get(item.thread.as_str()) {
                Some(&i) => threads[i].1.push(item),
                None => {
                    at.insert(&item.thread, threads.len());
                    threads.push((&item.thread, vec![item]));
                }
            }
        }
        let newest = |list: &[&Item]| list.iter().map(|i| i.at).max().unwrap_or(0);
        let now = now_ms();
        let mut threads: Vec<(u64, &str, Vec<&Item>)> =
            threads.into_iter().map(|(k, list)| (newest(&list), k, list)).collect();
        threads.sort_by_key(|(at, _, _)| std::cmp::Reverse(*at));
        if let Some(before) = before {
            threads.retain(|(at, _, _)| *at < before);
        }
        let total = threads.len();
        let limit = limit.unwrap_or(usize::MAX).max(1);
        let more = (total > limit).then(|| threads[limit - 1].0);
        threads.truncate(limit);
        let rows: Vec<Value> = threads
            .iter()
            .map(|(_, key, list)| {
                let mut from: Vec<String> = Vec::new();
                for i in list {
                    let shown = display_sender(&i.sender, &i.from);
                    if !from.contains(&shown) {
                        from.push(shown);
                    }
                }
                let unread: Vec<&&Item> = list.iter().filter(|i| !i.read).collect();
                let last = list.iter().max_by_key(|i| i.at);
                let class = if unread.iter().any(|i| i.class.urgent()) {
                    "blocker"
                } else if unread.iter().any(|i| i.class == PromptClass::Result) {
                    "action"
                } else {
                    "fyi"
                };
                let folded_count = inbox.folded.get(*key).copied().unwrap_or(0);
                json!({
                    "threadId": key, "key": key, "label": label(key), "from": from,
                    "unread": unread.len(), "new": list.iter().filter(|i| !i.noticed).count(),
                    "count": list.len() as u64 + folded_count, "folded": folded_count, "newestAt": newest(list),
                    "surgeHeld": list.iter().any(|i| i.surge_held),
                    // The held bar's "need you" filter: an unread message for the person.
                    // A program's notice that is no FIRE never is, held before that rule or not.
                    "needYou": unread.iter().any(|i| {
                        crate::surge_triage::needs_person(
                            i.class.as_str(), &i.text, super::super::presence::owner_name())
                            && !crate::surge_triage::program_fyi(&json!({
                                "fromSession": i.from_session, "sender": i.sender, "text": i.text}))
                    }),
                    "newestPreview": last.map(|i| preview(&i.text)), "class": class,
                    "sender": last.map(|i| i.sender.clone()),
                    // Deadlines (module docs): the soonest new message's, and how many new
                    // ones are past theirs (NOW counts those red).
                    "dueAt": list.iter().filter(|i| !i.noticed && !folded(i)).map(|i| i.due()).min(),
                    "overdue": list
                        .iter()
                        .filter(|i| !i.noticed && !folded(i) && i.due() < now)
                        .count(),
                })
            })
            .collect();
        let counts = {
            let mut counts = inbox.surge_counts.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((held, through)) = held_now {
                counts.settle_held(held, through);
            }
            counts.json()
        };
        json!({"sessionId": session.id, "threads": rows, "surge": counts,
               "total": total, "more": more})
    }

    /// `_acpmux/inbox_thread`: a thread's messages, newest first; `mark_read` marks them read.
    pub fn inbox_thread(&self, session: &Session, thread: &str, mark_read: bool) -> Value {
        let (messages, marked, label_key) = {
            let mut inbox = session.inbox();
            let mut marked = Vec::new();
            let mut messages = Vec::new();
            let allow_declared_fallback = thread.starts_with("from:")
                && !inbox.items.iter().any(|item| item.thread == thread);
            let label_key = inbox
                .items
                .iter()
                .find(|item| thread_matches(item, thread, allow_declared_fallback))
                .map(|item| item.thread.clone())
                .unwrap_or_else(|| thread.to_owned());
            for item in inbox
                .items
                .iter_mut()
                .rev()
                .filter(|i| thread_matches(i, thread, allow_declared_fallback))
            {
                // `from` is the agent's words (`inbox_read`, `acpmux session inbox`, the team
                // read); `fromName` is the name alone, which the transcript draws when the person
                // opens the thread, as a notice's parts name it.
                messages.push(json!({
                    "promptId": item.prompt_id, "from": display_sender(&item.sender, &item.from),
                    "fromName": shown_sender(&item.sender, &item.from), "fromSession": item.from_session,
                    "sender": item.sender,
                    "class": item.class, "kind": kind_of(item.class), "at": item.at,
                    "text": item.text, "read": item.read, "details": item.details,
                    "notice": item.tool_notice, "surgeHeld": item.surge_held,
                }));
                if mark_read && !item.read {
                    item.read = true;
                    marked.push(item.prompt_id.clone());
                }
            }
            (messages, marked, label_key)
        };
        if !marked.is_empty() {
            let msg = json!({"threadId": thread, "promptIds": marked, "wholeThread": true});
            self.append(session, "mux", super::super::surge_triage::READ_KIND, msg);
        }
        if mark_read {
            self.surge_after_read(session, Some(thread));
        }
        json!({"sessionId": session.id, "threadId": thread, "label": label(&label_key), "messages": messages})
    }
}
