//! Rate decisions belong to the receiver. A chat can process one ordinary message per
//! measured reply period. Keep one arrival timestamp regardless of how many senders it has.
use super::*;

/// The last journaled snapshot powers the single chat row even when older posts leave memory.
#[derive(Clone, Default)]
pub(super) struct Counts {
    pub(super) seq: u64,
    held: u64,
    need_you: u64,
    /// Actionable triage decisions, keyed by prompt so reads and withdrawals can apply a
    /// bounded delta without rescanning the inbox. The thread map is the distinct-topic view.
    actionable_by_prompt: std::collections::HashMap<String, String>,
    actionable_by_thread: std::collections::HashMap<String, u64>,
    read_prompts: std::collections::HashSet<String>,
}

impl Counts {
    pub(super) fn json(&self) -> Value {
        json!({"held": self.held, "needYou": self.need_you})
    }

    fn add_actionable(&mut self, prompt_id: &str, thread_id: &str) {
        if prompt_id.is_empty()
            || thread_id.is_empty()
            || self.actionable_by_prompt.contains_key(prompt_id)
        {
            return;
        }
        self.actionable_by_prompt.insert(prompt_id.to_owned(), thread_id.to_owned());
        *self.actionable_by_thread.entry(thread_id.to_owned()).or_default() += 1;
        self.need_you = self.actionable_by_thread.len() as u64;
    }

    fn remove_actionable(&mut self, prompt_id: &str) {
        let Some(thread_id) = self.actionable_by_prompt.remove(prompt_id) else { return };
        let Some(count) = self.actionable_by_thread.get_mut(&thread_id) else { return };
        *count = count.saturating_sub(1);
        if *count == 0 {
            self.actionable_by_thread.remove(&thread_id);
        }
        self.need_you = self.actionable_by_thread.len() as u64;
    }

    fn triage_additions(&self, msg: &Value) -> (Vec<(String, String)>, u64) {
        let mut additions = Vec::new();
        let mut new_threads = std::collections::HashSet::new();
        if let Some(items) = msg.get("items").and_then(Value::as_array) {
            for item in items {
                if item.get("category").and_then(Value::as_str) != Some("needs_this_session")
                    || item.get("repeatOf").and_then(Value::as_str).is_some()
                {
                    continue;
                }
                let prompt = item.get("promptId").and_then(Value::as_str).unwrap_or_default();
                let thread = item.get("threadId").and_then(Value::as_str).unwrap_or_default();
                if prompt.is_empty()
                    || thread.is_empty()
                    || self.read_prompts.contains(prompt)
                    || self.actionable_by_prompt.contains_key(prompt)
                    || additions.iter().any(|(id, _)| id == prompt)
                {
                    continue;
                }
                if !self.actionable_by_thread.contains_key(thread) {
                    new_threads.insert(thread.to_owned());
                }
                additions.push((prompt.to_owned(), thread.to_owned()));
            }
        }
        (additions, self.actionable_by_thread.len() as u64 + new_threads.len() as u64)
    }

    fn apply_event(&mut self, event: &EventRecord) {
        match event.kind.as_str() {
            "inbox_triaged" => {
                let (additions, _) = self.triage_additions(&event.msg);
                for (prompt, thread) in additions {
                    self.add_actionable(&prompt, &thread);
                }
                // Older callers wrote an empty record with a scalar actionable count. Keep that
                // compatibility value until a prompt-keyed delta supplies the authoritative map.
                if event
                    .msg
                    .get("items")
                    .and_then(Value::as_array)
                    .map_or(true, |items| items.is_empty())
                    && let Some(n) = event.msg.pointer("/surge/needYou").and_then(Value::as_u64)
                {
                    self.need_you = n;
                }
            }
            "inbox_read" => {
                if let Some(ids) = event.msg.get("promptIds").and_then(Value::as_array) {
                    for id in ids.iter().filter_map(Value::as_str) {
                        self.read_prompts.insert(id.to_owned());
                        self.remove_actionable(id);
                    }
                }
            }
            "inbox_removed" => {
                if let Some(id) = event.msg.get("promptId").and_then(Value::as_str) {
                    self.remove_actionable(id);
                }
            }
            _ => {}
        }
    }

    pub(super) fn apply(&mut self, event: &EventRecord) {
        self.apply_event(event);
        self.seq = self.seq.max(event.seq);
    }

    pub(super) fn restore(&mut self, event: &EventRecord) {
        if event.seq <= self.seq {
            return;
        }
        self.apply_event(event);
        if let (Some(held), Some(need_you)) = (
            event.msg.pointer("/surge/held").and_then(Value::as_u64),
            event.msg.pointer("/surge/needYou").and_then(Value::as_u64),
        ) {
            self.held = held;
            if self.actionable_by_thread.is_empty() {
                self.need_you = need_you;
            } else {
                self.need_you = self.actionable_by_thread.len() as u64;
            }
            self.seq = event.seq;
        } else if event.kind == "inbox" && event.msg["surgeHeld"] == true {
            self.held = self.held.saturating_add(1);
            self.seq = event.seq;
        } else {
            self.seq = event.seq;
        }
    }

