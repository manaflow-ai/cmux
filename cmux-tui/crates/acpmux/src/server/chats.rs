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
//!   harness's project folders grouped by acpmux (the cmux daemon reads them itself).
//! - `_acpmux/chats_search {query, ...filter, budgetMs?}`: the chats whose
//!   prompts or answers hold every word of `query`, each with its newest such
//!   message and a snippet, read now from the harnesses' stores within a time
//!   budget (`chats/search.rs`).
//! - `_acpmux/chat_open {key, cwd?}`: how the chat opens again (`chats/open.rs`), with the chat's
//!   value as `chat`:
//!   `adopt` with ready `session/new` params, `terminal` with argv/env/cwd,
//!   or `readOnly`; `needsFolder` when the person must pick the folder.
//! - `_acpmux/chat_resolve {ref}`: the chat a pasted reference names (`/resume <ref>`,
//!   `chats/resolve.rs`): a session id, its start, a transcript path, a key or a resume
//!   command. `{status: found, key, chat}`, `{status: ambiguous, chats}` (newest first, at most
//!   5), `{status: notFound}` or `{status: tooShort}`.
//! - `_acpmux/chat_transcript {key}`: the chat's past turns, read now from its
//!   harness's store: `{key, harness, title, cwd, turns: [{prompt, answer,
//!   promptAt?, answerAt?}]}`, the newest 200. A harness with no reader, or a
//!   file too large or unreadable, answers invalid params with `data.reason`
//!   `transcript_unsupported`, `transcript_too_large` or `transcript_unreadable`.
//! - `_acpmux/chat_transcript_page {key, cwd?, before?, metadataOnly?}` reads up to 32 terminal
//!   agent turns ending at a byte offset (the newest page by default). The response carries
//!   `pageEnd`, an older `before` cursor or null, and folded tool titles. A metadata-only read
//!   returns the key and dates without paging. Shortened rows supply UTF-8 offsets in `promptMore`
//!   or `answerMore`. Pass their `pageEnd` as `before` with `turn`, `role` (user or assistant), and
//!   `offset` for a bounded continuation `{text, nextOffset}` (null at the end of the message).
//!   `rawRanges: [{start,end,position}]` covers any complete JSONL source that spans the read cap.
//!   Positions are before or after the ordinary turns. Send the page's `before` cursor and
//!   `completeThrough` forward when paging older. To expand a range, send `before: pageEnd`,
//!   `completeThrough`, `rawStart`, `rawEnd`, and absolute UTF-8 byte `rawOffset`; the result
//!   is `{text,nextOffset}`, at most 64 KiB. End offsets are exclusive.
//! - `_acpmux/chat_transcript_find {key, cwd?, query, before?}` searches one bounded slice;
//!   `hits` supplies a page offset and turn index for each matching row, and `before` continues
//!   the search through older pages, including after an empty slice. Raw source hits use
//!   `role: "raw"` and `rawStart,rawEnd,rawOffset,completeThrough` instead of a turn index.
//!   These search rendered JSONL source literally (ASCII case-insensitive), including across
//!   chunks. JSON escape sequences are matched as written on disk.
//! - `_acpmux/chat_fork {harness, agentSessionId, cwd?}`: a terminal chat's fork, made by its
//!   harness's ACP agent (`chat_fork.rs`): `{harness, agentSessionId}` of the new session.
//! - `_acpmux/chat_roots`: the roots, refused roots with reasons, watcher errors.
//! - `_acpmux/chats_warm {chat?}`: `cmux chats warm`: every cold log segment of the chat, or of
//!   every chat, back to a plain `.ndjson` (`hub/cold_segments.rs`). Refused while
//!   `agents.chats.coldSegments` is on. `{chats, segments, rawBytes, compressedBytes, left,
//!   skipped}`: `left` names each segment that stays cold and why (nothing is removed).
//! - `_acpmux/chat_roots_record {harness, transcriptPath}`: a hook reports
//!   a transcript; its store root joins the index (recorded roots file).
//! - `_acpmux/chat_settings {enabled, discovery, roots, managedRoots,
//!   permissionMode?, permissionModeManaged?, allowFullAccess?,
//!   allowFullAccessManaged?, promptSuggestions?, promptSuggestionsManaged?}`:
//!   the app's effective cmux.json `agents.chats.*` values (`chats/settings.rs`)
//!   and its effective `agents.defaultPermissionMode`, `sessions.allowFullAccess`
//!   and `agents.promptSuggestions`, each with whether MDM or the team policy
//!   forces it (`hub/start_mode_state.rs`; a forced full-access off is an upper
//!   bound, a forced prompt-suggestions value beats the file); answers the roots view with
//!   `applied: true`. While chats are off, `_acpmux/chats` answers
//!   `enabled: false` and no chats.
//!
//! Titles and folders are user data (C5): only the local unix socket gets
//! them. Every WebSocket origin (Web, LocalApp, Peer) gets "Method not
//! found", like `_acpmux/directories`. Agents and MCP get them only through
//! the `chats.read` scope, which is never granted by default.

