//! Agent chat notifications (cx-sg1qz). One watch of this machine's acpmux
//! (`_acpmux/watch`, then its `_acpmux/session_changed` pushes) turns what a
//! chat does into notifications on every agent tab bound to it:
//!
//! - its turn ended: "<chat> finished" with the reply's last line, or
//!   "<chat> failed" (level error) when the turn failed;
//! - it waits for the person (a permission or a question): "<chat> needs
//!   input" with what it asks, and again for each ask that comes while it
//!   already waits;
//! - its agent went away mid-turn: "<chat> stopped responding" (error).
//!
//! The app shows them like any tab notification (a banner unless that tab is
//! focused, the Dock badge, a click that opens the tab, the workspace mute).
//! An ended turn notifies unless a pane showed the chat as it ended (acpmux
//! `shown`, and `unread` once it ended unseen). When acpmux says a
//! pane showed the chat (`unread` turned false) or the wait ended, the daemon
//! reads the tab's notifications, so seeing or answering the chat anywhere
//! clears them. A reconnect compares acpmux's page with what the watch knew,
//! so it catches up both ways; after a daemon start, a chat that needs nobody
//! has its notifications read. Each notice has a key of the chat, the turn
//! (or the record it waits on) and the tab's durable content, so one that was
//! posted before, by this daemon or an earlier one, is not posted again.
//!
//! A chat muted from its tab's menu carries the acpmux session tag
//! `notifications: muted`, so every window and device honors it: it posts
//! nothing, and muting it reads what it had posted.
//!
//! Only this machine's chats notify: a session a peer reports (`peer`) is
//! not followed, so a peer cannot post on, or read, a local chat's tab.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{Mux, NotificationLevel, NotificationSource};
use crate::resource::ContentPublicId;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::{Actor, SurfaceId};

/// Sessions per page of the watch's list. 2786 sessions were 14.7 MB in
/// one reply on cosmic-gray (2026-10-27), near acpmux's largest message.
const PAGE_SESSIONS: u64 = 500;
/// How long a connection stays up after its list before the next reconnect
/// starts again from the shortest delay.
const STAYED_UP: Duration = Duration::from_secs(60);
/// The acpmux session tag that mutes a chat, and its value.
const MUTE_TAG: &str = "notifications";
const MUTED: &str = "muted";
/// Longest chat name in a title, in characters.
const MAX_NAME_CHARS: usize = 80;
/// Longest notification body, in characters.
const MAX_BODY_CHARS: usize = 200;

impl Mux {
    /// This machine's acpmux socket (`set_acpmux_socket`), a watch of its
    /// chats that posts their notifications for as long as the daemon runs,
    /// and the agent message pump (`agent_message_pump.rs`), which the watch
    /// wakes whenever it reaches acpmux.
    pub fn watch_agent_chats(self: &Arc<Self>, socket: Option<PathBuf>) {
        self.set_acpmux_socket(socket.clone());
        let Some(socket) = socket else { return };
        self.start_agent_message_pump();
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-agent-chat-notices".into())
            .spawn(move || watch(&mux, &socket));
        if spawned.is_err() {
            self.report_internal_diagnostic("agent chat notifications not started");
        }
    }

    /// The tabs that show `session`, each with its durable content id.
    fn agent_chat_tabs(&self, session: &str) -> Vec<(SurfaceId, String)> {
        let surfaces = {
            let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            state.surfaces.iter().map(|(id, surface)| (*id, surface.clone())).collect::<Vec<_>>()
        };
        surfaces
            .into_iter()
            .filter(|(_, surface)| {
                matches!(self.conversation_tab_of(surface),
                    Some(ConversationTabRecord::AgentSession { session: Some(bound), .. }) if bound == session)
            })
            .filter_map(|(id, surface)| {
                let identity = surface.resource_identity()?;
                let ContentPublicId::Browser(content) = &identity.content_id else { return None };
                Some((id, content.as_str().to_owned()))
            })
            .collect()
    }

