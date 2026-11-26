//! Background delta sync: one bounded catch-up per wake, a cursor per surface
//! (`cmux-next-ios/design/background-delta-sync.md`; Leo, 2026-11-24: "the syncing can arguably
//! happen in the background too, so deltas can be sipped and maintained").
//!
//! The phone keeps, per Mac, the cursor each surface's host already answers by: the workspace
//! tree revision (`list-workspaces {known}`), the chat list's `listSeq`/`listEpoch`
//! (`_acpmux/watch`), each chat's `lastSeq` (`_acpmux/attach {afterSeq}`) and each terminal's
//! `offset` + `generation` (`attach-surface {resume_offset, resume_generation,
//! resume_max_bytes}`). A wake (foreground, a notification service extension run, a background
//! app refresh) asks [`plan`] for its requests, sends them over one resumed link, and feeds each
//! answer to [`Cursors::apply`]. A cursor moves only past what an answer held, so a wake iOS cuts
//! short is resumed by the next one, never skipped.
//!
//! Sans-I/O: [`Cursors::encode`] and [`Cursors::decode`] give the bytes the app keeps in its
//! read store, so a relaunch keeps every cursor.

use std::collections::BTreeMap;

pub mod relay;
pub mod service;

/// Bytes the list catch-up is counted at: an `unchanged` answer or a few changed rows.
pub const LIST_ESTIMATE_BYTES: u64 = 4 * 1024;
/// Bytes one wake may spend (the design's per-wake budget).
pub const WAKE_BUDGET_BYTES: u64 = 64 * 1024;
/// Recently opened chats a background wake refreshes after the one a push names.
pub const RECENT_CHATS: usize = 3;
/// Chats and terminals a cursor set keeps; the ones opened longest ago leave first.
pub const MAX_CHATS: usize = 600;
pub const MAX_TERMINALS: usize = 64;

const FORMAT: &str = "cmux-cursors/1";

/// The capability a Mac lists when its `list-workspaces` answers `since` with the changed
/// entries only. A Mac without it refuses `since` on the phone lane, so it is never sent there.
pub const WORKSPACE_LIST_DELTA_CAPABILITY: &str = "workspace-list-delta-v1";

/// The list cursors of one Mac.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ListCursor {
    /// The workspace tree revision last applied (`list-workspaces {known}`).
    pub tree_revision: Option<String>,
    /// The workspace delta cursor last applied (`list-workspaces {since: {epoch, seq}}`).
    pub tree_epoch: Option<String>,
    pub tree_seq: Option<u64>,
    /// The chat list's row log position and epoch (`_acpmux/watch {afterSeq, listEpoch}`).
    pub list_seq: Option<u64>,
    pub list_epoch: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatCursor {
    /// The last transcript event applied.
    pub last_seq: u64,
    /// When the person last opened it (any clock the app picks, larger is newer).
    pub opened_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCursor {
    pub offset: u64,
    pub generation: String,
    /// Bytes of the last screen replay: a resume missing more than this is not worth it.
    pub replay_bytes: u64,
    pub opened_at: u64,
}

/// What one Mac's surfaces were last brought up to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cursors {
    pub list: ListCursor,
    pub chats: BTreeMap<String, ChatCursor>,
    pub terminals: BTreeMap<String, TerminalCursor>,
    /// The Mac listed [`WORKSPACE_LIST_DELTA_CAPABILITY`] on this link. Not kept across a
    /// relaunch: until the Mac says so again, the plan asks by `known`, which every Mac answers.
    pub workspace_delta: bool,
}

/// Why the app runs a catch-up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wake {
    /// The app came forward; `chat` or `terminal` is the surface on screen.
    Foreground { chat: Option<String>, terminal: Option<String> },
    /// A notification service extension run for a push about `chat`.
    Push { chat: Option<String> },
    /// A `BGAppRefreshTask`.
    Refresh,
}

/// One request of a wake, carrying its cursor and the bytes it may answer with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// `since` is set only when the Mac listed [`WORKSPACE_LIST_DELTA_CAPABILITY`]; an empty
    /// epoch at seq 0 asks for the whole tree and a first cursor.
    Workspaces {
        known: Option<String>,
        since: Option<(String, u64)>,
    },
    ChatList {
        after_seq: Option<u64>,
        list_epoch: Option<String>,
    },
    Chat {
        session: String,
        after_seq: u64,
        max_bytes: u64,
    },
    Terminal {
        surface: String,
        offset: u64,
        generation: String,
        max_bytes: u64,
    },
}

/// An answer, reduced to the cursor it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    /// `delta`: the `epoch`/`seq` a delta-capable Mac answered with.
    Workspaces {
        revision: String,
        delta: Option<(String, u64)>,
    },
    ChatList {
        through_seq: u64,
        list_epoch: String,
    },
    /// `through_seq`: the last event the page held (`pageThrough`).
    Chat {
        session: String,
        through_seq: u64,
    },
    /// The terminal's stamp after the answer; `replay_bytes` when it was a screen replay.
    Terminal {
        surface: String,
        offset: u64,
        generation: String,
        replay_bytes: Option<u64>,
    },
}

