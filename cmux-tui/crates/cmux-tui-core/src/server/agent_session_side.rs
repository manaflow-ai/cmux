//! `agent-session-side-v1`: the owner's side chats of an attached chat on this machine, so the
//! owner's app on another Mac offers `/side` and `/btw` for a Cloud chat as it does for a local one.
//!
//! `agent-session-side {surface, op, …}` on the owner's own attachment:
//! - `open` with `through_seq` or `live: true`: forks the attached chat (acpmux
//!   `acp.session.fork`) and tags the fork its side chat (`_acpmux/side`) in one step. A fork whose
//!   tag fails is discarded, so no untagged copy is left in the lists. Answers acpmux's fork answer.
//! - `btw` with `text` (the question): acpmux's read-only side session about the chat
//!   (`_acpmux/btw`). Answers `{sessionId}`.
//! - `prompt` with `session`, `prompt_id`, `text`: a prompt to a side chat this attachment opened.
//! - `discard` with `session`: ends a side chat this attachment opened that never got its pane.
//!
//! What this trusts and never takes: the attached chat is the one the tab's store record pins, as
//! for every attach verb; the frame names no folder, command, agent, model or tag. The only id a
//! frame carries (`session`, for `prompt` and `discard`) must be a side chat this same attachment
//! opened: its id came from this machine's acpmux answer, never from a request. Everything runs
//! on this machine.
//!
//! Owner only. A teammate, a Cloud team member, a link guest and the phone carrier are refused
//! the verb (it is in none of their verb lists, and [`side`] refuses an authored attachment).
//! They never reach a side chat either: the daemon remembers every side chat it opened or saw
//! tagged ([`SideSessions`]) and refuses an authored attach to one, also when acpmux's attach
//! page shows the `side` tag for a chat the daemon had not seen yet (after a restart).
//! `agent-session-team-list` reads acpmux's own tags each time ([`tagged_now`]) and leaves
//! every side chat out, so a daemon that restarted lists none either; when acpmux's list cannot
//! be read it lists no chat.

use std::collections::{HashSet, VecDeque};
use std::sync::Mutex;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{AcpmuxLink, Attachment, CALL_TIMEOUT, MAX_PROMPT_BYTES, Mux, Refusal, SurfaceId};

pub const AGENT_SESSION_SIDE_CAPABILITY: &str = "agent-session-side-v1";
/// acpmux starts the side session's agent before it answers `_acpmux/btw`.
const BTW_TIMEOUT: Duration = Duration::from_secs(30);
/// Side chats one attachment may hold open for `prompt` and `discard`.
const MAX_SIDES: usize = 64;
/// Side chat ids the daemon remembers (the oldest goes first).
const MAX_KNOWN: usize = 1024;

/// The side chats this daemon opened or saw tagged, newest last.
#[derive(Default)]
pub(crate) struct SideSessions(Mutex<VecDeque<String>>);

impl SideSessions {
    pub(crate) fn remember(&self, session: &str) {
        let mut known = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if session.is_empty() || known.iter().any(|old| old == session) {
            return;
        }
        if known.len() >= MAX_KNOWN {
            known.pop_front();
        }
        known.push_back(session.to_owned());
    }

    /// True when `session` is a side chat as far as this daemon knows.
    pub(crate) fn contains(&self, session: &str) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|id| id == session)
    }
}

/// True when acpmux's attach page says its session is a side chat (the `side` tag, which only
/// acpmux sets: `_acpmux/side` and `_acpmux/btw`).
pub(super) fn tagged(page: &Value) -> bool {
    page.pointer("/session/tags/side").is_some_and(|tag| !tag.is_null())
}

/// The sessions acpmux tags `side` now, from its own list (`_acpmux/sessions`, the persisted
/// tags): what the daemon's memory cannot say after a restart. They are remembered from here
/// on. `None` when the list cannot be read whole: the caller then shows no chat at all.
pub(super) fn tagged_now(mux: &Mux) -> Option<HashSet<String>> {
    let sessions = &mux.control_clients.agent_sessions;
    let socket = sessions.socket()?;
    let link = AcpmuxLink::connect(&socket, |_| {}).ok()?;
    let list = link.call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT);
    link.close();
    let list = list.ok()?;
    let tagged: HashSet<String> = list
        .get("sessions")?
        .as_array()?
        .iter()
        .filter(|row| row.pointer("/tags/side").is_some_and(|tag| !tag.is_null()))
        // A tab's record may hold the chat's name instead of its id: both name the side chat.
        .flat_map(|row| [row.get("sessionId"), row.get("name")])
        .filter_map(|id| id.and_then(Value::as_str))
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .collect();
    for session in &tagged {
        sessions.sides.remember(session);
    }
    Some(tagged)
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Op {
    Open,
    Btw,
    Prompt,
    Discard,
}

/// `agent-session-side`. Unknown fields are a bad request, as for every attach verb.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SideParams {
    pub(super) surface: SurfaceId,
    op: Op,
    #[serde(default)]
    through_seq: Option<u64>,
    #[serde(default)]
    live: bool,
    #[serde(default)]
    session: Option<String>,
    #[serde(default)]
    prompt_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
}

impl Attachment {
    /// True when `session` is a side chat this attachment opened.
    pub(super) fn is_side(&self, session: &str) -> bool {
        self.sides.lock().unwrap_or_else(|e| e.into_inner()).contains(session)
    }

