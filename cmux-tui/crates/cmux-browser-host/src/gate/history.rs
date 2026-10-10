//! The REPL's `history` global (private data P2, H3): the machine's page
//! history (kind `page` only), which the daemon keeps, over the host's history link
//! (crate::history_link). Every call names this session as
//! `on_behalf_of`; the daemon stamps it origin agent whatever the session's
//! origin. Every delete answers a restore id; `restore` undoes it. Deletes
//! and restores are logged like cookie clears (private_data.rs), with op,
//! site, counts and restore id.
//!
//! - `search {query?, site?, since?, limit?}` -> `[{id, url, title, at}]`,
//!   newest first (`since`: Unix ms; `limit` 1..5000, default 100).
//! - `delete {site} | {ids} | {urls} | {range}` -> `{removed, restoreId}`.
//! - `restore {restoreId}` -> `{restored}`.

use super::Gate;
use crate::history_link::HistoryLink;
use serde_json::{Value, json};
use std::sync::Arc;

const MAX_SEARCH: u64 = 5000;

/// The longest search text the daemon takes, in bytes.
const MAX_SEARCH_TEXT: usize = 1024;

/// `text` cut to at most [`MAX_SEARCH_TEXT`] bytes at a character boundary:
/// the daemon refuses longer search text, and a prefix still narrows.
fn search_text(text: &str) -> &str {
    let mut end = text.len().min(MAX_SEARCH_TEXT);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// Whether `url`'s host is `site` or one of its subdomains.
fn on_site(url: &str, site: &str) -> bool {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_ascii_lowercase))
        .is_some_and(|host| host == site || host.ends_with(&format!(".{site}")))
}

impl Gate {
    /// The daemon's history link for this session's `history` global.
    pub fn with_history_link(mut self, link: Arc<HistoryLink>) -> Gate {
        self.history = Some(link);
        self
    }

    fn history_call(&self, operation: &str, fields: Value) -> Result<Value, String> {
        // The machine's page history is local data: a remote caller
        // (CALLER-LOCALITY) never reaches it.
        if self.grants.remote {
            return Err(
                "history: a remote session cannot read or change this machine's page history"
                    .into(),
            );
        }
        let link = self.history.as_ref().ok_or(
            "history: this host has no history link (it runs without the cmux daemon that keeps page history)",
        )?;
        let session = self.inputs.as_ref().map_or("", |inputs| inputs.session_id());
        link.call(session, operation, fields).map_err(|error| error.message)
    }

    /// Every page entry (newest first), at most `limit`.
    fn history_entries(&self, text: &str, limit: u64) -> Result<Vec<Value>, String> {
        let listed = self.history_call(
            "history.entries.list",
            json!({"kinds": ["page"], "text": text, "limit": limit}),
        )?;
        Ok(listed["entries"].as_array().cloned().unwrap_or_default())
    }

    pub(super) fn history_op(&self, op: &str, args: &Value) -> Result<Value, String> {
        let text = |name: &str| args.get(name).and_then(Value::as_str).filter(|s| !s.is_empty());
        match op {
            "search" => {
                let limit = match args.get("limit") {
                    None | Some(Value::Null) => 100,
                    Some(value) => value
                        .as_u64()
                        .filter(|n| (1..=MAX_SEARCH).contains(n))
                        .ok_or(format!("history.search: limit must be 1 to {MAX_SEARCH}"))?,
                };
                let site = text("site").map(str::to_ascii_lowercase);
                let since = args.get("since").and_then(Value::as_f64);
                // The daemon filters by text in its store, so the site goes in
                // as a search token (a superset of the site's visits) and the
                // exact host check below narrows it. Newest first, the visits
                // at or after `since` are a prefix, so `limit` covers them.
                let query = text("query").unwrap_or("");
                let entries = match &site {
                    Some(site) => self.history_entries(
                        search_text(format!("{query} {site}").trim()),
                        MAX_SEARCH,
                    )?,
                    None => self.history_entries(search_text(query), limit)?,
                };
                let rows: Vec<Value> = entries
                    .into_iter()
                    .filter(|entry| {
                        let url = entry["url"].as_str().unwrap_or("");
                        let at = entry["at_ms"].as_str().and_then(|at| at.parse::<f64>().ok());
                        site.as_deref().is_none_or(|site| on_site(url, site))
                            && since.is_none_or(|since| at.is_some_and(|at| at >= since))
                    })
                    .take(limit as usize)
                    .map(|entry| {
                        json!({
                            "id": entry["id"],
                            "url": entry["url"],
                            "title": entry["title"],
                            "at": entry["at_ms"].as_str().and_then(|at| at.parse::<u64>().ok()),
                        })
                    })
                    .collect();
                Ok(Value::Array(rows))
            }
            "delete" => {
                let given: Vec<&str> = ["site", "ids", "urls", "range"]
                    .into_iter()
                    .filter(|name| args.get(*name).is_some_and(|v| !v.is_null()))
                    .collect();
                let [what] = given.as_slice() else {
                    return Err(
                        "history.delete: give exactly one of {site}, {ids}, {urls} or {range}"
                            .into(),
                    );
                };
                let strings = |name: &str| -> Result<Vec<String>, String> {
                    args[name]
                        .as_array()
                        .and_then(|list| {
                            list.iter().map(|v| v.as_str().map(str::to_owned)).collect()
                        })
                        .ok_or(format!("history.delete: {name} must be a list of strings"))
                };
                let (removal, site) = match *what {
                    "site" => {
                        let site =
                            text("site").ok_or("history.delete: site must be a host name")?;
                        (
                            self.history_call("history.site.remove", json!({"host": site}))?,
                            json!(site),
                        )
                    }
                    "range" => {
                        let range = text("range").ok_or(
                            "history.delete: range must be hour, today, week, month or all",
                        )?;
                        (
                            self.history_call(
                                "history.clear",
                                json!({"kinds": ["page"], "range": range}),
                            )?,
                            Value::Null,
                        )
                    }
                    "ids" => (
                        self.history_call(
                            "history.entries.remove",
                            json!({"ids": strings("ids")?}),
                        )?,
                        Value::Null,
                    ),
                    _ => (
                        // Exact URLs, any catalog length, every profile, one
                        // removal: no search and no window of newest visits.
                        self.history_call(
                            "history.visit.remove",
                            json!({"urls": strings("urls")?}),
                        )?,
                        Value::Null,
                    ),
                };
                let answer =
                    json!({"removed": removal["removed"], "restoreId": removal["restore_id"]});
                self.record_private_data(
                    json!({"op": "history.delete", "site": site, "visits": removal["removed"], "restoreId": removal["restore_id"]}),
                    None,
                );
                Ok(answer)
            }
            "restore" => {
                let id = text("restoreId")
                    .ok_or("history.restore: restoreId must be a history:<id> restore id")?;
                let restored = self.history_call("history.restore", json!({"restore_id": id}))?;
                self.record_private_data(
                    json!({"op": "history.restore", "site": null, "visits": restored["restored"], "restoreId": id}),
                    None,
                );
                Ok(json!({"restored": restored["restored"]}))
            }
            other => Err(format!("history: unknown operation {other:?}")),
        }
    }
}