/// The ordered requests of one wake: lists first, then chats (the one on screen or pushed,
/// then the most recently opened in the background), then the terminal on screen (foreground
/// only: a terminal is not synced in the background). Chats share what the lists leave of
/// `budget`; the plan stops when it is spent.
pub fn plan(cursors: &Cursors, wake: &Wake, budget: u64) -> Vec<Request> {
    let mut requests = vec![
        Request::Workspaces {
            known: cursors.list.tree_revision.clone(),
            since: cursors.workspace_delta.then(|| {
                match (&cursors.list.tree_epoch, cursors.list.tree_seq) {
                    (Some(epoch), Some(seq)) => (epoch.clone(), seq),
                    _ => (String::new(), 0),
                }
            }),
        },
        Request::ChatList {
            after_seq: cursors.list.list_seq,
            list_epoch: cursors.list.list_epoch.clone(),
        },
    ];
    let mut left = budget.saturating_sub(2 * LIST_ESTIMATE_BYTES);
    let (first, recent) = match wake {
        Wake::Foreground { chat, .. } => (chat.as_deref(), 0),
        Wake::Push { chat } => (chat.as_deref(), RECENT_CHATS),
        Wake::Refresh => (None, RECENT_CHATS),
    };
    let mut chats: Vec<&str> = first.into_iter().collect();
    let mut by_recency: Vec<(&String, &ChatCursor)> = cursors.chats.iter().collect();
    by_recency.sort_by(|a, b| b.1.opened_at.cmp(&a.1.opened_at).then(a.0.cmp(b.0)));
    chats.extend(
        by_recency
            .into_iter()
            .map(|(id, _)| id.as_str())
            .filter(|id| Some(*id) != first)
            .take(recent),
    );
    let count = chats.len() as u64;
    for (index, session) in chats.into_iter().enumerate() {
        if left == 0 {
            break;
        }
        // The first chat may take half of what is left; the rest share the remainder evenly.
        let share = if index == 0 && count > 1 { left / 2 } else { left / (count - index as u64) };
        let share = share.max(1).min(left);
        left -= share;
        let after_seq = cursors.chats.get(session).map_or(0, |cursor| cursor.last_seq);
        requests.push(Request::Chat { session: session.to_string(), after_seq, max_bytes: share });
    }
    if let Wake::Foreground { terminal: Some(surface), .. } = wake
        && let Some(cursor) = cursors.terminals.get(surface)
    {
        // The cheaper of the exact missed bytes and one screen replay.
        requests.push(Request::Terminal {
            surface: surface.clone(),
            offset: cursor.offset,
            generation: cursor.generation.clone(),
            max_bytes: cursor.replay_bytes,
        });
    }
    requests
}

