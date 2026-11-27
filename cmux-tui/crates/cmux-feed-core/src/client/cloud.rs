//! The `FeedDO` stream over `cmux.wire/1` (`/v1/wire/feed`, feed.md
//! sections 4 and 6) as a pure state machine (Swift `CloudFeedSource` and
//! `FeedWireFrame`): frames in, frames to send and mirror changes out. The
//! owner sends a snapshot on subscribe and, on every commit, an event that
//! carries the items the commit changed and the ids still present; this
//! never replays ops itself. Intents go out as `op` frames with origin
//! `user`; an intent sent before a disconnect is resent with the same key
//! after the reconnect (the owner's ledger answers a decided key); nothing
//! new is sent while disconnected.
//!
//! Not `cmux_cloud_wire::StreamMirror`: the feed owner's events carry the
//! changed items, not the op log the mirror replays, and its subscribe asks
//! for the snapshot every time (resumed log events carry no items).

use std::collections::{HashMap, HashSet};

use serde_json::{Value, json};

use super::intent::{Intent, IntentKind};
use super::item::FeedItem;
use super::mirror::Reject;

/// The owner's path on the API origin.
pub const FEED_WIRE_PATH: &str = "/v1/wire/feed";

/// What the stream asks of the daemon.
#[derive(Clone, Debug, PartialEq)]
pub enum CloudAction {
    /// A text frame for the socket.
    Send(String),
    /// The welcome named the user (the reports mailbox is theirs).
    User(String),
    /// A snapshot made the mirror current: the stream is live.
    Snapshot { user: String, items: Vec<FeedItem> },
    /// One commit: the items it changed and the ids it removed.
    Event { items: Vec<FeedItem>, removed: Vec<String> },
    /// The owner settled one of this client's intents.
    Settled { key: String, reject: Option<Reject> },
}

/// One decoded frame.
#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    Welcome { user: String },
    Snapshot { user: String, items: Vec<FeedItem> },
    Event { items: Vec<FeedItem>, present: Option<Vec<String>> },
    Reject { key: String, reject: Reject },
    Settled { key: String },
    Ignored,
}

