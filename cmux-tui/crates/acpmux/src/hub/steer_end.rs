//! The answer of a turn that took steers (E19, 2026-10-09).
//!
//! codex-acp folds a steered `session/prompt` into the running turn and, at
//! the turn's end, answers only the last prompt it got: the turn's own
//! prompt and the earlier steers never get an answer, so their callers (the
//! Chief's turn) waited forever. A steer whose answer ends the turn (any
//! stop reason but Claude Code's `steered`, which it gives when it read the
//! steer and the turn runs on) answers every other prompt of that turn with
//! the same answer. Claude Code's steers are answered `steered` and change
//! nothing here.
//!
//! Also the steer itself (`Hub::steer_turn`): a prompt sent into a running turn.

use super::*;

/// Whether an agent's answer to a steer says that the turn ended.
fn ends_turn(answer: &Value) -> bool {
    answer.get("stopReason").and_then(Value::as_str).is_some_and(|reason| reason != "steered")
}

/// The agent's `session/prompt` for a prompt of turn `turn_id` (its own, or
/// a `steer` into it): the agent's answer, or the answer of a steer that
/// ended this turn first. `on_sent` runs once the prompt is written to the child, before its
/// answer is awaited: the first-message title path uses this gap so a harness title update can
/// win without waiting for the whole turn, and a family message lets go of its gate there
/// (`full_access_bound.rs` `family_gate`).
pub(super) async fn agent_prompt_hook<F: FnOnce()>(
    session: &Session,
    child: &ChildAgent,
    params: Value,
    turn_id: &str,
    steer: bool,
    on_sent: F,
) -> Result<Value, RpcError> {
    let mut ended = session.steer_end.subscribe();
    // A turn acpmux ended already (a Stop the agent never answered, `cancel.rs`) gets no prompt.
    if !steer
        && let Some((turn, answer)) = ended.borrow_and_update().clone()
        && turn == turn_id
    {
        return Ok(answer);
    }
    let request = child.request_with_hook(method::SESSION_PROMPT, params, on_sent);
    tokio::pin!(request);
    loop {
        tokio::select! {
            answer = &mut request => {
                if steer
                    && let Ok(value) = &answer
                    && ends_turn(value)
                {
                    session.steer_end.send_replace(Some((turn_id.to_owned(), value.clone())));
                }
                return answer;
            }
            changed = ended.changed() => {
                if changed.is_err() {
                    return request.await;
                }
                let by_steer = ended.borrow_and_update().clone();
                if let Some((turn, answer)) = by_steer
                    && turn == turn_id
                {
                    return Ok(answer);
                }
            }
        }
    }
}

