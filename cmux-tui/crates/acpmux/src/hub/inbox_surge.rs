//! Rate decisions belong to the receiver. A chat can process one ordinary message per
//! measured reply period. Keep one arrival timestamp regardless of how many senders it has.
use super::*;

/// The last journaled snapshot powers the single chat row even when older posts leave memory.
#[derive(Clone, Copy, Default)]
pub(super) struct Counts {
    pub(super) seq: u64,
    held: u64,
    need_you: u64,
}

impl Counts {
    pub(super) fn json(&self) -> Value {
        json!({"held": self.held, "needYou": self.need_you})
    }

    pub(super) fn restore(&mut self, event: &EventRecord) {
        if event.seq <= self.seq {
            return;
        }
        if let (Some(held), Some(need_you)) = (
            event.msg.pointer("/surge/held").and_then(Value::as_u64),
            event.msg.pointer("/surge/needYou").and_then(Value::as_u64),
        ) {
            *self = Self { seq: event.seq, held, need_you };
        } else if event.kind == "inbox" && event.msg["surgeHeld"] == true {
            self.held = self.held.saturating_add(1);
            self.seq = event.seq;
        }
    }
}

#[derive(Default)]
pub(super) struct SurgeRate {
    last_arrival: Option<u64>,
    excess_ms: u64,
    restored_period_ms: Option<u64>,
}

impl SurgeRate {
    pub(super) fn arrival(&mut self, now: u64, reply_period: Option<u64>) -> bool {
        let previous = self.last_arrival;
        self.last_arrival = Some(previous.map_or(now, |at| at.max(now)));
        let Some((at, period)) = previous.zip(reply_period) else {
            self.excess_ms = 0;
            return false;
        };
        // A burst can run at most one reply ahead. Spare time in later gaps pays that
        // excess down, so one long gap in a busy stream doesn't immediately reopen chat.
        let elapsed = now.saturating_sub(at);
        self.excess_ms =
            self.excess_ms.min(period).saturating_add(period).saturating_sub(elapsed).min(period);
        self.excess_ms > 0
    }

    pub(super) fn restore_held(&mut self, at: u64, period_ms: Option<u64>) {
        if self.last_arrival.is_none_or(|later| at >= later) {
            self.last_arrival = Some(at);
            self.restored_period_ms = period_ms.filter(|p| *p > 0);
        }
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
        let mut next = *counts;
        match actionable_topics {
            Some(n) => next.need_you = n,
            None => next.held = next.held.saturating_add(1),
        }
        msg["surge"] = next.json();
        // The caller retries a failed append. A parked copy must not be replayed behind it.
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.catch_up_locked(session);
        let (event, stored) =
            self.append_at_locked(session, "mux", kind, msg, None, None, true, true);
        if !stored {
            return Err(RpcError::internal("could not persist the surge inbox event"));
        }
        next.seq = event.seq;
        *counts = next;
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
        let elapsed = session.turn().map(|turn| now.saturating_sub(turn.started_at));
        let period = {
            let mut inbox = session.inbox();
            let rate = &mut inbox.surge_rate;
            // The previous hold records this receiver's measured service time. Reuse it while
            // the full timing reducer loads, even before a headless session starts another turn.
            let period = measured.or(rate.restored_period_ms).or(elapsed);
            if !rate.arrival(now, period) {
                return Ok(None);
            }
            period
        };
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
        assert!(slow.arrival(349, Some(100)));
        assert!(!slow.arrival(500, Some(100)));
        slow.restore_held(500, Some(100));
        assert!(slow.arrival(520, Some(100)));
    }

    #[test]
    fn surge_recovers_during_sustained_slower_traffic() {
        let mut rate = SurgeRate::default();
        assert!(!rate.arrival(0, Some(100)));
        for at in [5, 10, 120, 200, 325, 450, 575] {
            assert!(rate.arrival(at, Some(100)));
        }
        assert!(!rate.arrival(700, Some(100)));
        assert!(!rate.arrival(825, Some(100)));
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
