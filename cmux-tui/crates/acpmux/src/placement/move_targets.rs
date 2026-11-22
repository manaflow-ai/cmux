//! A started chat's Move to… destinations. This is the same placement reading and ranking as
//! `session move`, without its SSH probes or any side effects. A later probe may select a fallback.

use super::{Candidate, Work};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

/// Connected machines, once each and excluding the source. Non-SSH peers remain visible with an
/// explanation because `session move` currently reaches the target daemon only through SSH.
/// Named SSH targets allow a busy or interactive machine; Auto follows the move's stricter filter.
pub(crate) fn targets(
    rows: &[Value],
    source: Option<&str>,
    source_kind: Option<&str>,
    registry: Option<&Value>,
) -> Value {
    // Cloud's existing transfer path must bring the chat here before session move can reach it.
    // An omitted kind keeps older callers' local/SSH behavior unchanged.
    let source_reason =
        (source_kind == Some("cloud")).then_some("Move this chat to This Mac first");
    let source = source.map(|name| identity(registry, name));
    let mut seen = HashSet::new();
    let mut peers: Vec<&Value> = rows
        .iter()
        .filter(|row| super::peer_down(row).is_none())
        .filter(|row| {
            let Some(name) = row.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())
            else {
                return false;
            };
            let name = identity(registry, name);
            source.as_ref() != Some(&name) && seen.insert(name)
        })
        .collect();
    peers.sort_by_key(|row| {
        row.get("name").and_then(Value::as_str).unwrap_or_default().to_lowercase()
    });
    let candidates: Vec<Candidate> = peers.iter().filter_map(|row| Candidate::peer(row)).collect();
    let verdict = super::place(&candidates, registry, Work::Agent);
    let hosts = verdict.get("hosts").and_then(Value::as_array).cloned().unwrap_or_default();
    let by_name: HashMap<&str, &Value> =
        hosts.iter().filter_map(|host| Some((host.get("name")?.as_str()?, host))).collect();
    let mut entries: Vec<Value> = peers
        .iter()
        .filter_map(|row| {
            let name = row.get("name")?.as_str()?;
            let host = by_name.get(name).copied().unwrap_or(&Value::Null);
            let ssh = row
                .get("url")
                .and_then(Value::as_str)
                .is_some_and(|url| crate::peer::ssh_target(url).is_ok());
            let reason = if let Some(reason) = source_reason {
                Some(reason.to_owned())
            } else if ssh {
                super::held(registry, name)
            } else {
                Some("Moving to this machine requires an SSH connection".to_owned())
            };
            Some(json!({"id": name, "machine": name, "label": name,
                "kind": if ssh { "ssh" } else { "remote" }, "status": room_words(host),
                "room": host.get("room"), "reason": reason}))
        })
        .collect();
    let by_name: HashMap<&str, &Value> =
        entries.iter().filter_map(|entry| Some((entry.get("id")?.as_str()?, entry))).collect();
    let (order, _) = ranked(&hosts, &HashMap::new(), |name| {
        if super::interactive(registry, name) {
            return Some("Auto leaves machines in use by a person out".to_owned());
        }
        let entry = by_name.get(name)?;
        entry.get("reason").and_then(Value::as_str).map(str::to_owned)
    });
    let pick = order.first();
    let picked = pick.and_then(|name| by_name.get(name.as_str()).copied());
    let status = picked.map(|entry| {
        format!(
            "{} · {}",
            entry.get("label").and_then(Value::as_str).unwrap_or_default(),
            entry.get("status").and_then(Value::as_str).unwrap_or_default()
        )
    });
    let auto = json!({"id": "auto", "label": "Auto", "kind": "auto", "machine": pick,
        "status": status.unwrap_or_else(|| source_reason
            .unwrap_or("No connected machine can take this chat").to_owned()),
        "room": picked.and_then(|entry| entry.get("room")),
        "reason": source_reason.or_else(|| pick.is_none()
            .then_some("Connect an SSH machine to move this chat automatically"))});
    entries.insert(0, auto);
    json!({"targets": entries, "pick": pick})
}

/// Registry aliases describe one machine, even when saved peers use different host names.
pub(crate) fn identity(registry: Option<&Value>, name: &str) -> String {
    let canonical = super::canonical(name);
    registry
        .and_then(|r| r.get("machines"))
        .and_then(Value::as_object)
        .and_then(|machines| {
            machines
                .iter()
                .find(|(key, machine)| super::machine_names(key, machine).contains(&canonical))
                .map(|(key, _)| super::canonical(key))
        })
        .unwrap_or(canonical)
}

/// Room is counted by placement, never estimated by the menu. A missing health reading remains
/// unknown, and load/pressure is a warning rather than a reason to refuse a named move.
fn room_words(host: &Value) -> String {
    if host.get("load").and_then(Value::as_bool) == Some(true) {
        return "busy".to_owned();
    }
    match host.get("room").and_then(Value::as_f64) {
        Some(room) => format!("room for {room:.0}"),
        None => "room unknown".to_owned(),
    }
}

/// The hosts that may take the move, best first, and every other host with why it was passed
/// over: hosts that take the work first (`ok`), else those passed over only for load (`load`,
/// as `place` does: load caps only warn), by most room left, less the chats this run put there,
/// then fewer agents. Never this machine, never one placement refuses for its role or
/// `unusable` names a reason for.
pub(crate) fn ranked(
    hosts: &[Value],
    placed: &HashMap<String, f64>,
    unusable: impl Fn(&str) -> Option<String>,
) -> (Vec<String>, Vec<(String, String)>) {
    let name = |h: &Value| h.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let mine = |h: &Value| placed.get(&name(h)).copied().unwrap_or(0.0);
    let room = |h: &Value| h.get("room").and_then(Value::as_f64).unwrap_or(-1.0) - mine(h);
    // Fewer agents (live there, plus this run's) breaks a tie in room.
    let busy = |h: &Value| h.get("live").and_then(Value::as_f64).unwrap_or(f64::MAX) + mine(h);
    let mut usable_hosts: Vec<&Value> = Vec::new();
    let mut skipped = Vec::new();
    for h in hosts {
        if h.get("local").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let ok = h.get("ok").and_then(Value::as_bool) == Some(true);
        let load = h.get("load").and_then(Value::as_bool) == Some(true);
        if !ok && !load {
            let why = h.get("refused").and_then(Value::as_str).unwrap_or("refused by placement");
            skipped.push((name(h), why.to_owned()));
            continue;
        }
        if let Some(why) = unusable(&name(h)) {
            skipped.push((name(h), why));
            continue;
        }
        usable_hosts.push(h);
    }
    usable_hosts.sort_by(|a, b| {
        let fits = |h: &Value| h.get("ok").and_then(Value::as_bool) == Some(true) && room(h) >= 1.0;
        fits(b).cmp(&fits(a)).then(room(b).total_cmp(&room(a))).then(busy(a).total_cmp(&busy(b)))
    });
    (usable_hosts.iter().map(|h| name(h)).collect(), skipped)
}

#[cfg(test)]
#[path = "move_targets_tests.rs"]
mod tests;
