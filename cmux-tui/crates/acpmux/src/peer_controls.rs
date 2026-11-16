//! Receiver of the authenticated controls sideband. One worker per link walks its pages,
//! commits them, then sleeps until an explicit resync. The legacy watch remains active.
use super::*;
use crate::server::controls::{FEATURE, METHOD, PAGE};
use tokio::sync::watch;

type Key = (String, String);
pub(super) struct Open {
    link: u64,
    stream: Option<String>,
    ready_request: Option<String>,
    changed: watch::Sender<u64>,
    known: HashSet<Key>,
}

impl Peer {
    pub(super) fn start_controls(self: &Arc<Self>, link: u64) {
        if !self.controls_enabled()
            || !self.lists(FEATURE)
            || self.served_as().as_deref() != Some("peer")
        {
            return;
        }
        let (changed, mut resync) = watch::channel(0);
        *self.controls.lock_or_recover() =
            Some(Open { link, stream: None, ready_request: None, changed, known: HashSet::new() });
        let me = self.clone();
        self.scope.spawn_named("peer-controls", async move {
            loop {
                let generation = *resync.borrow_and_update();
                let result = tokio::time::timeout(me.timings.request, me.controls_snapshot(link)).await
                    .unwrap_or_else(|_| Err(RpcError::internal("controls snapshot deadline expired")));
                if me.link_epoch() != link || !me.open.load(Ordering::SeqCst) { return; }
                if let Err(error) = result {
                    if error.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
                        != Some("controls.resync") {
                        tracing::warn!(peer = %me.name, error = %error.message, "controls ended; the legacy watch remains active");
                        return;
                    }
                    // A peer repeatedly overflowing cannot make a busy reconnect loop.
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_millis(100)) => {},
                        changed = resync.changed() => if changed.is_err() { return; },
                    }
                    continue;
                }
                if *resync.borrow() != generation { continue; }
                if resync.changed().await.is_err() { return; }
            }
        });
    }

    pub(super) fn stop_controls(&self, link: u64) {
        let mut state = self.controls.lock_or_recover();
        if state.as_ref().is_some_and(|o| o.link == link) {
            state.take();
        }
    }

    async fn controls_snapshot(&self, link: u64) -> Result<(), RpcError> {
        let old = self
            .controls
            .lock_or_recover()
            .as_ref()
            .filter(|o| o.link == link)
            .map(|o| o.known.clone())
            .ok_or_else(crate::server::controls::resync_error)?;
        let mut seen = HashSet::new();
        let mut page =
            self.link_request_on(METHOD, json!({"kinds": ["asks", "ready"]}), Some(link)).await?;
        let stream = page
            .get("stream")
            .and_then(Value::as_str)
            .filter(|s| s.len() <= 64)
            .ok_or_else(crate::server::controls::resync_error)?
            .to_owned();
        {
            let mut state = self.controls.lock_or_recover();
            let open = state
                .as_mut()
                .filter(|o| o.link == link)
                .ok_or_else(crate::server::controls::resync_error)?;
            open.stream = Some(stream.clone());
        }
        let mut expected = 0;
        loop {
            if page.to_string().len() > PAGE
                || page["stream"] != stream
                || page["phase"] != "snapshot"
                || page["page"].as_u64() != Some(expected)
            {
                return Err(RpcError::invalid_params("invalid controls snapshot page"));
            }
            let entries = page
                .get("entries")
                .and_then(Value::as_array)
                .ok_or_else(|| RpcError::invalid_params("controls snapshot has no entries"))?;
            for entry in entries {
                if let Some(key) = ask_key(entry) {
                    seen.insert(key);
                }
                self.apply_control(link, entry).await?;
            }
            if page.get("next") == Some(&Value::Null) {
                break;
            }
            expected += 1;
            if page["next"].as_u64() != Some(expected) {
                return Err(RpcError::invalid_params("controls cursor did not advance"));
            }
            page = self
                .link_request_on(METHOD, json!({"stream": stream, "page": expected}), Some(link))
                .await?;
        }
        // Absence from an authoritative *ask* snapshot retires an old ask only; no row/cache
        // membership is changed. The existing hub checks the owner's membership and run.
        for (session, permission) in old.difference(&seen) {
            self.apply_control(
                link,
                &json!({"kind": "asks", "key": [session, permission], "value": null}),
            )
            .await?;
        }
        let ready = self
            .link_request_on(METHOD, json!({"stream": stream, "live": true}), Some(link))
            .await?;
        if ready["stream"] != stream || ready["phase"] != "live" {
            return Err(crate::server::controls::resync_error());
        }
        Ok(())
    }

    /// Called before sending a live request, so a response opens GitHub in the reader before
    /// the next frame can ask for it. An old link's answer never opens the current link.
    pub(super) fn controls_request(&self, link: u64, key: &str) {
        if let Some(open) = self.controls.lock_or_recover().as_mut().filter(|o| o.link == link) {
            open.ready_request = Some(key.to_owned());
        }
    }

    pub(super) fn controls_reply(&self, link: u64, key: &str, reply: &Result<Value, RpcError>) {
        let mut state = self.controls.lock_or_recover();
        let Some(open) = state.as_mut().filter(|o| o.link == link) else { return };
        if open.ready_request.as_deref() != Some(key) {
            return;
        }
        open.ready_request = None;
        if let Ok(reply) = reply
            && reply["phase"] == "live"
            && reply["ready"] == true
            && reply.get("stream").and_then(Value::as_str) == open.stream.as_deref()
            && self.link_epoch() == link
            && self.served_as().as_deref() == Some("peer")
        {
            self.github_link.store(link + 1, Ordering::SeqCst);
        }
    }

    pub(super) async fn controls_notice(&self, link: u64, value: Value) -> Result<(), RpcError> {
        if value.to_string().len() > crate::server::controls::BOUND {
            return Err(RpcError::invalid_params("control line exceeded its bound"));
        }
        {
            let mut state = self.controls.lock_or_recover();
            let Some(open) = state.as_mut().filter(|o| o.link == link) else { return Ok(()) };
            if value.get("stream").and_then(Value::as_str) != open.stream.as_deref() {
                return Ok(());
            }
            if value["phase"] == "resync" {
                open.changed.send_modify(|n| *n += 1);
            } else if value["phase"] != "change" {
                return Err(RpcError::invalid_params("unknown controls phase"));
            }
        }
        if value["phase"] == "resync" {
            return self
                .control_notification(
                    link,
                    "_acpmux/lagged",
                    json!({"origin": self.name, "reason": "controls.resync"}),
                )
                .await;
        }
        self.apply_control(link, &value["entry"]).await
    }

    async fn apply_control(&self, link: u64, entry: &Value) -> Result<(), RpcError> {
        if entry["kind"] == "ready" {
            return Ok(());
        }
        let (session, permission) =
            ask_key(entry).ok_or_else(|| RpcError::invalid_params("invalid controls ask key"))?;
        let value = &entry["value"];
        if !value.is_null()
            && (value["sessionId"] != session
                || value["permissionId"] != permission
                || value.get("personInstance").and_then(Value::as_str)
                    != self.person_instance().as_deref()
                || value.get("decisionNonce").and_then(Value::as_str).is_none_or(str::is_empty))
        {
            return Err(RpcError::invalid_params("control ask does not belong to this owner run"));
        }
        {
            let mut state = self.controls.lock_or_recover();
            let open = state
                .as_mut()
                .filter(|o| o.link == link)
                .ok_or_else(crate::server::controls::resync_error)?;
            if value.is_null() {
                open.known.remove(&(session.clone(), permission.clone()));
            } else {
                open.known.insert((session.clone(), permission.clone()));
            }
        }
        if value.is_null() {
            self.control_notification(
                link,
                method::MUX_EVENT,
                json!({"sessionId": session,
                "kind": "permission_withdrawn", "dir": "mux", "msg": {"permissionId": permission}}),
            )
            .await
        } else {
            self.control_notification(link, method::MUX_PERMISSION_PENDING, value.clone()).await
        }
    }

    async fn control_notification(
        &self,
        link: u64,
        method: &str,
        params: Value,
    ) -> Result<(), RpcError> {
        if self.link_epoch() != link {
            return Err(self.unreachable_error());
        }
        self.notices
            .send((
                self.name.clone(),
                self.generation,
                PeerNotice::Notification { method: method.to_owned(), params, link },
            ))
            .await
            .map_err(|_| self.unreachable_error())
    }
}

