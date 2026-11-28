//! Durable watches use the local outbox authority, never a Web/peer origin.
use super::*;
use crate::hub::watches::{Watch, resolve};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Add {
    to: Option<String>,
    #[serde(default)]
    sessions: Vec<String>,
    #[serde(default)]
    until: Vec<String>,
    #[serde(rename = "match")]
    match_text: Option<String>,
    /// Where `match` is looked for: `turn` (default, any reply text of the turn), `reply` (the
    /// turn's final reply only), `replyStart` (the final reply begins with it).
    #[serde(rename = "matchIn")]
    match_in: Option<crate::hub::watch_events::MatchIn>,
    once: Option<bool>,
    /// A time watch (`hub/watch_timers.rs`): first due time, period, last due time, in ms since
    /// the epoch (the CLI and MCP tool turn `--at`, `--every`, `--until` into these).
    #[serde(rename = "atMs")]
    at_ms: Option<u64>,
    #[serde(rename = "everyMs")]
    every_ms: Option<u64>,
    #[serde(rename = "endMs")]
    end_ms: Option<u64>,
    prompt: Option<String>,
}

/// A time watch's due time, period, end and prompt, or why the request is refused.
fn timer(a: &Add, now: u64) -> Result<(u64, Option<u64>, Option<u64>, String), RpcError> {
    use crate::hub::watches::timers::{MAX_PROMPT_BYTES, MIN_EVERY_MS};
    let bad = |m: &str| Err(RpcError::invalid_params(m.to_owned()));
    if !a.sessions.is_empty() || !a.until.is_empty() || a.match_text.is_some() {
        return bad("a time watch (at or every) takes no sessions, until states or match");
    }
    let prompt = match a.prompt.as_deref().map(str::trim) {
        Some(p) if !p.is_empty() => p.to_owned(),
        _ => return bad("a time watch needs a prompt: the message it sends when due"),
    };
    if prompt.len() > MAX_PROMPT_BYTES {
        return bad(&format!("prompt is over {MAX_PROMPT_BYTES} bytes"));
    }
    if a.every_ms.is_some_and(|e| e < MIN_EVERY_MS) {
        return bad(&format!("every must be at least {} s", MIN_EVERY_MS / 1000));
    }
    if a.end_ms.is_some() && a.every_ms.is_none() {
        return bad("an end time needs every");
    }
    let due = match (a.at_ms, a.every_ms) {
        (Some(at), _) => at,
        (None, Some(every)) => now.saturating_add(every),
        (None, None) => return bad("a time watch needs at or every"),
    };
    if a.end_ms.is_some_and(|end| end < due) {
        return bad("the end time is before the first fire");
    }
    Ok((due, a.every_ms, a.end_ms, prompt))
}
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(crate::hub::outbox::local_only());
    }
    match m {
        method::MUX_WATCH_LS => Ok(hub.watches.list(hub)),
        method::MUX_WATCH_RM => {
            let id = params["id"]
                .as_str()
                .ok_or_else(|| RpcError::invalid_params("watch id is required"))?;
            match hub.watches.remove(id)? {
                Some(owed) => Ok(json!({"removed": id, "owed": owed})),
                None => Err(RpcError::not_found(format!("no watch {id:?}; call _acpmux/watch_ls"))),
            }
        }
        _ => {
            hub.wait_logs().await;
            let mut a: Add = serde_json::from_value(params.clone())
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
            crate::hub::validate_match(a.match_text.as_deref())?;
            if a.match_in.is_some() && a.match_text.is_none() {
                return Err(RpcError::invalid_params(
                    "matchIn needs match: the text to look for in the turn's reply",
                ));
            }
            let time = (a.at_ms.is_some() || a.every_ms.is_some() || a.prompt.is_some())
                .then(|| timer(&a, crate::store::now_ms()))
                .transpose()?;
            if time.is_none() && a.once == Some(false) {
                return Err(RpcError::invalid_params("recurring watches are not supported yet"));
            }
            if time.is_none() && a.sessions.is_empty() {
                return Err(RpcError::invalid_params(
                    "watch needs at least one session; run acpmux ls",
                ));
            }
            if time.is_none() && a.until.is_empty() {
                a.until = vec!["ready".into(), "permission".into()];
            }
            if a.until
                .iter()
                .any(|u| !matches!(u.as_str(), "ready" | "permission" | "done" | "closed"))
            {
                return Err(RpcError::invalid_params(
                    "until accepts ready, permission, done or closed",
                ));
            }
            let key = match a.to.as_deref() {
                None | Some("@" | "current") => conn.caller().ok_or_else(|| {
                    RpcError::invalid_params(
                        "to is required without an authenticated caller session",
                    )
                })?,
                Some(to) => to,
            };
            let to = resolve(hub, key)?;
            let mut sessions =
                a.sessions.iter().map(|k| resolve(hub, k)).collect::<Result<Vec<_>, _>>()?;
            sessions.sort();
            sessions.dedup();
            if sessions.contains(&to) {
                return Err(RpcError::invalid_params(
                    "a session cannot watch itself (that would wake it forever)",
                ));
            }
            let cursors = sessions
                .iter()
                .map(|k| (k.clone(), crate::hub::watches::seed(hub, k, a.match_text.as_deref())))
                .collect();
            let (due_ms, every_ms, end_ms, prompt) = match time {
                Some((due, every, end, prompt)) => (Some(due), every, end, Some(prompt)),
                None => (None, None, None, None),
            };
            hub.watches.add(Watch {
                id: uuid::Uuid::now_v7().to_string(),
                to,
                sessions,
                until: a.until,
                match_text: a.match_text,
                match_in: a.match_in.unwrap_or_default(),
                once: a.once.unwrap_or(true) && every_ms.is_none(),
                caller: conn.caller().filter(|_| !conn.is_person()).map(str::to_owned),
                active: true,
                cursors,
                offline: Default::default(),
                due_ms,
                every_ms,
                end_ms,
                prompt,
            })
        }
    }
}
