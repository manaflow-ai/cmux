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
//! A connection follows at most [`MAX_PER_CONN`] chats; another opens with no live records.
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
/// The most chats one connection follows at once. The app follows the one chat it shows; a
/// connection past this opens a chat as it is, with no live records, so the hub's load stays
/// bounded by connections, not by chats.
const MAX_PER_CONN: usize = 8;
/// The records one read asks for. A page past the hub's 64 KiB halves its byte budget there.
const PAGE_LIMIT: u64 = 500;

/// Where a hub-only chat's records come from.
pub(crate) trait Feed: Send + Sync {
    /// The records of chat `id` on `host` after seq `after`: an `_acpmux/events` page
    /// (`events`, `hasMore`). Not named `next`: `home_writers_by_path_tests.rs` resolves a
    /// method by its name, and this one's return (read through the hub) would taint every
    /// iterator's `.next()` in the crate.
    fn page_after<'a>(
        &'a self,
        host: &'a str,
        id: &'a str,
        after: u64,
    ) -> BoxFuture<'a, Result<Value, RpcError>>;
}

/// [`Feed`] by asking the hub for the next page (`read.rs`).
pub(crate) struct ReadFeed(pub Arc<dyn MeshHub>);

impl Feed for ReadFeed {
    fn page_after<'a>(
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

/// One follower running: the nudge that wakes it, and what its client asked for the chat by.
struct Running {
    nudge: Arc<Notify>,
    /// The key the client opened the chat by (`HOST/ID`, `HOST/NAME` or the raw id), which its
    /// detach may name it by too.
    asked: String,
}

/// The followers running: connection id and the chat's raw id to the follower.
static RUNNING: LazyLock<StdMutex<HashMap<(String, String), Running>>> =
    LazyLock::new(Default::default);

/// One hub-only chat as a connection follows it.
#[derive(Clone, Debug)]
pub(crate) struct Chat {
    /// The machine it runs on.
    pub host: String,
    /// What the hub names it by there: its id (or whole name).
    pub remote: String,
    /// Its raw id there, as the start or attach answered it: the `sessionId` of what the client
    /// hears, which `deliver` qualifies as `HOST/ID` (`qualifiedSessionId`). Never `HOST/ID`
    /// itself, which it would qualify again (review F7 of #38377).
    pub key: String,
    /// What the client asked for it by, when not `key` (`HOST/ID`, `HOST/NAME`).
    pub asked: String,
}

/// Follow `chat` for `conn`, from after seq `after`: subscribes the connection to it as a remote
/// chat and starts the follower, or nudges the one running.
pub(crate) fn follow(hub: &Arc<Hub>, conn: &Arc<Conn>, chat: Chat, after: u64) {
    let Some(mesh) = hub.mesh.get() else { return };
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
        if let Some(follower) = running.get_mut(&id) {
            // The newest open's name for it is the one its detach names.
            follower.asked.clone_from(&chat.asked);
            follower.nudge.notify_one();
            return;
        }
        if running.keys().filter(|(conn_id, _)| *conn_id == conn.id).count() >= MAX_PER_CONN {
            tracing::info!(session = %chat.key, "not following a hub chat: this client follows {MAX_PER_CONN}");
            return;
        }
        let nudge = Arc::new(Notify::new());
        running.insert(id.clone(), Running { nudge: nudge.clone(), asked: chat.asked.clone() });
        nudge
    };
    let (owner, conn) = (hub.clone(), conn.clone());
    // The hub owns the follower: it ends with the chat's stream, or with the daemon.
    hub.scope.spawn_named("hub-chat-follow", async move {
        run(&owner, &conn, &chat, after, feed.as_ref(), &nudge).await;
        RUNNING.lock_or_recover().remove(&id);
    });
}

/// Tests only: the followers running for chat `id`, under any key that names it.
#[cfg(test)]
pub(crate) fn followers_of(id: &str) -> usize {
    let qualified = format!("/{id}");
    RUNNING.lock_or_recover().keys().filter(|(_, k)| k == id || k.ends_with(&qualified)).count()
}

/// The raw id of the chat `conn` follows that `key` names: the raw id itself, what the client
/// opened it by, or `HOST/ID`.
fn followed(
    running: &HashMap<(String, String), Running>,
    conn: &Conn,
    key: &str,
) -> Option<String> {
    if running.contains_key(&(conn.id.clone(), key.to_owned())) {
        return Some(key.to_owned());
    }
    let asked = running
        .iter()
        .find(|((conn_id, _), follower)| *conn_id == conn.id && follower.asked == key)
        .map(|((_, raw), _)| raw.clone());
    asked.or_else(|| {
        let (_, raw) = key.split_once('/')?;
        running.contains_key(&(conn.id.clone(), raw.to_owned())).then(|| raw.to_owned())
    })
}

/// Wake the follower of chat `key` (its raw id, or `HOST/ID`) for `conn` now: a prompt just went
/// there.
pub(crate) fn nudge(conn: &Conn, key: &str) {
    let running = RUNNING.lock_or_recover();
    if let Some(raw) = followed(&running, conn, key)
        && let Some(follower) = running.get(&(conn.id.clone(), raw))
    {
        follower.nudge.notify_one();
    }
}

/// Stop following chat `key` for `conn` (`_acpmux/detach`), by its raw id or by what the client
/// opened it by.
pub(crate) fn unfollow(conn: &Conn, key: &str) {
    let raw = followed(&RUNNING.lock_or_recover(), conn, key).unwrap_or_else(|| key.to_owned());
    let mut subs = conn.subs.lock_or_recover();
    if subs.get(&raw).is_some_and(|opts| opts.remote) {
        subs.remove(&raw);
    }
    drop(subs);
    nudge(conn, &raw);
}

async fn run(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    chat: &Chat,
    mut after: u64,
    feed: &dyn Feed,
    nudge: &Notify,
) {
    let Chat { host, remote, key, .. } = chat;
    let mut wait = FAST;
    let mut failures = 0;
    loop {
        if hub.is_stopping() || conn.sub_opts(key).is_none_or(|opts| !opts.remote) {
            return;
        }
        let mut more = false;
        match feed.page_after(host, remote, after).await {
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
                            row: Default::default(),
                            list_seq: 0,
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
