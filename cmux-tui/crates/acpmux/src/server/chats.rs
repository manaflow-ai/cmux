//! `_acpmux/chat*`: the device-wide chat index (ALL-CHATS-ON-DEVICE).
//!
//! - `_acpmux/chats {query?, harness?, folder?, account?, limit?, cursor?}`:
//!   one page, newest first: `{ready, chats, nextCursor}`.
//! - `_acpmux/chats_watch {enabled?, ...filter}`: the same page, then
//!   `_acpmux/chat_changed {kind: upsert|removed, key, chat?}` for every
//!   change on this connection (unfiltered; `_acpmux/chats_lagged` asks the
//!   client to list again).
//! - `_acpmux/chat_open {key, cwd?}`: how the chat opens again (`chats/open.rs`):
//!   `adopt` with ready `session/new` params, `terminal` with argv/env/cwd,
//!   or `readOnly`; `needsFolder` when the person must pick the folder.
//! - `_acpmux/chat_roots`: the roots, refused roots with reasons, watcher errors.
//! - `_acpmux/chat_roots_record {harness, transcriptPath}`: a hook reports
//!   a transcript; its store root joins the index (recorded roots file).
//! - `_acpmux/chat_settings {enabled, discovery, roots, managedRoots}`: the
//!   app's effective cmux.json `agents.chats.*` values (`chats/settings.rs`);
//!   answers the roots view with `applied: true`. While chats are off,
//!   `_acpmux/chats` answers `enabled: false` and no chats.
//!
//! Titles and folders are user data (C5): only the local unix socket gets
//! them. Every WebSocket origin (Web, LocalApp, Peer) gets "Method not
//! found", like `_acpmux/directories`. Agents and MCP get them only through
//! the `chats.read` scope, which is never granted by default.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use super::{Conn, Origin};
use crate::chats::{ChatQuery, ChatService, change_value};
use crate::hub::Hub;
use crate::rpc::{Message, RpcError};

const PREFIX: &str = "_acpmux/chat";

/// Answers the chat methods; every other method goes to `requests.rs`.
pub(super) async fn route(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    if !m.starts_with(PREFIX) {
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
            page(service, query).await
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
                    forward(service.clone(), conn.clone(), generation);
                }
            } else if on {
                // The index has not started (the app connects at launch):
                // subscribe when it does, and ask the client to list again.
                let conn = conn.clone();
                hub.when_chats_ready(Box::new(move |service| {
                    if conn.out.is_closed() {
                        return;
                    }
                    if let Some(generation) = service.watch_on(&conn.id) {
                        forward(service.clone(), conn.clone(), generation);
                    }
                    conn.send(&Message::notification(
                        "_acpmux/chats_lagged",
                        json!({"dropped": 0}),
                    ));
                }));
            }
            page(service, query).await
        }
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
                crate::chats::plan_open(&chat, &profiles, cwd.as_deref(), &home)
                    .map_err(RpcError::invalid_params)
            })
            .await
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
            let hub = hub.clone();
            blocking(move || {
                let running = hub.apply_chat_settings(settings).map_err(RpcError::internal)?;
                let mut view = match hub.chat_index() {
                    Some(service) if running => service.roots_view(),
                    _ => json!({"ready": false}),
                };
                view["applied"] = json!(true);
                Ok(view)
            })
            .await
        }
        other => Err(RpcError::method_not_found(other)),
    }
}

async fn page(service: Option<Arc<ChatService>>, query: ChatQuery) -> Result<Value, RpcError> {
    let Some(service) = service else {
        return Ok(json!({"ready": false, "chats": [], "nextCursor": null}));
    };
    blocking(move || {
        let (chats, next) = service.list(&query);
        let enabled = service.enabled();
        Ok(json!({"ready": true, "enabled": enabled, "chats": chats, "nextCursor": next}))
    })
    .await
}

/// The index lock may be held by a scan: never wait for it on the executor.
async fn blocking(
    f: impl FnOnce() -> Result<Value, RpcError> + Send + 'static,
) -> Result<Value, RpcError> {
    tokio::task::spawn_blocking(f).await.map_err(|e| RpcError::internal(e.to_string()))?
}

/// Sends every index change to `conn` until it closes or turns watching off.
fn forward(service: Arc<ChatService>, conn: Arc<Conn>, generation: u64) {
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
                    for change in changes.iter() {
                        conn.send(&Message::notification(
                            "_acpmux/chat_changed",
                            change_value(change),
                        ));
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
