//! A hub-only chat's new records, live in the client that opened it. A chat on a machine only the
//! mesh hub reaches (`hub/mesh_book.rs`) has no peer link to stream it, so the connection that
//! started it (`mesh_start.rs`) or opened it (`mesh_read.rs` `forward`, an attach) follows it here:
//! each new record reaches that connection as a peer chat's does (`server::deliver`, with the
//! machine as its `peer`), so the app draws the reply as it draws any remote chat's.
//!
//! The records come from a [`Feed`]. Today that is [`ReadFeed`]: `_acpmux/events` after the last
//! seq, read through the hub (`read::read`). The live hub stream carrier takes its place by
//! implementing [`Feed`] (its `next` waits on the pushed records instead of asking again); the
//! connection and the app see the same notifications either way.
//!
//! Every follower stops: when its connection ends or detaches the chat, when the daemon stops,
//! when the chat is gone there, or after [`MAX_FAILURES`] reads in a row fail. One per connection
//! and chat; a second open of the same chat nudges the one running.

use super::*;
use crate::mesh::MeshHub;
use crate::store::EventRecord;
use futures::future::BoxFuture;
use std::sync::LazyLock;
use std::time::Duration;
use tokio::sync::Notify;

/// The wait between two reads while records come (a turn runs).
const FAST: Duration = Duration::from_millis(300);
/// The longest wait between two reads of a quiet chat.
const SLOW: Duration = Duration::from_secs(5);
/// Reads that fail in a row before the follower gives up (the machine left, the hub is down).
const MAX_FAILURES: u32 = 12;
/// The records one read asks for. A page past the hub's 64 KiB halves its byte budget there.
const PAGE_LIMIT: u64 = 500;

/// Where a hub-only chat's records come from.
pub(crate) trait Feed: Send + Sync {
    /// The records of chat `id` on `host` after seq `after`: an `_acpmux/events` page
    /// (`events`, `hasMore`).
    fn next<'a>(
        &'a self,
        host: &'a str,
        id: &'a str,
        after: u64,
    ) -> BoxFuture<'a, Result<Value, RpcError>>;
}

/// [`Feed`] by asking the hub for the next page (`read.rs`).
pub(crate) struct ReadFeed(pub Arc<dyn MeshHub>);

impl Feed for ReadFeed {
    fn next<'a>(
        &'a self,
        host: &'a str,
        id: &'a str,
        after: u64,
    ) -> BoxFuture<'a, Result<Value, RpcError>> {
        Box::pin(async move {
            let params = json!({"afterSeq": after, "limit": PAGE_LIMIT, "waitLogs": false});
            super::read::read(self.0.as_ref(), host, id, method::MUX_EVENTS, &params).await
        })
    }
}

/// The followers running: connection id and the chat's key to the nudge that wakes one.
static RUNNING: LazyLock<StdMutex<HashMap<(String, String), Arc<Notify>>>> =
    LazyLock::new(Default::default);

/// One hub-only chat as a connection follows it.
#[derive(Clone, Debug)]
pub(crate) struct Chat {
    /// The machine it runs on.
    pub host: String,
    /// What the hub names it by there: its id (or whole name).
    pub remote: String,
    /// What the client names it by (its bare id, or `HOST/ID`): the `sessionId` of what it hears.
    pub key: String,
}

/// Follow `chat` for `conn`, from after seq `after`: subscribes the connection to it as a remote
/// chat and starts the follower, or nudges the one running.
pub(crate) fn follow(hub: &Arc<Hub>, conn: &Arc<Conn>, chat: Chat, after: u64) {
    let Some(mesh) = hub.mesh.get().cloned() else { return };
    follow_with(hub, conn, chat, after, Arc::new(ReadFeed(mesh)));
}

/// [`follow`] from `feed`.
pub(crate) fn follow_with(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    chat: Chat,
    after: u64,
    feed: Arc<dyn Feed>,
) {
    super::super::view::subscribe_remote(hub, conn, &chat.key, None);
    let id = (conn.id.clone(), chat.key.clone());
    let nudge = {
        let mut running = RUNNING.lock_or_recover();
        if let Some(nudge) = running.get(&id) {
            nudge.notify_one();
            return;
        }
        let nudge = Arc::new(Notify::new());
        running.insert(id.clone(), nudge.clone());
        nudge
    };
    let (hub, conn) = (hub.clone(), conn.clone());
    tokio::spawn(async move {
        run(&hub, &conn, &chat, after, feed.as_ref(), &nudge).await;
        RUNNING.lock_or_recover().remove(&id);
    });
}

/// Wake the follower of chat `key` for `conn` now: a prompt just went there.
pub(crate) fn nudge(conn: &Conn, key: &str) {
    if let Some(nudge) = RUNNING.lock_or_recover().get(&(conn.id.clone(), key.to_owned())) {
        nudge.notify_one();
    }
}

/// Stop following chat `key` for `conn` (`_acpmux/detach`).
pub(crate) fn unfollow(conn: &Conn, key: &str) {
    let mut subs = conn.subs.lock_or_recover();
    if subs.get(key).is_some_and(|opts| opts.remote) {
        subs.remove(key);
    }
    drop(subs);
    nudge(conn, key);
}

async fn run(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    chat: &Chat,
    mut after: u64,
    feed: &dyn Feed,
    nudge: &Notify,
) {
    let Chat { host, remote, key } = chat;
    let mut wait = FAST;
    let mut failures = 0;
    loop {
        if hub.is_stopping() || conn.sub_opts(key).is_none_or(|opts| !opts.remote) {
            return;
        }
        let mut more = false;
        match feed.next(host, remote, after).await {
            Ok(page) => {
                failures = 0;
                let events = page.get("events").and_then(Value::as_array);
                let mut came = false;
                for event in events.into_iter().flatten() {
                    let Some(record) = record(event).filter(|r| r.seq > after) else { continue };
                    after = record.seq;
                    came = true;
                    super::super::deliver(
                        hub,
                        conn,
                        crate::hub::HubEvent {
                            session_id: key.clone(),
                            record: Arc::new(record),
                            remote: Some(crate::hub::RemoteRef {
                                peer: host.clone(),
                                summary: Value::Null,
                            }),
                            update_line: Default::default(),
                        },
                    );
                }
                more = came && page.get("hasMore").and_then(Value::as_bool) == Some(true);
                wait = if came { FAST } else { (wait * 2).min(SLOW) };
            }
            // The chat is gone there: nothing more comes.
            Err(e) if e.code == RpcError::not_found("").code => return,
            Err(e) => {
                failures += 1;
                if failures >= MAX_FAILURES {
                    tracing::warn!(%host, session = %remote, "stopped following a hub chat: {}", e.message);
                    return;
                }
                wait = SLOW;
            }
        }
        if more {
            continue;
        }
        tokio::select! {
            () = tokio::time::sleep(wait) => {}
            () = nudge.notified() => wait = FAST,
            () = conn.closed() => return,
        }
    }
}

/// An `_acpmux/events` value as the record it was.
fn record(event: &Value) -> Option<EventRecord> {
    Some(EventRecord {
        seq: event.get("seq")?.as_u64()?,
        at: event.get("at").and_then(Value::as_u64).unwrap_or_default(),
        dir: event.get("dir")?.as_str()?.to_owned(),
        kind: event.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned(),
        msg: event.get("msg").cloned().unwrap_or(Value::Null),
        host_seq: None,
    })
}
