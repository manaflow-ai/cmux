//! The routed `feed` namespace (`feed-client-v1`,
//! plans/cmux-next/feed-page.md section 2): the Feed page's and native
//! callers' `feed.*` ops on the daemon's feed client (feed_client.rs). Only
//! the app's own process reaches them (`origin_gate::app_process`). The
//! page router has checked the origin (a mutation is origin `user`, with
//! its idempotency key in `params`); the integration owner's writes and
//! the presence also need the verified app connection itself, since only
//! the app posts update cards and knows whether it is active. Ops that wait
//! (an intent's settle line, `gh`, acpmux) answer from their own thread.

use std::sync::{Arc, Weak};
#[cfg(unix)]
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use cmux_feed_core::client::github::{MAX_INTERVAL_S, MIN_INTERVAL_S};
use cmux_feed_core::client::{FeedItem, Reject, ViewRequest};
use serde_json::{Value, json};

use super::Mux;
use crate::feed_client::{
    FeedClient, FeedDeps, FeedError, FeedEvent, GitHubConfig, Mailbox, ProcessGh,
};
use crate::request_origin::RequestOrigin;
use crate::resource::ResourceError;

/// A routed op's answer: now, or from a thread of its own.
pub(super) enum Answer {
    Now(Result<Value, ResourceError>),
    Later(Box<dyn FnOnce() -> Result<Value, ResourceError> + Send>),
}

/// The most ids one `feed.item.get` reads.
const MAX_IDS: usize = 500;
/// The longest Reports reply (it goes to acpmux on stdin).
const MAX_REPLY_BYTES: usize = 64 * 1024;

fn invalid(field: &str, reason: &str) -> ResourceError {
    ResourceError::validation_invalid(Some(field), reason)
}

/// `origin.forbidden` with the connection's derived origin (the catalog's required `derived`).
fn forbidden(derived: RequestOrigin, message: &str, reason: &str) -> ResourceError {
    crate::request_origin::forbidden(
        message,
        json!({"derived": derived.wire_name(), "reason": reason}),
    )
}

fn failure(derived: RequestOrigin, operation: &str, error: FeedError) -> ResourceError {
    match error {
        FeedError::Invalid(reason) => ResourceError::validation_invalid(Some("params"), reason),
        FeedError::Forbidden(reason) => forbidden(derived, reason, "app_connection_only"),
        FeedError::Unavailable(reason) => {
            ResourceError::operation_failed(operation, reason, json!({"code": "feed.unavailable"}))
        }
        FeedError::Rejected(reject) => {
            let extra = match &reject {
                Reject::Closed(item) => {
                    json!({"code": reject.code(), "details": {"item": item.to_value()}})
                }
                _ => json!({"code": reject.code()}),
            };
            ResourceError::operation_failed(operation, reject.message(), extra)
        }
    }
}

fn text<'a>(params: &'a Value, key: &str) -> Result<&'a str, ResourceError> {
    params.get(key).and_then(Value::as_str).ok_or_else(|| invalid(key, "must be a string"))
}

