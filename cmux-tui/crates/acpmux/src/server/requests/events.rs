//! Reading a chat's log: a page of its events (`_acpmux/events`) and an image one of its prompts
//! sent (`_acpmux/attachment`, `hub/prompt_images.rs`).

use super::*;

/// The most JSON one page holds when the caller names no `maxBytes`, and the most it may
/// name. A page's records are parsed trees until the reply is written, many times their
/// JSON: one read of a whole 31 MB log held about 1 GB (huge-blue, 2026-10-21), and a 4 MiB
/// page still grew the daemon by 95 MB. A longer read takes more pages through `hasMore`;
/// the app's pages are 128 and 256 KiB.
const DEFAULT_PAGE_BYTES: usize = 1 << 20;
const MAX_PAGE_BYTES: usize = 4 << 20;

/// A page's byte limit from `maxBytes`: [`DEFAULT_PAGE_BYTES`] when absent, at most
/// [`MAX_PAGE_BYTES`].
pub(super) fn page_bytes(params: &Value) -> usize {
    let asked = params.get("maxBytes").and_then(Value::as_u64).map(|b| b as usize);
    asked.unwrap_or(DEFAULT_PAGE_BYTES).min(MAX_PAGE_BYTES)
}

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
    let max_bytes = Some(page_bytes(params));
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
