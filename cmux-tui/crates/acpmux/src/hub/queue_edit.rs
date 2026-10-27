//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/queue_edit`: change a queued prompt before its
//! turn (`update` its prompt, or its text, which keeps its images; `move` it, `send_now` or
//! `interrupt`), or `resume` the prompts a failed turn holds (`queue.rs` `pause_queue`; any of
//! the queue's prompts names it), or `withdraw` a steer the agent has not read yet. Every change is a record in the log, so a new daemon rebuilds
//! the edited queue (`queue.rs` `restore_queues`), and every client sees it.
//!
//! In a chat several people share (`author.rs`), only the person who sent a prompt changes it or
//! takes it back (`author::may_change`, under the lock that changes it), `_acpmux/queue_remove` included: anyone else gets
//! `queue.not_author`. No author is the owner, and an agent's message counts as the owner's.

use super::queue::PromptRun;
use super::*;
use std::sync::atomic::Ordering;

/// How long Send now waits for the agent to stop its step for a steer.
const STEP_NOW_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

// `_acpmux/prompt_withdraw`, a queue change too (here: `hub/mod.rs` is at its size budget).
#[path = "withdraw.rs"]
mod withdraw;

/// The Full-access machine an edited prompt keeps (`PromptRun::full_access_device`): its own,
/// only when the edit comes from that same machine.
fn same_device(run: Option<&str>, editor: Option<&str>) -> Option<String> {
    run.filter(|d| editor == Some(*d)).map(str::to_owned)
}

/// The stricter of two controls: an edit never runs a prompt under looser rules than either
/// the prompt's sender's or the editor's.
fn stricter(a: Control, b: Control) -> Control {
    match (a, b) {
        (Control::Web, _) | (_, Control::Web) => Control::Web,
        (Control::Peer, _) | (_, Control::Peer) => Control::Peer,
        _ => Control::Local,
    }
}

/// What an `update` puts in a waiting prompt.
enum Edit {
    /// `prompt`: these blocks, all of it.
    Prompt(Vec<Value>),
    /// `text`: new words. The prompt keeps its other blocks (its images and files) after them,
    /// in their order (Leo, 2026-10-21: an edit dropped the screenshot); with `images` (ids, as
    /// the queue lists them) only the images it names.
    Text { text: String, images: Option<Vec<String>> },
}

impl Edit {
    fn parse(params: &Value) -> Result<Self, RpcError> {
        if let Some(blocks) = params.get("prompt").and_then(Value::as_array) {
            // Files come with a message (`attach.rs`), never with an edit of one.
            if crate::attach::any(blocks) || crate::prompt_uploads::any(blocks) {
                return Err(RpcError::invalid_params(
                    "an edit cannot attach files: send them with a message (acpmux send --attach)",
                )
                .with_data(serde_json::json!({"reason": "attach.edit"})));
            }
            return Ok(Self::Prompt(blocks.clone()));
        }
        let text = params
            .get("text")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("update needs prompt or text"))?;
        let images = match params.get("images") {
            None | Some(Value::Null) => None,
            Some(Value::Array(ids)) => Some(
                ids.iter()
                    .map(|id| id.as_str().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(|| RpcError::invalid_params("images must be image ids"))?,
            ),
            Some(_) => return Err(RpcError::invalid_params("images must be image ids")),
        };
        Ok(Self::Text { text: text.to_owned(), images })
    }

    /// The blocks the waiting prompt `before` runs once edited, and for each the index of the
    /// block of `before` it is (`None`: a new block). A `prompt` edit's blocks are all new: the
    /// client wrote them, so none is known to be one of `before`.
    fn blocks(self, before: &[Value]) -> (Vec<Value>, Vec<Option<usize>>) {
        let (text, images) = match self {
            Self::Prompt(blocks) => {
                let origin = vec![None; blocks.len()];
                return (blocks, origin);
            }
            Self::Text { text, images } => (text, images),
        };
        let kept: Vec<usize> = before
            .iter()
            .enumerate()
            .filter(|(_, block)| {
                if block.get("type").and_then(Value::as_str) == Some("text") {
                    return false;
                }
                let Some(ids) = &images else { return true };
                match super::prompt_images::id_of(block) {
                    Some(id) => ids.contains(&id),
                    // Not an image (or not one it can name): it stays.
                    None => true,
                }
            })
            .map(|(i, _)| i)
            .collect();
        let blocks = std::iter::once(json!({"type": "text", "text": text}))
            .chain(kept.iter().map(|&i| before[i].clone()))
            .collect();
        (blocks, std::iter::once(None).chain(kept.into_iter().map(Some)).collect())
    }
}

