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

/// The refusal [`agent_prompt_hook`] gives a steer a Stop ended the turn of before the agent
/// read it (its `data.answer` is the turn's answer).
const STEER_STOPPED_UNREAD: &str = "steer: the turn was stopped before the agent read it";

/// Whether `answer` is the end acpmux gave a turn whose agent never answered its Stop
/// (`cancel.rs` `forced_answer`).
fn forced(answer: &Value) -> bool {
    answer.pointer("/_meta/acpmux/cancelForced") == Some(&Value::Bool(true))
}

/// `sent`: the steer was written to the agent (it may hold it unread, or have read it).
fn stopped_unread(answer: Value, sent: bool) -> RpcError {
    RpcError::invalid_params(STEER_STOPPED_UNREAD)
        .with_data(json!({"reason": "stopped_unread", "answer": answer, "sent": sent}))
}

/// The turn's answer, and whether the steer was written, if `answer` is [`stopped_unread`]'s
/// refusal.
fn stopped_unread_answer(answer: &Result<Value, RpcError>) -> Option<(Value, bool)> {
    match answer {
        Err(e) if e.message.starts_with(STEER_STOPPED_UNREAD) => {
            let data = e.data.as_ref();
            let turn = data.and_then(|d| d.get("answer")).cloned().unwrap_or(Value::Null);
            Some((turn, data.and_then(|d| d.get("sent")) != Some(&Value::Bool(false))))
        }
        _ => None,
    }
}

/// The refusal of another agent's steer a Stop kept out of the turn it stops: it goes in as a
/// turn of its own instead, with no backoff (`inbox.rs` `notice_done`).
pub(super) fn stopped_steer_refused() -> RpcError {
    RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN)
        .with_data(json!({"reason": "stopped"}))
}

/// Whether `result` is [`stopped_steer_refused`]'s refusal.
pub(super) fn is_stopped_steer_refused(result: &Result<Value, RpcError>) -> bool {
    matches!(result, Err(e) if e.data.as_ref().and_then(|d| d.get("reason")) == Some(&json!("stopped"))
        && e.message.starts_with(crate::claude_stdio::STEER_NO_TURN))
}