    pub(super) fn need_you_for(&self, thread: &str) -> bool {
        self.actionable_by_thread.contains_key(thread)
    }
}

#[derive(Default)]
pub(super) struct SurgeRate {
    last_arrival: Option<u64>,
}

impl SurgeRate {
    pub(super) fn arrival(&mut self, now: u64, reply_period: Option<u64>) -> bool {
        let previous = self.last_arrival.replace(now);
        previous.zip(reply_period).is_some_and(|(at, period)| now.saturating_sub(at) < period)
    }

    pub(super) fn restore(&mut self, at: u64) {
        self.last_arrival = Some(self.last_arrival.map_or(at, |later| later.max(at)));
    }
}

fn eligible(opts: &PromptOptions, blocks: &[Value]) -> Option<String> {
    let provenance = opts.provenance.as_ref();
    if opts.human_authenticated
        || opts.unproven_owner
        || opts.send_now
        || opts.class.is_some_and(PromptClass::urgent)
        || opts.wake_or_fail
        || opts.reply_reader.is_some()
        || opts.race_guard.is_some()
        || opts.after_turn.is_some()
        || opts.supersede.is_some()
        || opts.steer_only
        || opts.control == Control::Web
        || crate::author::of_provenance(provenance).is_some()
        || fire_notice(provenance.and_then(|p| p.get("notice")))
        || !blocks.iter().all(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        || crate::prompt_uploads::any(blocks)
        || super::super::forum::slash_command(blocks).is_some()
        // The receiver's own batch must reach it. External tool notices have kind "notice".
        || provenance.and_then(|p| p["kind"].as_str()) == Some(super::NOTICE_KIND)
    {
        return None;
    }
    super::super::digest::agent_sender(provenance, opts.agent.as_deref())
}

impl Hub {
    /// The attach path only needs counters; it never has to group the session's messages.
    pub(crate) fn surge_snapshot(&self, session: &Session) -> Value {
        let state = session.inbox().surge_counts.clone();
        let counts = state.lock().unwrap_or_else(|e| e.into_inner());
        json!({"held": counts.held, "needYou": counts.need_you, "seq": counts.seq})
    }

    /// Store a triage pass together with its current number of actionable topics.
    pub(crate) fn persist_surge_triage(
        &self,
        session: &Session,
        batch: Value,
        actionable_topics: u64,
    ) -> Result<(), RpcError> {
        self.persist_surge_event(session, "inbox_triaged", batch, Some(actionable_topics))
    }

    fn persist_surge_event(
        &self,
        session: &Session,
        kind: &str,
        mut msg: Value,
        actionable_topics: Option<u64>,
    ) -> Result<(), RpcError> {
        let state = session.inbox().surge_counts.clone();
        let mut counts = state.lock().unwrap_or_else(|e| e.into_inner());
        let (additions, mut next_need) = if kind == "inbox_triaged" {
            counts.triage_additions(&msg)
        } else {
            (Vec::new(), counts.need_you)
        };
        if let Some(n) = actionable_topics {
            if additions.is_empty() {
                next_need = if counts.actionable_by_thread.is_empty() {
                    n
                } else {
                    counts.actionable_by_thread.len() as u64
                };
            }
        }
        let next_held = counts.held.saturating_add(u64::from(actionable_topics.is_none()));
        msg["surge"] = json!({"held": next_held, "needYou": next_need});
        // The caller retries a failed append. A parked copy must not be replayed behind it.
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.catch_up_locked(session);
        let (event, stored) =
            self.append_at_locked(session, "mux", kind, msg, None, None, true, true);
        if !stored {
            return Err(RpcError::internal("could not persist the surge inbox event"));
        }
        counts.held = next_held;
        for (prompt, thread) in additions {
            counts.add_actionable(&prompt, &thread);
        }
        counts.need_you = next_need;
        counts.seq = event.seq;
        Ok(())
    }

    /// Page the original records, including ones older than the live inbox projection.
    pub(crate) fn search_held_inbox(
        &self,
        session: &Session,
        needle: &crate::chats::search::Needle,
        before: Option<u64>,
    ) -> Result<Value, RpcError> {
        const PAGE: usize = 50;
        let mut hits = std::collections::VecDeque::with_capacity(PAGE);
        let mut more = false;
        self.scan_for_rebuild(session, &["inbox"], &mut |record| {
            if before.is_some_and(|end| record.seq >= end) { return false; }
            let msg = &record.msg;
            if msg["surgeHeld"].as_bool() == Some(true) {
                let searchable = ["text","from","threadId","promptId"].map(|key| msg[key].as_str().unwrap_or_default()).join("\n");
                if needle.find(&searchable).is_some() {
                    if hits.len() == PAGE { hits.pop_front(); more = true; }
                    hits.push_back(json!({"seq":record.seq,"at":record.at,"promptId":msg["promptId"],
                        "from":msg["from"], "threadId":msg["threadId"], "text":msg["text"],"sender":msg["sender"]}));
                }
            }
            true
        }).map_err(|e| RpcError::internal(format!("read held inbox: {e}")))?;
        let next = more.then(|| hits.front().and_then(|v| v["seq"].as_u64())).flatten();
        let hits: Vec<_> = hits.into_iter().rev().collect();
        Ok(json!({"sessionId":session.id,"hits":hits,"next":next}))
    }

    /// A surge receipt means the receiver journal already holds the entire original prompt.
    /// No turn, steer, ordinary inbox notice, or caller waiting on a nonexistent turn is created.
    pub(in crate::hub) fn hold_surge_message(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        client: &str,
        blocks: &[Value],
        opts: &PromptOptions,
        now: u64,
    ) -> Result<Option<Value>, RpcError> {
        let Some(from) = eligible(opts, blocks) else { return Ok(None) };
        self.start_time_breakdown_backfill(session);
        let measured =
            session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner()).reply_period_ms(now);
        let period =
            measured.or_else(|| session.turn().map(|turn| now.saturating_sub(turn.started_at)));
        if !session.inbox().surge_rate.arrival(now, period) {
            return Ok(None);
        }
        if super::super::queue::closing(session) {
            return Err(super::super::queue::closing_error());
        }
        if session.moving().is_some() {
            return Err(super::super::queue::moving_error(session));
        }

        let provenance = opts.provenance.as_ref();
        let text = prompt_text(blocks);
        let notice = tool_notice_of(provenance);
        let thread = surge_topic(
            opts.thread.as_deref(),
            &text,
            notice.as_ref(),
            &thread_sender(provenance, &from),
        );
        let from_session = sender_session(provenance);
        let sender_meta =
            from_session.as_deref().and_then(|id| self.resolve(id).ok()).map(|s| s.meta());
        let sender = crate::prompt_provenance::sender_record(
            provenance,
            from_session.as_deref(),
            sender_meta.as_ref(),
        );
        let class = opts.class.unwrap_or(if notice.is_some() {
            PromptClass::Fyi
        } else {
            PromptClass::Result
        });
        let msg = json!({"promptId": prompt_id, "threadId": thread, "from": from, "fromSession": from_session,
            "class":class,"kind":kind_of(class),"client":client,"text":text,"prompt":blocks,
            "sender":sender,"surgeHeld":true,"replyPeriodMs":period,"report":is_report(provenance)});
        self.persist_surge_event(
            session,
            "inbox",
            crate::prompt_provenance::marked(msg, provenance),
            None,
        )?;
        let item = Item {
            prompt_id: prompt_id.to_owned(),
            notice: None,
            answered: None,
            thread: thread.clone(),
            from,
            from_session,
            asker: None,
            sender,
            class,
            report: is_report(provenance),
            at: now,
            text,
            details: provenance.and_then(|p| p.get("details")).cloned(),
            tool_notice: notice,
            surge_held: true,
            noticed: true,
            read: false,
            answer: None,
            reader: None,
        };
        let mut inbox = session.inbox();
        inbox.items.push(item);
        trim(&mut inbox);
        Ok(Some(
            json!({"sessionId":session.id,"promptId":prompt_id,"threadId":thread,"inbox":true,"surgeHeld":true,"queued":false}),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn surge_starts_and_recovers_at_the_receivers_measured_rate() {
        let mut fast = SurgeRate::default();
        let mut slow = SurgeRate::default();
        assert!(!fast.arrival(100, Some(10)));
        assert!(!slow.arrival(100, Some(100)));
        assert!(!fast.arrival(150, Some(10)));
        assert!(slow.arrival(150, Some(100)));
        assert!(slow.arrival(249, Some(100)));
        assert!(!slow.arrival(349, Some(100)));
        slow.restore(500);
        assert!(slow.arrival(520, Some(100)));
    }

    #[test]
    fn surge_bypasses_people_questions_blocks_and_fire() {
        let blocks = [json!({"type":"text","text":"ordinary report"})];
        let mut opts = PromptOptions { agent: Some("lane".into()), ..Default::default() };
        assert!(eligible(&opts, &blocks).is_some());
        opts.human_authenticated = true;
        assert!(eligible(&opts, &blocks).is_none());
        opts.human_authenticated = false;
        let (_reader, receiver) = tokio::sync::watch::channel(false);
        opts.reply_reader = Some(receiver);
        assert!(eligible(&opts, &blocks).is_none());
        opts.reply_reader = None;
        for urgent in [PromptClass::Question, PromptClass::Block] {
            opts.class = Some(urgent);
            assert!(eligible(&opts, &blocks).is_none());
        }
        opts.class = Some(PromptClass::Fyi);
        opts.agent = None;
        opts.provenance = Some(crate::prompt_provenance::notice(
            &json!({"sender":"watcher","severity":"warn"}),
            "receiver",
        ));
        assert_eq!(eligible(&opts, &blocks).as_deref(), Some("watcher"));
        opts.provenance = Some(crate::prompt_provenance::notice(
            &json!({"sender":"watcher","severity":"fire"}),
            "receiver",
        ));
        assert!(eligible(&opts, &blocks).is_none());
    }
}
