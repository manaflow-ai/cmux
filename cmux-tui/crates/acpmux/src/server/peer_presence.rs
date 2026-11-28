//! Client-owned presence carried over a shared daemon link. Tokens are scoped to that link;
//! closing a client, detaching, or switching Live off withdraws only that client's entries.
//!
//! Reconnect restores accepted visible views after every successful peer handshake, without
//! needing a fresh client request. Typing is transient and never replaces the saved view.
//! Requests, replay and withdrawal serialize per entry and are pinned to the negotiated link.
//! Incoming tokens are bounded and belong to one canonical chat; detach releases that chat's
//! tokens even when a request used an alias. The peer integration presence tests cover these
//! lifecycle boundaries.
use super::{Conn, view};
use crate::{
    hub::Hub,
    no_panic::LockExt,
    peer::{ATTACH_RETRY_AFTER, Peer, refuses_attach},
    rpc::{RpcError, method},
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

const MAX_INCOMING_TOKENS: usize = 1024;

struct Entry {
    peer: Arc<Peer>,
    chat: String,
    author: String,
    token: String,
    link: AtomicU64,
    restored_link: AtomicU64,
    replay_link: AtomicU64,
    live_epoch: u64,
    leave: Value,
    view: Mutex<Option<Value>>,
    active: AtomicBool,
    sending: tokio::sync::Mutex<()>,
}

pub(super) struct Outgoing(Mutex<Option<Vec<Arc<Entry>>>>);
impl Default for Outgoing {
    fn default() -> Self {
        Self(Mutex::new(Some(Vec::new())))
    }
}

fn withdraw(hub: &Hub, entry: Arc<Entry>) {
    entry.active.store(false, Ordering::Release);
    hub.scope.spawn_named("peer-presence-withdraw", async move {
        // A withdrawal must follow an in-flight view even if its client closed meanwhile.
        let _sending = entry.sending.lock().await;
        let _ = entry
            .peer
            .request_on(
                method::MUX_VIEW,
                entry.leave.clone(),
                Some(entry.link.load(Ordering::Acquire)),
            )
            .await;
    });
}

impl Outgoing {
    pub(super) fn close(&self, hub: &Hub) {
        for entry in self.0.lock_or_recover().take().into_iter().flatten() {
            withdraw(hub, entry);
        }
    }

    fn remove(&self, hub: &Hub, matches: impl Fn(&Entry) -> bool) {
        if let Some(entries) = self.0.lock_or_recover().as_mut() {
            entries.retain(|entry| {
                if matches(entry) {
                    withdraw(hub, entry.clone());
                    false
                } else {
                    true
                }
            });
        }
    }

    pub(super) fn live_off(&self, hub: &Hub, epoch: u64) {
        self.remove(hub, |entry| entry.live_epoch < epoch);
    }

    pub(super) fn detach(&self, hub: &Hub, chat: &str) {
        self.remove(hub, |entry| entry.chat == chat);
    }

    /// Called when a peer finishes a handshake; coalesced notices restore every current link.
    pub(super) fn reconnected(&self, hub: &Arc<Hub>) {
        let entries = self.0.lock_or_recover().as_ref().cloned().unwrap_or_default();
        for entry in entries {
            if !entry.peer.connected.load(Ordering::SeqCst) {
                continue;
            }
            let Some(link) = entry.peer.lists_on(crate::hub::presence::PEER_FEATURE) else {
                continue;
            };
            if entry.restored_link.load(Ordering::Acquire) == link
                || entry.replay_link.swap(link, Ordering::AcqRel) == link
            {
                continue;
            }
            let owner = hub.clone();
            hub.scope.spawn_until_cancelled("peer-presence-replay", async move {
                for attempt in 0..=ATTACH_RETRY_AFTER.len() {
                    if attempt > 0 {
                        // Never hold `sending` during backoff: a leave must get through.
                        tokio::time::sleep(ATTACH_RETRY_AFTER[attempt - 1]).await;
                    }
                    let _sending = entry.sending.lock().await;
                    if !entry.active.load(Ordering::Acquire)
                        || !owner.presence.is_live()
                        || owner.presence.off_epoch() != entry.live_epoch
                        || entry.peer.lists_on(crate::hub::presence::PEER_FEATURE) != Some(link)
                        || !entry.peer.connected.load(Ordering::SeqCst)
                    {
                        break;
                    }
                    match restore(&entry, link, true).await {
                        Ok(()) => break,
                        Err(error) if refuses_attach(&error) => {
                            tracing::info!(peer = %entry.peer.name, %error, "presence replay refused; not retrying");
                            break;
                        }
                        Err(error) if attempt == ATTACH_RETRY_AFTER.len() => {
                            tracing::warn!(peer = %entry.peer.name, %error, attempt, "presence replay retries exhausted; next link or client request retries");
                        }
                        Err(error) => {
                            tracing::debug!(peer = %entry.peer.name, %error, attempt, "presence replay failed; retrying");
                        }
                    }
                }
            });
        }
    }

    pub(super) async fn send(
        &self,
        hub: &Arc<Hub>,
        conn: &Conn,
        peer: Arc<Peer>,
        method: &str,
        mut params: Value,
        link: u64,
    ) -> Result<Value, RpcError> {
        let chat = params["sessionId"].as_str().unwrap_or_default().to_owned();
        let author =
            crate::author::author(&params)?.ok_or_else(crate::hub::presence::peer_unsupported)?.id;
        let epoch = hub.presence.off_epoch();
        let entry = {
            let subs = conn.subs.lock_or_recover();
            if *conn.ended.borrow()
                || subs.get(&chat).is_none_or(|sub| {
                    !sub.remote || sub.remote_peer.as_deref() != Some(peer.name.as_str())
                })
            {
                return Err(RpcError::invalid_params(
                    "attach to the peer session before sharing presence",
                ));
            }
            let mut table = self.0.lock_or_recover();
            let entries =
                table.as_mut().ok_or_else(|| RpcError::invalid_params("client closed"))?;
            if let Some(entry) = entries.iter().find(|e| {
                Arc::ptr_eq(&e.peer, &peer)
                    && e.chat == chat
                    && e.author == author
                    && e.live_epoch == epoch
            }) {
                entry.clone()
            } else {
                let token = uuid::Uuid::now_v7().to_string();
                let mut leave = params.clone();
                leave["visible"] = json!(false);
                crate::hub::merge_mux_meta(
                    &mut leave,
                    json!({"presenceClient": token, "presenceLeave": true}),
                );
                let entry = Arc::new(Entry {
                    peer,
                    chat,
                    author,
                    token,
                    link: AtomicU64::new(link),
                    restored_link: AtomicU64::new(link),
                    replay_link: AtomicU64::new(link),
                    live_epoch: epoch,
                    leave,
                    view: Mutex::new(None),
                    active: AtomicBool::new(true),
                    sending: tokio::sync::Mutex::new(()),
                });
                entries.push(entry.clone());
                entry
            }
        };
        let owner = hub.clone();
        let hub = hub.clone();
        let method = method.to_owned();
        // Finish the wire request even if the caller cancels: its withdrawal waits for this
        // answer, so a late view cannot resurrect a client after its leave.
        owner
            .scope
            .spawn_named("peer-presence-send", async move {
                let _sending = entry.sending.lock().await;
                if !entry.active.load(Ordering::Acquire)
                    || !hub.presence.is_live()
                    || hub.presence.off_epoch() != epoch
                {
                    return Err(crate::hub::presence::peer_unsupported());
                }
                // A new view supersedes the saved one. In particular, hiding must not
                // depend on successfully replaying a stale visible view first.
                restore(&entry, link, method != method::MUX_VIEW).await?;
                crate::hub::merge_mux_meta(
                    &mut params,
                    json!({"presenceClient": entry.token, "presenceLeave": false}),
                );
                let result = entry.peer.request_on(&method, params.clone(), Some(link)).await?;
                // Only accepted viewing state survives reconnect. Typing has a short lifetime
                // and must neither overwrite a view nor be resurrected after an outage.
                if method == method::MUX_VIEW {
                    *entry.view.lock_or_recover() = (params["visible"] == true).then_some(params);
                    entry.restored_link.store(link, Ordering::Release);
                }
                Ok(result)
            })
            .await
            .map_err(|_| RpcError::internal("presence forwarding task ended"))?
    }
}

/// Caller holds `sending`, so reconnect, fresh requests and withdrawal stay ordered.
async fn restore(entry: &Entry, link: u64, replay_view: bool) -> Result<(), RpcError> {
    if entry.restored_link.load(Ordering::Acquire) == link {
        return Ok(());
    }
    if entry.peer.lists_on(crate::hub::presence::PEER_FEATURE) != Some(link) {
        return Err(crate::hub::presence::peer_unsupported());
    }
    // The ready notice can precede the handshake's hidden reattachments. Establish the
    // subscription on this exact link before restoring its synthetic client's view.
    entry
        .peer
        .request_on(
            method::MUX_ATTACH,
            json!({"sessionId": entry.chat, "visible": false, "limit": 0}),
            Some(link),
        )
        .await?;
    // A withdrawal must target this link even if a view is accepted but its reply is lost.
    entry.link.store(link, Ordering::Release);
    if replay_view {
        let view = entry.view.lock_or_recover().clone();
        if let Some(params) = view {
            entry.peer.request_on(method::MUX_VIEW, params, Some(link)).await?;
        }
        entry.restored_link.store(link, Ordering::Release);
    }
    Ok(())
}

/// Synthetic connection ids distinguish clients on the same authenticated peer link.
#[derive(Default)]
pub(super) struct Incoming(Mutex<HashMap<String, IncomingEntry>>);

struct IncomingEntry {
    chat: String,
    key: String,
}

impl Incoming {
    pub(super) fn key(&self, conn: &Conn, params: &Value, chat: &str) -> Result<String, RpcError> {
        if !view::a_link(conn) {
            return Ok(conn.id.clone());
        }
        let Some(token) = params.pointer("/_meta/acpmux/presenceClient").and_then(Value::as_str)
        else {
            return Ok(conn.id.clone());
        };
        if uuid::Uuid::parse_str(token).is_err() {
            return Err(RpcError::invalid_params("invalid presence client"));
        }
        let mut entries = self.0.lock_or_recover();
        if let Some(entry) = entries.get(token) {
            if entry.chat != chat {
                return Err(RpcError::invalid_params("presence client belongs to another chat"));
            }
            return Ok(entry.key.clone());
        }
        if entries.len() >= MAX_INCOMING_TOKENS {
            return Err(RpcError::invalid_params("too many presence clients on peer link"));
        }
        let key = format!("{}:presence:{}", conn.id, token);
        entries.insert(token.to_owned(), IncomingEntry { chat: chat.to_owned(), key: key.clone() });
        Ok(key)
    }

    pub(super) fn leave(
        &self,
        hub: &Hub,
        conn: &Conn,
        params: &Value,
        chat: &str,
    ) -> Result<bool, RpcError> {
        if !view::a_link(conn)
            || params.pointer("/_meta/acpmux/presenceLeave") != Some(&json!(true))
        {
            return Ok(false);
        }
        if let Some(token) = params.pointer("/_meta/acpmux/presenceClient").and_then(Value::as_str)
        {
            let mut entries = self.0.lock_or_recover();
            if entries.get(token).is_some_and(|entry| entry.chat != chat) {
                return Err(RpcError::invalid_params("presence client belongs to another chat"));
            }
            if let Some(entry) = entries.remove(token) {
                hub.presence.close(&entry.key);
            }
        }
        Ok(true)
    }

    pub(super) fn detach(&self, hub: &Hub, chat: &str) {
        let keys = {
            let mut entries = self.0.lock_or_recover();
            let tokens: Vec<_> = entries
                .iter()
                .filter(|(_, entry)| entry.chat == chat)
                .map(|(token, _)| token.clone())
                .collect();
            tokens
                .into_iter()
                .filter_map(|token| entries.remove(&token).map(|entry| entry.key))
                .collect::<Vec<_>>()
        };
        for key in keys {
            hub.presence.close(&key);
        }
    }

    pub(super) fn close(&self, hub: &Hub) {
        for (_, entry) in self.0.lock_or_recover().drain() {
            hub.presence.close(&entry.key);
        }
    }
}
