//! `_acpmux/paused_files` (RFD 0144 piece 2, capability `paused-reads-v1`): the app's or phone's
//! file tree and search of a paused machine, answered from its replica and write journal
//! (`hub/paused_fs.rs`, `write_journal/browse.rs`) with no wake. Off unless
//! `writeJournal.servePausedReads` (and `writeJournal.enabled`) is on.
//!
//! The reply always says whether it answered. `{"answered": false, "reason": "notPaused"}`: the
//! machine runs (or the setting is off), so ask it as before. `"stale"`, `"machineOnly"` or
//! `"notText"`: only the machine can answer, so the client wakes it as before. A client of a
//! daemon without this method hears `method_not_found` and does the same; a daemon never asks a
//! client for anything new, so old clients see no change.
//!
//! The person only (their app on this machine or a paired phone): what is on a machine's disk is
//! theirs, as with `_acpmux/review_brief`.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};

use super::Conn;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::write_journal::browse::{ListOutcome, SearchOutcome};
use crate::write_journal::paused::Routed;
use crate::write_journal::replica::NeedsMachine;

/// Most hits one search returns.
pub const MAX_HITS: usize = 1000;

/// One checked request.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Ask {
    List { machine: String, path: PathBuf },
    Search { machine: String, root: PathBuf, query: String, max_hits: usize },
}

fn bad(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message)
}

fn text<'a>(params: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && !s.chars().any(char::is_control))
        .ok_or_else(|| bad(format!("{key} is required")))
}

fn absolute(params: &Value, key: &str) -> Result<PathBuf, RpcError> {
    let path = PathBuf::from(text(params, key)?);
    if !path.is_absolute() {
        return Err(bad(format!("{key} must be an absolute path")));
    }
    Ok(path)
}

/// `{"op": "list", "machine": M, "path": DIR}` or
/// `{"op": "search", "machine": M, "root": DIR, "query": Q, "maxHits": N}`.
pub(super) fn parse(params: &Value) -> Result<Ask, RpcError> {
    let machine = text(params, "machine")?.to_owned();
    match params.get("op").and_then(Value::as_str) {
        Some("list") => Ok(Ask::List { machine, path: absolute(params, "path")? }),
        Some("search") => {
            let max_hits = params
                .get("maxHits")
                .and_then(Value::as_u64)
                .map_or(200, |n| (n as usize).min(MAX_HITS));
            Ok(Ask::Search {
                machine,
                root: absolute(params, "root")?,
                query: text(params, "query")?.to_owned(),
                max_hits,
            })
        }
        other => Err(bad(format!("op must be \"list\" or \"search\", not {other:?}"))),
    }
}

fn not_answered(reason: &str) -> Value {
    json!({"answered": false, "reason": reason})
}

fn needs(why: NeedsMachine) -> Value {
    not_answered(match why {
        NeedsMachine::Stale => "stale",
        NeedsMachine::MachineOnly => "machineOnly",
        NeedsMachine::NotText => "notText",
    })
}

pub(super) fn list_reply(routed: Routed<ListOutcome>) -> Value {
    match routed {
        Routed::NotPaused => not_answered("notPaused"),
        Routed::NeedsMachine(why) | Routed::Answered(ListOutcome::NeedsMachine(why)) => needs(why),
        Routed::Answered(ListOutcome::NotFound) => json!({"answered": true, "found": false}),
        Routed::Answered(ListOutcome::Entries(entries)) => json!({
            "answered": true,
            "found": true,
            "entries": entries
                .iter()
                .map(|e| json!({"name": e.name, "isDir": e.is_dir, "size": e.size}))
                .collect::<Vec<_>>(),
        }),
    }
}

