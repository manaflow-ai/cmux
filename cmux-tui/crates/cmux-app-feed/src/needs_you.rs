//! The phone's Needs You list (`FeedNeedsYouPhone`): the open requests a person answers that no
//! agent tab already shows, sent only once the Feed view is settled and someone's.

use crate::json::str_at;
use serde::Serialize;
use serde_json::Value;

/// One request the phone lists.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request {
    pub id: String,
    pub title: String,
    pub body: String,
    pub kind: String,
    pub source: String,
    pub url: Option<String>,
    /// Seconds since 1970.
    #[serde(rename = "createdAt")]
    pub created_at: f64,
}

fn nested<'a>(item: &'a Value, object: &str, key: &str) -> Option<&'a str> {
    item.get(object).and_then(|object| str_at(object, key))
}

/// Whether `item` is a notice (`type`, else `kind`, default `notice`).
pub fn is_notice(item: &Value) -> bool {
    match str_at(item, "type") {
        Some(kind) => kind == "notice",
        None => str_at(item, "kind").unwrap_or("notice") == "notice",
    }
}

/// Whether `item` is open (`state`, default `open`).
pub fn is_open(item: &Value) -> bool {
    str_at(item, "state").unwrap_or("open") == "open"
}

/// Whether `item` is an open request.
pub fn is_open_request(item: &Value) -> bool {
    !is_notice(item) && is_open(item)
}

/// The phone's requests among the pinned items: open requests not on an agent session.
pub fn requests(pinned: &[Value]) -> Vec<Request> {
    pinned
        .iter()
        .filter(|item| is_open_request(item) && nested(item, "context", "acp_session").is_none())
        .map(|item| Request {
            id: str_at(item, "id").unwrap_or_default().to_owned(),
            title: nested(item, "github", "title")
                .or_else(|| str_at(item, "title"))
                .unwrap_or_default()
                .to_owned(),
            body: str_at(item, "body").unwrap_or_default().to_owned(),
            kind: str_at(item, "kind").unwrap_or_default().to_owned(),
            source: nested(item, "poster", "label").unwrap_or_default().to_owned(),
            url: nested(item, "context", "url")
                .or_else(|| nested(item, "github", "url"))
                .map(str::to_owned),
            created_at: item.get("created_at").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0,
        })
        .collect()
}

/// Whether the view is the whole truth: live, or disconnected once loaded or signed out.
pub fn is_settled(view: &Value) -> bool {
    let loaded = view.get("loaded") == Some(&Value::Bool(true));
    let state = nested(view, "connection", "state");
    if loaded && state == Some("connected") {
        return true;
    }
    state == Some("disconnected")
        && (loaded || nested(view, "connection", "reason") == Some("signed_out"))
}

/// The account the view is (none when signed out).
pub fn owner(view: &Value) -> Option<String> {
    let account = view.get("account").filter(|account| account.is_object())?;
    if nested(view, "connection", "reason") == Some("signed_out") {
        return None;
    }
    str_at(account, "id").map(str::to_owned)
}

/// The head items of the view's group `id`.
pub fn group_items(view: &Value, id: &str) -> Vec<Value> {
    view.get("groups")
        .and_then(Value::as_array)
        .and_then(|groups| groups.iter().find(|group| str_at(group, "id") == Some(id)))
        .and_then(|group| group.get("entries"))
        .and_then(Value::as_array)
        .map(|entries| entries.iter().filter_map(|entry| entry.get("item").cloned()).collect())
        .unwrap_or_default()
}

/// What the phone shows now: `None` (keep what it has) until the view is settled and someone's.
pub fn current(view: &Value) -> Option<Vec<Request>> {
    if !is_settled(view) || owner(view).is_none() {
        return None;
    }
    Some(requests(&group_items(view, "needs_you")))
}
