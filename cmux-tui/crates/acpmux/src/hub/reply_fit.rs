//! Part of `Hub`; see `hub/mod.rs`. A reply fits one message (`rpc::MAX_MESSAGE_BYTES`) as a
//! whole: a session row or a chat's detail too large for it is trimmed, its largest fields
//! first, rather than refused, so the list page or the `_acpmux/info` it is in still goes. A
//! refused reply is refused again on every retry: `acpmux ls` on a fleet host failed with
//! "message too large to send: 16927852 bytes" on 2026-10-31, and no lead could list its
//! sessions.
//!
//! [`shrink_largest`] is the one rule: replace the largest parts, largest first, until the
//! value fits. [`fit_object`] applies it to an object's own fields and marks what it trimmed.

use std::cmp::Reverse;

use serde_json::{Map, Value, json};

/// The most one reply's result holds: a megabyte under the message limit, for the JSON-RPC
/// envelope, its id and what masking a peer's text may add.
pub(crate) const REPLY_BYTES: usize = crate::rpc::MAX_MESSAGE_BYTES - (1 << 20);

/// A trimmed string keeps this much of its start, so a row still says what it was.
const PREVIEW_BYTES: usize = 1 << 10;

/// Room kept for the `omitted` mark [`fit_object`] adds.
const MARK_BYTES: usize = 4 << 10;

/// The fields a row is found, paged, filtered and opened by: never trimmed. The same set the
/// attach reply's session keeps (`_acpmux/attach`).
const KEEP: &[&str] = &[
    "sessionId",
    "id",
    "qualifiedSessionId",
    "sessionReceipt",
    "peer",
    "status",
    "harness",
    "cwd",
    "updatedAt",
    "name",
    // With `sessionId` and `harness`, what a peer's reply masks a summary by (`peer_text.rs`):
    // a trimmed row without it would go to a peer unmasked.
    "lastSeq",
];

fn size(value: &Value) -> usize {
    serde_json::to_string(value).map_or(usize::MAX, |text| text.len())
}

/// Replaces the parts of `value` at `pointers` (JSON pointers), largest first, with
/// `replace(part, its bytes)` until `value` serializes in `budget` bytes, and returns the
/// pointers it replaced. `bytes` is `value`'s size now.
pub(crate) fn shrink_largest(
    value: &mut Value,
    mut bytes: usize,
    budget: usize,
    pointers: impl IntoIterator<Item = String>,
    mut replace: impl FnMut(&mut Value, usize),
) -> Vec<String> {
    let mut parts: Vec<(String, usize)> = pointers
        .into_iter()
        .filter_map(|at| {
            let part = size(value.pointer(&at)?);
            Some((at, part))
        })
        .collect();
    parts.sort_by_key(|(_, part)| Reverse(*part));
    let mut replaced = Vec::new();
    for (at, part) in parts {
        if bytes <= budget {
            break;
        }
        let Some(target) = value.pointer_mut(&at) else { continue };
        replace(target, part);
        bytes = bytes.saturating_sub(part.saturating_sub(size(target)));
        replaced.push(at);
    }
    replaced
}

/// Trims `object`'s largest fields until it serializes in `budget` bytes: a string keeps its
/// first [`PREVIEW_BYTES`], any other value goes. The fields of [`KEEP`] stay whole. What it
/// trimmed is marked `omitted: {bytes, reason: "too_large", fields}`, `bytes` the object's size
/// before, as a record too large for a reply is (`hub/paging.rs`). False when it still does not
/// fit (a kept field alone is that large): the caller sends a stub instead.
pub(crate) fn fit_object(object: &mut Value, budget: usize) -> bool {
    let before = size(object);
    if before <= budget {
        return true;
    }
    let Some(map) = object.as_object() else { return false };
    let pointers: Vec<String> = map
        .keys()
        .filter(|key| !KEEP.contains(&key.as_str()))
        .map(|key| format!("/{}", key.replace('~', "~0").replace('/', "~1")))
        .collect();
    let room = budget.saturating_sub(MARK_BYTES);
    let trimmed = shrink_largest(object, before, room, pointers, |part, _| {
        *part = match part {
            Value::String(text) => Value::String(preview(text)),
            _ => Value::Null,
        };
    });
    let Some(map) = object.as_object_mut() else { return false };
    let mut fields = Vec::with_capacity(trimmed.len());
    for at in &trimmed {
        let key = at.get(1..).unwrap_or("").replace("~1", "/").replace("~0", "~");
        if map.get(&key).is_some_and(Value::is_null) {
            map.remove(&key);
        }
        fields.push(Value::String(key));
    }
    let mark = json!({"bytes": before, "reason": "too_large", "fields": fields});
    map.insert("omitted".to_owned(), mark);
    size(object) <= budget
}