    fn side_room(&self) -> Result<(), Refusal> {
        if self.sides.lock().unwrap_or_else(|e| e.into_inner()).len() >= MAX_SIDES {
            return Err(Refusal::Limit);
        }
        Ok(())
    }

    /// Holds `session` (acpmux's answer) as this attachment's side chat: the daemon refuses it to
    /// every teammate from now on, and `new-conversation-tab` admits its tab beside the chat.
    fn note_side(&self, session: &str) {
        self.sides.lock().unwrap_or_else(|e| e.into_inner()).insert(session.to_owned());
        if let Some(mux) = self.mux.upgrade() {
            mux.control_clients.agent_sessions.sides.remember(session);
        }
        self.follow_children(&[session.to_owned()]);
    }

    /// Ends side chat `session` and its conversation copy. It stays remembered as a side chat:
    /// a kill acpmux did not answer leaves it there, still refused to teammates.
    fn discard_side(&self, session: &str) {
        let kill = json!({"sessionId": session, "purge": true, "cancelFork": true});
        let _ = self.link.call("_acpmux/kill", kill, CALL_TIMEOUT);
        self.sides.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
        self.children.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
        if let Some(mux) = self.mux.upgrade() {
            mux.control_clients.agent_sessions.known_children.forget(session);
        }
    }
}

/// The id acpmux answered for a new session: never empty, never the attached chat itself.
fn answered_session(attachment: &Attachment, answer: &Value) -> Result<String, Refusal> {
    answer
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && *id != attachment.session)
        .map(str::to_owned)
        .ok_or(Refusal::Refused)
}

pub(super) fn side(attachment: &Attachment, params: SideParams) -> Result<Value, Refusal> {
    // The owner's own attachment only (`run_on_worker` refuses the rest before a worker starts).
    if attachment.author.is_some() || attachment.cloud_mobile {
        return Err(Refusal::NotTrusted);
    }
    let chat = attachment.session.as_str();
    let SideParams { op, through_seq, live, session, prompt_id, text, .. } = params;
    match op {
        Op::Open => {
            if session.is_some() || prompt_id.is_some() || text.is_some() {
                return Err(Refusal::BadRequest);
            }
            // `acp.session.fork`, the validated boundary: through a completed turn, or the chat
            // as it is now while its turn goes on.
            let fork = match (through_seq, live) {
                (Some(seq), false) if seq > 0 => json!({"sessionId": chat, "throughSeq": seq}),
                (None, true) => json!({"sessionId": chat, "live": true}),
                _ => return Err(Refusal::BadRequest),
            };
            attachment.side_room()?;
            let forked = attachment
                .link
                .call("acp.session.fork", fork, CALL_TIMEOUT)
                .map_err(Refusal::of)?;
            let id = answered_session(attachment, &forked)?;
            // Remembered before the tag: no teammate reaches it in between either.
            attachment.note_side(&id);
            let tag = json!({"sessionId": id, "chat": chat});
            if let Err(error) = attachment.link.call("_acpmux/side", tag, CALL_TIMEOUT) {
                attachment.discard_side(&id);
                return Err(Refusal::of(error));
            }
            Ok(forked)
        }
        Op::Btw => {
            if through_seq.is_some() || live || session.is_some() || prompt_id.is_some() {
                return Err(Refusal::BadRequest);
            }
            let Some(question) =
                text.filter(|text| !text.trim().is_empty() && text.len() <= MAX_PROMPT_BYTES)
            else {
                return Err(Refusal::BadRequest);
            };
            attachment.side_room()?;
            // acpmux tags the side session, makes it read-only and asks it the question.
            let ask = json!({"sessionId": chat, "question": question});
            let started =
                attachment.link.call("_acpmux/btw", ask, BTW_TIMEOUT).map_err(Refusal::of)?;
            let id = answered_session(attachment, &started)?;
            attachment.note_side(&id);
            Ok(json!({"sessionId": id}))
        }
        Op::Prompt => {
            let (Some(side), Some(prompt_id), Some(text), None, false) =
                (session, prompt_id, text, through_seq, live)
            else {
                return Err(Refusal::BadRequest);
            };
            if !attachment.is_side(&side) {
                return Err(Refusal::BadRequest);
            }
            super::prompt(attachment, Some(&side), prompt_id, Some(text), None, false)
        }
        Op::Discard => {
            let (Some(side), None, None, None, false) =
                (session, prompt_id, text, through_seq, live)
            else {
                return Err(Refusal::BadRequest);
            };
            if !attachment.is_side(&side) {
                return Err(Refusal::BadRequest);
            }
            attachment.discard_side(&side);
            Ok(json!({}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn side_sessions_keep_the_newest_and_only_a_tagged_page_is_a_side_chat() {
        let known = SideSessions::default();
        for index in 0..=MAX_KNOWN {
            known.remember(&format!("acp_{index}"));
        }
        known.remember("");
        assert!(!known.contains("acp_0"));
        assert!(known.contains("acp_1"));
        assert!(known.contains(&format!("acp_{MAX_KNOWN}")));
        assert!(!known.contains(""));
        assert!(tagged(&json!({"session": {"tags": {"side": "acp_chat"}}})));
        assert!(!tagged(&json!({"session": {"tags": {"bead:cx-1": "1"}}})));
        assert!(!tagged(&json!({"session": {"sessionId": "acp_chat"}})));
    }
}