impl Frame {
    pub fn decode(text: &str) -> Self {
        let Ok(frame) = serde_json::from_str::<Value>(text) else { return Frame::Ignored };
        let key = || frame.get("idempotency_key").and_then(Value::as_str).map(str::to_owned);
        match frame.get("t").and_then(Value::as_str) {
            Some("welcome") => frame
                .pointer("/principal/user")
                .and_then(Value::as_str)
                .map_or(Frame::Ignored, |user| Frame::Welcome { user: user.to_owned() }),
            Some("snapshot") => {
                let state = frame.get("state");
                let items = state
                    .and_then(|state| state.get("items"))
                    .and_then(Value::as_object)
                    .map(|items| items.values().filter_map(FeedItem::from_value).collect())
                    .unwrap_or_default();
                let user = state
                    .and_then(|state| state.get("user"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                Frame::Snapshot { user, items }
            }
            Some("event") => Frame::Event {
                items: frame
                    .get("items")
                    .and_then(Value::as_array)
                    .map(|items| items.iter().filter_map(FeedItem::from_value).collect())
                    .unwrap_or_default(),
                present: frame
                    .get("present")
                    .and_then(Value::as_array)
                    .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
            },
            Some("reject") => match key() {
                Some(key) => Frame::Reject {
                    key,
                    reject: reject(
                        frame.get("code").and_then(Value::as_str).unwrap_or_default(),
                        frame.get("message").and_then(Value::as_str).unwrap_or_default(),
                        frame.get("details"),
                    ),
                },
                None => Frame::Ignored,
            },
            Some("request-settled") => key().map_or(Frame::Ignored, |key| Frame::Settled { key }),
            _ => Frame::Ignored,
        }
    }
}

/// A reject frame as the client's typed refusal.
pub fn reject(code: &str, message: &str, details: Option<&Value>) -> Reject {
    match code {
        "feed.closed" => details
            .and_then(|details| details.get("item"))
            .and_then(FeedItem::from_value)
            .map_or_else(
                || Reject::Other(message.to_owned()),
                |item| Reject::Closed(Box::new(item)),
            ),
        "feed.moving" => Reject::Moving,
        "validation.invalid" => Reject::Invalid(message.to_owned()),
        _ => Reject::Other(format!("{code}: {message}")),
    }
}

/// Most item ids one read, archive or snooze op carries (the cloud owner's limit). A longer
/// intent goes to the cloud as several ops (``CloudStream::send``), settled as one.
pub const MAX_INTENT_IDS: usize = 256;

/// Most item ids one `read` intent carries: every item the view shows (``MAX_VIEW_ENTRIES``),
/// so the Inbox's Mark All Read is one page call (one gesture) however long the Inbox is.
pub const MAX_READ_IDS: usize = super::view::MAX_VIEW_ENTRIES;

/// The owner's op params of one intent (Swift `FeedWireEncode.op`), one per op, or none when it
/// has nothing to send. An item list goes as ops of at most [`MAX_INTENT_IDS`] ids. Mark All Read
/// sends the owner's `all` (it also reads an item posted between the click and the commit), and
/// only while an unread item posted by `before` is known.
pub fn op_params(intent: &Intent, unread_before: impl Fn(i64) -> bool) -> Vec<Value> {
    let parts = |items: &[String], extra: Option<i64>| -> Vec<Value> {
        items
            .chunks(MAX_INTENT_IDS)
            .map(|chunk| match extra {
                Some(until) => json!({"items": chunk, "until": until}),
                None => json!({"items": chunk}),
            })
            .collect()
    };
    match &intent.kind {
        IntentKind::Answer { item, value } => vec![json!({"item": item, "answer": value})],
        IntentKind::Decline { item } => vec![json!({"item": item, "reason": "declined"})],
        IntentKind::Read { items } | IntentKind::Archive { items } => parts(items, None),
        IntentKind::Snooze { items, until } => parts(items, Some(*until)),
        IntentKind::MarkAllRead { before } => {
            if unread_before(*before) {
                vec![json!({"all": true})]
            } else {
                Vec::new()
            }
        }
    }
}

/// The idempotency key of part `index` of an intent sent as several ops: the first keeps the
/// intent's key, so an intent of one op is sent as before.
fn part_key(key: &str, index: usize) -> String {
    if index == 0 { key.to_owned() } else { format!("{key}:{}", index.saturating_add(1)) }
}

/// The stream's client state across connections.
#[derive(Default)]
pub struct CloudStream {
    stream: String,
    /// A snapshot arrived on this connection.
    live: bool,
    active: bool,
    /// Ops of intents sent and not settled, in send order (resent in that
    /// order on reconnect): the intent's key, the op's key, the frame.
    unsettled: Vec<(String, String, String)>,
    rejects: HashMap<String, Reject>,
    /// The first refusal of an intent sent as several ops, while another op is unsettled.
    part_rejects: HashMap<String, Reject>,
    /// Unread items and when they were posted, for Mark All Read.
    unread: HashMap<String, i64>,
    known: HashSet<String>,
}

impl CloudStream {
    pub fn new() -> Self {
        Self::default()
    }

    /// A snapshot arrived on the current connection: intents go out.
    pub fn is_live(&self) -> bool {
        self.live
    }

    /// A new socket opened: nothing is live until its snapshot.
    pub fn on_connect(&mut self) {
        self.live = false;
    }

    /// The socket closed.
    pub fn on_disconnect(&mut self) {
        self.live = false;
    }

    /// Sign-out or another account: forgets every intent and item. Returns
    /// the keys of the intents that never settled (refuse them).
    pub fn reset(&mut self) -> Vec<String> {
        let mut keys: Vec<String> = Vec::new();
        for (key, _, _) in self.unsettled.drain(..) {
            if !keys.contains(&key) {
                keys.push(key);
            }
        }
        *self = Self { active: self.active, ..Self::default() };
        keys
    }

    /// One intent for the owner: the frames to send (one per op; none when
    /// there is nothing to send, it settles at once), or `Err` while the
    /// stream is not live (refused, nothing queues). An intent of several ops
    /// settles once every op did, with the first refusal.
    pub fn send(&mut self, intent: &Intent) -> Result<Vec<String>, Reject> {
        if !self.live {
            return Err(Reject::Disconnected);
        }
        let unread = &self.unread;
        let parts = op_params(intent, |cut| unread.values().any(|posted| *posted <= cut));
        let mut frames = Vec::with_capacity(parts.len());
        for (index, params) in parts.into_iter().enumerate() {
            let key = part_key(&intent.key, index);
            let frame = json!({
                "t": "op",
                "op": intent.op(),
                "params": params,
                "idempotency_key": key,
                "origin": "user",
            })
            .to_string();
            self.unsettled.push((intent.key.clone(), key, frame.clone()));
            frames.push(frame);
        }
        Ok(frames)
    }

    /// The app's active state for the owner's push rule (a Mac in use gets
    /// banners, not iPhone pushes): the frame to send now, if live.
    pub fn set_presence(&mut self, active: bool) -> Option<String> {
        self.active = active;
        self.presence_frame()
    }

    /// Only on a live stream: a reconnect sends presence after its snapshot, never before the
    /// subscribe.
    fn presence_frame(&self) -> Option<String> {
        (self.live && !self.stream.is_empty()).then(|| {
            json!({"t": "presence.set", "stream": self.stream, "state": {"active": self.active, "client": "mac"}})
                .to_string()
        })
    }

    /// Applies one frame.
    pub fn on_text(&mut self, text: &str) -> Vec<CloudAction> {
        self.on_frame(Frame::decode(text))
    }

    pub fn on_frame(&mut self, frame: Frame) -> Vec<CloudAction> {
        let mut actions = Vec::new();
        match frame {
            Frame::Welcome { user } => {
                self.stream = format!("feed:{user}");
                // No `after_seq`: resumed log events carry no items, so a
                // (re)subscribe always takes the snapshot.
                let pending: Vec<&str> =
                    self.unsettled.iter().map(|(_, key, _)| key.as_str()).collect();
                actions.push(CloudAction::User(user));
                actions.push(CloudAction::Send(
                    json!({"t": "subscribe", "stream": self.stream, "pending": pending})
                        .to_string(),
                ));
            }
            Frame::Snapshot { user, items } => {
                self.live = true;
                self.known = items.iter().map(|item| item.id.clone()).collect();
                self.unread = items
                    .iter()
                    .filter(|item| item.is_unread())
                    .map(|item| (item.id.clone(), item.created_at))
                    .collect();
                actions.push(CloudAction::Snapshot { user, items });
                if let Some(frame) = self.presence_frame() {
                    actions.push(CloudAction::Send(frame));
                }
                for (_, _, frame) in &self.unsettled {
                    actions.push(CloudAction::Send(frame.clone()));
                }
            }
            Frame::Event { items, present } => {
                for item in &items {
                    self.known.insert(item.id.clone());
                    if item.is_unread() {
                        self.unread.insert(item.id.clone(), item.created_at);
                    } else {
                        self.unread.remove(&item.id);
                    }
                }
                let mut removed = Vec::new();
                if let Some(present) = present {
                    let present: HashSet<String> = present.into_iter().collect();
                    removed = self.known.difference(&present).cloned().collect();
                    removed.sort();
                    for id in &removed {
                        self.known.remove(id);
                        self.unread.remove(id);
                    }
                }
                if !items.is_empty() || !removed.is_empty() {
                    actions.push(CloudAction::Event { items, removed });
                }
            }
            Frame::Reject { key, reject } => {
                self.rejects.insert(key, reject);
            }
            Frame::Settled { key } => {
                let reject = self.rejects.remove(&key);
                if let Some(index) = self.unsettled.iter().position(|(_, sent, _)| *sent == key) {
                    let (intent, _, _) = self.unsettled.remove(index);
                    if self.unsettled.iter().any(|(other, _, _)| *other == intent) {
                        if let Some(reject) = reject {
                            self.part_rejects.entry(intent).or_insert(reject);
                        }
                    } else {
                        let reject = self.part_rejects.remove(&intent).or(reject);
                        actions.push(CloudAction::Settled { key: intent, reject });
                    }
                }
            }
            Frame::Ignored => {}
        }
        actions
    }
}