/// One routed `feed.*` request.
pub(super) fn routed(mux: &Arc<Mux>, client: u64, operation: &str, params: Value) -> Answer {
    let derived = super::origin_gate::derived_origin(mux, client);
    let feed = mux.feed_client().clone();
    let app = || {
        if matches!(
            super::origin_gate::connection_actor(mux, client),
            crate::Actor::Frontend { .. }
        ) {
            Ok(())
        } else {
            Err(failure(
                derived,
                operation,
                FeedError::Forbidden("this feed op needs the verified cmux app connection"),
            ))
        }
    };
    // Every feed op, reads too: only the app's own process (its main connection or its Feed
    // page relay) reads the person's feed; an agent or script on the socket is refused.
    if !super::origin_gate::app_process(mux, client) {
        return Answer::Now(Err(forbidden(
            derived,
            "the feed is read only by the cmux app",
            "app_process_only",
        )));
    }
    let op = operation.to_owned();
    let now = |result: Result<Value, ResourceError>| Answer::Now(result);
    match operation {
        "feed.view.read" => {
            let mut params = params;
            if let Some(object) = params.as_object_mut() {
                object.remove("idempotency_key");
            }
            now(serde_json::from_value::<ViewRequest>(params)
                .map_err(|error| invalid("params", &error.to_string()))
                .map(|request| feed.view(&request)))
        }
        "feed.item.get" => now((|| {
            let ids: Vec<String> = params
                .get("ids")
                .and_then(Value::as_array)
                .and_then(|ids| ids.iter().map(|id| id.as_str().map(str::to_owned)).collect())
                .ok_or_else(|| invalid("ids", "must be a list of item ids"))?;
            if ids.len() > MAX_IDS {
                return Err(invalid("ids", "takes at most 500 ids"));
            }
            let confirmed = params.get("confirmed").and_then(Value::as_bool).unwrap_or(false);
            Ok(json!({"items": feed.items(&ids, confirmed)}))
        })()),
        "feed.items.list" => now((|| {
            let state = params.get("state").and_then(Value::as_str);
            if state.is_some_and(|state| state != "open" && state != "closed") {
                return Err(invalid("state", "must be open or closed"));
            }
            let home = params.get("home").and_then(Value::as_str);
            if home.is_some_and(|home| home != "cloud" && home != "local") {
                return Err(invalid("home", "must be cloud or local"));
            }
            let confirmed = params.get("confirmed").and_then(Value::as_bool).unwrap_or(false);
            Ok(json!({"items": feed.list(state, home, confirmed)}))
        })()),
        "feed.intent" => {
            let key = match text(&params, "idempotency_key") {
                Ok(key) => key.to_owned(),
                Err(error) => return now(Err(error)),
            };
            match feed.intent(&key, &params) {
                Err(error) => now(Err(failure(derived, operation, error))),
                Ok(reply) => Answer::Later(Box::new(move || match reply.wait() {
                    Some(Ok(())) => Ok(json!({"settled": true})),
                    Some(Err(reject)) => Err(failure(derived, &op, FeedError::Rejected(reject))),
                    // Still pending and shown; its settle line ends it.
                    None => Ok(json!({"settled": false})),
                })),
            }
        }
        "feed.post" => now(app().and_then(|()| {
            let item = params.get("item").ok_or_else(|| invalid("item", "is required"))?;
            let item =
                FeedItem::from_value(item).ok_or_else(|| invalid("item", "is not a feed item"))?;
            let posted = feed.post(item);
            Ok(json!({"id": posted.id, "deduped": posted.deduped}))
        })),
        "feed.withdraw" => now(app().and_then(|()| {
            let key = text(&params, "dedupe_key")?;
            Ok(json!({"cancelled": feed.withdraw(key)}))
        })),
        "feed.github.configure" => now(app().and_then(|()| {
            let enabled = params
                .get("enabled")
                .and_then(Value::as_bool)
                .ok_or_else(|| invalid("enabled", "must be a boolean"))?;
            let interval_s = params
                .get("interval_s")
                .and_then(Value::as_u64)
                .unwrap_or(cmux_feed_core::client::github::DEFAULT_INTERVAL_S)
                .clamp(MIN_INTERVAL_S, MAX_INTERVAL_S);
            let config = feed.configure_github(GitHubConfig { enabled, interval_s });
            Ok(json!({"enabled": config.enabled, "interval_s": config.interval_s}))
        })),
        "feed.github.refresh" => now(Ok(json!({"enabled": feed.refresh_github()}))),
        "feed.github.find_work" => Answer::Later(Box::new(move || {
            feed.find_work().map_err(|error| failure(derived, &op, error))
        })),
        "feed.reports.read" => now(Ok(feed.reports())),
        "feed.reports.reply" => {
            let fields = (|| {
                // `to`, not `session`: the page router takes `session` as the host selector.
                let session = text(&params, "to")?.to_owned();
                let body = text(&params, "text")?.to_owned();
                if body.trim().is_empty() || body.len() > MAX_REPLY_BYTES {
                    return Err(invalid("text", "takes 1 to 65536 bytes"));
                }
                let prompt_id = match params.get("prompt_id").and_then(Value::as_str) {
                    Some(id) => id.to_owned(),
                    None => text(&params, "idempotency_key")?.to_owned(),
                };
                Ok((session, body, prompt_id))
            })();
            match fields {
                Err(error) => now(Err(error)),
                Ok((session, body, prompt_id)) => Answer::Later(Box::new(move || {
                    Ok(json!({"sent": feed.reply(&session, &body, &prompt_id)}))
                })),
            }
        }
        "feed.presence.set" => now(app().and_then(|()| {
            let active = params
                .get("active")
                .and_then(Value::as_bool)
                .ok_or_else(|| invalid("active", "must be a boolean"))?;
            feed.set_presence(client, active);
            Ok(json!({"active": active}))
        })),
        _ => now(Err(ResourceError::operation_failed(
            operation,
            "the feed namespace has no such op",
            json!({"code": "feed.unknown_op"}),
        ))),
    }
}

/// The acpmux mailbox over this machine's acpmux socket; one link, opened
/// again after a failure.
struct AcpmuxMailbox {
    #[cfg_attr(not(unix), allow(dead_code))]
    mux: Weak<Mux>,
    #[cfg(unix)]
    link: Mutex<Option<Arc<super::agent_session_attach::agent_session_link::AcpmuxLink>>>,
}

impl Mailbox for AcpmuxMailbox {
    #[cfg(unix)]
    fn available(&self) -> bool {
        self.mux.upgrade().is_some_and(|mux| mux.control_clients.agent_sessions.socket().is_some())
    }