mod ledger;
mod offers;
mod scorecard;
mod search;
mod stats;
mod team_audit;
mod transcript;
mod transcript_index;
mod transcript_preview;
mod transcript_raw;
pub(crate) use team_audit::usage_upload_loop;
mod workspace_purge;

use crate::no_panic::JsonExt;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use super::{Conn, Origin};
use crate::chats::{ChatQuery, ChatService, change_value, changes_activity, transcript_turns};
use crate::heap_future::heap;
use crate::hub::Hub;
use crate::hub::HubEvent;
use crate::hub::chat_activity::activity_change;
use crate::rpc::{Message, RpcError};

const PREFIX: &str = "_acpmux/chat";

/// Answers the chat methods; every other method goes to `requests.rs`.
pub(super) async fn route(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
    sender_token: Option<crate::sender_token::Presented>,
) -> Result<Value, RpcError> {
    // A read-only paired machine reads, nothing else (`pairing.rs`), before any dispatcher.
    let params = super::pairing::gate(conn, m, params)?;
    // So does a teammate through the Cloud carrier, to its verbs (`carrier.rs`).
    let params = super::carrier::gate(hub, conn, m, params)?;
    // The app's and webviews' own spans of one user action, into this daemon's Perfetto trace
    // (`perf_trace.rs`): no store, no peer.
    if m == crate::perf_trace::METHOD_SPANS {
        return Ok(crate::perf_trace::record_client_spans(&params));
    }
    if m == crate::perf_trace::METHOD_STATUS {
        return Ok(
            serde_json::json!({"enabled": crate::perf_trace::enabled(), "now_us": crate::perf_trace::now_us()}),
        );
    }
    hub.prepare_store_request(m, &params).await;
    // The owner's phone a peer daemon vouches for on this request, before any rule reads it.
    super::remote_guard::note_vouched_phone(hub, conn, &params);
    if m == crate::rpc::method::MUX_OWNER_PHONE_CHANGED {
        return super::remote_guard::owner_phone_changed(hub, conn, &params).await;
    }
    // A browser's own device on the mesh hub (`web_device.rs`): web connections only.
    if let Some(reply) = super::web_device::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::pairing::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::machine_tunnel::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::consent_grant::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // Agent byte channels: listen, unlisten, open (`channels.rs`).
    if let Some(reply) = super::channels::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // Adding a machine this computer reaches over ssh (`machine_join_ssh.rs`): the app's only.
    if let Some(reply) = super::machine_join_ssh::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    #[cfg(feature = "hub-carrier")]
    if let Some(reply) = super::machine_routes::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = super::vault::dispatch(conn, m).await {
        return reply;
    }
    if let Some(reply) = super::share_host::dispatch(conn, m) {
        return reply;
    }
    // The secret methods check their own callers and never reach a peer (`secrets.rs`).
    if let Some(reply) = heap(|| super::secrets::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    // So do the MCP connect methods: the person answers the card (`mcp_connect.rs`).
    if let Some(reply) = heap(|| super::mcp_connect::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    // A one-shot completion runs a harness CLI with the user's own login:
    // the unix socket only. `Hub::complete` is its one gate (it never reaches
    // `remote_guard` or a peer).
    if m == crate::rpc::method::MUX_COMPLETE {
        return hub.complete(conn.origin, &params).await;
    }
    // So does a hunk's summary (`hub/hunk_summary.rs`), which runs one on a cache miss.
    if m == crate::rpc::method::MUX_HUNK_SUMMARY {
        return hub.hunk_summary(conn.origin, &params).await;
    }
    if let Some(reply) = offers::dispatch(hub, conn, m, &params) {
        return reply;
    }
    // So do the sub-session methods (`subsessions.rs`): this daemon's own sessions only.
    if let Some(reply) = heap(|| super::subsessions::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::races::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    // So do the forum methods (`forum.rs`): this daemon's own log.
    if let Some(reply) = heap(|| super::forum::dispatch(hub, conn, m, &params)).await {
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
    if let Some(reply) = heap(|| super::bg_tasks::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::run_elsewhere::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    // The machine's GitHub poller (`github_prs.rs`, `pr_poller.rs`).
    if let Some(reply) = super::github_prs::dispatch(conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::surgery::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = super::goal::dispatch(hub, conn, m, &params) {
        return reply;
    }
    if let Some(reply) = super::history::dispatch(hub, conn, m, &params).await {
        return reply;
    }
    // The plan approval card's builds (`plan_build.rs`): sub-sessions of this daemon.
    if let Some(reply) = heap(|| super::plan_build::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = super::agent_home::dispatch(conn, m, &params).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::memory_inbox::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::prompt_coach::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::pull_request_actions::dispatch(hub, conn, m, &params)).await
    {
        return reply;
    }
    if let Some(reply) = heap(|| super::workflow_runs::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    if let Some(reply) = heap(|| super::workflow_activity::dispatch(hub, conn, m, &params)).await {
        return reply;
    }
    // Moving a chat to another daemon (`hub/transfer_out.rs`): a bundle holds the whole chat and
    // runs its queue with the rules it was sent under, so only the local socket moves one.
    if m.starts_with("_acpmux/transfer_") {
        // What a move would interrupt is read-only: the app's own pane asks it too, to say so
        // before its Cloud / Auto / Evacuate (RFD 0063 item 6).
        let read_only = m == "_acpmux/transfer_interrupts" && conn.origin == Origin::LocalApp;
        if conn.origin != Origin::Local && !read_only {
            return Err(RpcError::method_not_found(&format!("{m} (local socket only)")));
        }
        // A move's finish may carry the owner's login for the chat's agent (`transfer_in.rs`),
        // taken as `session/new` takes one: never from an agent's own connection.
        if params.get(crate::agent_credentials::FIELD).is_some() {
            crate::agent_credentials::admit(true, conn.caller())?;
        }
        return heap(|| hub.transfer_request(m, &params)).await;
    }
    // An incognito workspace's chats, ended and deleted (`workspace_purge.rs`): local only.
    if m == workspace_purge::METHOD {
        return heap(|| workspace_purge::handle(hub, conn.origin, &params)).await;
    }
    // Personal stats over the session logs (`stats.rs`): local, never a peer's.
    if m == crate::rpc::method::MUX_STATS {
        return stats::handle(hub, conn.origin, &params).await;
    }
    // The harness-magic scorecard over the session logs (`scorecard.rs`): local, never a peer's.
    if m == crate::rpc::method::MUX_SCORECARD {
        return scorecard::handle(hub, conn.origin, &params).await;
    }
    // Replay of recorded logs against RFD 0161's invariants (`scorecard_replay.rs`): local only.
    if m == crate::rpc::method::MUX_SCORECARD_REPLAY {
        return scorecard::replay(hub, conn.origin, &params).await;
    }
    // The review queue, review verdicts and the approvals audit trail (`review_queue.rs`).
    if let Some(reply) =
        super::review_queue::route(hub, conn.origin, conn.auth, conn.is_person(), m, &params).await
    {
        return reply;
    }
    // What turns cost (`hub/ledger`): local and the app's pane, never a peer's.
    if m == crate::rpc::method::MUX_LEDGER {
        return ledger::handle(hub, conn.origin, &params);
    }
    // The team's spend, from cmux-platform with this daemon's sign-in: local and the app's pane.
    if m == crate::rpc::method::MUX_TEAM_AUDIT {
        return team_audit::handle(conn.origin, &params).await;
    }
    // Routing, moving and placing a chat belong to the request dispatcher, which checks the
    // caller's origin for each operation before running its handler.
    let of_a_session = matches!(
        m,
        crate::rpc::method::MUX_CHAT_ROUTE_SET
            | crate::rpc::method::MUX_CHAT_MOVE
            | "_acpmux/chat_place"
            | "_acpmux/chat_place_set"
    );
    if !m.starts_with(PREFIX) || of_a_session {
        return heap(|| super::requests::handle_request(hub, conn, m, params, sender_token)).await;
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
            // A chats watch hears every chat's activity (`push_activity`), attached or not.
            if on {
                conn.interest.hear_activity();
            }
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
        "_acpmux/chats_warm" => {
            // A `chat` that is there but not a string names no chat: refused, never every chat
            // (#43562 review F2).
            let chat = match params.get("chat") {
                None | Some(Value::Null) => None,
                Some(Value::String(chat)) => Some(chat.clone()),
                Some(other) => {
                    return Err(RpcError::invalid_params(format!(
                        "chat must be a chat id, not {other}"
                    )));
                }
            };
            let hub = hub.clone();
            blocking(move || {
                hub.warm_cold_segments(chat.as_deref())
                    .map_err(|e| RpcError::invalid_params(format!("{e:#}")))
            })
            .await
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
                let mut plan = crate::chats::plan_open(&chat, &profiles, cwd.as_deref(), &home)
                    .map_err(RpcError::invalid_params)?;
                // The chat itself (title, folder, harness), so a client that opens it holds no
                // copy of the index to name it.
                plan.set("chat", crate::chats::chat_value(&chat));
                Ok(plan)
            })
            .await
        }
        // `/resume <ref>`: the one chat a pasted id, id start, path or command names.
        "_acpmux/chat_resolve" => {
            let service =
                service.ok_or_else(|| RpcError::internal("the chat index is starting"))?;
            let text = params
                .get("ref")
                .and_then(Value::as_str)
                .filter(|text| text.len() <= 4096)
                .map(str::to_owned)
                .ok_or_else(|| RpcError::invalid_params("ref must be a string"))?;
            blocking(move || {
                Ok(match service.resolve_ref(&text) {
                    crate::chats::Resolved::Found(key) => match service.get(&key) {
                        Some(chat) => json!({
                            "status": "found",
                            "key": crate::chats::key_text(&key),
                            "chat": crate::chats::chat_value(&chat),
                        }),
                        None => json!({"status": "notFound"}),
                    },
                    crate::chats::Resolved::Ambiguous(keys) => {
                        let chats: Vec<Value> = keys
                            .iter()
                            .filter_map(|key| service.get(key))
                            .map(|chat| crate::chats::chat_value(&chat))
                            .collect();
                        json!({"status": "ambiguous", "chats": chats})
                    }
                    crate::chats::Resolved::TooShort => json!({"status": "tooShort"}),
                    crate::chats::Resolved::NotFound | crate::chats::Resolved::Unindexed(_) => {
                        json!({"status": "notFound"})
                    }
                })
            })
            .await
        }
        transcript::PAGE | transcript::FIND => {
            heap(|| transcript::handle(hub, service, m, &params)).await
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
            let (profile_name, mut profile) = {
                let cfg = hub.config.read().await;
                let (name, profile) =
                    crate::chat_fork::profile_for(&cfg, harness).ok_or_else(|| {
                        RpcError::invalid_params(format!(
                            "no ACP harness runs {harness} here, so its chat cannot fork"
                        ))
                    })?;
                (name.to_owned(), profile.clone())
            };
            if crate::config::derive_family(&profile_name, &profile) == "github-copilot" {
                let mut env = profile.env.clone();
                hub.apply_route_for(&profile_name, None, None, true, &profile, &mut env).await?;
                profile.env = env;
            }
            let forked = crate::chat_fork::fork(harness, &profile_name, &profile, id, &cwd).await?;
            crate::fork_spec::log(
                &crate::fork_spec::ForkSpec::preset(crate::fork_spec::Preset::TerminalChat),
                id,
                &forked,
            );
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
            hub.apply_prompt_suggestions_push(prompt_suggestions_forced(&params)?).await;
            hub.set_session_recap(settings.session_recap);
            hub.set_terminal_chat_writable(settings.terminal_chat_writable).await;
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

/// The `agents.promptSuggestions` MDM or the team policy forces, from a `_acpmux/chat_settings`
/// push: `None` unless `promptSuggestionsManaged` is true (an older app sends neither key). A forced
/// value that is not a boolean is off, so an unreadable policy never turns on extra model calls.
fn prompt_suggestions_forced(params: &Value) -> Result<Option<bool>, RpcError> {
    let managed = match params.get("promptSuggestionsManaged") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(managed)) => *managed,
        Some(_) => {
            return Err(RpcError::invalid_params("promptSuggestionsManaged must be true or false"));
        }
    };
    Ok(managed.then(|| params.get("promptSuggestions") == Some(&Value::Bool(true))))
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
                    // One activity per batch, shared by every watcher of it.
                    let activity = hub.chat_activity_for_batch(&changes);
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
    // A window shows the chat's activity too: its rows are recomputed when it may show this one.
    super::chat_windows::activity_changed(
        conn,
        &ev.session_id,
        &rec.kind,
        || {
            hub.resolve(&ev.session_id)
                .ok()
                .and_then(|session| crate::hub::chat_activity::session_chat_key(&session))
                .map(|key| crate::chats::key_text(&key))
        },
        // Read now, after the record: the newest session of the chat decides its fold.
        |chat| hub.chat_activity().has_parent(chat),
    );
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

/// `_acpmux/release_to_watch {sessionId, terminalPid?}`: once idle, the chat's harness stops and
/// the chat watches its own transcript, which a terminal now runs (`hub/release_to_watch.rs`).
/// `terminalPid` is the process that runs the conversation next (`acpmux resume-here`, which
/// becomes the harness): the chat's prompts go into it. It binds only when it is the caller itself
/// over this machine's unix socket, by the pid the kernel gave at accept. Any other `terminalPid`
/// (a pid the kernel did not give: a Windows pipe, a credential read that failed, an in-process
/// caller; another process's pid; a remote origin) is refused whole (`watch.terminal_unverified`):
/// nothing is released and nothing bound, so a caller never hands a chat to a process it only names.
pub(super) async fn release_to_watch(
    hub: &Arc<Hub>,
    params: &Value,
    origin: super::Origin,
    socket_peer: crate::sender_harness::SocketPeer,
) -> Result<Value, RpcError> {
    use crate::sender_harness::SocketPeer;
    let s = hub.resolve(super::session_key(params)?)?;
    // Write to a chat a terminal runs off (the default): `terminalPid` is not read at all, and the
    // chat becomes a View Only watch as before.
    let named = params.get("terminalPid").filter(|v| !v.is_null() && hub.terminal_chat_writable());
    let terminal = match named {
        None => None,
        Some(named) => {
            let named = named.as_u64().and_then(|p| u32::try_from(p).ok());
            match (named, origin, socket_peer) {
                (Some(named), super::Origin::Local, SocketPeer::Pid(pid)) if named == pid => {
                    Some(pid)
                }
                _ => return Err(terminal_unverified()),
            }
        }
    };
    hub.release_to_watch(&s, terminal).await
}

/// A `terminalPid` the daemon cannot prove is its caller's own (`release_to_watch`).
fn terminal_unverified() -> RpcError {
    RpcError::invalid_params(
        "a chat is handed to a terminal only by that terminal's own process over this machine's unix socket",
    )
    .with_data(json!({"reason": "watch.terminal_unverified"}))
}

#[cfg(test)]
mod prompt_suggestions_push_tests {
    use super::prompt_suggestions_forced;
    use serde_json::json;

    #[test]
    fn only_a_managed_push_forces_and_a_non_boolean_is_off() {
        let forced = |p| prompt_suggestions_forced(&p).unwrap();
        assert_eq!(forced(json!({})), None, "an older app sends neither key");
        assert_eq!(
            forced(json!({"promptSuggestions": false})),
            None,
            "not managed: the file decides"
        );
        assert_eq!(forced(json!({"promptSuggestionsManaged": null})), None);
        assert_eq!(
            forced(json!({"promptSuggestions": false, "promptSuggestionsManaged": true})),
            Some(false)
        );
        assert_eq!(
            forced(json!({"promptSuggestions": true, "promptSuggestionsManaged": true})),
            Some(true)
        );
        assert_eq!(
            forced(json!({"promptSuggestions": "true", "promptSuggestionsManaged": true})),
            Some(false)
        );
        assert_eq!(forced(json!({"promptSuggestionsManaged": true})), Some(false));
        assert!(prompt_suggestions_forced(&json!({"promptSuggestionsManaged": "yes"})).is_err());
    }
}
