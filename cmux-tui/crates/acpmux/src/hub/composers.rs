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
//! queue's labels live in memory: a moved chat carries them in its bundle (`Composers::bundled`),
//! a restarted one shows its queue unlabelled; the durable shared draft stays `_acpmux/draft_set`.

use super::*;
use cmux_json::JsonSet as _;
use std::collections::{BTreeMap, VecDeque};

/// Longest surface id or name, in characters.
pub const MAX_SURFACE_FIELD_CHARS: usize = 64;
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
            v.set("kind", json!(kind));
        }
        v
    }

    /// It as `surface()` reads it back: `{id, name, kind?}`.
    fn record_in(&self) -> Value {
        let mut v = json!({"id": self.id, "name": self.name});
        if let Some(kind) = &self.kind {
            v.set("kind", json!(kind));
        }
        v
    }

    /// The `composer` record for it: who, through which connection, and whether it composes.
    fn composer(&self, client: &str, composing: bool) -> Value {
        let mut v = self.record();
        v.set("client", json!(client));
        v.set("composing", json!(composing));
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
    /// Whether any surface holds unsent text (whitespace clears a surface's draft).
    pub(in crate::hub) fn any_draft(&self) -> bool {
        !self.drafts.is_empty()
    }

    fn sent_by(&self, prompt_id: &str) -> Option<&Surface> {
        self.sent.iter().rev().find(|(id, _)| id == prompt_id).map(|(_, s)| s)
    }

    /// What a move carries (`transfer.rs`, [`BUNDLE_FILE`]): every surface's unsent text and
    /// who sent the prompts still queued, so the chat arrives with both, not blank and
    /// unlabelled. Leo: "moving sessions back and forth, the histories the pausing the images".
    pub(in crate::hub) fn bundled(&self) -> Value {
        let drafts: Vec<Value> = self
            .drafts
            .values()
            .map(|d| {
                json!({"surface": d.surface.record_in(), "text": d.text, "updatedAt": d.updated_at, "order": d.order})
            })
            .collect();
        let sent: Vec<Value> = self
            .sent
            .iter()
            .map(|(id, s)| json!({"promptId": id, "surface": s.record_in()}))
            .collect();
        json!({"drafts": drafts, "sent": sent})
    }

    /// Takes what [`Self::bundled`] wrote on the other machine. A bundle is a file another
    /// daemon wrote: each surface is checked as `composer_set` checks one, and a bad entry is
    /// dropped, never the move.
    pub(in crate::hub) fn restore(&mut self, v: &Value) {
        let list = |key: &str| v.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
        // The other machine's `order` only ranks the carried drafts among themselves: each gets
        // this chat's next number in that rank, so a bundle naming `u64::MAX` cannot leave the
        // counter where the next keystroke overflows it.
        let mut carried = Vec::new();
        for d in list("drafts") {
            let Ok(Some(surface)) = self::surface(d.get("surface")) else { continue };
            let Some(text) = d.get("text").and_then(Value::as_str) else { continue };
            if text.trim().is_empty() {
                continue;
            }
            let rank = d.get("order").and_then(Value::as_u64).unwrap_or(0);
            let updated_at = d.get("updatedAt").and_then(Value::as_u64).unwrap_or_else(now_ms);
            carried.push((rank, surface, text.to_owned(), updated_at));
        }
        carried.sort_by_key(|(rank, ..)| *rank);
        for (_, surface, text, updated_at) in carried {
            self.typed = self.typed.saturating_add(1);
            let draft = Draft { surface: surface.clone(), text, updated_at, order: self.typed };
            self.drafts.insert(surface.id, draft);
        }
        for s in list("sent") {
            let Ok(Some(surface)) = self::surface(s.get("surface")) else { continue };
            let Some(id) = s.get("promptId").and_then(Value::as_str) else { continue };
            self.sent.push_back((id.to_owned(), surface));
        }
        while self.sent.len() > SENT_LEDGER {
            self.sent.pop_front();
        }
    }
}

