//! Reading a chat's log: a page of its events (`_acpmux/events`) and an image one of its prompts
//! sent (`_acpmux/attachment`, `hub/prompt_images.rs`).

use super::*;
use crate::hub::page_replies;

pub(super) fn handle(
    hub: &Arc<Hub>,
    m: &str,
    params: &Value,
    caller: Option<&str>,
) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    if m == method::MUX_ATTACHMENT {
        let id =
            str_param(params, "id").ok_or_else(|| RpcError::invalid_params("id is required"))?;
        // An image a surface's unsent draft holds (`hub/composers.rs`), or one a prompt sent.
        if let Some(image) = hub.composer_image(&s, id) {
            return Ok(image);
        }
        return hub.prompt_image(&s.id, id);
    }
    let pattern = str_param(params, "match");
    crate::hub::validate_match(pattern)?;
    let after = params.get("afterSeq").and_then(Value::as_u64).unwrap_or(0);
    let before = params.get("beforeSeq").and_then(Value::as_u64);
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(5000) as usize;
    let max_bytes = Some(crate::hub::page_bytes(params));
    // A client that bounds its page wants the transcript in it, not superseded tool output.
    let filter = crate::hub::EventFilter::parse(params.get("kinds"))?
        .omitting_superseded(params.get("maxBytes").is_some_and(|b| !b.is_null()))
        // One subagent's own records, for its pane (`EventFilter::of_subagent`).
        .of_subagent(str_param(params, "subagent"))
        // Records past it go as stubs: a reader that pages on its own (a durable watch) always
        // moves past a record too large for its read (`EventFilter::stubbing_over`).
        .stubbing_over(
            params
                .get("recordMaxBytes")
                .and_then(Value::as_u64)
                .map(|b| usize::try_from(b).unwrap_or(usize::MAX)),
        )
        // A watch's `match`: a stubbed reply chunk says whether its whole text held it.
        .matching(pattern)
        // The phone's pages: a tool call past it goes with its output cut, marked with the
        // record's size and seq, and is read whole on the person's tap (`hub/tool_output_cut.rs`).
        .cutting_tool_output(tool_output_max(params));
    // After a hard stop the log runs ahead of the saved session until the chat's log loads: a
    // client reading the records it missed (its own cursor, a lag's resync) asks past the saved
    // `lastSeq`, and was refused as `cursor_future`, so its hole stayed.
    hub.catch_up_tail(&s);
    let (last, created) = {
        let meta = s.meta();
        (meta.last_seq, meta.created_at)
    };
    if after > last {
        return Err(RpcError::invalid_params(format!(
            "cursor_future: afterSeq {after} is beyond the last event {last}"
        )));
    }
    // The same ask of an unchanged log is answered as it was (`hub/page_replies.rs`): an app
    // asks for a chat's newest page again and again while nothing is appended.
    let kept = (caller.is_none() && max_bytes.is_some_and(|b| b <= page_replies::MAX_PAGE_BYTES))
        .then(|| hub.page_log_stamp(&s.id))
        .flatten()
        .map(|stamp| (page_replies::key(params), stamp));
    if let Some((key, stamp)) = &kept
        && let Some(reply) = hub.page_replies.get(&s.id, key, last, *stamp)
    {
        return Ok(reply);
    }
    // The prompt index (`Hub::prompt_index`): the newest prompts before `beforeSeq`, cut short,
    // in a page `limit` and `maxBytes` bound, so the rail draws a long chat's every turn before
    // its history pages in, and asks for the older pages by `hasMore`. A daemon without it reads
    // `promptIndex` as nothing and answers the bounded page the pane also asks for. Kept while the
    // log is unchanged, as the other pages are: no prompt reads as live state.
    if params.get("promptIndex").and_then(Value::as_bool) == Some(true) {
        let page = hub
            .prompt_index(&s.id, before, limit, max_bytes)
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let through = newest_seq(&page.events);
        let keep = kept.filter(|(_, stamp)| {
            s.meta().last_seq == last && hub.page_log_stamp(&s.id) == Some(*stamp)
        });
        let reply = json!({
            "events": values(&s.id, page.events),
            "hasMore": page.has_more,
            "lastSeq": last,
            "pageThrough": through,
            "createdAt": created,
        });
        if let Some((key, stamp)) = keep {
            hub.page_replies.put(&s.id, key, last, stamp, reply.clone());
        }
        return Ok(reply);
    }
    // beforeSeq pages backwards: the newest `limit` records before it.
    let page = hub
        .events_page(&s.id, after, before, limit, max_bytes, before.is_some(), &filter)
        .map_err(|e| RpcError::internal(e.to_string()))?;
    // Read before the page: a peer's copy of the chat covers this far (`hub/peer_snapshot.rs`). A
    // page that stops short of the log (older records, or one more page to read) holds only to its
    // own last record.
    let through = if before.is_none() && !page.has_more { last } else { newest_seq(&page.events) };
    // Background peer read-ahead needs the same prompt context as attach. Opt in so
    // ordinary history/index reads keep their current cost (and cannot recurse here).
    let opener = if params.get("turnOpener").and_then(Value::as_bool) == Some(true) {
        turn_opener::turn_opener(hub, &s.id, &page)
    } else {
        None
    };
    hub.lane_report_events_read(caller, &s.id, &page.events);
    // Kept only when the log neither grew nor changed while the page was read.
    let keep = kept.filter(|(_, stamp)| {
        page_replies::keepable(&page.events)
            && s.meta().last_seq == last
            && hub.page_log_stamp(&s.id) == Some(*stamp)
    });
    let mut reply = json!({
        "events": values(&s.id, page.events),
        "hasMore": page.has_more,
        "lastSeq": last,
        "pageThrough": through,
        // The session the page is of: a copy never joins another journal of the same id.
        "createdAt": created,
    });
    if params.get("turnOpener").and_then(Value::as_bool) == Some(true)
        && let Some(object) = reply.as_object_mut()
    {
        object.insert("turnOpener".to_owned(), json!(opener));
    }
    if let Some((key, stamp)) = keep {
        hub.page_replies.put(&s.id, key, last, stamp, reply.clone());
    }
    Ok(reply)
}

/// `toolOutputMaxBytes`: the most bytes a tool call record goes whole with (none: every one).
pub(super) fn tool_output_max(params: &Value) -> Option<usize> {
    params
        .get("toolOutputMaxBytes")
        .and_then(Value::as_u64)
        .map(|b| usize::try_from(b).unwrap_or(usize::MAX))
}

/// The newest seq a page holds (0: none).
pub(super) fn newest_seq(records: &[crate::store::EventRecord]) -> u64 {
    records.iter().map(|r| r.seq).max().unwrap_or(0)
}

/// A page's records as `_acpmux/event` values, each moved into its value: the page is never
/// held twice.
pub(super) fn values(session_id: &str, records: Vec<crate::store::EventRecord>) -> Vec<Value> {
    records.into_iter().map(|r| into_event_value(session_id, r)).collect()
}

#[cfg(test)]
#[path = "events_tests.rs"]
mod tests;