    fn post_agent_chat_notice(&self, session: &str, notice: &Notice) {
        // One wait, one notice: a daemon restart mid-wait sees the wait again
        // under a newer sequence, and the tab still holds the first notice.
        // The question it asks tells it from a new wait.
        let unread = if notice.restated {
            self.notification_rows(usize::MAX).unwrap_or_default()
        } else {
            Vec::new()
        };
        for (surface, content) in self.agent_chat_tabs(session) {
            if unread.iter().any(|(row, acknowledged)| {
                !acknowledged
                    && row.surface == Some(surface)
                    && row.title == notice.title
                    && row.body == notice.body
            }) {
                continue;
            }
            // Hashed: an adopted session's id is the agent's own, of any length.
            let digest = Sha256::digest(format!("{session}\n{}\n{content}", notice.key));
            let key = format!("acpmux-{digest:x}");
            let posted = self.create_durable_notification(
                &Actor::Daemon,
                &key,
                notice.title.clone(),
                None,
                notice.body.clone(),
                notice.level,
                Some(surface),
                NotificationSource::Agent,
            );
            if posted.is_err() {
                self.report_internal_diagnostic("agent chat notification not posted");
            }
        }
    }

    fn read_agent_chat_notices(&self, session: &str) {
        for (surface, _) in self.agent_chat_tabs(session) {
            if self.acknowledge_tab_notifications(surface).is_err() {
                self.report_internal_diagnostic("agent chat notification not read");
            }
        }
    }
}

/// Connects whenever acpmux listens and follows it until the daemon ends.
fn watch(mux: &Weak<Mux>, socket: &Path) {
    let mut backoff = crate::backoff::Backoff::new(Duration::from_secs(1), Duration::from_secs(10));
    let mut chats = HashMap::new();
    loop {
        match mux.upgrade() {
            Some(live) if !live.shutting_down.load(std::sync::atomic::Ordering::Acquire) => {}
            _ => return,
        }
        let stream = UnixStream::connect(socket);
        if stream.is_ok()
            && let Some(live) = mux.upgrade()
        {
            // acpmux is back: what waited for it goes out now.
            live.wake_agent_message_pump();
        }
        if let Ok(stream) = stream
            && follow(mux, stream, &mut chats).is_ok()
        {
            backoff.reset();
        }
        std::thread::sleep(backoff.next_delay());
    }
}

/// One connection: the watch's list sets what each chat is doing, and every
/// push is a change that may notify. Ends with the connection: `Ok` only when
/// acpmux listed every session whole and the connection then stayed up
/// [`STAYED_UP`], so a cut or unreadable line, an error reply or a connection
/// that keeps ending at once spaces the reconnects out instead of resetting them.
fn follow(
    mux: &Weak<Mux>,
    stream: UnixStream,
    chats: &mut HashMap<String, Chat>,
) -> std::io::Result<()> {
    // What the watch knew before this connection: the list is a change from it.
    let mut unlisted = std::mem::take(chats);
    let listed = read_watch(mux, stream, chats, &mut unlisted);
    // Ended before the list did: what the watch knew of the chats nothing on
    // this connection reached stays for the next one to compare with.
    for (session, chat) in unlisted {
        chats.entry(session).or_insert(chat);
    }
    match listed? {
        Some(whole) if whole.elapsed() >= STAYED_UP => Ok(()),
        Some(_) => Err(std::io::Error::other("acpmux ended the watch right after its list")),
        None => Err(std::io::Error::other("acpmux ended the watch before its list")),
    }
}

