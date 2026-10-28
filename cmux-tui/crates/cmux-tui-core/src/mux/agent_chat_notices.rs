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
//!
//! The same connection carries the daemon's Energy Saver to acpmux
//! (`acpmux_energy.rs`): its mode as the watch connects, then each edge.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::acpmux_energy::AcpmuxEnergy;
use super::{Mux, NotificationLevel, NotificationSource};
use crate::panic_free::JsonFields;
use crate::resource::ContentPublicId;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use crate::{Actor, SurfaceId};

/// Longest acpmux line read; a session summary is far smaller.
const MAX_LINE_BYTES: u64 = 4 << 20;
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
    /// the agent message pump (`agent_message_pump.rs`), which the watch
    /// wakes whenever it reaches acpmux, and the Energy Saver relay
    /// (`acpmux_energy.rs`), which sends the mode on the watch's connection.
    #[track_caller]
    pub fn watch_agent_chats(self: &Arc<Self>, socket: Option<PathBuf>) {
        self.set_acpmux_socket(socket.clone());
        let Some(socket) = socket else { return };
        self.start_agent_message_pump();
        let energy = AcpmuxEnergy::start(self.energy.mode(), &self.memory);
        if energy.is_err() {
            self.report_internal_diagnostic("acpmux energy relay not started");
        }
        let mux = Arc::downgrade(self);
        let spawned = supervised::spawn_raisable(
            "mux-agent-chat-notices",
            crate::thread_qos::ThreadType::Utility.qos(),
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                watch(&mux, &socket, energy.ok().as_ref());
            },
        );
        if spawned.is_err() {
            self.report_internal_diagnostic("agent chat notifications not started");
        }
    }

    /// The tabs that show `session`, each with its durable content id.
    #[track_caller]
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

    #[track_caller]
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

    #[track_caller]
    fn read_agent_chat_notices(&self, session: &str) {
        for (surface, _) in self.agent_chat_tabs(session) {
            if self.acknowledge_tab_notifications(surface).is_err() {
                self.report_internal_diagnostic("agent chat notification not read");
            }
        }
    }
}

/// Connects whenever acpmux listens and follows it until the daemon ends.
#[track_caller]
fn watch(mux: &Weak<Mux>, socket: &Path, energy: Option<&AcpmuxEnergy>) {
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
            && follow(mux, stream, energy, &mut chats).is_ok()
        {
            backoff.reset();
        }
        crate::request_path::sleep(backoff.next_delay());
    }
}

/// One connection: the watch page sets what each chat is doing, and every
/// push after it is a change that may notify. Ends with the connection.
#[track_caller]
fn follow(
    mux: &Weak<Mux>,
    stream: UnixStream,
    energy: Option<&AcpmuxEnergy>,
    chats: &mut HashMap<String, Chat>,
) -> std::io::Result<()> {
    let mut writer = stream.try_clone()?;
    let initialize = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1,
        "clientInfo": {"name": "cmux-tui-agent-chat-notices", "version": "1"},
        "clientCapabilities": {},
    }});
    let watch =
        json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": {"enabled": true}});
    writer.write_all(format!("{initialize}\n{watch}\n").as_bytes())?;
    if let Some(energy) = energy {
        energy.reached(&writer);
    }
    let mut reader = BufReader::new(stream);
    let mut watching = false;
    loop {
        let mut line = Vec::new();
        let read = (&mut reader).take(MAX_LINE_BYTES).read_until(b'\n', &mut line)?;
        if read == 0 || line.last() != Some(&b'\n') {
            return Ok(());
        }
        let Ok(message) = serde_json::from_slice::<Value>(&line) else { continue };
        let Some(mux) = mux.upgrade() else { return Ok(()) };
        if message.field("id") == 2 {
            // What the watch knew before this connection: the page is a change from it.
            let mut before = std::mem::take(chats);
            for summary in
                message.field("result").field("sessions").as_array().into_iter().flatten()
            {
                let Some(next) = Chat::of(summary) else { continue };
                let known = before.remove(&next.session);
                if known.is_none() && next.needs_nobody() {
                    // After a daemon start: what it posted before was seen or answered.
                    mux.read_agent_chat_notices(&next.session);
                }
                apply(&mux, known.as_ref(), next, chats);
            }
            watching = true;
        } else if watching && message.field("method") == "_acpmux/session_changed" {
            changed(&mux, message.field("params"), chats);
        } else if watching && message.field("method") == "_acpmux/permission_pending" {
            asked(&mux, message.field("params"), chats);
        }
    }
}

/// A new ask of a chat the watch follows: it comes right after the change that recorded it.
#[track_caller]
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
#[track_caller]
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
            muted: summary.field("tags").field(MUTE_TAG) == MUTED,
            last_turn,
            notified_turn: None,
            last_message: summary
                .field("lastMessage")
                .field("text")
                .as_str()
                .unwrap_or_default()
                .to_owned(),
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
    fn notices(&mut self, before: Option<&Chat>) -> Vec<Notice> {
        let mut notices = Vec::new();
        let name = &self.name;
        // The turn ended in this change (not one the watch saw ended before).
        let ended_now = |turn: &String| {
            before.is_some_and(|chat| chat.last_turn.as_ref().map(|(id, _)| id) != Some(turn))
        };
        if let Some((turn, status)) = &self.last_turn
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

    fn key(notice: Option<Notice>) -> Option<String> {
        notice.map(|notice| notice.key)
    }

    /// The watch's chat after a change from `before`, as `apply` keeps it.
    fn after(before: &Chat, indicator: &str, seq: u64) -> Chat {
        let mut next = chat(indicator, seq);
        next.keep_asks(Some(before));
        next
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
