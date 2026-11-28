//! Part of `Hub`; see `hub/mod.rs`. One chat typed into from several places at once
//! (cmuxterm-hq#2580 idea 2): the Mac app, a second Mac window, the iPhone app, the CLI.
//!
//! A *surface* is one place a person types, named by the client: `{id, name, kind?}`. Every
//! surface may send prompts; the hub's queue (`queue.rs`) already runs them one turn at a time,
//! in the order they reached the hub, so the queue stays the single source of truth. This module
//! adds what several writers need on top of it:
//!
//! - each surface keeps its own unsent text (`_acpmux/composer_set`), so two places typing do
//!   not overwrite each other's draft the way the one shared `_acpmux/draft_set` slot would,
//!   and the images it holds unsent (`images`, kept by content hash as a prompt's are), so a
//!   moved chat's composer arrives with them (RFD 0138, "Attachments pending in the composer");
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
/// Most images one surface's unsent draft holds.
pub const MAX_DRAFT_IMAGES: usize = 32;
const MAX_IMAGE_NAME_CHARS: usize = 256;
const MAX_IMAGE_MIME_CHARS: usize = 128;

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

/// One surface's unsent text, and the images it holds unsent.
#[derive(Debug, Clone)]
struct Draft {
    surface: Surface,
    text: String,
    /// Each as a prompt's record names it: `{id, mimeType, name?, width?, height?}`, its bytes
    /// kept under `attachments/` by the SHA-256 that is its id (`prompt_images.rs`).
    images: Vec<Value>,
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

    /// The ids of the images every surface's draft holds: a move bundles them (`transfer.rs`).
    pub(in crate::hub) fn image_ids(&self) -> Vec<String> {
        self.drafts.values().flat_map(|d| d.images.iter()).filter_map(image_id).collect()
    }