/// Reads one connection to its end; when the watch's list came whole. The
/// list comes [`PAGE_SESSIONS`] at a time (the watch's first page, then
/// `_acpmux/sessions` from its cursor), so no reply nears acpmux's largest
/// message whatever the number of sessions. `unlisted` is what the watch knew
/// before this connection, less the chats a page or a push has reached.
///
/// acpmux sends pushes as soon as the watch is on, apart from the replies, so
/// a push may come before the page it is newer than: a chat a push reached
/// follows its pushes alone for the rest of the connection.
fn read_watch(
    mux: &Weak<Mux>,
    stream: UnixStream,
    chats: &mut HashMap<String, Chat>,
    unlisted: &mut HashMap<String, Chat>,
) -> std::io::Result<Option<Instant>> {
    let mut writer = stream.try_clone()?;
    let initialize = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1,
        "clientInfo": {"name": "cmux-tui-agent-chat-notices", "version": "1"},
        "clientCapabilities": {},
    }});
    let watch = json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch",
        "params": {"enabled": true, "limit": PAGE_SESSIONS}});
    writer.write_all(format!("{initialize}\n{watch}\n").as_bytes())?;
    let mut reader = BufReader::new(stream);
    // The reply that carries the next page; none once the list is whole.
    let mut page = Some(2_u64);
    let mut whole = None;
    let mut pushed = HashSet::new();
    loop {
        // A whole line however long: acpmux sends none past its largest message.
        let mut line = Vec::new();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(whole);
        }
        if line.last() != Some(&b'\n') {
            return Err(std::io::Error::other("acpmux cut a line short"));
        }
        let message = serde_json::from_slice::<Value>(&line)?;
        let Some(mux) = mux.upgrade() else { return Ok(None) };
        if page.is_some_and(|id| message["id"] == id) {
            let (Some(sessions), next) =
                (message["result"]["sessions"].as_array(), &message["result"]["nextCursor"])
            else {
                return Err(std::io::Error::other("acpmux did not list its sessions"));
            };
            for summary in sessions {
                let Some(next) = Chat::of(summary) else { continue };
                if pushed.contains(&next.session) {
                    continue;
                }
                // A chat an earlier page reached compares with that.
                let known = unlisted.remove(&next.session).or_else(|| chats.remove(&next.session));
                if known.is_none() && next.needs_nobody() {
                    // After a daemon start: what it posted before was seen or answered.
                    mux.read_agent_chat_notices(&next.session);
                }
                apply(&mux, known.as_ref(), next, chats);
            }
            page = match next {
                Value::String(cursor) => {
                    let id = page.unwrap_or(2) + 1;
                    let more = json!({"jsonrpc": "2.0", "id": id, "method": "_acpmux/sessions",
                        "params": {"limit": PAGE_SESSIONS, "cursor": cursor}});
                    writer.write_all(format!("{more}\n").as_bytes())?;
                    Some(id)
                }
                Value::Null => {
                    // The list is whole: a chat it left out is gone.
                    unlisted.clear();
                    whole = Some(Instant::now());
                    None
                }
                _ => return Err(std::io::Error::other("acpmux sent a cursor that is no cursor")),
            };
        } else if let Some(method @ ("_acpmux/session_changed" | "_acpmux/permission_pending")) =
            message["method"].as_str()
        {
            let params = &message["params"];
            if params["peer"].is_null()
                && let Some(session) = params["sessionId"].as_str()
            {
                // A push about a chat no page reached yet compares with what the watch knew.
                if let Some(known) = unlisted.remove(session) {
                    chats.insert(known.session.clone(), known);
                }
                if method == "_acpmux/session_changed" {
                    pushed.insert(session.to_owned());
                    // Its page will not count now: what it posted before a daemon start
                    // was seen or answered when the push finds it needing nobody.
                    if !chats.contains_key(session)
                        && Chat::of(&params["session"]).is_some_and(|chat| chat.needs_nobody())
                    {
                        mux.read_agent_chat_notices(session);
                    }
                }
            }
            if method == "_acpmux/session_changed" {
                changed(&mux, params, chats);
            } else {
                asked(&mux, params, chats);
            }
        }
    }
}

/// A new ask of a chat the watch follows: it comes right after the change that recorded it.
fn asked(mux: &Mux, ask: &Value, chats: &mut HashMap<String, Chat>) {
    // A peer's session is not this machine's chat.
    if !ask["peer"].is_null() {
        return;
    }
    let Some(chat) = ask["sessionId"].as_str().and_then(|session| chats.get_mut(session)) else {
        return;
    };
    if let Some(notice) = chat.asked(ask)
        && !chat.muted
    {
        mux.post_agent_chat_notice(&chat.session, &notice);
    }
}

