//! Rate decisions belong to the receiver. A chat can process one ordinary message per
//! measured reply period. Keep one arrival timestamp regardless of how many senders it has.
use super::*;

/// The last journaled snapshot powers the single chat row even when older posts leave memory.
#[derive(Clone, Copy, Default, Debug, serde::Serialize, serde::Deserialize)]
pub(super) struct Counts {
    pub(super) seq: u64,
    held: u64,
    need_you: u64,
}

impl Counts {
    pub(super) fn need_you(&self) -> u64 {
        self.need_you
    }

    pub(super) fn json(&self) -> Value {
        json!({"held": self.held, "needYou": self.need_you})
    }

    /// Sets `held` to the journal's count of undecided held messages, read through record
    /// `through`, unless a newer snapshot came since. The running counter (+1 a hold, minus a
    /// record's ids) drifts: a resent prompt id counts twice, a fork counts its parent's
    /// (`Hub::surge_held_now`).
    pub(super) fn settle_held(&mut self, held: u64, through: u64) {
        if self.seq <= through {
            self.held = held;
        }
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
        } else if event.kind == "inbox"
            && event.msg.get("surgeHeld").and_then(Value::as_bool) == Some(true)
        {
            self.held = self.held.saturating_add(1);
            self.seq = event.seq;
        }
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
    /// Store a triage record together with its current number of actionable topics. The held
    /// messages it decides (its `items`: digested, owner-bound or dropped as noise or a repeat)
    /// are held no longer, so the row's held count goes down by them.
    pub(crate) fn persist_surge_triage(
        &self,
        session: &Session,
        batch: Value,
        actionable_topics: u64,
    ) -> Result<(), RpcError> {
        let released =
            u64::try_from(crate::surge_triage::triaged_ids(&batch).count()).unwrap_or(u64::MAX);
        self.persist_surge_event(
            session,
            "inbox_triaged",
            batch,
            Some((actionable_topics, released)),
        )
    }

    fn persist_surge_event(
        &self,
        session: &Session,
        kind: &str,
        mut msg: Value,
        triaged: Option<(u64, u64)>,
    ) -> Result<(), RpcError> {
        let state = session.inbox().surge_counts.clone();
        let mut counts = state.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = *counts;
        match triaged {
            Some((topics, released)) => {
                next.need_you = topics;
                next.held = next.held.saturating_sub(released);
            }
            None => next.held = next.held.saturating_add(1),
        }
        crate::surge_triage::set_key(&mut msg, "surge", next.json());
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

    /// `_acpmux/inbox_thread` whole: [`Self::inbox_thread`], plus the thread's surge-held
    /// messages that left memory (`trim` lets them go first) read back from the log. The surge
    /// notice links to `acpmux session inbox ID --thread T`; without this, a busy chat's link
    /// answered "no messages" while only `--search` found them (2026-11-23).
    pub(crate) fn inbox_thread_whole(
        &self,
        session: &Session,
        thread: &str,
        mark_read: bool,
    ) -> Result<Value, RpcError> {
        let mut reply = self.inbox_thread(session, thread, mark_read);
        if !session.inbox().held_evicted.contains(thread) {
            return Ok(reply);
        }
        let mut messages = match reply.get_mut("messages").map(Value::take) {
            Some(Value::Array(list)) => list,
            _ => Vec::new(),
        };
        let shown: std::collections::HashSet<String> =
            messages.iter().filter_map(|m| m["promptId"].as_str().map(str::to_owned)).collect();
        self.scan_for_rebuild(session, &["inbox"], &mut |record| {
            let msg = &record.msg;
            let id = msg["promptId"].as_str().unwrap_or_default();
            if msg["surgeHeld"].as_bool() == Some(true)
                && msg["threadId"].as_str() == Some(thread)
                && !shown.contains(id)
            {
                let from = msg["from"].as_str().unwrap_or_default();
                let sender = &msg["sender"];
                messages.push(json!({
                    "promptId": id, "from": display_sender(sender, from),
                    "fromName": shown_sender(sender, from), "fromSession": msg["fromSession"],
                    "sender": sender, "class": msg["class"], "kind": msg["kind"],
                    "at": record.at, "text": msg["text"], "read": false,
                    "details": msg.pointer("/_meta/provenance/details").cloned(),
                    "notice": Value::Null, "surgeHeld": true,
                }));
            }
            true
        })
        .map_err(|e| RpcError::internal(format!("read held inbox: {e}")))?;
        // Newest first, as the thread reads in memory.
        messages.sort_by_key(|m| std::cmp::Reverse(m["at"].as_u64().unwrap_or(0)));
        reply["messages"] = Value::Array(messages);
        Ok(reply)
    }

    /// Surge admission is a preview: Settings > Experimental > Labs > Show Preview Features
    /// (`labs.previewFeatures`), off by default, read at each eligible message so the switch
    /// applies to the next one. Off, every message takes the path it took before the surge inbox.
    pub(in crate::hub) fn surge_inbox_on(&self) -> bool {
        if let Some(on) = *self.surge_inbox.lock().unwrap_or_else(|e| e.into_inner()) {
            return on;
        }
        use crate::user_settings::{self, Settings};
        matches!(user_settings::read(), Settings::Parsed(doc)
            if user_settings::value(&doc, "labs.previewFeatures") == Some(Value::Bool(true)))
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
    ) -> Result<Option<Value>, RpcError> {
        let Some(from) = eligible(opts, blocks) else { return Ok(None) };
        if !self.surge_inbox_on() {
            return Ok(None);
        }
        let now = now_ms();
        let period =
            session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner()).reply_period_ms(now);
        if !session.inbox().surge_rate.arrival(now, period) {
            return Ok(None);
        }
        self.hold_in_inbox(session, prompt_id, client, blocks, opts, from).map(Some)
    }

