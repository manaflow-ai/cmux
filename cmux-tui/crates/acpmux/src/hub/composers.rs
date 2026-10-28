//! Part of `Hub`; see `hub/mod.rs`. One chat typed into from several places at once
//! (cmuxterm-hq#2580 idea 2): the Mac app, a second Mac window, the iPhone app, the CLI.
//!
//! A *surface* is one place a person types, named by the client: `{id, name, kind?}`. Every
//! surface may send prompts; the hub's queue (`queue.rs`) already runs them one turn at a time,
//! in the order they reached the hub, so the queue stays the single source of truth. This module
//! adds what several writers need on top of it:
//!
//! - each surface keeps its own unsent text (`_acpmux/composer_set`), so two places typing do
//!   not overwrite each other's draft the way the one shared `_acpmux/draft_set` slot would;
//! - every attached client hears when a surface starts or stops composing, and which surface
//!   sent a prompt: a `composer` record `{surfaceId, name, kind?, client, composing, promptId?}`,
//!   written only when that changes (never per keystroke), and once the hub took a prompt (right
//!   after its `queued` or `user_message` record; a refused or duplicate prompt writes none);
//! - `_acpmux/composers` answers every surface's draft and the queue, each prompt labelled with
//!   the surface that sent it.
//!
//! A surface's name is what its client says (a label, never a right): `client` beside it is the
//! connection the hub saw. A client opts in by naming its surface (`_meta.acpmux.surface` on
//! `session/prompt`, and `composer_set`); one that never does sees nothing new. Drafts and the
//! queue's labels live in memory, so a restarted or moved chat shows its queue unlabelled; the
//! durable shared draft stays `_acpmux/draft_set`.

use super::*;
use std::collections::{BTreeMap, VecDeque};

/// Longest surface id or name, in characters.
pub const MAX_SURFACE_FIELD_CHARS: usize = 64;
/// Longest unsent text one surface keeps, in characters.
pub const MAX_SURFACE_DRAFT_CHARS: usize = 100_000;
/// Surfaces one chat keeps a draft for; the one typed into least recently goes first.
const MAX_SURFACES: usize = 16;
/// Sent prompts whose surface one chat remembers, for labelling the queue.
const SENT_LEDGER: usize = 64;

/// One place a person types into a chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Surface {
    pub id: String,
    pub name: String,
    pub kind: Option<String>,
}

impl Surface {
    fn record(&self) -> Value {
        let mut v = json!({"surfaceId": self.id, "name": self.name});
        if let Some(kind) = &self.kind {
            v["kind"] = json!(kind);
        }
        v
    }

    /// The `composer` record for it: who, through which connection, and whether it composes.
    fn composer(&self, client: &str, composing: bool) -> Value {
        let mut v = self.record();
        v["client"] = json!(client);
        v["composing"] = json!(composing);
        v
    }
}

/// A character a surface's id or name may not hold: a control, or an invisible format
/// character (a bidi override, a zero-width one) that could make a name read as another.
fn hidden(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{FEFF}')
        || ('\u{200B}'..='\u{200F}').contains(&c)
        || ('\u{202A}'..='\u{202E}').contains(&c)
        || ('\u{2060}'..='\u{206F}').contains(&c)
        || ('\u{FFF9}'..='\u{FFFB}').contains(&c)
}

/// One surface's unsent text.
#[derive(Debug, Clone)]
struct Draft {
    surface: Surface,
    text: String,
    updated_at: u64,
    /// When it was typed into, among this chat's drafts: orders them, unlike a clock.
    order: u64,
}

/// A chat's surfaces: who is typing what, and who sent the prompts still in play.
#[derive(Debug, Default)]
pub struct Composers {
    drafts: BTreeMap<String, Draft>,
    sent: VecDeque<(String, Surface)>,
    typed: u64,
}

impl Composers {
    fn sent_by(&self, prompt_id: &str) -> Option<&Surface> {
        self.sent.iter().rev().find(|(id, _)| id == prompt_id).map(|(_, s)| s)
    }
}

fn refusal(message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": "surface.invalid"}))
}

fn field(v: &Value, key: &str, required: bool) -> Result<Option<String>, RpcError> {
    let Some(raw) = v.get(key).filter(|x| !x.is_null()) else {
        return if required {
            Err(refusal(format!("surface.{key} is required")))
        } else {
            Ok(None)
        };
    };
    let s = raw.as_str().ok_or_else(|| refusal(format!("surface.{key} must be a string")))?;
    let s = s.trim();
    if s.is_empty() || s.chars().count() > MAX_SURFACE_FIELD_CHARS || s.chars().any(hidden) {
        return Err(refusal(format!(
            "surface.{key} must be one line of 1-{MAX_SURFACE_FIELD_CHARS} characters"
        )));
    }
    Ok(Some(s.to_owned()))
}

