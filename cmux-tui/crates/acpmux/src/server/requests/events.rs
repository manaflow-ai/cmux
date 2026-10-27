//! Reading a chat's log: a page of its events (`_acpmux/events`) and an image one of its prompts
//! sent (`_acpmux/attachment`, `hub/prompt_images.rs`).

use super::*;

pub(super) fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    if m == method::MUX_ATTACHMENT {
        let id =
            str_param(params, "id").ok_or_else(|| RpcError::invalid_params("id is required"))?;
        return hub.prompt_image(&s.id, id);
    }
    let after = params.get("afterSeq").and_then(Value::as_u64).unwrap_or(0);
    let before = params.get("beforeSeq").and_then(Value::as_u64);
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(5000) as usize;
    let max_bytes = Some(crate::hub::page_bytes(params));
    let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
    let (last, created) = {
        let meta = s.meta();
        (meta.last_seq, meta.created_at)
    };
    if after > last {
        return Err(RpcError::invalid_params(format!(
            "cursor_future: afterSeq {after} is beyond the last event {last}"
        )));
    }
    // beforeSeq pages backwards: the newest `limit` records before it.
    let page = hub
        .events_page(&s.id, after, before, limit, max_bytes, before.is_some(), &filter)
        .map_err(|e| RpcError::internal(e.to_string()))?;
    // Read before the page: a peer's copy of the chat covers this far (`hub/peer_snapshot.rs`). A
    // page that stops short of the log (older records, or one more page to read) holds only to its
    // own last record.
    let through = if before.is_none() && !page.has_more { last } else { newest_seq(&page.events) };
    Ok(json!({
        "events": values(&s.id, page.events),
        "hasMore": page.has_more,
        "lastSeq": last,
        "pageThrough": through,
        // The session the page is of: a copy never joins another journal of the same id.
        "createdAt": created,
    }))
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