/// A waiting prompt's display metadata (`PromptRun::display_parts`) once an edit moved its blocks
/// (`origin`, `Edit::blocks`): each part follows its own block to where it is now, and a
/// companion (`companionOf`, the original file of an image) follows its image. A part whose block
/// or image the edit did not keep is dropped, never put on another block; the count of those is
/// returned with it. No part is matched by its name.
fn moved_display_parts(parts: Option<&Value>, origin: &[Option<usize>]) -> (Option<Value>, usize) {
    let Some(Value::Array(parts)) = parts else { return (None, 0) };
    let now: HashMap<u64, u64> = origin
        .iter()
        .enumerate()
        .filter_map(|(new, old)| Some(((*old)? as u64, new as u64)))
        .collect();
    let mut dropped = 0;
    let kept: Vec<Value> = parts
        .iter()
        .filter_map(|part| {
            // `None`: it names no such block; `Some(None)`: the edit did not keep that block.
            let index =
                |key: &str| part.get(key).map(|v| v.as_u64().and_then(|i| now.get(&i).copied()));
            let (at, of) = (index("blockIndex"), index("companionOf"));
            let (Some(Some(at)), Some(mut fields)) = (at, part.as_object().cloned()) else {
                dropped += 1;
                return None;
            };
            if of == Some(None) {
                dropped += 1;
                return None;
            }
            fields.insert("blockIndex".into(), json!(at));
            if let Some(Some(of)) = of {
                fields.insert("companionOf".into(), json!(of));
            }
            Some(Value::Object(fields))
        })
        .collect();
    ((!kept.is_empty()).then_some(Value::Array(kept)), dropped)
}

/// `parts` as the daemon keeps a prompt's display metadata (`server/requests.rs`): only what
/// `validated_display_parts` accepts for `blocks` (a `companionOf` only where it names its own
/// image), one part a block, in block order. A record restored from the log holds whatever was
/// written there, so an edit keeps nothing of it unchecked. Answers the count it refused too.
fn checked_display_parts(parts: Option<&Value>, blocks: &[Value]) -> (Option<Value>, usize) {
    let given = parts.and_then(Value::as_array).map_or(0, Vec::len);
    let mut valid: Vec<_> =
        super::prompt_images::validated_display_parts(parts, blocks).into_iter().collect();
    valid.sort_by_key(|(index, _)| *index);
    let refused = given.saturating_sub(valid.len());
    let valid: Vec<Value> = valid
        .into_iter()
        .map(|(index, mut part)| {
            part["blockIndex"] = json!(index);
            part
        })
        .collect();
    ((!valid.is_empty()).then_some(Value::Array(valid)), refused)
}