    #[cfg(not(unix))]
    fn available(&self) -> bool {
        false
    }

    #[cfg(unix)]
    fn wait(
        &self,
        recipient: &str,
        after: u64,
        limit: usize,
        timeout: Duration,
    ) -> Result<Value, String> {
        use super::agent_session_attach::agent_session_link::AcpmuxLink;
        let link = {
            let mut held = self.link.lock().unwrap_or_else(PoisonError::into_inner);
            match held.as_ref() {
                Some(link) => Arc::clone(link),
                None => {
                    let mux = self.mux.upgrade().ok_or("the daemon is gone")?;
                    let socket = mux
                        .control_clients
                        .agent_sessions
                        .socket()
                        .ok_or("acpmux is not running")?;
                    let link =
                        AcpmuxLink::connect(&socket, |_| {}).map_err(|error| error.to_string())?;
                    *held = Some(Arc::clone(&link));
                    link
                }
            }
        };
        let params = json!({
            "recipient": recipient,
            "after": after,
            "limit": limit,
            "timeoutMs": u64::try_from(timeout.as_millis()).unwrap_or(30_000),
        });
        link.call("_acpmux/mail/wait", params, timeout + Duration::from_secs(5)).map_err(|error| {
            link.close();
            *self.link.lock().unwrap_or_else(PoisonError::into_inner) = None;
            format!("{error:?}")
        })
    }

    #[cfg(not(unix))]
    fn wait(&self, _: &str, _: u64, _: usize, _: Duration) -> Result<Value, String> {
        Err("acpmux is unix-only".to_owned())
    }
}

impl Mux {
    /// The daemon's feed client, made on first use with the installed cloud
    /// link (none: local items only).
    pub(crate) fn feed_client(self: &Arc<Self>) -> &FeedClient {
        self.cloud_services().feed.get_or_init(|| {
            let sink_mux = Arc::downgrade(self);
            let place_mux = Arc::downgrade(self);
            let feed = FeedClient::new(FeedDeps {
                cloud: self.cloud_conversations().cloned(),
                gh: Arc::new(ProcessGh),
                mailbox: Arc::new(AcpmuxMailbox {
                    mux: Arc::downgrade(self),
                    #[cfg(unix)]
                    link: Mutex::new(None),
                }),
                sink: Arc::new(move |event| {
                    if let Some(mux) = sink_mux.upgrade() {
                        mux.emit(match event {
                            FeedEvent::View { revision, changed } => {
                                crate::mux::MuxEvent::FeedViewChanged {
                                    revision,
                                    changed: changed.into(),
                                }
                            }
                            FeedEvent::Reports { revision } => {
                                crate::mux::MuxEvent::FeedReportsChanged { revision }
                            }
                        });
                    }
                }),
                now_ms: Arc::new(|| {
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
                }),
                place: Arc::new(move || match place_mux.upgrade() {
                    Some(mux) => mux.feed_places(),
                    None => Box::new(|_| None),
                }),
            });
            feed.set_reply_sender(self.cloud_services().feed_reply.get().cloned());
            feed
        })
    }

    /// Installs how `feed.reports.reply` reaches acpmux (the binary that
    /// embeds acpmux does this at startup).
    pub fn set_feed_reply_sender(&self, sender: crate::feed_client::ReplySender) {
        let _ = self.cloud_services().feed_reply.set(Arc::clone(&sender));
        if let Some(feed) = self.cloud_services().feed.get() {
            feed.set_reply_sender(Some(sender));
        }
    }

    /// The app set or cleared the cloud lease: the feed client forgets
    /// another person's account at once and its socket stops waiting.
    pub(crate) fn feed_lease_changed(&self) {
        if let Some(feed) = self.cloud_services().feed.get() {
            feed.lease_changed();
        }
    }

    /// A control connection closed: the feed presence it held ends (a
    /// crashed app no longer counts as active for the person's pushes).
    pub(crate) fn feed_connection_closed(&self, client: u64) {
        if let Some(feed) = self.cloud_services().feed.get() {
            feed.connection_closed(client);
        }
    }