fn changed(mux: &Mux, params: &Value, chats: &mut HashMap<String, Chat>) {
    // A peer's session is not this machine's chat.
    if !params["peer"].is_null() {
        return;
    }
    let Some(session) = params["sessionId"].as_str() else { return };
    if params["kind"] == "purged" {
        chats.remove(session);
        return;
    }
    let Some(next) = Chat::of(&params["session"]) else { return };
    let before = chats.remove(&next.session);
    apply(mux, before.as_ref(), next, chats);
}

/// What the chat's change from `before` reads and posts; then the watch knows `next`.
fn apply(mux: &Mux, before: Option<&Chat>, mut next: Chat, chats: &mut HashMap<String, Chat>) {
    next.notified_turn = before.and_then(|chat| chat.notified_turn.clone());
    next.keep_asks(before);
    let waited = before.is_some_and(|chat| chat.indicator == "input");
    let read = before.is_some_and(|chat| chat.unread) && !next.unread;
    let muted = next.muted && !before.is_some_and(|chat| chat.muted);
    if read || muted || (waited && next.indicator != "input") {
        mux.read_agent_chat_notices(&next.session);
    }
    // A muted chat's turns still count as notified, so unmuting posts none of them.
    let notices = next.notices(before);
    for notice in notices.iter().filter(|_| !next.muted) {
        mux.post_agent_chat_notice(&next.session, notice);
    }
    chats.insert(next.session.clone(), next);
}

/// What the watch knows of one chat.
#[derive(Clone, Debug)]
struct Chat {
    session: String,
    name: String,
    indicator: String,
    unread: bool,
    /// A pane shows the chat now.
    shown: bool,
    /// Muted from its tab's menu ([`MUTE_TAG`]).
    muted: bool,
    /// The last turn that ended: its id and status.
    last_turn: Option<(String, String)>,
    /// Work it started runs past its turn (a background subagent, a working sub-session;
    /// acpmux's `subagentsWorkingSince`): the task is not done yet.
    works_below: bool,
    /// The ended turn already notified (or passed over), so it notifies once.
    notified_turn: Option<String>,
    last_message: String,
    last_seq: u64,
    /// The asks of its current wait, by group (asks grouped on one card) or permission id.
    asks: HashSet<String>,
}

struct Notice {
    /// Unique per chat; the notification's idempotency key.
    key: String,
    title: String,
    body: String,
    level: NotificationLevel,
    /// Seen first since a daemon start: it may restate one posted before.
    restated: bool,
}

impl Chat {
    /// A summary of this machine's acpmux; nil for a peer's session.
    fn of(summary: &Value) -> Option<Self> {
        if !summary["peer"].is_null() {
            return None;
        }
        let session = summary["sessionId"].as_str()?.to_owned();
        let text = |key: &str| summary[key].as_str().filter(|text| !text.trim().is_empty());
        let name =
            text("title").or_else(|| text("name")).or_else(|| text("harness")).unwrap_or("Agent");
        let name = short(name, MAX_NAME_CHARS);
        let last_turn = summary["lastTurn"].as_object().map(|turn| {
            let id = turn.get("turnId").and_then(Value::as_str).map(str::to_owned);
            let ended = turn.get("endedAt").map(Value::to_string).unwrap_or_default();
            let status = turn.get("status").and_then(Value::as_str).unwrap_or_default();
            (id.unwrap_or(ended), status.to_owned())
        });
        Some(Self {
            session,
            name,
            indicator: summary["indicator"].as_str().unwrap_or_default().to_owned(),
            unread: summary["unread"].as_bool() == Some(true),
            shown: summary["shown"].as_bool() == Some(true),
            muted: summary["tags"][MUTE_TAG] == MUTED,
            last_turn,
            works_below: summary["subagentsWorkingSince"].is_u64(),
            notified_turn: None,
            last_message: summary["lastMessage"]["text"].as_str().unwrap_or_default().to_owned(),
            last_seq: summary["lastSeq"].as_u64().unwrap_or(0),
            asks: HashSet::new(),
        })
    }

