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
    let last = s.meta().last_seq;
    if after > last {
        return Err(RpcError::invalid_params(format!(
            "cursor_future: afterSeq {after} is beyond the last event {last}"
        )));
    }
    // beforeSeq pages backwards: the newest `limit` records before it.
    let page = hub
        .events_page(&s.id, after, before, limit, max_bytes, before.is_some(), &filter)
        .map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(json!({
        "events": values(&s.id, page.events),
        "hasMore": page.has_more,
        "lastSeq": last,
    }))
}

/// A page's records as `_acpmux/event` values, each moved into its value: the page is never
/// held twice.
pub(super) fn values(session_id: &str, records: Vec<crate::store::EventRecord>) -> Vec<Value> {
    records.into_iter().map(|r| into_event_value(session_id, r)).collect()
}
