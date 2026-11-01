//! `_acpmux/chat*`: the device-wide chat index (ALL-CHATS-ON-DEVICE).
//!
//! - `_acpmux/chats {query?, harness?, folder?, account?, limit?, cursor?}`:
//!   one page, newest first: `{ready, chats, nextCursor, seq}`. acpmux owns
//!   the order and each chat's `brand` (its agent mark id, or null).
//!   `seq` numbers the index changes: the page holds every change up to it.
//! - `_acpmux/chat_settled {query?, harness?, folder?, account?, limit?, cursor?}`:
//!   the same read-only history page, explicitly marked `settled: true`.
//! - `_acpmux/chats_watch {enabled?, ...filter}`: the same page, then
//!   `_acpmux/chat_changed {kind: upsert|removed, seq, key, chat?}` for every
//!   change on this connection (unfiltered; `_acpmux/chats_lagged` asks the
//!   client to list again). `seq` goes up by one per index change: a change
//!   at or below the page's `seq` is already in the page, and a jump means a
//!   lost change (list again). One file change is one delta. And `{kind: activity, key, attention, preview}`
//!   when the live session continuing a chat changes what it needs from the
//!   person (`chats/activity.rs`). Every chat value carries `attention`
//!   (`needsInput`, `failed`, `unread` or null) and `preview` (its live
//!   session's latest reply, or null).
//! - `_acpmux/chats_window {window, ...filter, limit?, topLevel?, exclude?, keys?}` and
//!   `_acpmux/chats_window_close {window}`: a client's visible window, kept current with row
//!   diffs (`_acpmux/chats_window_changed`, `chat_windows.rs`). A client that shows a list asks
//!   for its window instead of mirroring the whole index.
//! - `_acpmux/chat_projects`: `{ready, enabled, projects: [{harness, path, lastUsedMs}]}`, each
//!   harness's project folders grouped by acpmux (the app relays them to the cmux daemon).
//! - `_acpmux/chats_search {query, ...filter, budgetMs?}`: the chats whose
//!   prompts or answers hold every word of `query`, each with its newest such
//!   message and a snippet, read now from the harnesses' stores within a time
//!   budget (`chats/search.rs`).
//! - `_acpmux/chat_open {key, cwd?}`: how the chat opens again (`chats/open.rs`), with the chat's
//!   value as `chat`:
//!   `adopt` with ready `session/new` params, `terminal` with argv/env/cwd,
//!   or `readOnly`; `needsFolder` when the person must pick the folder.
//! - `_acpmux/chat_transcript {key}`: the chat's past turns, read now from its
//!   harness's store: `{key, harness, title, cwd, turns: [{prompt, answer,
//!   promptAt?, answerAt?}]}`, the newest 200. A harness with no reader, or a
//!   file too large or unreadable, answers invalid params with `data.reason`
//!   `transcript_unsupported`, `transcript_too_large` or `transcript_unreadable`.
//! - `_acpmux/chat_fork {harness, agentSessionId, cwd?}`: a terminal chat's fork, made by its
//!   harness's ACP agent (`chat_fork.rs`): `{harness, agentSessionId}` of the new session.
//! - `_acpmux/chat_roots`: the roots, refused roots with reasons, watcher errors.
//! - `_acpmux/chat_roots_record {harness, transcriptPath}`: a hook reports
//!   a transcript; its store root joins the index (recorded roots file).
//! - `_acpmux/chat_settings {enabled, discovery, roots, managedRoots,
//!   permissionMode?, permissionModeManaged?, allowFullAccess?,
//!   allowFullAccessManaged?}`: the app's effective cmux.json
//!   `agents.chats.*` values (`chats/settings.rs`) and its effective
//!   `agents.defaultPermissionMode` and `sessions.allowFullAccess`, each with
//!   whether MDM or the team policy forces it (`hub/start_mode_state.rs`; a
//!   forced full-access off is an upper bound); answers the roots view with
//!   `applied: true`. While chats are off, `_acpmux/chats` answers
//!   `enabled: false` and no chats.
//!
//! Titles and folders are user data (C5): only the local unix socket gets
//! them. Every WebSocket origin (Web, LocalApp, Peer) gets "Method not
//! found", like `_acpmux/directories`. Agents and MCP get them only through
//! the `chats.read` scope, which is never granted by default.