/// [`fit_object`] for a whole reply (`_acpmux/info`'s detail): what still does not fit goes as
/// only its [`KEEP`] fields that are small, marked as [`fit_object`] marks.
pub(crate) fn fit_reply_object(object: &mut Value) {
    let before = size(object);
    if fit_object(object, REPLY_BYTES) {
        return;
    }
    let mut stub = Map::new();
    for key in KEEP {
        if let Some(value) = object.get(*key).filter(|v| size(v) <= PREVIEW_BYTES) {
            stub.insert((*key).to_owned(), value.clone());
        }
    }
    stub.insert("omitted".to_owned(), json!({"bytes": before, "reason": "too_large"}));
    *object = Value::Object(stub);
}

/// The start of `text`, at most [`PREVIEW_BYTES`], masked (`secret_scan.rs`) before it is cut,
/// over [`SCAN_SLACK_BYTES`] more, as a lane's title is (`views.rs` `masked_cut`): a secret the
/// cut would split is masked whole, never left as a head a peer's masking no longer knows.
fn preview(text: &str) -> String {
    let head = prefix(text, PREVIEW_BYTES.saturating_add(SCAN_SLACK_BYTES));
    prefix(&crate::secret_scan::mask(head), PREVIEW_BYTES).to_owned()
}

/// How far past the cut a preview is scanned for secrets.
const SCAN_SLACK_BYTES: usize = 4 << 10;

/// The start of `text`, at most `max` bytes, ending on a character boundary.
fn prefix(text: &str, max: usize) -> &str {
    let end = text
        .char_indices()
        .map(|(at, c)| at.saturating_add(c.len_utf8()))
        .take_while(|end| *end <= max)
        .last()
        .unwrap_or(0);
    text.get(..end).unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_row_too_large_keeps_its_keys_and_a_preview_and_says_what_it_trimmed() {
        let mut row = json!({"sessionId": "s1", "status": "idle", "updatedAt": 5, "cwd": "/w",
            "title": "é".repeat(1 << 20), "turn": {"plan": ["x".repeat(1 << 19)]}});
        let before = size(&row);
        assert!(fit_object(&mut row, 64 << 10));
        assert!(size(&row) <= 64 << 10, "{}", size(&row));
        assert_eq!((row["sessionId"].as_str(), row["cwd"].as_str()), (Some("s1"), Some("/w")));
        let title = row["title"].as_str().unwrap();
        assert!(title.len() <= PREVIEW_BYTES && title.starts_with('é'));
        assert!(row.get("turn").is_none());
        assert_eq!(row["omitted"]["bytes"], before);
        assert_eq!(row["omitted"]["reason"], "too_large");
        assert_eq!(row["omitted"]["fields"], json!(["title", "turn"]));
        // One that fits is left as it was.
        let small = json!({"sessionId": "s2", "title": "t"});
        let mut same = small.clone();
        assert!(fit_object(&mut same, 1 << 10));
        assert_eq!(same, small);
    }

    #[test]
    fn a_reply_whose_kept_field_alone_is_too_large_goes_as_a_stub() {
        let mut detail = json!({"sessionId": "s", "name": "n".repeat(REPLY_BYTES), "cwd": "/w"});
        fit_reply_object(&mut detail);
        assert_eq!(detail["sessionId"], "s");
        // The kept fields that are small stay, the huge one goes.
        assert!(detail.get("name").is_none());
        assert_eq!(detail["cwd"], "/w");
        assert_eq!(detail["omitted"]["reason"], "too_large");
    }

    #[test]
    fn shrink_largest_replaces_largest_first_and_stops_once_it_fits() {
        let mut v = json!({"a": "x".repeat(100), "b": "y".repeat(300), "c": "z".repeat(200)});
        let bytes = size(&v);
        let ptrs = ["/a", "/b", "/c", "/missing"].map(str::to_owned);
        let done = shrink_largest(&mut v, bytes, bytes - 250, ptrs, |p, _| *p = Value::Null);
        assert_eq!(done, ["/b"]);
        assert!(v["b"].is_null() && v["a"].is_string() && v["c"].is_string());
    }
}
