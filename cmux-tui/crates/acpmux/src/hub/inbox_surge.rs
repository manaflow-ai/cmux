//! Rate decisions belong to the receiver. A chat can process one ordinary message per
//! measured reply period. Keep one arrival timestamp regardless of how many senders it has.
use super::*;

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
        || opts.after_turn.is_some()
        || opts.supersede.is_some()
        || opts.steer_only
        || opts.control == Control::Web
        || crate::author::of_provenance(provenance).is_some()
        || provenance
            .and_then(|p| p.pointer("/notice/severity"))
            .and_then(Value::as_str)
            .is_some_and(|s| s.eq_ignore_ascii_case("fire"))
        || !blocks.iter().all(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        || crate::prompt_uploads::any(blocks)
        || super::super::forum::slash_command(blocks).is_some()
        || is_notice(provenance)
    {
        return None;
    }
    super::super::digest::agent_sender(provenance, opts.agent.as_deref())
}

impl Hub {
    /// A surge receipt means the receiver journal already holds the entire original prompt.
    /// No turn, steer, ordinary inbox notice, or caller waiting on a nonexistent turn is created.
    pub(in crate::hub) fn hold_surge_message(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        client: &str,
        blocks: &[Value],
        opts: &PromptOptions,
    ) -> Result<Option<Value>, RpcError> {
        let Some(from) = eligible(opts, blocks) else { return Ok(None) };
        let now = now_ms();
        let period =
            session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner()).reply_period_ms(now);
        if !session.inbox().surge_rate.arrival(now, period) {
            return Ok(None);
        }
        if super::super::queue::closing(session) {
            return Err(super::super::queue::closing_error());
        }

        let provenance = opts.provenance.as_ref();
        let text = prompt_text(blocks);
        let thread = thread_key(opts.thread.as_deref(), &thread_sender(provenance, &from), &text);
        let from_session = sender_session(provenance);
        let sender_meta =
            from_session.as_deref().and_then(|id| self.resolve(id).ok()).map(|s| s.meta());
        let sender = crate::prompt_provenance::sender_record(
            provenance,
            from_session.as_deref(),
            sender_meta.as_ref(),
        );
        let notice = tool_notice_of(provenance);
        let class = opts.class.unwrap_or(if notice.is_some() {
            PromptClass::Fyi
        } else {
            PromptClass::Result
        });
        let msg = json!({"promptId": prompt_id, "threadId": thread, "from": from, "fromSession": from_session,
            "class":class,"kind":kind_of(class),"client":client,"text":text,"prompt":blocks,
            "sender":sender,"surgeHeld":true,"replyPeriodMs":period,"report":is_report(provenance)});
        let (_, stored) = self.append_logged(
            session,
            "mux",
            "inbox",
            crate::prompt_provenance::marked(msg, provenance),
            None,
        );
        if !stored {
            return Err(RpcError::internal("could not persist the surge inbox message"));
        }
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
        session.inbox().items.push(item);
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
        for urgent in [PromptClass::Question, PromptClass::Block] {
            opts.class = Some(urgent);
            assert!(eligible(&opts, &blocks).is_none());
        }
        opts.class = Some(PromptClass::Fyi);
        opts.provenance = Some(crate::prompt_provenance::notice(
            &json!({"sender":"watcher","severity":"fire"}),
            "receiver",
        ));
        assert!(eligible(&opts, &blocks).is_none());
    }
}