/// The agent's `session/prompt` for a prompt of turn `turn_id` (its own, or
/// a `steer` into it): the agent's answer, or the answer of a steer that
/// ended this turn first. With `confirm_written`, `on_sent` requires the harness writer
/// receipt; otherwise it runs when the transport accepts the prompt. Before its answer is awaited, the first-message title path uses this gap so a harness title update can
/// win without waiting for the whole turn, and a family message lets go of its gate there
/// (`full_access_bound.rs` `family_gate`). A `bound` steer goes only into turn `turn_id`: checked
/// while it holds the input handoff, which no other prompt is written past, so no later turn's
/// prompt can come between the check and its write (the turn cap's notice, `turn_cap.rs`).
#[allow(clippy::too_many_arguments)]
pub(super) async fn agent_prompt_hook<F: FnOnce()>(
    session: &Session,
    child: &ChildAgent,
    params: Value,
    turn_id: &str,
    steer: bool,
    bound: bool,
    fence: Option<&crate::agent::Fence>,
    confirm_written: bool,
    held: Option<&(dyn Fn() -> bool + Send + Sync)>,
    on_sent: F,
) -> Result<Value, RpcError> {
    let mut ended = session.steer_end.subscribe();
    // Before transport handoff, an ordinary completion belongs only to prompts the old
    // turn actually received. An unsent steer must take the existing no-turn fallback.
    // Once delivery begins it may already have reached a translator, so do not retry it.
    let delivery_started = std::sync::atomic::AtomicBool::new(false);
    // A steer may be read in a turn its agent ran on into after `turn_id` ended
    // (`carried_turn.rs`): that turn's forced end settles it too.
    let settles = |turn: &str| turn == turn_id || (steer && Hub::succeeds(session, turn_id, turn));
    // The answer is a settlement acpmux published already, not the agent's: never published
    // again, under this prompt's turn (a carried turn's forced end, review 5 of #27536).
    let published = std::sync::atomic::AtomicBool::new(false);
    let settled = |answer: Value| {
        let sent = delivery_started.load(std::sync::atomic::Ordering::SeqCst);
        if steer && !sent && answer["stopReason"] != "cancelled" {
            Err(RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN))
        } else if steer && (!sent || forced(&answer)) {
            // A Stop ended the turn before the agent answered this steer: never written, or
            // written and the agent, which answers a steer as it reads it, never did
            // (`steer_turn` decides what becomes of it).
            Err(stopped_unread(answer, sent))
        } else {
            Ok(answer)
        }
    };
    // A turn acpmux ended already (a Stop the agent never answered, `cancel.rs`) gets no prompt.
    if !steer
        && let Some((turn, answer)) = ended.borrow_and_update().clone()
        && turn == turn_id
    {
        return Ok(answer);
    }
    // A session-wide cancel has no turn id. Keep the next prompt behind the current prompt's
    // handoff so a delayed Stop cannot overtake it (or be overtaken by it) at the child writer.
    // The guard is released by `on_sent`, once `write_fenced` has handed the frame to the child;
    // it is also dropped if the request is cut before it is written.
    let request = async {
        let input_handoff = session.input_handoff.clone().lock_owned().await;
        // The turn can settle while this prompt waits behind a Stop's handoff.
        if let Some((turn, answer)) = session.steer_end.borrow().clone()
            && settles(&turn)
        {
            published.store(true, std::sync::atomic::Ordering::SeqCst);
            return settled(answer);
        }
        if bound && session.turn().is_none_or(|t| t.turn_id != turn_id) {
            return Err(RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN));
        }
        // A steer that may not go in now (an inbox notice behind a waiting prompt or past the
        // turn's cap, `inbox.rs`), checked while it holds the handoff no prompt is written past.
        if held.is_some_and(|held| held()) {
            return Err(RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN));
        }
        delivery_started.store(true, std::sync::atomic::Ordering::SeqCst);
        let callback = move || {
            drop(input_handoff);
            on_sent();
        };
        if confirm_written {
            child.request_with_confirmed_hook(method::SESSION_PROMPT, params, fence, callback).await
        } else {
            child.request_with_hook(method::SESSION_PROMPT, params, fence, callback).await
        }
    };
    tokio::pin!(request);
    loop {
        tokio::select! {
            answer = &mut request => {
                if steer
                    && !published.load(std::sync::atomic::Ordering::SeqCst)
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
                    && settles(&turn)
                {
                    return settled(answer);
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
        if !super::turn_cap::notice_reaches(session, opts.provenance.as_ref(), turn_id) {
            return Err(RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN));
        }
        // A running turn has a live agent.
        let child = self.child_for(session).await?;
        // A family message is checked again here, as a dispatched one is, and the gate held
        // until it is written: it was checked before an MDM off push may have come
        // (`family_gate`).
        let family_gate = self.family_gate(session, opts.provenance.as_ref()).await?;
        // A goal's continuation whose goal moved on is refused here, past the last await before
        // the steer is recorded and accepted (`goal_tools.rs` `check_goal_mark`).
        super::goal_tools::check_goal_mark(session, opts.goal_mark.as_deref())?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let text = prompt_text(&blocks);
        let msg = json!({"text": text, "steer": true, "client": client, "promptId": prompt_id, "turnId": turn_id});
        let msg = crate::prompt_provenance::marked(msg, opts.provenance.as_ref());
        self.append_prompt(session, msg, &blocks, opts.display_parts.as_ref());
        let mut accepted = json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "state": "steered", "steer": true});
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
        // fallback would start one after the Stop. Another agent's message goes on: it is kept
        // out of the stopping turn, or comes back if that turn ends before its agent read it
        // (below), and starts the next turn.
        let from_agent = super::inbox::is_notice(opts.provenance.as_ref())
            || (!opts.send_now
                && super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref())
                    .is_some());
        if !from_agent && session.cancels.load(std::sync::atomic::Ordering::SeqCst) != cancels {
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
            // The turn it starts if its agent reads it after this one ended (`carried_turn.rs`).
            // A family message's continuation speaks for its sender (`turns.rs`).
            let from = opts
                .provenance
                .as_ref()
                .filter(|p| super::subsession_guard::is_family(Some(p)))
                .and_then(|p| p.get("from")?.as_str())
                .map(str::to_owned);
            let sent = super::carried_turn::SteerSent {
                client: client.to_owned(),
                text: text.clone(),
                line: super::prompt_line::prompt_line(&text, client, opts.provenance.as_ref()),
                control,
                continues: super::carried_turn::Continues {
                    from,
                    trust_gate,
                    reports: super::lane_reports::reports_only(opts.provenance.as_ref()),
                    trigger: crate::prompt_provenance::is_trigger(opts.provenance.as_ref()),
                },
            };
            now.sent.insert(prompt_id.clone(), sent);
            now.step.remove(&prompt_id) || opts.steer_now
        };
        if step_now {
            params["_meta"]["steerNow"] = json!(true);
        }
        // Another session's plain message goes in with the other agents' messages waiting for
        // this step, as one message (claude_stdio `steer_batch.rs`). One read now goes alone at
        // once, and so do a family message (its gate holds until it is written), a slash command
        // (only a line's first words run one), one with uploaded files and an inbox digest (one
        // steer, `inbox_digest.rs`).
        let sender = super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref());
        let (class, provenance) = (opts.class, opts.provenance.as_ref());
        super::prompt_sender::add_steer_sender(&mut params, sender.as_deref(), class, provenance);
        if let Some(from) = sender
            && !step_now
            && !super::subsession_guard::is_family_prompt(opts.provenance.as_ref())
            && super::forum::slash_command(&blocks).is_none()
            && !crate::prompt_uploads::any(&blocks)
            && !super::digest::inbox_digest::is_digest(opts.provenance.as_ref())
        {
            params["_meta"]["batch"] = json!({"from": from});
        }
        // Counted in the turn before the agent can read it (`lane_reports.rs`).
        let count = self.lane_steer_in(session, opts.provenance.as_ref());
        let fence = family_gate.map(|hold| self.hold_until_written(session, hold));
        // A fence no writer took is cut (review 86 of #23322).
        let _unsent = crate::agent::CutOnDrop(fence.as_ref());
        // The turn cap's notice goes into the turn it names or nowhere (`turn_cap.rs`).
        let bound = super::turn_cap::is_notice(opts.provenance.as_ref());
        // An inbox notice (`inbox.rs`): only while no prompt waits and the turn is under its cap,
        // and in once the agent's writer took it.
        let inbox_notice = super::inbox::is_notice(opts.provenance.as_ref());
        // Another agent's steer, checked again as it is written: a chat that became a review box
        // since (a `review.` tag) takes it as a turn of its own after the review, and one where
        // the person's prompt waits behind the running turn now as one after it (`inbox.rs`).
        let agent_steer = !opts.send_now
            && super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref())
                .is_some();
        // A digest its drain asked to steer is not held behind a waiting prompt (`turns.rs`).
        let digest = super::digest::inbox_digest::is_digest(opts.provenance.as_ref());
        // A sub-session family message still goes into the person's own turn (`turns.rs`).
        let family = super::subsession_guard::is_family_prompt(opts.provenance.as_ref());
        // Set when the person's waiting prompt is what held it, so a steer-only one says so.
        let prompt_held = std::sync::atomic::AtomicBool::new(false);
        // Another agent's message (an inbox notice too) never goes into a turn a Stop is ending:
        // its agent may never read it, and the forced end would answer it unread. It starts the
        // next turn instead (2026-11-02: a coordinator's message sent a second after Stop went
        // into the cancelling turn and was answered by its forced end; the chat sat idle).
        let agent_message = agent_steer || inbox_notice;
        let stop_held = std::sync::atomic::AtomicBool::new(false);
        let trigger = crate::prompt_provenance::is_trigger(opts.provenance.as_ref());
        let held = || {
            if agent_message && super::cancel::is_stopping(session, turn_id) {
                stop_held.store(true, std::sync::atomic::Ordering::SeqCst);
                true
            } else if trigger || session.turn().is_some_and(|t| t.trigger) {
                true
            } else if inbox_notice {
                super::inbox::notice_held(session)
            } else if agent_steer && super::inbox::review_box(session) {
                true
            } else if agent_steer && !digest && super::inbox::persons_prompt_waits(session) {
                prompt_held.store(true, std::sync::atomic::Ordering::SeqCst);
                true
            } else if agent_steer && !digest && !family && super::inbox::persons_turn(session) {
                // The person's own turn (`inbox.rs`): it goes in after it. A sub-session family
                // message still goes in (`turns.rs`).
                true
            } else {
                false
            }
        };
        let answer = agent_prompt_hook(
            session,
            &child,
            params,
            turn_id,
            true,
            bound || inbox_notice,
            fence.as_ref(),
            inbox_notice,
            Some(&held as &(dyn Fn() -> bool + Send + Sync)),
            || {
                if inbox_notice {
                    self.inbox_prompt_written(session, &prompt_id);
                }
            },
        )
        .await;
        // A Stop ended the turn before its agent answered another agent's message. Never
        // written (it waited behind the Stop), it comes back and starts the next turn (module
        // docs of `cancel.rs`). Written, it comes back only once its agent confirms it dropped it
        // unread (Claude Code's `cancel_async_message`): an agent that answers steers only at
        // the turn's end (codex-acp), one whose line went in batched with others, or one that
        // does not answer may have read it, and a second copy would repeat its work.
        let stopped = stopped_unread_answer(&answer);
        let forced_err = super::cancel::forced_turn(session, turn_id)
            && answer.is_err()
            && steer_entered_turn(&answer)
            && stopped.is_none();
        let unread = agent_message
            && match &stopped {
                Some((_, false)) => true,
                Some((_, true)) => self.steer_taken_back(session, &child, &prompt_id).await,
                None => forced_err && self.steer_taken_back(session, &child, &prompt_id).await,
            };
        let answer = match (answer, stopped) {
            // Anyone else's (the person's) steer a Stop ended, and one its agent may have read,
            // ends with the turn, as before.
            (Err(_), Some((turn, _))) if !unread => Ok(turn),
            (answer, _) => answer,
        };
        // Read in a turn its agent ran on after the one it was steered into ended: it went into
        // that turn, which the turn before named as it ended (`carried_turn.rs`).
        let into = match super::carried_turn::steer_carry(&answer) {
            // Boxed: this future stays small (it runs inside a prompt's, `steer_queued`).
            Some(seq) => Box::pin(Self::carried_into(session, seq)).await,
            None => None,
        };
        {
            let mut now =
                session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            now.waiting.remove(&prompt_id);
            now.sent.remove(&prompt_id);
            // No steer waits on an older carried turn any more (`carried_turn.rs`).
            if now.waiting.is_empty() {
                super::carried_turn::trim_successors(&mut now.successors);
            }
        }
        let turn_id = into.as_deref().unwrap_or(turn_id);
        if let Some(count) = count {
            count.done(!unread && steer_entered_turn(&answer));
        }
        // An inbox digest's steer that went into the turn and failed with it: the messages it
        // took go back held, as messages that joined a failed turn do (`inbox_digest.rs`). One a
        // Stop kept from its agent goes back unheld: its messages start the next turn.
        if answer.is_err() && steer_entered_turn(&answer) {
            let made =
                session.inbox_digests.lock().unwrap_or_else(|e| e.into_inner()).remove(&prompt_id);
            if let Some(made) = made {
                self.requeue_joined(session, &made, !unread);
                if unread {
                    self.steer_stopped_unread(session, &prompt_id, turn_id);
                    return Err(stopped_steer_refused());
                }
            }
        }
        let answer = if unread {
            self.steer_stopped_unread(session, &prompt_id, turn_id);
            if inbox_notice {
                // Its messages are new again and go in as the next turn (`notice_done`).
                self.inbox_notice_unwritten(session, &prompt_id);
            }
            Err(stopped_steer_refused())
        } else if stop_held.load(std::sync::atomic::Ordering::SeqCst)
            && matches!(&answer, Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN))
        {
            Err(stopped_steer_refused())
        } else {
            answer
        };
        let mut r = match answer {
            Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN) => {
                let Some(blocks) = fallback else {
                    // Logged above, it never went: the log says so (a notice whose turn ended, a
                    // steer-only one the person's prompt queued ahead of meanwhile).
                    let waits = prompt_held.load(std::sync::atomic::Ordering::SeqCst);
                    if bound || waits {
                        let msg = json!({"promptId": prompt_id, "turnId": turn_id});
                        self.append(session, "mux", "steer_withdrawn", msg);
                    }
                    if waits {
                        return Err(super::inbox::prompt_waits_steer_refused());
                    }
                    return Err(e);
                };
                // A send-now (`interrupt`) still goes next, but the turn it was for has ended:
                // it stops no other.
                let opts = PromptOptions {
                    prompt_id: Some(prompt_id),
                    message_id: opts.message_id,
                    control,
                    cloud_mobile: opts.cloud_mobile,
                    trust_gate,
                    interrupt: opts.interrupt,
                    interrupt_turn: opts.interrupt.then(|| turn_id.to_owned()),
                    provenance: opts.provenance,
                    message_sender: opts.message_sender,
                    agent: opts.agent,
                    class: opts.class,
                    // Queued under its key, so a later correction still replaces it.
                    supersede: opts.supersede,
                    display_parts: opts.display_parts,
                    full_access_device: opts.full_access_device,
                    // Accepted as a steer already: a full queue does not refuse it now.
                    admitted: true,
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

    /// Another agent's steer a Stop ended the turn of before its agent read it (`steer_turn`):
    /// the log says it came back (`steer_returned`) and starts the next turn.
    fn steer_stopped_unread(&self, session: &Arc<Session>, prompt_id: &str, turn_id: &str) {
        let msg = json!({"promptId": prompt_id, "turnId": turn_id, "reason": "stopped"});
        self.append(session, "mux", "steer_returned", msg);
    }

    /// Whether the agent dropped steer `prompt_id` unread when asked (`MUX_STEER_WITHDRAW`,
    /// Claude Code's `cancel_async_message`). False when it read it, holds it batched with other
    /// messages, cannot take one back (codex-acp), or its process ends first. No timeout, as for
    /// the person's take-back (`queue_edit.rs` `withdraw_steer`): the drop is on its way once
    /// asked, so only the agent's answer, or its end, says whether the message left it; one
    /// given up on early could still be dropped after, and be in neither place.
    async fn steer_taken_back(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        prompt_id: &str,
    ) -> bool {
        let Some(sid) = session.meta().agent_session_id else { return false };
        let params = json!({"sessionId": sid, "promptId": prompt_id});
        let answer = child.request(method::MUX_STEER_WITHDRAW, params).await;
        matches!(&answer, Ok(v) if v["withdrawn"] == true)
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

#[cfg(test)]
#[path = "steer_end_race_tests.rs"]
mod race_tests;
