//! Import of the leo-asks ledger (RFD 0010, piece 6): `asks.json` (schema `leo-asks/v1`) becomes
//! append-only ask events, so an existing ledger is the first data set the daemon's ledger holds.
//!
//! Each leo-asks record becomes a `captured` (its words and source) and the events its fields
//! imply: `routed` to its owner, `prOpened` / `prMerged` per linked PR, then `answered` or
//! `dropped` when leo-asks settled it so. The ask's id is a digest of ("leo-asks", host, record
//! id), so a rerun captures nothing twice, and an event whose kind the ask already holds is not
//! added again: importing the same file twice adds nothing, and a newer file adds only what
//! changed (a new PR, a merge, an owner). leo-asks states the reconciler derives (`stale`,
//! `in_progress`, `done`) are not events and stay leo-asks's.
//!
//! Reached only through `_acpmux/ask_ledger_import` with `askLedger: true`: the same default-off
//! experiment the capture opts in with.

use super::{Kind, Line, TEXT_CHARS, identity};
use serde_json::{Value, json};

pub(crate) const METHOD: &str = "_acpmux/ask_ledger_import";
pub(crate) const SCHEMA: &str = "leo-asks/v1";
/// Who an imported event names as its cause.
const BY: &str = "leo-asks";

/// The events one `asks.json` holds, every ask's `captured` first, and how many records had no
/// id or time and were skipped.
pub(crate) fn lines(doc: &Value) -> Result<(Vec<Line>, usize), String> {
    if doc.get("schema").and_then(Value::as_str) != Some(SCHEMA) {
        return Err(format!("not a {SCHEMA} ledger"));
    }
    let Some(hosts) = doc.get("hosts").and_then(Value::as_object) else {
        return Err("no hosts".into());
    };
    let mut out = Vec::new();
    let mut skipped = 0;
    for (host, section) in hosts {
        let records =
            section.get("asks").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
        for record in records {
            match record_lines(host, record) {
                Some(lines) => out.extend(lines),
                None => skipped += 1,
            }
        }
    }
    Ok((out, skipped))
}

fn ms(value: Option<&Value>) -> Option<u64> {
    let at = chrono::DateTime::parse_from_rfc3339(value?.as_str()?).ok()?;
    u64::try_from(at.timestamp_millis()).ok()
}

fn str_of<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn record_lines(host: &str, record: &Value) -> Option<Vec<Line>> {
    let source_id = str_of(record, "id")?;
    let ts = ms(record.get("ts"))?;
    let host = str_of(record, "host").unwrap_or(host);
    let ask = identity(BY, host, source_id);
    let sid = format!("{BY}:{host}");
    let source = record.get("source").cloned().unwrap_or(Value::Null);
    let words = str_of(record, "full_text").or_else(|| str_of(record, "text")).unwrap_or("");
    let body: String = words.chars().take(TEXT_CHARS).collect();
    let row = json!({
        "id": ask,
        "messageId": source_id,
        "sessionId": str_of(&source, "session").or_else(|| str_of(record, "session")),
        "harness": str_of(&source, "harness"),
        "host": host,
        "text": body,
        "truncated": body.len() < words.len(),
        "createdAt": ts,
        "kind": str_of(record, "kind"),
        "area": str_of(record, "area"),
        "importedFrom": BY,
    });
    let event = |ts: u64, kind: Kind| Line::Event {
        ask: ask.clone(),
        sid: sid.clone(),
        ts,
        by: BY.into(),
        kind,
    };
    let mut lines = vec![event(ts, Kind::Captured { row })];
    let mut last = ts;
    if let Some(owner) = str_of(record, "owner") {
        lines.push(event(ts, Kind::Routed { to: owner.into() }));
    }
    for pr in record.get("prs").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]) {
        let (Some(repo), Some(number)) =
            (str_of(pr, "repo"), pr.get("number").and_then(Value::as_u64))
        else {
            continue;
        };
        let opened = ms(pr.get("created")).unwrap_or(ts).max(ts);
        lines.push(event(opened, Kind::PrOpened { repo: repo.into(), number }));
        last = last.max(opened);
        if pr.get("state").and_then(Value::as_str) == Some("MERGED") {
            let merged = ms(pr.get("merged")).unwrap_or(opened).max(opened);
            lines.push(event(merged, Kind::PrMerged { repo: repo.into(), number }));
            last = last.max(merged);
        }
    }
    match str_of(record, "status") {
        Some("answered") => lines.push(event(last, Kind::Answered)),
        Some("dropped") => {
            let reason = str_of(record, "status_reason").unwrap_or("dropped");
            lines.push(event(last, Kind::Dropped { reason: reason.into() }));
        }
        _ => {}
    }
    Some(lines)
}