    /// The asks of the wait it had before, while it still waits (`apply`).
    fn keep_asks(&mut self, before: Option<&Chat>) {
        if self.indicator == "input"
            && let Some(before) = before.filter(|chat| chat.indicator == "input")
        {
            self.asks.clone_from(&before.asks);
        }
    }

    /// A new ask acpmux says the chat waits on (`_acpmux/permission_pending`): "needs input"
    /// again when it comes while the chat already waits on another. The ask that starts the
    /// wait notifies through the wait itself (`notices`); asks grouped on one card count once;
    /// an ask an acpmux restart re-issues (`permission_reissued`, which names no turn) was told
    /// before.
    fn asked(&mut self, ask: &Value) -> Option<Notice> {
        if self.indicator != "input" || ask.get("turnId").is_none() {
            return None;
        }
        let key = ask["groupId"].as_str().or_else(|| ask["permissionId"].as_str())?;
        let first = self.asks.is_empty();
        if !self.asks.insert(key.to_owned()) || first {
            return None;
        }
        Some(Notice {
            key: format!("input-{}", ask["seq"].as_u64().unwrap_or(self.last_seq)),
            title: format!("{} needs input", self.name),
            body: short(&self.last_message, MAX_BODY_CHARS),
            level: NotificationLevel::Warning,
            restated: false,
        })
    }

    /// Nothing waits for the person: no unseen turn, no question, no lost agent.
    fn needs_nobody(&self) -> bool {
        !self.unread && self.indicator != "input" && self.indicator != "lost"
    }

    /// What this change says to the person, given what the chat did before.
    /// An ended turn notifies once, unless a pane showed the chat as it ended:
    /// when it ends while no pane shows the chat, or once acpmux marks the
    /// chat unread (a turn that failed before it started is never marked so).
    /// A turn that ends while work it started still runs waits: acpmux marks
    /// the chat unread when that work ends (manaflow-ai/cmux#25563).
    fn notices(&mut self, before: Option<&Chat>) -> Vec<Notice> {
        let mut notices = Vec::new();
        let name = &self.name;
        // The turn ended in this change (not one the watch saw ended before).
        let ended_now = |turn: &String| {
            before.is_some_and(|chat| chat.last_turn.as_ref().map(|(id, _)| id) != Some(turn))
        };
        if let Some((turn, status)) = &self.last_turn
            && !self.works_below
            && (self.unread || (!self.shown && ended_now(turn)))
            && self.notified_turn.as_ref() != Some(turn)
        {
            self.notified_turn = Some(turn.clone());
            match status.as_str() {
                "completed" => notices.push(Notice {
                    key: format!("done-{turn}"),
                    title: format!("{name} finished"),
                    body: short(&self.last_message, MAX_BODY_CHARS),
                    level: NotificationLevel::Info,
                    restated: false,
                }),
                "failed" => notices.push(Notice {
                    key: format!("failed-{turn}"),
                    title: format!("{name} failed"),
                    body: short(&self.last_message, MAX_BODY_CHARS),
                    level: NotificationLevel::Error,
                    restated: false,
                }),
                _ => {}
            }
        }
        let was = before.map_or("", |chat| chat.indicator.as_str());
        if self.indicator == "input" && was != "input" {
            notices.push(Notice {
                // The record it waits on: the same key while it still waits.
                key: format!("input-{}", self.last_seq),
                title: format!("{name} needs input"),
                body: short(&self.last_message, MAX_BODY_CHARS),
                level: NotificationLevel::Warning,
                restated: before.is_none(),
            });
        }
        if self.indicator == "lost" && was != "lost" {
            notices.push(Notice {
                key: format!("lost-{}", self.last_seq),
                title: format!("{name} stopped responding"),
                body: short(&self.last_message, MAX_BODY_CHARS),
                level: NotificationLevel::Error,
                restated: false,
            });
        }
        notices
    }
}

