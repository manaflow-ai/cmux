//! Read held originals without restoring them into the bounded live inbox.
use super::*;
use std::collections::{HashMap, HashSet};

pub(super) fn recorded_item(e: &EventRecord) -> Item {
    let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("");
    let provenance = crate::prompt_provenance::recorded(&e.msg);
    let from_session = e.msg.get("fromSession").and_then(Value::as_str).map(str::to_owned);
    let stored_sender = e.msg.get("sender");
    let sender = stored_sender.cloned().unwrap_or_else(|| {
        crate::prompt_provenance::sender_record(provenance.as_ref(), from_session.as_deref(), None)
    });
    let thread = field("threadId").to_owned();
    let thread = if stored_sender.is_none() {
        legacy_thread_key(provenance.as_ref(), field("from"), thread)
    } else {
        thread
    };
    Item {
        surge_held: e.msg.get("surgeHeld") == Some(&Value::Bool(true)),
        prompt_id: field("promptId").to_owned(),
        notice: None,
        answered: None,
        thread,
        from: field("from").to_owned(),
        from_session,
        asker: super::super::question_replies::asker_of(provenance.as_ref()),
        sender,
        class: crate::prompt_class::recorded(&e.msg).unwrap_or(PromptClass::Result),
        report: e.msg.get("report") == Some(&Value::Bool(true)),
        at: e.at,
        text: field("text").to_owned(),
        details: provenance.as_ref().and_then(|p| p.get("details").cloned()),
        tool_notice: tool_notice_of(provenance.as_ref()),
        noticed: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
        read: e.msg.get("deliveredRead") == Some(&Value::Bool(true)),
        answer: None,
        reader: None,
    }
}

impl Hub {
    /// Listing needs only outstanding originals missing from KEEP, not every archived body.
    pub(super) fn archived_actionable_inbox(&self, session: &Session) -> anyhow::Result<Vec<Item>> {
        let ids: HashSet<String> = {
            let inbox = session.inbox();
            let counts = inbox.surge_counts.lock().unwrap_or_else(|e| e.into_inner());
            let live: HashSet<&str> = inbox.items.iter().map(|i| i.prompt_id.as_str()).collect();
            counts.actionable_prompts().filter(|id| !live.contains(id)).map(str::to_owned).collect()
        };
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        self.archived_inbox_items(session, Some(&ids), None)
    }

    /// An explicit thread open includes its archived held originals, with read/removal events
    /// replayed in journal order. It never grows the live inbox or revives a withdrawn message.
    pub(super) fn archived_inbox_items(
        &self,
        session: &Session,
        ids: Option<&HashSet<String>>,
        thread: Option<&str>,
    ) -> anyhow::Result<Vec<Item>> {
        let mut items: HashMap<String, Item> = HashMap::new();
        let mut keep = |h: &crate::store::KindHead<'_>| {
            ids.is_none_or(|ids| {
                h.unread
                    || h.prompt_id.is_some_and(|id| ids.contains(id))
                    || h.names(|id| ids.contains(id))
            })
        };
        self.scan_for_rebuild_keyed(
            session,
            &["inbox", "inbox_read", "inbox_removed"],
            &mut keep,
            &mut |e| {
                match e.kind.as_str() {
                    "inbox" if e.msg["surgeHeld"] == true => {
                        let mut item = recorded_item(&e);
                        if !item.prompt_id.is_empty()
                            && ids.is_none_or(|ids| ids.contains(&item.prompt_id))
                            && thread.is_none_or(|thread| thread_matches(&item, thread, true))
                        {
                            item.noticed = true;
                            items.entry(item.prompt_id.clone()).or_insert(item);
                        }
                    }
                    "inbox_read" => {
                        for id in e.msg["promptIds"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                        {
                            if let Some(item) = items.get_mut(id) {
                                item.read = true;
                            }
                        }
                    }
                    "inbox_removed" => {
                        if let Some(id) = e.msg["promptId"].as_str() {
                            items.remove(id);
                        }
                    }
                    _ => {}
                }
                true
            },
        )?;
        let mut items: Vec<_> = items.into_values().collect();
        items.sort_by(|a, b| (a.at, &a.prompt_id).cmp(&(b.at, &b.prompt_id)));
        Ok(items)
    }
}