/// The file in a move's bundle that holds [`Composers::bundled`].
pub(in crate::hub) const BUNDLE_FILE: &str = "composers.json";

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
        if session.moving().is_some() {
            return Err(queue::moving_error(session));
        }
        let composing = !text.trim().is_empty();
        let changed = {
            let mut c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            let before = c.drafts.get(&surface.id).map(|d| d.surface.clone());
            if composing {
                c.typed = c.typed.saturating_add(1);
                let draft = Draft {
                    surface: surface.clone(),
                    text: text.to_owned(),
                    updated_at: now_ms(),
                    order: c.typed,
                };
                c.drafts.insert(surface.id.clone(), draft);
            } else {
                c.drafts.remove(&surface.id);
            }
            before.as_ref() != composing.then_some(&surface)
        };
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
        rec.set("promptId", json!(prompt_id));
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
                v.set("text", json!(d.text));
                v.set("updatedAt", json!(d.updated_at));
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
                let (from_session_id, from_harness) =
                    crate::prompt_provenance::sender_of(q.run.provenance.as_ref());
                json!({
                    "promptId": q.prompt_id,
                    "turnId": q.turn_id,
                    "client": q.client,
                    "prompt": q.preview,
                    "queuedAt": q.queued_at,
                    "held": q.held,
                    "awaitingOwner": q.awaiting_owner,
                    "revision": q.revision,
                    "fromAgent": q.run.agent,
                    "fromSessionId": from_session_id,
                    "fromHarness": from_harness,
                    "class": q.run.class,
                    "author": crate::author::listed(q.run.provenance.as_ref()),
                    "subagentRetry": super::subagent_retry::listed(q.run.provenance.as_ref()),
                    "provenance": super::digest::listed_provenance(q.run.provenance.as_ref(), q.run.agent.as_deref()),
                    "surface": label(&q.prompt_id),
                })
            })
            .collect();
        json!({"sessionId": session.id, "composers": composers, "turn": turn, "queue": queue})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bundle_carries_every_surfaces_draft_and_drops_what_composer_set_would_refuse() {
        let mut c = Composers::default();
        let phone = Surface { id: "phone".into(), name: "iPhone".into(), kind: Some("ios".into()) };
        let mac = Surface { id: "mac".into(), name: "Mac".into(), kind: None };
        for (order, (s, text)) in [(&mac, "first"), (&phone, "second")].into_iter().enumerate() {
            let draft = Draft {
                surface: s.clone(),
                text: text.into(),
                updated_at: 7,
                order: order as u64 + 1,
            };
            c.drafts.insert(s.id.clone(), draft);
        }
        c.sent.push_back(("p-1".into(), phone.clone()));
        let mut bundled = c.bundled();
        // Another daemon wrote it: a hidden character, a blank draft and a missing id are dropped.
        bundled["drafts"].as_array_mut().unwrap().extend([
            json!({"surface": {"id": "x\u{202E}", "name": "spoof"}, "text": "t", "order": 9}),
            json!({"surface": {"id": "blank", "name": "Blank"}, "text": "  ", "order": 9}),
        ]);
        bundled["sent"]
            .as_array_mut()
            .unwrap()
            .push(json!({"surface": {"id": "mac", "name": "Mac"}}));

        let mut back = Composers::default();
        back.restore(&bundled);
        let mut ids: Vec<_> = back.drafts.keys().cloned().collect();
        ids.sort();
        assert_eq!(ids, ["mac", "phone"]);
        assert_eq!(back.drafts["phone"].surface, phone);
        assert_eq!(back.drafts["mac"].text, "first");
        assert_eq!(back.typed, 2, "the next draft typed here orders after the carried ones");
        assert_eq!(back.sent_by("p-1"), Some(&phone));
        assert_eq!(back.sent.len(), 1);
    }

    #[test]
    fn a_bundles_draft_order_only_ranks_the_drafts_it_carries() {
        let draft = |id: &str, order: u64| json!({"surface": {"id": id, "name": id}, "text": "t", "order": order});
        let bundled = json!({"drafts": [draft("late", u64::MAX), draft("early", 3)]});
        let mut back = Composers { typed: 5, ..Composers::default() };
        back.restore(&bundled);
        assert_eq!(back.drafts["early"].order, 6, "numbered on from this chat's own count");
        assert_eq!(back.drafts["late"].order, 7, "in the order the other machine typed them");
        assert_eq!(back.typed, 7, "the next keystroke has a number left to take");
    }
}
