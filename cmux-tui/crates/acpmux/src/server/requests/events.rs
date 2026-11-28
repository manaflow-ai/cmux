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
    let max_bytes = params.get("maxBytes").and_then(Value::as_u64).map(|b| b as usize);
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
        "events": page.events.iter().map(|r| event_value(&s.id, r)).collect::<Vec<_>>(),
        "hasMore": page.has_more,
        "lastSeq": last,
    }))
}