pub(super) fn search_reply(routed: Routed<SearchOutcome>) -> Value {
    match routed {
        Routed::NotPaused => not_answered("notPaused"),
        Routed::NeedsMachine(why) | Routed::Answered(SearchOutcome::NeedsMachine(why)) => {
            needs(why)
        }
        Routed::Answered(SearchOutcome::Hits { hits, truncated }) => json!({
            "answered": true,
            "truncated": truncated,
            "hits": hits
                .iter()
                .map(|h| json!({"path": h.path, "line": h.line, "text": h.text}))
                .collect::<Vec<_>>(),
        }),
    }
}

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if !conn.is_person() {
        return Err(RpcError::method_not_found(method::MUX_PAUSED_FILES));
    }
    let io = |e: std::io::Error| RpcError::new(-32000, format!("paused files: {e}"));
    match parse(params)? {
        Ask::List { machine, path } => {
            hub.paused_list_dir(&machine, &path).await.map(list_reply).map_err(io)
        }
        Ask::Search { machine, root, query, max_hits } => {
            hub.paused_search(&machine, &root, &query, max_hits).await.map(search_reply).map_err(io)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::write_journal::browse::{Hit, ListEntry};

    #[test]
    fn parse_checks_op_machine_and_absolute_paths() {
        assert_eq!(
            parse(&json!({"op": "list", "machine": "vm", "path": "/w"})).unwrap(),
            Ask::List { machine: "vm".into(), path: "/w".into() }
        );
        assert_eq!(
            parse(&json!({"op": "search", "machine": "vm", "root": "/w", "query": "fn", "maxHits": 99999}))
                .unwrap(),
            Ask::Search { machine: "vm".into(), root: "/w".into(), query: "fn".into(), max_hits: MAX_HITS }
        );
        for bad in [
            json!({"op": "list", "path": "/w"}),
            json!({"op": "list", "machine": "vm", "path": "w"}),
            json!({"op": "search", "machine": "vm", "root": "/w"}),
            json!({"op": "read", "machine": "vm", "path": "/w"}),
        ] {
            assert!(parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn replies_say_whether_they_answered() {
        assert_eq!(
            list_reply(Routed::NotPaused),
            json!({"answered": false, "reason": "notPaused"})
        );
        assert_eq!(list_reply(Routed::NeedsMachine(NeedsMachine::Stale))["reason"], json!("stale"));
        assert_eq!(
            list_reply(Routed::Answered(ListOutcome::NeedsMachine(NeedsMachine::MachineOnly)))["reason"],
            json!("machineOnly")
        );
        assert_eq!(
            list_reply(Routed::Answered(ListOutcome::Entries(vec![ListEntry {
                name: "a.rs".into(),
                is_dir: false,
                size: 3
            }]))),
            json!({"answered": true, "found": true, "entries": [{"name": "a.rs", "isDir": false, "size": 3}]})
        );
        assert_eq!(
            search_reply(Routed::Answered(SearchOutcome::Hits {
                hits: vec![Hit { path: "a.rs".into(), line: 2, text: "fn x".into() }],
                truncated: false
            })),
            json!({"answered": true, "truncated": false, "hits": [{"path": "a.rs", "line": 2, "text": "fn x"}]})
        );
    }

    /// Old and new on the wire: a new client of an old daemon finds no `paused-reads-v1` and
    /// never sends the method (it wakes the machine, as before); a new daemon lists it, and an old
    /// client that does not know the id ignores it, since ids are opaque strings.
    #[test]
    fn paused_reads_id_is_listed_by_a_new_daemon_and_absent_from_an_old_one() {
        let new_ids = crate::capabilities::ids();
        assert!(new_ids.contains(&crate::capabilities::PAUSED_READS));
        let old_ids: Vec<&str> =
            new_ids.iter().copied().filter(|id| *id != crate::capabilities::PAUSED_READS).collect();
        let client_sends = |ids: &[&str]| ids.contains(&crate::capabilities::PAUSED_READS);
        assert!(client_sends(&new_ids));
        assert!(!client_sends(&old_ids));
        #[cfg(feature = "hub-carrier")]
        assert_eq!(
            crate::capabilities::PAUSED_READS,
            serde_json::to_value(cmux_remote_protocol::RemoteCapability::PausedReadsV1)
                .unwrap()
                .as_str()
                .unwrap(),
            "acpmux and the cmux protocol name the surface the same"
        );
    }
}