/// `text` cut to `max` characters.
fn short(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut cut = text.chars().take(max - 1).collect::<String>();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A chat as acpmux summarizes it at `seq`.
    fn chat(indicator: &str, seq: u64) -> Chat {
        Chat::of(&json!({
            "sessionId": "chat-1",
            "title": "Review",
            "indicator": indicator,
            "lastSeq": seq,
            "lastMessage": {"text": "Run npm test?"},
        }))
        .expect("a local chat")
    }

    /// The `_acpmux/permission_pending` a watcher gets for a new ask (a `permission_request`
    /// record: it names its turn and its group, null when none).
    fn ask(permission: &str, group: Option<&str>, seq: u64) -> Value {
        json!({"permissionId": permission, "groupId": group, "turnId": "turn-1", "seq": seq,
               "sessionId": "chat-1", "via": "watch", "request": {}})
    }

    /// The same ask re-issued by an acpmux that restarted (`permission_reissued`: no turn, no group).
    fn reissued(permission: &str, seq: u64) -> Value {
        json!({"permissionId": permission, "seq": seq, "sessionId": "chat-1", "via": "watch", "request": {}})
    }

    /// A chat whose turn `turn` ended, hidden, `unread`, with or without work below it.
    fn ended(turn: &str, unread: bool, works_below: bool) -> Chat {
        Chat::of(&json!({
            "sessionId": "chat-1",
            "title": "Review",
            "indicator": if works_below { "working" } else { "done" },
            "unread": unread,
            "lastSeq": 20,
            "lastTurn": {"turnId": turn, "status": "completed"},
            "subagentsWorkingSince": if works_below { json!(1_700_000_000_000_u64) } else { Value::Null },
        }))
        .expect("a local chat")
    }

    fn key(notice: Option<Notice>) -> Option<String> {
        notice.map(|notice| notice.key)
    }

    /// The watch's chat after a change from `before`, as `apply` keeps it.
    fn after(before: &Chat, indicator: &str, seq: u64) -> Chat {
        let mut next = chat(indicator, seq);
        next.keep_asks(Some(before));
        next
    }

    /// A fake acpmux on one end of a socket pair. It answers each list request
    /// (`_acpmux/watch`, then `_acpmux/sessions`) with the next of `replies`, written
    /// as is, and ends the connection after the last one, or when the client asks for
    /// nothing more. The thread returns the requests it read.
    fn fake_acpmux(replies: Vec<String>) -> (UnixStream, std::thread::JoinHandle<Vec<Value>>) {
        let (client, server) = UnixStream::pair().expect("a socket pair");
        server.set_read_timeout(Some(Duration::from_secs(5))).expect("a read timeout");
        let serve = std::thread::spawn(move || {
            let mut writer = server.try_clone().expect("a writer");
            let mut replies = replies.into_iter();
            let mut requests = Vec::new();
            for line in BufReader::new(server).lines() {
                let Ok(line) = line else { break };
                let request: Value = serde_json::from_str(&line).expect("a JSON request");
                let lists = ["_acpmux/watch", "_acpmux/sessions"]
                    .contains(&request["method"].as_str().unwrap_or_default());
                requests.push(request);
                if lists {
                    let Some(reply) = replies.next() else { break };
                    // The client may stop reading a reply it cannot use.
                    let _ = writer.write_all(reply.as_bytes());
                    if replies.as_slice().is_empty() {
                        break;
                    }
                }
            }
            requests
        });
        (client, serve)
    }

    /// One page of the session list as acpmux answers request `id`.
    fn list_reply(id: u64, sessions: &[Value], next: Option<&str>) -> String {
        let mut result = json!({"sessions": sessions});
        if let Some(next) = next {
            result["nextCursor"] = json!(next);
        }
        format!("{}\n", json!({"jsonrpc": "2.0", "id": id, "result": result}))
    }

    fn local(session: &str) -> Value {
        json!({"sessionId": session, "title": session, "indicator": "idle", "lastSeq": 1})
    }

    fn test_mux(name: &str) -> Arc<Mux> {
        Mux::new_for_test(name, crate::SurfaceOptions::default())
    }

    #[test]
    fn a_list_past_four_mib_is_read_whole_and_an_at_once_end_is_no_success() {
        // cosmic-gray (2026-10-27): 2786 sessions were one 14.7 MB line. A 4 MiB read
        // cut it, counted the cut as a success and reconnected every second.
        let filler = "x".repeat(4096);
        let mut sessions: Vec<Value> = (0..1500)
            .map(|n| json!({"sessionId": format!("peer-{n}"), "peer": "builder", "title": filler}))
            .collect();
        sessions.push(local("chat-1"));
        let reply = list_reply(2, &sessions, None);
        assert!(reply.len() > 4 << 20);
        let mux = test_mux("notices-long-list");
        let mut chats = HashMap::new();
        let (client, serve) = fake_acpmux(vec![reply]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
        serve.join().expect("the fake acpmux");
        assert!(chats.contains_key("chat-1"), "the whole list was read");
        assert!(followed.is_err(), "a connection that ends right after its list keeps the backoff");
    }

    #[test]
    fn a_line_cut_short_is_a_failure() {
        let mux = test_mux("notices-cut-line");
        let mut chats = HashMap::new();
        let (client, serve) =
            fake_acpmux(vec![r#"{"jsonrpc":"2.0","id":2,"result":{"sessions":["#.to_owned()]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
        serve.join().expect("the fake acpmux");
        assert!(followed.is_err());
    }

    #[test]
    fn the_list_comes_a_page_at_a_time() {
        let mux = test_mux("notices-pages");
        let mut chats = HashMap::new();
        let (client, serve) = fake_acpmux(vec![
            list_reply(2, &[local("chat-1")], Some("k5.1")),
            list_reply(3, &[local("chat-2")], None),
        ]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
        let requests = serve.join().expect("the fake acpmux");
        assert!(followed.is_err(), "it ended right after its list");
        assert_eq!(requests[1]["method"], "_acpmux/watch");
        assert_eq!(requests[1]["params"]["limit"], PAGE_SESSIONS);
        assert_eq!(requests[2]["method"], "_acpmux/sessions");
        assert_eq!(requests[2]["params"], json!({"limit": PAGE_SESSIONS, "cursor": "k5.1"}));
        let mut known: Vec<_> = chats.keys().cloned().collect();
        known.sort();
        assert_eq!(known, ["chat-1", "chat-2"]);
    }

    #[test]
    fn a_connection_that_ends_mid_list_keeps_what_the_watch_knew() {
        let mux = test_mux("notices-mid-list");
        let mut chats = HashMap::from([("chat-1".to_owned(), chat("idle", 3))]);
        let (client, serve) = fake_acpmux(vec![
            list_reply(2, &[local("chat-2")], Some("k5.1")),
            r#"{"jsonrpc":"2.0","id":3,"result":"#.to_owned(),
        ]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
        serve.join().expect("the fake acpmux");
        assert!(followed.is_err());
        assert!(chats.contains_key("chat-1"), "no page reached it: the next connection compares");
        assert!(chats.contains_key("chat-2"));
    }

    #[test]
    fn a_page_older_than_a_push_before_it_does_not_undo_the_push() {
        // acpmux turns the watch on, then reads its page: the push of a change made
        // in between can come first, and the page still shows the chat before it.
        let mux = test_mux("notices-push-first");
        let mut chats = HashMap::new();
        let waiting =
            json!({"sessionId": "chat-1", "title": "chat-1", "indicator": "input", "lastSeq": 5});
        let push = json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed",
            "params": {"sessionId": "chat-1", "kind": "updated", "session": waiting}});
        let mut stale = local("chat-1");
        stale["indicator"] = json!("working");
        let (client, serve) =
            fake_acpmux(vec![format!("{push}\n{}", list_reply(2, &[stale], None))]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
        serve.join().expect("the fake acpmux");
        assert!(followed.is_err());
        assert_eq!(chats["chat-1"].indicator, "input");
    }

    #[test]
    fn an_unreadable_line_or_cursor_is_a_failure() {
        for reply in [
            "not json\n".to_owned(),
            format!(
                "{}\n",
                json!({"jsonrpc": "2.0", "id": 2, "result": {"sessions": [], "nextCursor": 7}})
            ),
        ] {
            let mux = test_mux("notices-unreadable");
            let mut chats = HashMap::from([("chat-1".to_owned(), chat("idle", 3))]);
            let (client, serve) = fake_acpmux(vec![reply]);
            let followed = follow(&Arc::downgrade(&mux), client, &mut chats);
            serve.join().expect("the fake acpmux");
            assert!(followed.is_err());
            assert!(chats.contains_key("chat-1"), "an unfinished list drops no chat");
        }
    }

    #[test]
    fn a_turn_that_ends_while_its_subagents_run_finishes_when_they_end() {
        // manaflow-ai/cmux#25563: the parent's turn ended unseen, its background work runs on.
        let working = chat("working", 8);
        let mut waiting = ended("turn-1", false, true);
        waiting.notified_turn = working.notified_turn.clone();
        assert!(waiting.notices(Some(&working)).is_empty(), "not done while its subagents run");
        // The last of the work ends and acpmux marks the chat unread: now it finished.
        let mut done = ended("turn-1", true, false);
        done.notified_turn = waiting.notified_turn.clone();
        let keys: Vec<_> = done.notices(Some(&waiting)).into_iter().map(|n| n.key).collect();
        assert_eq!(keys, ["done-turn-1"]);
    }

    #[test]
    fn the_ask_that_starts_a_wait_notifies_through_the_wait_alone() {
        let working = chat("working", 8);
        let mut waiting = after(&working, "input", 10);
        assert_eq!(waiting.notices(Some(&working)).len(), 1);
        assert_eq!(key(waiting.asked(&ask("p1", None, 10))), None);
    }

    #[test]
    fn a_second_ask_while_the_chat_waits_notifies_again() {
        let mut waiting = after(&chat("working", 8), "input", 10);
        waiting.asked(&ask("p1", None, 10));
        let mut later = after(&waiting, "input", 12);
        assert_eq!(key(later.asked(&ask("p2", None, 12))), Some("input-12".into()));
        // The same ask heard again is not new.
        assert_eq!(key(later.asked(&ask("p2", None, 12))), None);
    }

    #[test]
    fn a_burst_grouped_on_one_card_notifies_once() {
        let mut waiting = after(&chat("working", 8), "input", 10);
        waiting.asked(&ask("p1", None, 10));
        assert_eq!(key(waiting.asked(&ask("p2", Some("g1"), 12))), Some("input-12".into()));
        assert_eq!(key(waiting.asked(&ask("p3", Some("g1"), 13))), None);
        assert_eq!(key(waiting.asked(&ask("p4", Some("g1"), 14))), None);
    }

    #[test]
    fn asks_an_acpmux_restart_reissues_post_nothing_new() {
        let mut waiting = after(&chat("idle", 8), "input", 10);
        assert_eq!(key(waiting.asked(&reissued("p1", 10))), None);
        assert_eq!(key(waiting.asked(&reissued("p2", 11))), None);
    }

    #[test]
    fn a_new_wait_starts_counting_again() {
        let mut waiting = after(&chat("working", 8), "input", 10);
        waiting.asked(&ask("p1", None, 10));
        waiting.asked(&ask("p2", None, 11));
        let answered = after(&waiting, "working", 12);
        let mut again = after(&answered, "input", 14);
        assert_eq!(key(again.asked(&ask("p3", None, 14))), None);
    }
}