impl Hub {
    /// `_acpmux/queue_edit {sessionId, promptId, op, prompt?|text?, images?, index?}`. Answers
    /// `{sessionId, promptId, op, ok}`, and `send_now` and `interrupt` also how it was sent
    /// (`sent`: `steer`, `interrupt` or `next`). `ok` is false when the prompt no longer waits.
    pub async fn queue_edit(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: &Value,
        control: Control,
        trust_gate: bool,
        device: Option<&str>,
    ) -> Result<Value, RpcError> {
        let prompt_id = params
            .get("promptId")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
            .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
        let op = params.get("op").and_then(Value::as_str).unwrap_or_default();
        // A chat in Full access by a machine's setting: that machine only (`full_access_hold`).
        self.full_access_hold(&session.meta(), control, device)?;
        // The queue moves as it is (`transfer_out.rs`).
        if session.moving().is_some() {
            return Err(super::queue::moving_error());
        }
        // Only its sender changes a prompt (`author.rs`), checked under the lock that changes it;
        // `resume` changes no one prompt.
        let author = crate::author::author(params)?;
        let editor = crate::author::editor(author.as_ref());
        let mut reply = json!({"sessionId": session.id, "promptId": prompt_id, "op": op});
        reply["ok"] = match op {
            "update" => {
                let edit = Edit::parse(params)?;
                let updated = self
                    .update_queued(session, prompt_id, edit, control, trust_gate, device, editor)?;
                json!(updated)
            }
            "move" => {
                let index = params
                    .get("index")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| RpcError::invalid_params("move needs index"))?;
                json!(self.move_queued(session, prompt_id, index as usize, editor)?)
            }
            "send_now" => {
                let sent =
                    match self.send_queued_now(session, prompt_id, control, device, editor)? {
                        Some(sent) => Some(sent),
                        None => self.step_now(session, prompt_id, control, device, editor).await?,
                    };
                reply["sent"] = json!(sent);
                json!(sent.is_some())
            }
            "interrupt" => {
                let sent = self.interrupt_for_queued(session, prompt_id, editor).await?;
                reply["sent"] = json!(sent);
                json!(sent.is_some())
            }
            "resume" => json!(self.resume_queue(session)),
            "withdraw" => json!(self.withdraw_steer(session, prompt_id, control, editor).await?),
            _ => {
                let e = "op must be update, move, send_now, interrupt, resume or withdraw";
                return Err(RpcError::invalid_params(e));
            }
        };
        Ok(reply)
    }

    /// Whether a waiting prompt holds a secret (`secret_scan`). A peer reads it
    /// masked (`server/peer_text.rs`), so it may not rewrite it: an edit from
    /// the masked text would write the mask over the secret.
    pub fn queued_holds_secret(&self, session: &Session, prompt_id: &str) -> bool {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue
            .iter()
            .find(|q| q.prompt_id == prompt_id)
            .is_some_and(|q| !crate::secret_scan::find(&prompt_text(&q.run.blocks)).is_empty())
    }

    /// Replaces a waiting prompt's content (`Edit`); it keeps its place. It runs under the
    /// stricter rules of its sender and its editor. Only its sender edits it (`editor`,
    /// `author.rs`), and a person's prompt edited by that person is still theirs.
    fn update_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        edit: Edit,
        control: Control,
        trust_gate: bool,
        device: Option<&str>,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        let (turn_id, run, text) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(q) = queue.iter_mut().find(|q| q.prompt_id == prompt_id) else {
                return Ok(false);
            };
            crate::author::may_change(editor, q.sender())?;
            let (mut blocks, origin) = edit.blocks(&q.run.blocks);
            // Only `session/prompt` adds a hidden context (prompt_context.rs).
            crate::prompt_context::strip_marks(&mut blocks);
            let text = prompt_text(&blocks);
            // Its images keep their names and their original files (`moved_display_parts`),
            // checked again against the blocks they name now.
            let (moved, dropped) = moved_display_parts(q.run.display_parts.as_ref(), &origin);
            let (display_parts, refused) = checked_display_parts(moved.as_ref(), &blocks);
            if dropped + refused > 0 {
                tracing::info!(session = %session.id, prompt = %prompt_id, dropped, refused, "a queue edit dropped display parts of blocks it did not keep or that no longer fit them");
            }
            q.run = Arc::new(PromptRun {
                blocks,
                display_parts,
                control: stricter(q.run.control, control),
                trust_gate: q.run.trust_gate || trust_gate,
                // The person rewrote it: it is no longer the sender's message, unless the sender
                // is that person.
                provenance: q.run.provenance.clone().filter(|p| {
                    crate::author::of_provenance(Some(p)).is_some_and(|id| editor == Some(Some(id)))
                }),
                agent: None,
                supersede: None,
                full_access_device: same_device(q.run.full_access_device.as_deref(), device),
            });
            q.preview = short_text(&text, 200);
            (q.turn_id.clone(), q.run.clone(), text)
        };
        let mut msg = json!({"promptId": prompt_id, "turnId": turn_id, "text": text, "prompt": run.blocks, "control": run.control.as_str(), "trustGate": run.trust_gate});
        // Its images, kept and named as `queued` names them (`prompt_images.rs`).
        let images = super::prompt_images::keep(&run.blocks);
        if !images.is_empty() {
            msg["images"] = Value::Array(images);
        }
        let inline_parts = super::prompt_images::inline_parts(
            &run.blocks,
            msg.get("images").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default(),
            run.display_parts.as_ref(),
        );
        if !inline_parts.is_empty() {
            msg["inlineParts"] = Value::Array(inline_parts);
        }
        if let Some(display_parts) = &run.display_parts {
            msg["displayParts"] = display_parts.clone();
        }
        super::session::mark_pasted(&mut msg, &run.blocks);
        let msg = crate::prompt_provenance::marked(msg, run.provenance.as_ref());
        self.append(session, "mux", "queue_updated", msg);
        Ok(true)
    }

    /// Moves a waiting prompt to `index` (0 is next); the queue's order is what runs. Only its
    /// sender moves it (`editor`, `author.rs`).
    pub(super) fn move_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        index: usize,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        let order: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(from) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return Ok(false);
            };
            crate::author::may_change(editor, queue[from].sender())?;
            let q = queue.remove(from);
            let to = index.min(queue.len());
            queue.insert(to, q);
            queue.iter().map(|q| q.prompt_id.clone()).collect()
        };
        session.queue_moved.notify_waiters();
        self.append(session, "mux", "queue_order", json!({"promptId": prompt_id, "order": order}));
        Ok(true)
    }

    /// Sends a waiting prompt now. Into a running turn of an agent that steers it is steered in
    /// (`steer`) by the task that waits with it, so its `session/prompt` answers how it ran, and
    /// the agent's current step stops so it reads it at once (Claude Code; another agent reads it
    /// when its step ends); otherwise it goes next (`next`) and runs once the turn ends. It never
    /// stops the turn: `interrupt` does. `None` when it no longer waits. A failed turn no longer
    /// holds it.
    fn send_queued_now(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        control: Control,
        device: Option<&str>,
        editor: crate::author::Editor<'_>,
    ) -> Result<Option<&'static str>, RpcError> {
        if session.turn().is_some() && session.steering.load(Ordering::SeqCst) {
            let Some(waiting) = session.queue().into_iter().find(|q| q.prompt_id == prompt_id)
            else {
                return Ok(None);
            };
            // The steer runs under the stricter rules of the prompt and of who sent it now.
            let control = stricter(waiting.run.control, control);
            let device = same_device(waiting.run.full_access_device.as_deref(), device);
            self.check_steer(session, control, device.as_deref())?;
            {
                let mut queue =
                    session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let Some(q) = queue.iter_mut().find(|q| q.prompt_id == prompt_id) else {
                    return Ok(None);
                };
                crate::author::may_change(editor, q.sender())?;
                let run = PromptRun {
                    blocks: q.run.blocks.clone(),
                    display_parts: q.run.display_parts.clone(),
                    control,
                    trust_gate: q.run.trust_gate,
                    provenance: q.run.provenance.clone(),
                    agent: q.run.agent.clone(),
                    supersede: q.run.supersede.clone(),
                    full_access_device: device,
                };
                (q.run, q.steer) = (Arc::new(run), true);
            }
            let mut now =
                session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            now.step.insert(prompt_id.to_owned());
            drop(now);
            session.queue_moved.notify_waiters();
            return Ok(Some("steer"));
        }
        Ok(self.put_next(session, prompt_id, editor)?.then_some("next"))
    }

    /// `interrupt`: a waiting prompt goes next and the running turn stops, whether or not its
    /// agent could take the prompt as a steer (`next` with no turn running). `None` when it no
    /// longer waits.
    async fn interrupt_for_queued(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        editor: crate::author::Editor<'_>,
    ) -> Result<Option<&'static str>, RpcError> {
        let running = session.turn().map(|t| t.turn_id);
        if !self.put_next(session, prompt_id, editor)? {
            return Ok(None);
        }
        let Some(running) = running else {
            return Ok(Some("next"));
        };
        self.cancel_turn(session, &running).await;
        Ok(Some("interrupt"))
    }

    /// Send now on a steer the agent has not read yet (`steer_end.rs`): the agent's current step
    /// stops so it reads the steer at once, and the turn runs on (`now`). An agent that cannot
    /// stop one step reads it when the step ends (`steer`). `None` when no steer of that id waits.
    async fn step_now(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        control: Control,
        device: Option<&str>,
        editor: crate::author::Editor<'_>,
    ) -> Result<Option<&'static str>, RpcError> {
        let waiting = session
            .steer_now
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .waiting
            .get(prompt_id)
            .map(|sender| crate::author::may_change(editor, sender.as_deref()));
        let Some(mine) = waiting else {
            return Ok(None);
        };
        mine?;
        self.check_steer(session, control, device)?;
        let child = session.child.lock().await.clone();
        let (Some(child), Some(sid)) = (child, session.meta().agent_session_id) else {
            return Ok(Some("steer"));
        };
        let ask = child.request(method::MUX_STEP_NOW, json!({"sessionId": sid}));
        let answer = tokio::time::timeout(STEP_NOW_WAIT, ask).await;
        let stopped = matches!(&answer, Ok(Ok(v)) if v["interrupted"] == true);
        Ok(Some(if stopped { "now" } else { "steer" }))
    }

    /// `withdraw`: takes back a steer the agent has not read yet (the X on its row), so the
    /// person can edit it. The agent drops it from its queue (Claude Code's
    /// `cancel_async_message`, `MUX_STEER_WITHDRAW`), and the steer's `session/prompt` records
    /// `steer_withdrawn` (`steer_end.rs`). False once the agent read it, or when its agent cannot
    /// take one back.
    async fn withdraw_steer(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        control: Control,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        let waiting = session
            .steer_now
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .waiting
            .get(prompt_id)
            .map(|sender| crate::author::may_change(editor, sender.as_deref()));
        let Some(mine) = waiting else {
            return Ok(false);
        };
        mine?;
        // Who may steer may take one back; taking it back raises no turn's control.
        self.web_control_check(session, control)?;
        let child = session.child.lock().await.clone();
        let (Some(child), Some(sid)) = (child, session.meta().agent_session_id) else {
            return Ok(false);
        };
        // No timeout: the drop is already on its way, so only the agent's answer (or its end)
        // says whether the steer was taken back.
        let params = json!({"sessionId": sid, "promptId": prompt_id});
        let answer = child.request(method::MUX_STEER_WITHDRAW, params).await;
        Ok(matches!(&answer, Ok(v) if v["withdrawn"] == true))
    }
}

