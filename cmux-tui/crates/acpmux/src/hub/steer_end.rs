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
/// ended this turn first.
pub(super) async fn agent_prompt(
    session: &Session,
    child: &ChildAgent,
    params: Value,
    turn_id: &str,
    steer: bool,
) -> Result<Value, RpcError> {
    let mut ended = session.steer_end.subscribe();
    let request = child.request(method::SESSION_PROMPT, params);
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

/// The default `steerReadDeadlineMs`.
const STEER_READ_DEADLINE_MS: u64 = 500;

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
        let prompt_id = opts.prompt_id.unwrap_or_default();
        self.check_steer(session, control)?;
        // A running turn has a live agent.
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let text = prompt_text(&blocks);
        let msg = json!({"text": text, "steer": true, "client": client, "promptId": prompt_id, "turnId": turn_id});
        let msg = crate::prompt_provenance::marked(msg, opts.provenance.as_ref());
        self.append_prompt(session, msg, &blocks);
        accept(
            json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "steer": true}),
        );
        let fallback = (!opts.steer_only).then(|| blocks.clone());
        let wire_blocks = super::turns::acp_prompt_blocks(session, &blocks)?;
        let mut params = json!({"sessionId": agent_sid, "prompt": wire_blocks});
        params["_meta"] = json!({"steer": true});
        // The steer's answer comes when the agent read it. Claude Code reads one only at its
        // next tool boundary, so one still unread at the deadline stops the running tool
        // (`MUX_STEER_NOW`): a tell never waits for a long tool (user 2026-10-20).
        let deadline = {
            let cfg = self.config.read().await;
            // Only Claude Code's stream-json reads a steer late; Codex and ACP agents take it
            // at once and never get the notification.
            let claude = cfg
                .harnesses
                .get(&session.meta().harness)
                .is_some_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio);
            if claude { cfg.steer_read_deadline_ms.unwrap_or(STEER_READ_DEADLINE_MS) } else { 0 }
        };
        let read = agent_prompt(session, &child, params, turn_id, true);
        tokio::pin!(read);
        let answer = if deadline == 0 {
            read.await
        } else {
            tokio::select! {
                answer = &mut read => answer,
                // A bounded deadline that is the intended behavior, not a poll.
                () = tokio::time::sleep(std::time::Duration::from_millis(deadline)) => {
                    if session.turn().is_some_and(|t| t.turn_id == turn_id) {
                        let _ = child.notify(method::MUX_STEER_NOW, json!({"sessionId": agent_sid})).await;
                        self.append(session, "mux", "steer_now", json!({"promptId": prompt_id, "turnId": turn_id, "afterMs": deadline}));
                    }
                    read.await
                }
            }
        };
        let mut r = match answer {
            Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN) => {
                let Some(blocks) = fallback else { return Err(e) };
                // A send-now (`interrupt`) still goes next.
                let opts = PromptOptions {
                    prompt_id: Some(prompt_id),
                    control,
                    trust_gate,
                    interrupt: opts.interrupt,
                    provenance: opts.provenance,
                    ..PromptOptions::default()
                };
                return Box::pin(self.run_prompt(session, blocks, client, false, opts)).await;
            }
            r => r?,
        };
        merge_mux_meta(&mut r, json!({"promptId": prompt_id, "turnId": turn_id, "steer": true}));
        Ok(r)
    }
}