    /// Keeps a prompt from `from` whole in `session`'s journal and inbox as a held message: no
    /// turn, steer or inbox notice (the surge, and a held chat: `session_hold.rs`).
    pub(in crate::hub) fn hold_in_inbox(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        client: &str,
        blocks: &[Value],
        opts: &PromptOptions,
        from: String,
    ) -> Result<Value, RpcError> {
        if super::super::queue::closing(session) {
            return Err(super::super::queue::closing_error());
        }
        let now = now_ms();
        let period =
            session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner()).reply_period_ms(now);
        let provenance = opts.provenance.as_ref();
        let text = prompt_text(blocks);
        let notice = notice_of(provenance, &text);
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
        // A program's message is an inbox fyi, whatever class it asked for, unless a FIRE
        // (hq docs/handbook/notice-flood.md rule 1).
        let program = notice.is_some()
            || crate::surge_triage::program_notice(
                &json!({"fromSession": from_session, "sender": sender, "text": text}),
            );
        let class = if program && !crate::surge_triage::fire_text(&text) {
            PromptClass::Fyi
        } else {
            opts.class.unwrap_or(PromptClass::Result)
        };
        let msg = json!({"promptId": prompt_id, "threadId": thread, "from": from, "fromSession": from_session,
            "class":class,"kind":kind_of(class),"client":client,"text":text,"prompt":blocks,
            "sender":sender,"surgeHeld":true,"replyPeriodMs":period,"report":is_report(provenance),
            "program":program});
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
            // A surge hold is the inbox's own pacing: it stands whether or not the message waited.
            waited: false,
            at: now,
            within: None,
            text,
            details: provenance.and_then(|p| p.get("details")).cloned(),
            fire: fire_notice(notice.as_ref()),
            tool_notice: notice,
            surge_held: true,
            verdict: None,
            noticed: true,
            read: false,
            answer: None,
            reader: None,
        };
        let mut inbox = session.inbox();
        inbox.items.push(item);
        trim(&mut inbox);
        Ok(
            json!({"sessionId":session.id,"promptId":prompt_id,"threadId":thread,"inbox":true,"surgeHeld":true,"queued":false}),
        )
    }
}

#[cfg(test)]
#[path = "inbox_surge_tests.rs"]
mod tests;