#[cfg(test)]
mod tests {
    use super::{Edit, checked_display_parts, moved_display_parts};
    use serde_json::{Value, json};

    /// Image bytes `bytes` as an ACP image block, and its attachment id.
    fn image(bytes: &[u8], name: &str) -> (Value, String) {
        use base64::Engine;
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        let block = json!({"type": "image", "mimeType": "image/png", "data": data, "name": name});
        let id = super::super::prompt_images::id_of(&block).expect("an image id");
        (block, id)
    }

    fn link(name: &str) -> Value {
        json!({"type": "resource_link", "uri": format!("file:///originals/{name}"), "name": name})
    }

    /// A text edit moves every block after the new text: each image keeps its display part and
    /// its original file (`companionOf`) still names it, at its new place.
    #[test]
    fn a_text_edit_moves_display_parts_with_their_blocks() {
        let (a, _) = image(b"first", "a.png");
        let (b, _) = image(b"second", "b.png");
        let before = vec![
            a,
            link("a.png"),
            json!({"type": "text", "text": "look at these"}),
            b,
            link("b.png"),
        ];
        let parts = json!([
            {"kind": "image", "blockIndex": 0, "name": "Screenshot A.png"},
            {"kind": "file", "blockIndex": 1, "name": "a.png", "companionOf": 0},
            {"kind": "pasted", "blockIndex": 2, "start": 0, "end": 4},
            {"kind": "image", "blockIndex": 3, "name": "Screenshot B.png"},
            {"kind": "file", "blockIndex": 4, "name": "b.png", "companionOf": 3}
        ]);
        let edit = Edit::Text { text: "look again".into(), images: None };
        let (blocks, origin) = edit.blocks(&before);
        assert_eq!(origin, [None, Some(0), Some(1), Some(3), Some(4)]);
        let (moved, dropped) = moved_display_parts(Some(&parts), &origin);
        // The pasted range named the old words, which the edit replaced.
        assert_eq!(dropped, 1);
        assert_eq!(
            moved,
            Some(json!([
                {"kind": "image", "blockIndex": 1, "name": "Screenshot A.png"},
                {"kind": "file", "blockIndex": 2, "name": "a.png", "companionOf": 1},
                {"kind": "image", "blockIndex": 3, "name": "Screenshot B.png"},
                {"kind": "file", "blockIndex": 4, "name": "b.png", "companionOf": 3}
            ]))
        );
        let moved = moved.unwrap();
        for part in moved.as_array().unwrap() {
            let at = part["blockIndex"].as_u64().unwrap() as usize;
            let was = origin[at].unwrap();
            assert_eq!(blocks[at], before[was], "{part} is on another block");
        }
    }