impl Hub {
    /// Sends a prompt into the running turn `turn_id` of an agent that steers. The turn may end
    /// between the check and the agent: without `steer_only` the prompt then becomes the next one.
    pub(super) async fn steer_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        turn_id: &str,
        opts: PromptOptions,
        accept: &mut impl FnMut(Value),
    ) -> Result<Value, RpcError> {
        let (control, trust_gate) = (opts.control, opts.trust_gate);
        // A Stop from here on ends the turn this steer is for: it is not written (below).
        let cancels = session.cancels.load(std::sync::atomic::Ordering::SeqCst);
        let prompt_id = opts.prompt_id.unwrap_or_default();
        self.check_steer(session, control, opts.full_access_device.as_deref())?;
        // A family message is checked again here, as a dispatched one is, and the gate held
        // until it is written: it was checked before an MDM off push may have come
        // (`family_gate`).
        let family_gate = self.family_gate(session, opts.provenance.as_ref()).await?;
        // A running turn has a live agent.
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let text = prompt_text(&blocks);
        let msg = json!({"text": text, "steer": true, "client": client, "promptId": prompt_id, "turnId": turn_id});
        let msg = crate::prompt_provenance::marked(msg, opts.provenance.as_ref());
        self.append_prompt(session, msg, &blocks, opts.display_parts.as_ref());
        let mut accepted = json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "steer": true});
        // Steered in: the sender's prompts still queued under its key are replaced (`supersede.rs`).
        if let Some(key) = opts.supersede.as_deref() {
            let sender =
                super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref());
            let gone = self.supersede_queued(session, key, sender.as_deref(), &prompt_id);
            super::queue::supersede::mark(&mut accepted, Some(&gone));
        }
        accept(accepted);
        let fallback = (!opts.steer_only).then(|| blocks.clone());
        let wire_blocks = super::turns::agent_blocks(self, session, &blocks).await?;
        // Stopped while its copies were made: written now, it would reach no turn, and its
        // fallback would start one after the Stop.
        if session.cancels.load(std::sync::atomic::Ordering::SeqCst) != cancels {
            return Err(super::turns::stopped_before_prompt());
        }
        let mut params = json!({"sessionId": agent_sid, "prompt": wire_blocks});
        // Its promptId names it to a withdraw (`queue_edit.rs` `withdraw`).
        params["_meta"] = json!({"steer": true, "promptId": prompt_id});
        // Until the agent answers it, Send now can stop the agent's step for it
        // (`queue_edit.rs`); a queued prompt sent now stops it right away.
        let step_now = {
            let mut now =
                session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let author = crate::author::of_provenance(opts.provenance.as_ref());
            now.waiting.insert(prompt_id.clone(), author.map(str::to_owned));
            now.step.remove(&prompt_id) || opts.steer_now
        };
        if step_now {
            params["_meta"]["steerNow"] = json!(true);
        }
        // Counted in the turn before the agent can read it (`lane_reports.rs`).
        let count = self.lane_steer_in(session, opts.provenance.as_ref());
        let answer =
            agent_prompt_hook(session, &child, params, turn_id, true, || drop(family_gate)).await;
        session
            .steer_now
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .waiting
            .remove(&prompt_id);
        if let Some(count) = count {
            count.done(steer_entered_turn(&answer));
        }
        let mut r = match answer {
            Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN) => {
                let Some(blocks) = fallback else { return Err(e) };
                // A send-now (`interrupt`) still goes next, but the turn it was for has ended:
                // it stops no other.
                let opts = PromptOptions {
                    prompt_id: Some(prompt_id),
                    control,
                    trust_gate,
                    interrupt: opts.interrupt,
                    interrupt_turn: opts.interrupt.then(|| turn_id.to_owned()),
                    provenance: opts.provenance,
                    agent: opts.agent,
                    // Queued under its key, so a later correction still replaces it.
                    supersede: opts.supersede,
                    display_parts: opts.display_parts,
                    full_access_device: opts.full_access_device,
                    ..PromptOptions::default()
                };
                return Box::pin(self.run_prompt(session, blocks, client, false, opts)).await;
            }
            // Taken back before the agent read it: the log says so, and the steer ends there.
            Err(e) if e.message.starts_with(crate::claude_stdio::STEER_WITHDRAWN) => {
                let msg = json!({"promptId": prompt_id, "turnId": turn_id});
                self.append(session, "mux", "steer_withdrawn", msg);
                json!({"stopReason": "withdrawn"})
            }
            r => r?,
        };
        merge_mux_meta(&mut r, json!({"promptId": prompt_id, "turnId": turn_id, "steer": true}));
        Ok(r)
    }
}

/// Whether a steer's answer means it went into the running turn: any answer but one that found
/// no turn or was withdrawn before the agent read it. One the turn took that ended in an error
/// was still part of it.
fn steer_entered_turn(answer: &Result<Value, RpcError>) -> bool {
    !matches!(answer, Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN)
        || e.message.starts_with(crate::claude_stdio::STEER_WITHDRAWN))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_steer_the_turn_took_counts_as_in_it() {
        let err = |m: &str| Err(RpcError::internal(m.to_owned()));
        assert!(steer_entered_turn(&Ok(json!({}))));
        assert!(steer_entered_turn(&err("agent process closed")));
        assert!(!steer_entered_turn(&err(crate::claude_stdio::STEER_NO_TURN)));
        assert!(!steer_entered_turn(&err(crate::claude_stdio::STEER_WITHDRAWN)));
    }
}