mod offers;
mod search;
mod stats;

use crate::no_panic::JsonExt;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use super::{Conn, Origin};
use crate::chats::{ChatQuery, ChatService, activity_change, change_value, changes_activity};
use crate::hub::Hub;
use crate::hub::HubEvent;
use crate::rpc::{Message, RpcError};

const PREFIX: &str = "_acpmux/chat";

/// Answers the chat methods; every other method goes to `requests.rs`.
pub(super) async fn route(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    // A read-only paired machine reads, nothing else (`pairing.rs`), before any dispatcher.
    let params = super::pairing::gate(conn, m, params)?;
    hub.prepare_store_request(m, &params).await;
    if let Some(reply) = super::pairing::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // The secret methods check their own callers and never reach a peer (`secrets.rs`).
    if let Some(reply) = super::secrets::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // A one-shot completion runs a harness CLI with the user's own login:
    // the unix socket only. `Hub::complete` is its one gate (it never reaches
    // `remote_guard` or a peer).
    if m == crate::rpc::method::MUX_COMPLETE {
        return hub.complete(conn.origin, &params).await;
    }
    if let Some(reply) = offers::dispatch(hub, conn, m, &params) {
        return reply;
    }
    // So do the sub-session methods (`subsessions.rs`): this daemon's own sessions only.
    if let Some(reply) = super::subsessions::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // So do the forum methods (`forum.rs`): this daemon's own log.
    if let Some(reply) = super::forum::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // So do the process methods (`processes.rs`).
    // And the worktree cleanup methods (`worktrees.rs`).
    if let Some(reply) = super::worktrees::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::worktrees::retention(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::processes::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::bg_tasks::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // Moving a chat to another daemon (`hub/transfer_out.rs`): a bundle holds the whole chat and
    // runs its queue with the rules it was sent under, so only the local socket moves one.
    if m.starts_with("_acpmux/transfer_") {
        if conn.origin != Origin::Local {
            return Err(RpcError::method_not_found(&format!("{m} (local socket only)")));
        }
        return hub.transfer_request(m, &params).await;
    }
    // Personal stats over the session logs (`stats.rs`): local, never a peer's.
    if m == crate::rpc::method::MUX_STATS {
        return stats::handle(hub, conn.origin, &params).await;
    }
    // A chat's route (`routes.rs`) is a session method, not the chat index.
    if !m.starts_with(PREFIX) || m == crate::rpc::method::MUX_CHAT_ROUTE_SET {
        return super::requests::handle_request(hub, conn, m, params).await;
    }
    if conn.origin != Origin::Local {
        return Err(RpcError::method_not_found(&format!(
            "{m} (served only on the local unix socket)"
        )));
    }
    let service = hub.chat_index().cloned();
    match m {
        "_acpmux/chats" => {
            let query = ChatQuery::from_params(&params).map_err(RpcError::invalid_params)?;
            page(hub, service, query).await
        }
        "_acpmux/chat_settled" => {
            let query = ChatQuery::from_params(&params).map_err(RpcError::invalid_params)?;
            settled_page(hub, service, query).await
        }
        "_acpmux/chats_watch" => {
            let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
            let query = ChatQuery::from_params(&params).map_err(RpcError::invalid_params)?;
            if let Some(service) = &service {
                if !on {
                    service.watch_off(&conn.id);
                    return Ok(json!({"ready": true, "watching": false}));
                }
                // Subscribe before the snapshot so no change falls between.
                if let Some(generation) = service.watch_on(&conn.id) {
                    forward(hub.clone(), service.clone(), conn.clone(), generation);
                }
            } else if on {
                // The index has not started (the app connects at launch):
                // subscribe when it does, and ask the client to list again.
                let conn = conn.clone();
                let owner = hub.clone();
                hub.when_chats_ready(Box::new(move |service| {
                    if conn.out.is_closed() {
                        return;
                    }
                    if let Some(generation) = service.watch_on(&conn.id) {
                        forward(owner.clone(), service.clone(), conn.clone(), generation);
                    }
                    conn.send(&Message::notification(
                        "_acpmux/chats_lagged",
                        json!({"dropped": 0}),
                    ));
                }));
            }
            page(hub, service, query).await
        }
        // The chats whose prompts or answers hold the words (`chats/search.rs`).
        "_acpmux/chats_search" => search::handle(hub, service, &params).await,
        "_acpmux/chat_roots" => match service {
            Some(service) => blocking(move || Ok(service.roots_view())).await,
            None => Ok(json!({"ready": false, "roots": [], "refused": []})),
        },
        "_acpmux/chat_open" => {
            let service =
                service.ok_or_else(|| RpcError::internal("the chat index is starting"))?;
            let key = params
                .get("key")
                .and_then(Value::as_str)
                .and_then(crate::chats::parse_key)
                .ok_or_else(|| {
                RpcError::invalid_params("key must be <harness>:<session id>")
            })?;
            let cwd = params.get("cwd").and_then(Value::as_str).map(PathBuf::from);
            let homes = hub.harness_homes();
            let profiles = crate::chats::store_profiles(&*hub.config.read().await, &homes);
            blocking(move || {
                let chat = service.get(&key).ok_or_else(|| {
                    RpcError::not_found(format!("no chat {}", crate::chats::key_text(&key)))
                })?;
                let home = dirs::home_dir().unwrap_or_default();
                let mut plan = crate::chats::plan_open(&chat, &profiles, cwd.as_deref(), &home)
                    .map_err(RpcError::invalid_params)?;
                // The chat itself (title, folder, harness), so a client that opens it holds no
                // copy of the index to name it.
                plan.set("chat", crate::chats::chat_value(&chat));
                Ok(plan)
            })
            .await
        }
        // A chat's past turns from its harness's store, read now and never kept: for a chat with
        // no ACP resume (cx-5esm), and a Claude Code or Codex chat shown before it is adopted.
        "_acpmux/chat_transcript" => {
            let service =
                service.ok_or_else(|| RpcError::internal("the chat index is starting"))?;
            let key = params
                .get("key")
                .and_then(Value::as_str)
                .and_then(crate::chats::parse_key)
                .ok_or_else(|| {
                RpcError::invalid_params("key must be <harness>:<session id>")
            })?;
            blocking(move || {
                let chat = service.get(&key).ok_or_else(|| {
                    RpcError::not_found(format!("no chat {}", crate::chats::key_text(&key)))
                })?;
                let entry = &chat.entry;
                let turns = transcript_turns(entry).map_err(|e| {
                    RpcError::invalid_params(format!("transcript.{}: {e}", e.code()))
                        .with_data(json!({"reason": format!("transcript_{}", e.code())}))
                })?;
                Ok(json!({
                    "key": crate::chats::key_text(&key),
                    "harness": entry.harness.id(),
                    "title": entry.title,
                    "cwd": entry.cwd,
                    "turns": turns,
                }))
            })
            .await
        }
        // Fork Conversation of a terminal chat whose agent's CLI has no fork (`chat_fork.rs`).
        "_acpmux/chat_fork" => {
            let text = |key: &str| {
                params.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
            };
            let harness =
                text("harness").ok_or_else(|| RpcError::invalid_params("harness is missing"))?;
            let id = text("agentSessionId")
                .ok_or_else(|| RpcError::invalid_params("agentSessionId is missing"))?;
            let cwd = text("cwd")
                .map(PathBuf::from)
                .or_else(dirs::home_dir)
                .unwrap_or_else(|| PathBuf::from("/"));
            let (family, profile) = {
                let cfg = hub.config.read().await;
                let (name, profile) =
                    crate::chat_fork::profile_for(&cfg, harness).ok_or_else(|| {
                        RpcError::invalid_params(format!(
                            "no ACP harness runs {harness} here, so its chat cannot fork"
                        ))
                    })?;
                (crate::config::derive_family(name, profile), profile.clone())
            };
            let forked = crate::chat_fork::fork(harness, &family, &profile, id, &cwd).await?;
            Ok(json!({"harness": harness, "agentSessionId": forked}))
        }
        "_acpmux/chat_roots_record" => {
            let service =
                service.ok_or_else(|| RpcError::internal("the chat index is starting"))?;
            let harness = params
                .get("harness")
                .and_then(Value::as_str)
                .and_then(cmux_chat_index::AdapterKind::from_id)
                .ok_or_else(|| RpcError::invalid_params("harness must be claude-code or codex"))?;
            let path = params
                .get("transcriptPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .ok_or_else(|| RpcError::invalid_params("transcriptPath is missing"))?;
            blocking(move || {
                let added =
                    service.record_transcript(harness, &path).map_err(RpcError::invalid_params)?;
                Ok(json!({"added": added}))
            })
            .await
        }
        "_acpmux/chat_settings" => {
            let settings = crate::chats::ChatSettings::from_params(&params)
                .map_err(RpcError::invalid_params)?;
            let managed = match params.get("permissionModeManaged") {
                None | Some(Value::Null) => false,
                Some(Value::Bool(managed)) => *managed,
                Some(_) => {
                    return Err(RpcError::invalid_params(
                        "permissionModeManaged must be true or false",
                    ));
                }
            };
            // Anything but a short string is no value; forced, that is a
            // value acpmux does not know (`Hub::apply_permission_push`). The
            // rest of the push applies either way.
            let mode = match params.get("permissionMode") {
                Some(Value::String(mode)) if mode.len() <= 64 => Some(mode.clone()),
                None | Some(Value::Null) => None,
                Some(other) => {
                    let kind =
                        if other.is_string() { "an over-long string" } else { "not a string" };
                    tracing::warn!(
                        managed,
                        "chat_settings permissionMode is {kind}; read as no value"
                    );
                    None
                }
            };
            hub.apply_permission_push(mode, managed).await;
            // `sessions.allowFullAccess` as MDM or the team policy forces it: only a forced value
            // counts, and anything but `true` is off. No key (an older app, or nothing forced)
            // forces nothing.
            let full_access_managed = match params.get("allowFullAccessManaged") {
                None | Some(Value::Null) => false,
                Some(Value::Bool(managed)) => *managed,
                Some(_) => {
                    return Err(RpcError::invalid_params(
                        "allowFullAccessManaged must be true or false",
                    ));
                }
            };
            let forced = full_access_managed
                .then(|| params.get("allowFullAccess") == Some(&Value::Bool(true)));
            hub.apply_full_access_push(forced).await;
            let hub = hub.clone();
            blocking(move || {
                let running = hub.apply_chat_settings(settings).map_err(RpcError::internal)?;
                let mut view = match hub.chat_index() {
                    Some(service) if running => service.roots_view(),
                    _ => json!({"ready": false}),
                };
                view.set("applied", json!(true));
                Ok(view)
            })
            .await
        }
        "_acpmux/chat_projects" => {
            let Some(service) = service else {
                return Ok(json!({"ready": false, "enabled": true, "projects": []}));
            };
            let activity = hub.chat_activity();
            blocking(move || {
                Ok(match service.projects(&activity) {
                    Some(projects) => json!({"ready": true, "enabled": true, "projects": projects}),
                    None => json!({"ready": true, "enabled": false, "projects": []}),
                })
            })
            .await
        }
        "_acpmux/chats_window" => super::chat_windows::open(hub, conn, service, &params).await,
        "_acpmux/chats_window_close" => super::chat_windows::close(conn, &params),
        other => Err(RpcError::method_not_found(other)),
    }
}

async fn page(
    hub: &Arc<Hub>,
    service: Option<Arc<ChatService>>,
    query: ChatQuery,
) -> Result<Value, RpcError> {
    let Some(service) = service else {
        return Ok(json!({"ready": false, "chats": [], "nextCursor": null}));
    };
    let activity = hub.chat_activity();
    blocking(move || {
        let (mut chats, next, seq) = service.list_at(&query);
        for chat in &mut chats {
            activity.decorate(chat);
        }
        let enabled = service.enabled();
        Ok(json!({"ready": true, "enabled": enabled, "chats": chats, "nextCursor": next, "seq": seq}))
    })
    .await
}

/// The settled view is an explicit contract for clients that show device-wide
/// history. It intentionally reuses the same index and filters as `_acpmux/chats`;
/// the distinction is the UI disposition, not a second transcript store.
async fn settled_page(
    hub: &Arc<Hub>,
    service: Option<Arc<ChatService>>,
    query: ChatQuery,
) -> Result<Value, RpcError> {
    let mut page = page(hub, service, query).await?;
    page.set("settled", Value::Bool(true));
    Ok(page)
}

/// A chat's turns: Claude Code and Codex through adopt's reader (`adopt_replay.rs`, the turns an
/// adopted chat replays), every other harness through `cmux_chat_index::transcript`. Both come
/// out with the same caps, and a file that cannot be read is an error, never "no turns".
fn transcript_turns(
    entry: &cmux_chat_index::ChatEntry,
) -> Result<Vec<cmux_chat_index::transcript::Turn>, cmux_chat_index::transcript::TranscriptError> {
    use cmux_chat_index::AdapterKind;
    use cmux_chat_index::transcript::{TranscriptError, Turn, capped};
    let family = match entry.harness {
        AdapterKind::ClaudeCode => "claude",
        AdapterKind::Codex => "codex",
        kind => {
            return cmux_chat_index::transcript::read_turns(
                kind,
                &entry.source_path,
                &entry.session_id,
            );
        }
    };
    // adopt's reader answers an unreadable file with no turns.
    std::fs::File::open(&entry.source_path)
        .map_err(|e| TranscriptError::Unreadable(e.to_string()))?;
    let turns = crate::adopt_replay::read(family, &entry.source_path);
    Ok(turns
        .into_iter()
        .map(|t| Turn {
            prompt: capped(t.prompt),
            // No answer yet has no answer time (adopt's reader starts it at the prompt's).
            answer_at: t.answer_at.filter(|_| !t.answer.is_empty()),
            answer: capped(t.answer),
            prompt_at: t.prompt_at,
        })
        .collect())
}

/// The index lock may be held by a scan: never wait for it on the executor.
async fn blocking(
    f: impl FnOnce() -> Result<Value, RpcError> + Send + 'static,
) -> Result<Value, RpcError> {
    tokio::task::spawn_blocking(f).await.map_err(|e| RpcError::internal(e.to_string()))?
}

/// Sends every index change to `conn` until it closes or turns watching off.
fn forward(hub: Arc<Hub>, service: Arc<ChatService>, conn: Arc<Conn>, generation: u64) {
    let mut rx = service.subscribe();
    tokio::spawn(async move {
        loop {
            let next = tokio::select! {
                () = conn.out.closed() => break,
                next = rx.recv() => next,
            };
            if !service.is_watching(&conn.id, generation) {
                return;
            }
            match next {
                Ok(changes) => {
                    let activity = hub.chat_activity();
                    for change in changes.iter() {
                        let mut value = change_value(change);
                        if let Some(chat) = value.get_mut("chat") {
                            activity.decorate(chat);
                        }
                        conn.send(&Message::notification("_acpmux/chat_changed", value));
                    }
                }
                Err(RecvError::Lagged(dropped)) => conn.send(&Message::notification(
                    "_acpmux/chats_lagged",
                    json!({"dropped": dropped}),
                )),
                Err(RecvError::Closed) => break,
            }
        }
        service.watch_off(&conn.id);
    });
}

/// AV: a session record that can change its chat's attention or preview
/// reaches a chats watcher as `_acpmux/chat_changed {kind: "activity"}`,
/// whether or not the connection watches or attaches to sessions.
pub(super) fn push_activity(hub: &Hub, conn: &Conn, ev: &HubEvent) {
    let rec = &ev.record;
    if rec.dir != "mux" || !changes_activity(&rec.kind) {
        return;
    }
    // A window shows the chat's activity too: its rows are recomputed.
    super::chat_windows::activity_changed(conn);
    if !hub.chat_index().is_some_and(|service| service.watches(&conn.id)) {
        return;
    }
    if let Ok(session) = hub.resolve(&ev.session_id)
        && let Some(change) = activity_change(hub, &session)
    {
        conn.send(&Message::notification("_acpmux/chat_changed", change));
    }
}

/// `_acpmux/watch_take_over {sessionId, ifLive?}`: the watched chat runs the conversation itself
/// (`hub/watch.rs`).
pub(super) async fn watch_take_over(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(super::session_key(params)?)?;
    let if_live = crate::adopt::IfLive::parse(super::str_param(params, "ifLive"))
        .map_err(RpcError::invalid_params)?;
    hub.watch_take_over(&s, if_live).await
}
