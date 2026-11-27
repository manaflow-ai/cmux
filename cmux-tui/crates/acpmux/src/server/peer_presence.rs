//! Client-owned presence carried over a shared daemon link. Tokens are scoped to that link;
//! closing a client, detaching, or switching Live off withdraws only that client's entries.
use super::{Conn, view};
use crate::{
    hub::Hub,
    no_panic::LockExt,
    peer::Peer,
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
    live_epoch: u64,
    leave: Value,
    replay: Mutex<(String, Value)>,
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
        let (entry, replay) = {
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
            let mut replay = Vec::new();
            for entry in entries.iter() {
                if Arc::ptr_eq(&entry.peer, &peer)
                    && entry.link.load(Ordering::Acquire) != link
                    && entry.active.load(Ordering::Acquire)
                {
                    entry.link.store(link, Ordering::Release);
                    replay.push(entry.clone());
                }
            }
            let entry = if let Some(entry) = entries.iter().find(|e| {
                Arc::ptr_eq(&e.peer, &peer)
                    && e.link.load(Ordering::Acquire) == link
                    && e.chat == chat
                    && e.author == author
                    && e.live_epoch == epoch
            }) {
                *entry.replay.lock_or_recover() = (method.to_owned(), params.clone());
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
                    live_epoch: epoch,
                    leave,
                    replay: Mutex::new((method.to_owned(), params.clone())),
                    active: AtomicBool::new(true),
                    sending: tokio::sync::Mutex::new(()),
                });
                entries.push(entry.clone());
                entry
            };
            (entry, replay)
        };
        for replay_entry in replay {
            if Arc::ptr_eq(&replay_entry, &entry) {
                continue;
            }
            let hub = hub.clone();
            drop(hub.scope.spawn_named("peer-presence-replay", async move {
                let _sending = replay_entry.sending.lock().await;
                if !replay_entry.active.load(Ordering::Acquire)
                    || !hub.presence.is_live()
                    || hub.presence.off_epoch() != replay_entry.live_epoch
                {
                    return;
                }
                let (method, mut params) = replay_entry.replay.lock_or_recover().clone();
                crate::hub::merge_mux_meta(
                    &mut params,
                    json!({"presenceClient": replay_entry.token, "presenceLeave": false}),
                );
                let _ = replay_entry.peer.request_on(&method, params, Some(link)).await;
            }));
        }
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
                crate::hub::merge_mux_meta(
                    &mut params,
                    json!({"presenceClient": entry.token, "presenceLeave": false}),
                );
                entry.peer.request_on(&method, params, Some(link)).await
            })
            .await
            .map_err(|_| RpcError::internal("presence forwarding task ended"))?
    }
}

/// Synthetic connection ids distinguish clients on the same authenticated peer link.
#[derive(Default)]
pub(super) struct Incoming(Mutex<HashMap<String, IncomingEntry>>);

struct IncomingEntry {
    chat: String,
    key: String,
}

impl Incoming {
    pub(super) fn key(&self, conn: &Conn, params: &Value) -> Result<String, RpcError> {
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
            return Ok(entry.key.clone());
        }
        if entries.len() >= MAX_INCOMING_TOKENS {
            return Err(RpcError::invalid_params("too many presence clients on peer link"));
        }
        let chat = params.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        let key = format!("{}:presence:{}", conn.id, token);
        entries.insert(token.to_owned(), IncomingEntry { chat, key: key.clone() });
        Ok(key)
    }

    pub(super) fn leave(&self, hub: &Hub, conn: &Conn, params: &Value) -> bool {
        if !view::a_link(conn)
            || params.pointer("/_meta/acpmux/presenceLeave") != Some(&json!(true))
        {
            return false;
        }
        if let Some(token) = params.pointer("/_meta/acpmux/presenceClient").and_then(Value::as_str)
            && let Some(entry) = self.0.lock_or_recover().remove(token)
        {
            hub.presence.close(&entry.key);
        }
        true
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
