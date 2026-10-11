//! Agent chat notifications (cx-sg1qz). One watch of this machine's acpmux
//! (`_acpmux/watch`, then its `_acpmux/session_changed` pushes) turns what a
//! chat does into notifications on every agent tab bound to it:
//!
//! - its turn ended: "<chat> finished" with the reply's last line, or
//!   "<chat> failed" (level error) when the turn failed;
//! - it waits for the person (a permission or a question): "<chat> needs
//!   input" with what it asks;
//! - its agent went away mid-turn: "<chat> stopped responding" (error).
//!
//! The app shows them like any tab notification (a banner unless that tab is
//! focused, the Dock badge, a click that opens the tab, the workspace mute).
//! When acpmux says a pane showed the chat (`unread` turned false) or the wait
//! ended, the daemon reads the tab's notifications, so seeing or answering the
//! chat anywhere clears them. A (re)connect catches up on what it missed: a
//! turn that ended unseen, a chat that waits or whose agent went away. Each
//! notice has a key of the chat and the turn (or the record it waits on), so
//! one that was posted before is not posted again.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use super::{Mux, NotificationLevel, NotificationSource};
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::{Actor, SurfaceId};

/// Longest acpmux line read; a session summary is far smaller.
const MAX_LINE_BYTES: u64 = 4 << 20;
/// Longest notification body, in characters.
const MAX_BODY_CHARS: usize = 200;

impl Mux {
    /// This machine's acpmux socket (`set_acpmux_socket`), and a watch of its
    /// chats that posts their notifications for as long as the daemon runs.
    pub fn watch_agent_chats(self: &Arc<Self>, socket: Option<PathBuf>) {
        self.set_acpmux_socket(socket.clone());
        let Some(socket) = socket else { return };
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-agent-chat-notices".into())
            .spawn(move || watch(&mux, &socket));
        if spawned.is_err() {
            self.report_internal_diagnostic("agent chat notifications not started");
        }
    }

    /// The tabs that show `session`.
    fn agent_chat_tabs(&self, session: &str) -> Vec<SurfaceId> {
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
            .map(|(id, _)| id)
            .collect()
    }

    fn post_agent_chat_notice(&self, session: &str, notice: &Notice) {
        for surface in self.agent_chat_tabs(session) {
            let key = format!("acpmux-{session}-{}-{surface}", notice.key);
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
        for surface in self.agent_chat_tabs(session) {
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
        if let Ok(stream) = UnixStream::connect(socket)
            && follow(mux, stream, &mut chats).is_ok()
        {
            backoff.reset();
        }
        std::thread::sleep(backoff.next_delay());
    }
}

/// One connection: the watch page sets what each chat is doing, and every
/// push after it is a change that may notify. Ends with the connection.
fn follow(
    mux: &Weak<Mux>,
    stream: UnixStream,
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
        if message["id"] == 2 {
            chats.clear();
            for summary in message["result"]["sessions"].as_array().into_iter().flatten() {
                let Some(chat) = Chat::of(summary) else { continue };
                // An ended turn notifies while nobody has seen it; older ones were read.
                for notice in chat.notices(None) {
                    if chat.unread || !notice.ended_turn {
                        mux.post_agent_chat_notice(&chat.session, &notice);
                    }
                }
                chats.insert(chat.session.clone(), chat);
            }
            watching = true;
        } else if watching && message["method"] == "_acpmux/session_changed" {
            changed(&mux, &message["params"], chats);
        }
    }
}

fn changed(mux: &Mux, params: &Value, chats: &mut HashMap<String, Chat>) {
    let Some(session) = params["sessionId"].as_str() else { return };
    if params["kind"] == "purged" {
        chats.remove(session);
        return;
    }
    let Some(next) = Chat::of(&params["session"]) else { return };
    let before = chats.insert(next.session.clone(), next.clone());
    let before = before.as_ref();
    let waited = before.is_some_and(|chat| chat.indicator == "input");
    let read = before.is_some_and(|chat| chat.unread) && !next.unread;
    if read || (waited && next.indicator != "input") {
        mux.read_agent_chat_notices(&next.session);
    }
    for notice in next.notices(before) {
        mux.post_agent_chat_notice(&next.session, &notice);
    }
}

/// What the watch knows of one chat.
#[derive(Clone, Debug)]
struct Chat {
    session: String,
    name: String,
    indicator: String,
    unread: bool,
    /// The last turn that ended: its id and status.
    last_turn: Option<(String, String)>,
    last_message: String,
    last_seq: u64,
}

struct Notice {
    /// Unique per chat; the notification's idempotency key.
    key: String,
    /// It tells of an ended turn (done or failed).
    ended_turn: bool,
    title: String,
    body: String,
    level: NotificationLevel,
}

impl Chat {
    fn of(summary: &Value) -> Option<Self> {
        let session = summary["sessionId"].as_str()?.to_owned();
        let text = |key: &str| summary[key].as_str().filter(|text| !text.trim().is_empty());
        let name = text("title")
            .or_else(|| text("name"))
            .or_else(|| text("harness"))
            .unwrap_or("Agent")
            .to_owned();
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
            last_turn,
            last_message: summary["lastMessage"]["text"].as_str().unwrap_or_default().to_owned(),
            last_seq: summary["lastSeq"].as_u64().unwrap_or(0),
        })
    }

    /// What this change says to the person, given what the chat did before.
    fn notices(&self, before: Option<&Chat>) -> Vec<Notice> {
        let mut notices = Vec::new();
        let name = &self.name;
        if let Some((turn, status)) = &self.last_turn
            && before.and_then(|chat| chat.last_turn.as_ref()).map(|(id, _)| id) != Some(turn)
        {
            match status.as_str() {
                "completed" => notices.push(Notice {
                    key: format!("done-{turn}"),
                    ended_turn: true,
                    title: format!("{name} finished"),
                    body: short(&self.last_message),
                    level: NotificationLevel::Info,
                }),
                "failed" => notices.push(Notice {
                    key: format!("failed-{turn}"),
                    ended_turn: true,
                    title: format!("{name} failed"),
                    body: short(&self.last_message),
                    level: NotificationLevel::Error,
                }),
                _ => {}
            }
        }
        let was = before.map_or("", |chat| chat.indicator.as_str());
        if self.indicator == "input" && was != "input" {
            notices.push(Notice {
                // The record it waits on: the same key while it still waits.
                key: format!("input-{}", self.last_seq),
                ended_turn: false,
                title: format!("{name} needs input"),
                body: short(&self.last_message),
                level: NotificationLevel::Warning,
            });
        }
        if self.indicator == "lost" && was != "lost" {
            notices.push(Notice {
                key: format!("lost-{}", self.last_seq),
                ended_turn: false,
                title: format!("{name} stopped responding"),
                body: short(&self.last_message),
                level: NotificationLevel::Error,
            });
        }
        notices
    }
}

/// `text` cut to [`MAX_BODY_CHARS`] characters.
fn short(text: &str) -> String {
    let text = text.trim();
    if text.chars().count() <= MAX_BODY_CHARS {
        return text.to_owned();
    }
    let mut cut = text.chars().take(MAX_BODY_CHARS - 1).collect::<String>();
    cut.push('…');
    cut
}