fn ask_key(entry: &Value) -> Option<Key> {
    if entry["kind"] != "asks" {
        return None;
    }
    let key = entry.get("key")?.as_array()?;
    if key.len() != 2 {
        return None;
    }
    let session = key[0].as_str()?.to_owned();
    let permission = key[1].as_str()?.to_owned();
    if session.len() > 1024 || permission.len() > 1024 {
        return None;
    }
    Some((session, permission))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::{
        WebSocketStream,
        tungstenite::{Message as Frame, protocol::Role},
    };

    #[tokio::test]
    async fn controls_resync_reopens_snapshot_and_retires_only_ask_keys_with_watch_kept() {
        let (tx, mut notices) = mpsc::channel(64);
        let peer = Peer::new("owner", "ws://127.0.0.1:9", None, None, tx);
        let links = Arc::new(crate::link_v2::Shared::default());
        let (index, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
        links.install(Arc::new(acpmux_core::life::V2::with_surfaces(
            index,
            writer,
            ["list", "peers"].into_iter().map(str::to_owned).collect(),
        )));
        peer.set_mirror(links);
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client =
            WebSocketStream::from_raw_socket(ours, Role::Client, Some(crate::server::ws_config()))
                .await;
        let mut server = WebSocketStream::from_raw_socket(
            theirs,
            Role::Server,
            Some(crate::server::ws_config()),
        )
        .await;
        let watches = Arc::new(AtomicU64::new(0));
        let opened = Arc::new(AtomicU64::new(0));
        let watch_count = watches.clone();
        let open_count = opened.clone();
        let fake = tokio::spawn(async move {
            while let Some(Ok(Frame::Text(text))) = server.next().await {
                let request: Value = serde_json::from_str(&text).unwrap();
                let Some(id) = request.get("id") else { continue };
                let method = request["method"].as_str().unwrap_or_default();
                let result = match method {
                    method::INITIALIZE => json!({"_meta": {"acpmux": {
                        "origin": "peer", "personInstance": "owner-run", "features": [FEATURE]}}}),
                    method::MUX_WATCH => {
                        watch_count.fetch_add(1, Ordering::SeqCst);
                        json!({"sessions": []})
                    }
                    METHOD if request["params"]["kinds"].is_array() => {
                        let n = open_count.fetch_add(1, Ordering::SeqCst) + 1;
                        let entries = if n == 1 {
                            vec![json!({"kind": "asks", "key": ["s", "a"],
                            "value": {"sessionId": "s", "permissionId": "a", "personInstance": "owner-run",
                                "decisionNonce": "nonce", "label": "A", "handle": "worker", "request": {}}})]
                        } else {
                            vec![]
                        };
                        json!({"stream": n.to_string(), "phase": "snapshot", "page": 0, "next": null, "entries": entries})
                    }
                    METHOD => {
                        json!({"stream": request["params"]["stream"], "phase": "live", "ready": true})
                    }
                    _ => json!({}),
                };
                server
                    .send(Frame::Text(Message::ok(id.clone(), result).to_line().into()))
                    .await
                    .unwrap();
                if method == METHOD
                    && request["params"]["live"] == true
                    && open_count.load(Ordering::SeqCst) == 1
                {
                    server.send(Frame::Text(Message::notification(crate::server::controls::NOTICE,
                        json!({"stream": "1", "phase": "resync", "origin": "local", "reason": "overflow"})).to_line().into())).await.unwrap();
                }
            }
        });
        let mut output = peer.out_rx.lock().await.take().unwrap();
        let serving_peer = peer.clone();
        let serving = tokio::spawn(async move { serving_peer.serve(client, &mut output).await });
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut pending = false;
            let mut lagged = false;
            while let Some((_, _, notice)) = notices.recv().await {
                if let PeerNotice::Notification { method: m, params, .. } = notice {
                    if m == method::MUX_PERMISSION_PENDING {
                        pending = true;
                        assert_eq!(params["decisionNonce"], "nonce");
                    }
                    if m == "_acpmux/lagged" {
                        lagged = true;
                    }
                    if m == method::MUX_EVENT && params["kind"] == "permission_withdrawn" {
                        assert!(pending && lagged);
                        assert_eq!(params["sessionId"], "s");
                        break;
                    }
                }
            }
        })
        .await
        .expect("resync reopens and retires the old ask");
        assert_eq!(watches.load(Ordering::SeqCst), 1, "the existing watch stays active");
        assert_eq!(opened.load(Ordering::SeqCst), 2);
        serving.abort();
        fake.abort();
        peer.stop_controls(peer.link_epoch());
    }

    #[test]
    fn controls_keys_are_typed_and_bounded() {
        assert!(ask_key(&json!({"kind": "asks", "key": ["s", "a"]})).is_some());
        for entry in [
            json!({"kind": "asks", "key": ["s"]}),
            json!({"kind": "ready", "key": ["s", "a"]}),
            json!({"kind": "asks", "key": ["s".repeat(1025), "a"]}),
        ] {
            assert!(ask_key(&entry).is_none());
        }
    }
}