/// The surface `v` names (`{id, name, kind?}`), or None for a missing or null one.
pub fn surface(v: Option<&Value>) -> Result<Option<Surface>, RpcError> {
    let Some(v) = v.filter(|v| !v.is_null()) else { return Ok(None) };
    if !v.is_object() {
        return Err(refusal("surface must be an object {id, name, kind?}".into()));
    }
    Ok(Some(Surface {
        id: field(v, "id", true)?.unwrap_or_default(),
        name: field(v, "name", true)?.unwrap_or_default(),
        kind: field(v, "kind", false)?,
    }))
}

impl Hub {
    /// `_acpmux/composer_set {sessionId, surface, text}` from the connection `client`: the
    /// surface's unsent text. Whitespace clears it. Records `composer` when the surface starts or
    /// stops composing (or renames itself while it composes), so every client sees who is typing
    /// without a record per key. Answers only this surface's state; `_acpmux/composers` has all.
    pub fn composer_set(
        &self,
        session: &Session,
        surface: Surface,
        text: &str,
        client: &str,
    ) -> Result<Value, RpcError> {
        if text.chars().count() > MAX_SURFACE_DRAFT_CHARS {
            return Err(RpcError::invalid_params(format!(
                "a surface's draft exceeds {MAX_SURFACE_DRAFT_CHARS} characters"
            )));
        }
        if session.moving().is_some() {
            return Err(queue::moving_error());
        }
        let composing = !text.trim().is_empty();
        let (changed, evicted) = {
            let mut c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            let before = c.drafts.get(&surface.id).map(|d| d.surface.clone());
            let mut evicted = None;
            if composing {
                c.typed += 1;
                let draft = Draft {
                    surface: surface.clone(),
                    text: text.to_owned(),
                    updated_at: now_ms(),
                    order: c.typed,
                };
                c.drafts.insert(surface.id.clone(), draft);
                if c.drafts.len() > MAX_SURFACES
                    && let Some(oldest) =
                        c.drafts.values().min_by_key(|d| d.order).map(|d| d.surface.id.clone())
                {
                    evicted = c.drafts.remove(&oldest).map(|d| d.surface);
                }
            } else {
                c.drafts.remove(&surface.id);
            }
            (before.as_ref() != composing.then_some(&surface), evicted)
        };
        // A draft pushed out by too many surfaces stops composing as far as every client knows.
        if let Some(gone) = evicted {
            self.append(session, "mux", "composer", gone.composer(client, false));
        }
        if changed {
            self.append(session, "mux", "composer", surface.composer(client, composing));
        }
        Ok(json!({"sessionId": session.id, "surfaceId": surface.id, "composing": composing}))
    }

    /// The hub took a prompt a surface sent through the connection `client`
    /// (`_meta.acpmux.surface` on `session/prompt`; `accepted` is what `promptAccepted` carries):
    /// that surface's draft is sent, and a `composer` record says who sent it. A duplicate prompt
    /// id was labelled the first time.
    pub fn composer_accepted(
        &self,
        session: &Session,
        surface: Surface,
        client: &str,
        accepted: &Value,
    ) {
        if accepted.get("duplicate") == Some(&json!(true)) {
            return;
        }
        let Some(prompt_id) = accepted.get("promptId").and_then(Value::as_str) else { return };
        {
            let mut c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            c.drafts.remove(&surface.id);
            c.sent.push_back((prompt_id.to_owned(), surface.clone()));
            while c.sent.len() > SENT_LEDGER {
                c.sent.pop_front();
            }
        }
        let mut rec = surface.composer(client, false);
        rec["promptId"] = json!(prompt_id);
        self.append(session, "mux", "composer", rec);
    }
    /// `_acpmux/composers {sessionId}`: every surface's unsent text (latest first), the running
    /// turn and the queue in run order, each labelled with the surface that sent it when one did.
    pub fn composers_view(&self, session: &Session) -> Value {
        let c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
        let mut drafts: Vec<&Draft> = c.drafts.values().collect();
        drafts.sort_by_key(|d| std::cmp::Reverse(d.order));
        let composers: Vec<Value> = drafts
            .into_iter()
            .map(|d| {
                let mut v = d.surface.record();
                v["text"] = json!(d.text);
                v["updatedAt"] = json!(d.updated_at);
                v
            })
            .collect();
        let label = |prompt_id: &str| c.sent_by(prompt_id).map(Surface::record);
        let turn = session.turn().map(|t| {
            json!({"promptId": t.prompt_id, "turnId": t.turn_id, "client": t.client, "surface": label(&t.prompt_id)})
        });
        let queue: Vec<Value> = session
            .queue()
            .into_iter()
            .map(|q| {
                json!({
                    "promptId": q.prompt_id,
                    "turnId": q.turn_id,
                    "client": q.client,
                    "prompt": q.preview,
                    "queuedAt": q.queued_at,
                    "held": q.held,
                    "fromAgent": q.run.agent,
                    "author": crate::author::listed(q.run.provenance.as_ref()),
                    "surface": label(&q.prompt_id),
                })
            })
            .collect();
        json!({"sessionId": session.id, "composers": composers, "turn": turn, "queue": queue})
    }
}