    /// Stops the feed client's threads (daemon shutdown).
    pub(crate) fn shutdown_feed_client(&self) {
        if let Some(feed) = self.cloud_services().feed.get() {
            feed.shutdown();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::SurfaceOptions;
    use crate::server::origin_gate::{
        app_process, set_page_for_test, set_peer_key_for_test, set_role_for_test,
        set_verified_app_for_test,
    };
    use crate::server::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink};

    use super::Mux;

    fn connection(mux: &Arc<Mux>, transport: ClientTransport, peer: &str) -> u64 {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound, control: None });
        let client = mux.control_clients.register(transport, writer);
        set_peer_key_for_test(mux, client, peer);
        client
    }

    /// Review F1 on #37377: an agent or script on the socket reads no feed; the app's verified
    /// main connection and a page relay of the same process do.
    #[test]
    fn only_the_apps_own_process_reads_the_feed() {
        let mux = Mux::new_for_test("feed-app-process", SurfaceOptions::default());
        let script = connection(&mux, ClientTransport::Unix, "pid:2");
        assert!(!app_process(&mux, script), "a plain local connection");
        let relay = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, relay, "page_relay");
        assert!(!app_process(&mux, relay), "a page relay with no verified app in its process");
        let app = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, app, "main");
        assert!(!app_process(&mux, app), "a main connection that did not prove itself");
        set_verified_app_for_test(&mux, app, true);
        assert!(app_process(&mux, app), "the verified app");
        assert!(app_process(&mux, relay), "the app's own page relay");
        let other_relay = connection(&mux, ClientTransport::Unix, "pid:2");
        set_role_for_test(&mux, other_relay, "page_relay");
        assert!(!app_process(&mux, other_relay), "a page relay of another process");
        let agent = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, agent, "main");
        set_verified_app_for_test(&mux, agent, true);
        mux.bind_conversation_principal(agent, "agent:test".to_string()).unwrap();
        assert!(!app_process(&mux, agent), "a connection bound to an agent");
        let socket = connection(&mux, ClientTransport::WebSocket, "pid:1");
        set_role_for_test(&mux, socket, "main");
        set_verified_app_for_test(&mux, socket, true);
        assert!(!app_process(&mux, socket), "not the local socket");
    }

    /// A reply names its sending session in `to`, which the page router passes through (it takes
    /// `session` as the host's selector), next to the page's own `session: "current"`.
    #[test]
    fn a_report_reply_reaches_the_feed_through_the_page_router() {
        let mux = Mux::new_for_test("feed-reply-route", SurfaceOptions::default());
        let app = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, app, "main");
        set_verified_app_for_test(&mux, app, true);
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let request = serde_json::json!({"protocol": "cmux.protocol/2", "type": "request",
            "id": "r1", "operation": "feed.reports.reply", "idempotency_key": "p1",
            "params": {"session": "current", "to": "mbp:claude-api-server", "text": "Go ahead"}});
        let (done, wait) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let handled =
                crate::server::page_router::try_handle(&mux, app, &request.to_string(), &writer);
            let _ = done.send(handled);
        });
        assert_eq!(
            wait.recv_timeout(std::time::Duration::from_secs(10)).expect("answered in time"),
            Some(true)
        );
        let reply = || outbound.try_pop();
        let mut text = reply();
        for _ in 0..200 {
            if text.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            text = reply();
        }
        let reply: serde_json::Value = serde_json::from_str(&text.expect("a reply")).unwrap();
        // No reply sender is installed in a test daemon: routed, validated, not sent.
        assert!(reply["error"].is_null(), "{reply}");
        assert_eq!(reply["result"]["sent"], false, "{reply}");
    }

    /// The relay path end to end (page_router::try_handle): the app's own Feed page relay reads
    /// the view, a relay of another process gets the refusal, and neither waits.
    #[test]
    fn the_apps_feed_relay_reads_and_another_relay_is_refused() {
        let mux = Mux::new_for_test("feed-relay-gate", SurfaceOptions::default());
        let app = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, app, "main");
        set_verified_app_for_test(&mux, app, true);
        let read = |client: u64| {
            let outbound = Arc::new(BoundedOutbound::default());
            let writer =
                MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
            let request = serde_json::json!({"protocol": "cmux.protocol/2", "type": "request",
                "id": "r1", "operation": "feed.view.read", "params": {"layout": "list"}});
            let (done, wait) = std::sync::mpsc::channel();
            let mux = mux.clone();
            std::thread::spawn(move || {
                let handled = crate::server::page_router::try_handle(
                    &mux,
                    client,
                    &request.to_string(),
                    &writer,
                );
                let _ = done.send(handled);
            });
            assert_eq!(
                wait.recv_timeout(std::time::Duration::from_secs(10)).expect("answered in time"),
                Some(true)
            );
            let reply: serde_json::Value =
                serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
            reply
        };
        let own = connection(&mux, ClientTransport::Unix, "pid:1");
        set_role_for_test(&mux, own, "page_relay");
        set_page_for_test(&mux, own, "feed");
        let reply = read(own);
        assert!(reply["error"].is_null(), "{reply}");
        let other = connection(&mux, ClientTransport::Unix, "pid:2");
        set_role_for_test(&mux, other, "page_relay");
        set_page_for_test(&mux, other, "feed");
        let reply = read(other);
        assert_eq!(reply["error"]["details"]["reason"], "app_process_only", "{reply}");
    }
}