    /// An edit that keeps one image only: the other's part and its original file's relation are
    /// dropped, never moved onto the image that stays (both are named like it).
    #[test]
    fn a_dropped_image_takes_its_display_parts_with_it() {
        let (a, _) = image(b"first", "shot.png");
        let (b, b_id) = image(b"second", "shot.png");
        let before = vec![a, link("shot.png"), b, link("shot.png")];
        let parts = json!([
            {"kind": "image", "blockIndex": 0, "name": "shot.png"},
            {"kind": "file", "blockIndex": 1, "name": "shot.png", "companionOf": 0},
            {"kind": "image", "blockIndex": 2, "name": "shot.png"},
            {"kind": "file", "blockIndex": 3, "name": "shot.png", "companionOf": 2}
        ]);
        let edit = Edit::Text { text: "the second".into(), images: Some(vec![b_id]) };
        let (blocks, origin) = edit.blocks(&before);
        assert_eq!(origin, [None, Some(1), Some(2), Some(3)]);
        assert_eq!(blocks.len(), 4);
        let (moved, dropped) = moved_display_parts(Some(&parts), &origin);
        assert_eq!(dropped, 2);
        assert_eq!(
            moved,
            Some(json!([
                {"kind": "image", "blockIndex": 2, "name": "shot.png"},
                {"kind": "file", "blockIndex": 3, "name": "shot.png", "companionOf": 2}
            ]))
        );
    }

