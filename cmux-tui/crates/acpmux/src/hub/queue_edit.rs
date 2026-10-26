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
            if crate::attach::any(blocks) {
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

    /// The blocks the waiting prompt `before` runs once edited.
    fn blocks(self, before: &[Value]) -> Vec<Value> {
        let (text, images) = match self {
            Self::Prompt(blocks) => return blocks,
            Self::Text { text, images } => (text, images),
        };
        let kept = before.iter().filter(|block| {
            if block.get("type").and_then(Value::as_str) == Some("text") {
                return false;
            }
            let Some(ids) = &images else { return true };
            match super::prompt_images::id_of(block) {
                Some(id) => ids.contains(&id),
                // Not an image (or not one it can name): it stays.
                None => true,
            }
        });
        std::iter::once(json!({"type": "text", "text": text})).chain(kept.cloned()).collect()
    }
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
            let mut blocks = edit.blocks(&q.run.blocks);
            // Only `session/prompt` adds a hidden context (prompt_context.rs).
            crate::prompt_context::strip_marks(&mut blocks);
            let text = prompt_text(&blocks);
            q.run = Arc::new(PromptRun {
                blocks,
                display_parts: None,
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