impl Cursors {
    /// Records the capabilities the Mac listed on this link (its `identify` reply).
    pub fn set_capabilities<'a>(&mut self, capabilities: impl IntoIterator<Item = &'a str>) {
        self.workspace_delta =
            capabilities.into_iter().any(|name| name == WORKSPACE_LIST_DELTA_CAPABILITY);
    }

    /// Moves a cursor past what `reply` held, never back: an older or repeated answer is a no-op.
    pub fn apply(&mut self, reply: Reply, now: u64) {
        match reply {
            Reply::Workspaces { revision, delta } => {
                self.list.tree_revision = Some(revision);
                if let Some((epoch, seq)) = delta {
                    let same_epoch = self.list.tree_epoch.as_deref() == Some(epoch.as_str());
                    if !same_epoch || self.list.tree_seq.is_none_or(|known| seq > known) {
                        self.list.tree_seq = Some(seq);
                    }
                    self.list.tree_epoch = Some(epoch);
                }
            }
            Reply::ChatList { through_seq, list_epoch } => {
                let same_epoch = self.list.list_epoch.as_deref() == Some(list_epoch.as_str());
                if !same_epoch || self.list.list_seq.is_none_or(|seq| through_seq > seq) {
                    self.list.list_seq = Some(through_seq);
                }
                self.list.list_epoch = Some(list_epoch);
            }
            Reply::Chat { session, through_seq } => {
                let cursor =
                    self.chats.entry(session).or_insert(ChatCursor { last_seq: 0, opened_at: now });
                cursor.last_seq = cursor.last_seq.max(through_seq);
                self.trim();
            }
            Reply::Terminal { surface, offset, generation, replay_bytes } => {
                let cursor = self.terminals.entry(surface).or_insert(TerminalCursor {
                    offset,
                    generation: generation.clone(),
                    replay_bytes: replay_bytes.unwrap_or(0),
                    opened_at: now,
                });
                if cursor.generation != generation || offset >= cursor.offset {
                    cursor.offset = offset;
                    cursor.generation = generation;
                }
                if let Some(replay) = replay_bytes {
                    cursor.replay_bytes = replay;
                }
                self.trim();
            }
        }
    }

    /// The person opened a chat or a terminal: it ranks first among the recent ones.
    pub fn opened_chat(&mut self, session: &str, now: u64) {
        self.chats
            .entry(session.to_string())
            .or_insert(ChatCursor { last_seq: 0, opened_at: now })
            .opened_at = now;
        self.trim();
    }

    fn trim(&mut self) {
        while self.chats.len() > MAX_CHATS {
            let Some(oldest) =
                self.chats.iter().min_by_key(|(_, c)| c.opened_at).map(|(k, _)| k.clone())
            else {
                break;
            };
            self.chats.remove(&oldest);
        }
        while self.terminals.len() > MAX_TERMINALS {
            let Some(oldest) =
                self.terminals.iter().min_by_key(|(_, c)| c.opened_at).map(|(k, _)| k.clone())
            else {
                break;
            };
            self.terminals.remove(&oldest);
        }
    }

    /// The bytes the app keeps: one line per cursor, fields separated by tabs.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = String::from(FORMAT);
        out.push('\n');
        let opt = |value: Option<String>| value.unwrap_or_else(|| "-".to_string());
        out.push_str(&format!(
            "list\t{}\t{}\t{}\n",
            opt(self.list.tree_revision.as_deref().map(escape)),
            opt(self.list.list_seq.map(|seq| seq.to_string())),
            opt(self.list.list_epoch.as_deref().map(escape)),
        ));
        if let (Some(epoch), Some(seq)) = (&self.list.tree_epoch, self.list.tree_seq) {
            out.push_str(&format!("tree\t{}\t{seq}\n", escape(epoch)));
        }
        for (id, cursor) in &self.chats {
            out.push_str(&format!(
                "chat\t{}\t{}\t{}\n",
                escape(id),
                cursor.last_seq,
                cursor.opened_at
            ));
        }
        for (id, cursor) in &self.terminals {
            out.push_str(&format!(
                "term\t{}\t{}\t{}\t{}\t{}\n",
                escape(id),
                cursor.offset,
                escape(&cursor.generation),
                cursor.replay_bytes,
                cursor.opened_at
            ));
        }
        out.into_bytes()
    }

    /// Reads what [`Cursors::encode`] wrote. Anything else reads as no cursors: the next wake
    /// asks from the start, the answer every surface gives today.
    pub fn decode(bytes: &[u8]) -> Self {
        Self::try_decode(bytes).unwrap_or_default()
    }

    fn try_decode(bytes: &[u8]) -> Option<Self> {
        let text = std::str::from_utf8(bytes).ok()?;
        let mut lines = text.lines();
        if lines.next()? != FORMAT {
            return None;
        }
        let mut cursors = Self::default();
        for line in lines {
            let fields: Vec<&str> = line.split('\t').collect();
            let opt = |field: &str| (field != "-").then(|| unescape(field)).flatten();
            match fields.as_slice() {
                ["list", revision, seq, epoch] => {
                    cursors.list.tree_revision = opt(revision);
                    cursors.list.list_seq =
                        if *seq == "-" { None } else { Some(seq.parse().ok()?) };
                    cursors.list.list_epoch = opt(epoch);
                }
                ["tree", epoch, seq] => {
                    cursors.list.tree_epoch = Some(unescape(epoch)?);
                    cursors.list.tree_seq = Some(seq.parse().ok()?);
                }
                ["chat", id, seq, opened] => {
                    cursors.chats.insert(
                        unescape(id)?,
                        ChatCursor { last_seq: seq.parse().ok()?, opened_at: opened.parse().ok()? },
                    );
                }
                ["term", id, offset, generation, replay, opened] => {
                    cursors.terminals.insert(
                        unescape(id)?,
                        TerminalCursor {
                            offset: offset.parse().ok()?,
                            generation: unescape(generation)?,
                            replay_bytes: replay.parse().ok()?,
                            opened_at: opened.parse().ok()?,
                        },
                    );
                }
                _ => return None,
            }
        }
        Some(cursors)
    }
}

/// Percent-escapes `%`, tab, newline and a lone `-`, so any id fits one field.
fn escape(value: &str) -> String {
    if value == "-" {
        return "%2D".to_string();
    }
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '%' => out.push_str("%25"),
            '\t' => out.push_str("%09"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            _ => out.push(ch),
        }
    }
    out
}

fn unescape(value: &str) -> Option<String> {
    let mut out = Vec::with_capacity(value.len());
    let mut bytes = value.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let high = char::from(bytes.next()?).to_digit(16)?;
            let low = char::from(bytes.next()?).to_digit(16)?;
            out.push(u8::try_from(high.checked_mul(16)?.checked_add(low)?).ok()?);
        } else {
            out.push(byte);
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
#[path = "catch_up_tests.rs"]
mod tests;