    /// A whole new prompt names none of the old blocks, and a part that is not one is dropped.
    #[test]
    fn a_prompt_edit_and_a_malformed_part_keep_nothing() {
        let (a, _) = image(b"first", "a.png");
        let parts = json!([{"kind": "image", "blockIndex": 0, "name": "a.png"}]);
        let edit = Edit::Prompt(vec![a.clone()]);
        let (_, origin) = edit.blocks(std::slice::from_ref(&a));
        assert_eq!(moved_display_parts(Some(&parts), &origin), (None, 1));
        let origin = [None, Some(0)];
        let bad = json!([
            "image",
            {"kind": "image"},
            {"kind": "image", "blockIndex": "0"},
            {"kind": "file", "blockIndex": 0, "companionOf": 7}
        ]);
        assert_eq!(moved_display_parts(Some(&bad), &origin), (None, 4));
        assert_eq!(moved_display_parts(None, &origin), (None, 0));
    }

    /// What an edit keeps is checked against the blocks it names now: a part from the log that
    /// does not fit its block is refused, and no `companionOf` is kept that does not name the
    /// image just before its file.
    #[test]
    fn kept_parts_are_checked_against_their_blocks() {
        let (a, _) = image(b"first", "a.png");
        let blocks = vec![json!({"type": "text", "text": "hi"}), a, link("a.png")];
        let parts = json!([
            {"kind": "image", "blockIndex": 0, "name": "on the text"},
            {"kind": "image", "blockIndex": 1, "name": "a.png"},
            {"kind": "file", "blockIndex": 2, "name": "a.png", "companionOf": 0},
            {"kind": "file", "blockIndex": 2, "name": "again"}
        ]);
        let (kept, refused) = checked_display_parts(Some(&parts), &blocks);
        let kept = kept.expect("the image's part");
        let kept = kept.as_array().unwrap();
        assert!(kept.iter().all(|p| p.get("companionOf").is_none()), "{kept:?}");
        assert_eq!(kept[0], json!({"kind": "image", "blockIndex": 1, "name": "a.png"}));
        // The text's image part and the second part of block 2 always; the file whose
        // `companionOf` names the text too, where the relation is checked (cmux#25717).
        assert!(refused >= 2, "{refused}");
        assert_eq!(checked_display_parts(None, &blocks), (None, 0));
    }
}