    /// The record of image `id` in a surface's draft, when one holds it.
    fn draft_image(&self, id: &str) -> Option<&Value> {
        self.drafts
            .values()
            .flat_map(|d| d.images.iter())
            .find(|image| image_id(image).as_deref() == Some(id))
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
                let mut v = json!({"surface": d.surface.record_in(), "text": d.text, "updatedAt": d.updated_at, "order": d.order});
                // Only when it holds one: a bundle without images reads as before.
                if !d.images.is_empty() {
                    v.set("images", json!(d.images));
                }
                v
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
    /// dropped, never the move. A draft's image is kept only when this machine holds its bytes
    /// (the move's `restore_images` ran first and kept each whose bytes hash to its name).
    pub(in crate::hub) fn restore(&mut self, v: &Value) {
        let list = |key: &str| v.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
        // The other machine's `order` only ranks the carried drafts among themselves: each gets
        // this chat's next number in that rank, so a bundle naming `u64::MAX` cannot leave the
        // counter where the next keystroke overflows it.
        let mut carried = Vec::new();
        for d in list("drafts") {
            let Ok(Some(surface)) = self::surface(d.get("surface")) else { continue };
            let Some(text) = d.get("text").and_then(Value::as_str) else { continue };
            let images: Vec<Value> = d
                .get("images")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(carried_image)
                .filter(|image| {
                    image_id(image)
                        .and_then(|id| super::prompt_images::image_path(&id))
                        .is_some_and(|path| path.is_file())
                })
                .take(MAX_DRAFT_IMAGES)
                .collect();
            if text.trim().is_empty() && images.is_empty() {
                continue;
            }
            let rank = d.get("order").and_then(Value::as_u64).unwrap_or(0);
            let updated_at = d.get("updatedAt").and_then(Value::as_u64).unwrap_or_else(now_ms);
            carried.push((rank, surface, text.to_owned(), images, updated_at));
        }
        carried.sort_by_key(|(rank, ..)| *rank);
        for (_, surface, text, images, updated_at) in carried {
            self.typed = self.typed.saturating_add(1);
            let draft =
                Draft { surface: surface.clone(), text, images, updated_at, order: self.typed };
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

/// The id of a draft image's record.
fn image_id(image: &Value) -> Option<String> {
    let id = image.get("id")?.as_str()?;
    super::prompt_images::valid_id(id).then(|| id.to_owned())
}

/// A draft image's record as another daemon wrote it, keeping only what a record names
/// (`{id, mimeType, name?, width?, height?}`), each field checked; None for one with no valid id.
fn carried_image(raw: &Value) -> Option<Value> {
    let id = image_id(raw)?;
    let short = |key: &str, max: usize| {
        raw.get(key).and_then(Value::as_str).filter(|s| !s.is_empty() && s.chars().count() <= max)
    };
    let mime = short("mimeType", MAX_IMAGE_MIME_CHARS).unwrap_or("image/png");
    let mut v = json!({"id": id, "mimeType": mime});
    if let Some(name) = short("name", MAX_IMAGE_NAME_CHARS) {
        v.set("name", json!(name));
    }
    for key in ["width", "height"] {
        if let Some(n) = raw.get(key).and_then(Value::as_u64) {
            v.set(key, json!(n));
        }
    }
    Some(v)
}

fn image_refusal(message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": "composer.image.invalid"}))
}

/// The images `_acpmux/composer_set` names (`images`, optional; missing or null is none). Each is
/// an ACP `image` block (`{type: "image", mimeType, data, name?}`), kept by the SHA-256 of its
/// bytes under `attachments/` as `session/prompt` keeps one, or `{id}` of an image a draft of
/// this chat already holds, so a client sending its draft again need not send the bytes again.
/// `held` is what this chat's drafts hold now. Answers each as a prompt's record names it.
fn draft_images(raw: Option<&Value>, held: &[Value]) -> Result<Vec<Value>, RpcError> {
    let Some(raw) = raw.filter(|v| !v.is_null()) else { return Ok(Vec::new()) };
    let list = raw.as_array().ok_or_else(|| image_refusal("images must be an array".into()))?;
    if list.len() > MAX_DRAFT_IMAGES {
        return Err(image_refusal(format!("a draft holds at most {MAX_DRAFT_IMAGES} images")));
    }
    let mut out = Vec::with_capacity(list.len());
    for item in list {
        if item.get("type").and_then(Value::as_str) == Some("image") {
            if super::prompt_images::id_of(item).is_none() {
                return Err(image_refusal("an image block's data must be base64".into()));
            }
            let kept = super::prompt_images::keep_sourced(std::slice::from_ref(item), None);
            let kept = kept.into_iter().next().ok_or_else(|| {
                RpcError::internal("could not keep the image")
                    .with_data(json!({"reason": "composer.image.unkept"}))
            })?;
            out.push(kept);
            continue;
        }
        let id = image_id(item).ok_or_else(|| {
            image_refusal(
                "each image is an image block or {id} of one this chat's drafts hold".into(),
            )
        })?;
        let known = held.iter().find(|h| image_id(h).as_deref() == Some(id.as_str()));
        let known = known
            .filter(|_| super::prompt_images::image_path(&id).is_some_and(|p| p.is_file()))
            .ok_or_else(|| {
                RpcError::invalid_params(format!(
                    "no image {id} in this chat's drafts: send its bytes"
                ))
                .with_data(json!({"reason": "composer.image.unknown", "id": id}))
            })?;
        out.push(known.clone());
    }
    Ok(out)
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
    /// `_acpmux/composer_set {sessionId, surface, text, images?}` from the connection `client`:
    /// the surface's unsent text and the images it holds unsent (`draft_images`; a request
    /// without `images` holds none). Whitespace and no image clears it. Records `composer` when the surface starts or
    /// stops composing (or renames itself while it composes), so every client sees who is typing
    /// without a record per key. Answers only this surface's state; `_acpmux/composers` has all.
    pub fn composer_set(
        &self,
        session: &Session,
        surface: Surface,
        text: &str,
        images: Option<&Value>,
        client: &str,
    ) -> Result<Value, RpcError> {
        if session.moving().is_some() {
            return Err(queue::moving_error(session));
        }
        let held: Vec<Value> = {
            let c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            c.drafts.values().flat_map(|d| d.images.iter().cloned()).collect()
        };
        // Kept before the lock: a large image is written to disk.
        let images = draft_images(images, &held)?;
        let composing = !text.trim().is_empty() || !images.is_empty();
        let changed = {
            let mut c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            let before = c.drafts.get(&surface.id).map(|d| d.surface.clone());
            if composing {
                c.typed = c.typed.saturating_add(1);
                let draft = Draft {
                    surface: surface.clone(),
                    text: text.to_owned(),
                    images: images.clone(),
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
        let mut answer =
            json!({"sessionId": session.id, "surfaceId": surface.id, "composing": composing});
        if composing && !images.is_empty() {
            answer.set("images", json!(images));
        }
        Ok(answer)
    }

    /// `_acpmux/attachment` for an image a surface's unsent draft holds, as `{mimeType, data}`
    /// (base64), like a sent prompt's (`prompt_images.rs` `prompt_image`); None when no draft of
    /// this chat holds `id` or its bytes are gone.
    pub fn composer_image(&self, session: &Session, id: &str) -> Option<Value> {
        use base64::Engine;
        let named = {
            let c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            c.draft_image(id).cloned()?
        };
        let bytes = std::fs::read(super::prompt_images::image_path(id)?).ok()?;
        let mime = super::prompt_images::sniffed_type(&bytes)
            .map(|known| json!(known))
            .or_else(|| named.get("mimeType").cloned())
            .unwrap_or_else(|| json!("image/png"));
        Some(json!({
            "mimeType": mime,
            "data": base64::engine::general_purpose::STANDARD.encode(bytes),
        }))
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
                if !d.images.is_empty() {
                    v.set("images", json!(d.images));
                }
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
#[path = "composers_tests.rs"]
mod tests;
