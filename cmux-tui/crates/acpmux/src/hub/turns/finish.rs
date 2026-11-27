//! A turn's end: `finish_turn`, refusing or failing a turn that never started, draining inbound,
//! recording the last turn (part of `hub/turns.rs`).

use super::*;

impl Hub {
    /// Settle a turn once its `session/prompt` answered (or failed), also one recovered from an
    /// adopted agent host: `turn_end`/`turn_error`, `turn_result` and the session status.
    pub(in crate::hub) async fn finish_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        mut result: Result<Value, RpcError>,
        prompt_id: &str,
        turn_id: &str,
        turn_seq: u64,
        joined: Option<&super::digest::DigestTurn>,
        trigger: bool,
        next: Option<&super::carried_turn::NextTurn>,
    ) -> Result<Value, RpcError> {
        // The turn's end, which its cost is ready after (`turn_cost.rs`).
        let ended = std::time::Instant::now();
        // This turn's number, before taking it lets the next one start (`lane_reports.rs`).
        let turn = session.meta().turn_count;
        // A turn its agent ended well clears the chat's rate-limit strikes (`rate_hold.rs`):
        // every turn's end comes here, a recovered or carried one's too.
        if matches!(&result, Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled"))
        {
            self.rate_turn_ok(session);
            // Nothing its process said before this end explains a later exit (`exit_reason.rs`).
            session.exit_line.lock().unwrap_or_else(|e| e.into_inner()).turn_ended_well();
        }
        // A model switch (`detach_child`) ended this turn already: its failure is not the queue's.
        let in_place = next.map(|n| n.next.clone());
        // Taken under the shutdown's lock: its sweep finds the turn running or here, never in
        // between (`shutdown.rs` `settle_ends`).
        // Its start comes from the turn taken here, not a read of the live-turn lock before
        // `take_turn`: that read took `turn` ahead of `auto_resume`, against Stop's order
        // (`auto_resume/turn_completion_tests.rs`).
        let (detached, started_at) = {
            let _ends = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
            let taken = self.take_turn(session, turn_id, in_place);
            let started_at = taken.as_ref().map(|t| t.started_at);
            let took = taken.as_ref().is_some_and(|t| t.turn_id == turn_id);
            if took {
                *session.ending.lock().unwrap_or_else(|e| e.into_inner()) = taken;
            }
            (!took, started_at)
        };
        let ending = EndUnderWay { hub: self, session, turn_id };
        // Named in this turn's `turn_result`, so a restart before it starts still runs it.
        let carried_next = next.filter(|_| !detached);
        // The turn a Stop was stopping has ended (`cancel.rs`): it no longer reads `stopping`,
        // unless its agent runs on in the turn that takes its place (`carried_turn.rs`).
        let was_stopping = take_if_turn(&session.stopping, turn_id);
        if was_stopping && let Some(n) = carried_next {
            *session.stopping.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(n.next.turn_id.clone());
        }
        if take_if_turn(&session.stop_restart, turn_id) && result.is_err() {
            result = Ok(super::cancel::forced_answer(true));
        }
        let carries_on = carried_next.is_some();
        let carried_to = || {
            carried_next.map(|n| {
                let live = session.turn().filter(|t| t.turn_id == n.next.turn_id);
                n.record(live.map_or(n.next.control, |t| t.control))
            })
        };
        session.queue_moved.notify_waiters();
        // Debug builds only: `ACPMUX_TEST_FINISH_HOLD_MS` holds a turn's end once its turn is
        // taken, as a slow end does (`tests/durable_agents.rs`). Bounded; release builds have no
        // seam.
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_FINISH_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
        {
            tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
        }
        #[cfg(test)]
        {
            let seam = self.finish_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // A turn Claude answered is in its store: a respawn resumes it.
        if result.is_ok() {
            let was_unstored = {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.claude_unstored_work = false;
                std::mem::take(&mut m.claude_unstored)
            };
            if was_unstored {
                self.save_meta(session);
            }
        } else if let Err(e) = &result
            && session.meta().claude_unstored
            && self.unstored_turn_worked(session, &e.message)
        {
            // A failed turn whose agent did work keeps the unstored conversation awake
            // (`SessionMeta::claude_unstored_work`); one that only got agent errors does not.
            let marked = {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                !std::mem::replace(&mut m.claude_unstored_work, true)
            };
            if marked {
                self.save_meta(session);
            }
        }
        // Its to-do call ids still held go with it, however the turn ends or is handed off
        // (`todo_tools.rs`): a late result passes through as any other tool's.
        crate::todo_tools::forget(&session.id);
        // Quit Everything already recorded this turn as cancelled. It ends the lane's parent too and
        // no agent starts after it, so the lane reports nothing (`lane_reports.rs`). A restart
        // handed it to the next daemon, which continues it: its end is that daemon's to write.
        if self.settled_by_shutdown.lock().unwrap().contains(turn_id) {
            if self.hands_off(session) {
                super::digest::forget_joined(joined);
            }
            return result;
        }
        // The agent's end came with a shutdown that hands the chat to the next daemon, or after
        // it began: the turn is cut, not ended, and that daemon continues it. Nothing here writes
        // its end, puts its messages back or holds the queue, whoever took the turn first.
        if result.is_err() && self.hands_off(session) {
            super::digest::forget_joined(joined);
            return result;
        }
        // acpmux ended a turn whose model said nothing for `stalledTurnEndMs`: it failed.
        let stalled = result.as_ref().ok().and_then(Self::stalled_error);
        if let Some(e) = stalled {
            result = Err(e);
        }
        // acpmux ended a turn whose model API refused the agent's sign-in (`turn_retry.rs`).
        let refused = result.as_ref().ok().and_then(Self::sign_in_refused_error);
        if let Some(e) = refused {
            result = Err(e);
        }
        if let Some(e) = result.as_ref().ok().and_then(Self::capacity_retry_error) {
            result = Err(e);
        }
        // Apply queued stderr before classifying a dead process (a limit never resumes).
        Self::drain_inbound(session).await;
        // Before the message gains the stderr line: `recovery::annotate_as` below types it.
        let dead = matches!(&result, Err(e) if crate::recovery::dead_process(e));
        if let Err(e) = &mut result
            && dead
        {
            let tail: Vec<String> = session.stderr_tail.lock().unwrap().iter().cloned().collect();
            // The last stderr line that says why: not a stack frame, a wrapper tag or a wrapper exit line.
            if let Some(last) = tail.iter().rev().find(|line| explains_exit(line)).cloned() {
                let agent = session.meta().harness;
                e.message = format!("{} ({agent}): {last}", e.message);
            }
        }
        // A harness that reported a terminal error in-band (Codex
        // `_meta.codex.error` without willRetry) and then ended the turn
        // normally still failed it: answer the prompt with that error.
        let harness_error = session.stream.lock().unwrap().harness_error.clone();
        let harness_failure = match (&result, &harness_error) {
            (Ok(v), Some(h))
                if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") =>
            {
                let text = h.get("text").and_then(Value::as_str).unwrap_or("");
                let text =
                    if text.is_empty() { "the harness reported an error" } else { text }.to_owned();
                let data = json!({"errorSource": h.get("source"), "errorCode": h.get("code"), "stopReason": v.get("stopReason")});
                Some(RpcError::new(-32000, text).with_data(data))
            }
            _ => None,
        };
        let harness_failed = harness_failure.is_some();
        if let Some(e) = harness_failure {
            result = Err(e);
        }
        // The agent messages that went in with it go back before anything here waits, so one sent
        // from now on goes behind them (`digest.rs`).
        // A turn the account's limit refused before its model read a word: every agent message in
        // it goes in again with the next turn, the one that led it too (`rate_hold.rs`).
        if let (Err(e), Some(joined)) = (&result, joined) {
            if self.unread_by_limit(session, turn_seq, &e.message) {
                self.requeue_unread(session, joined);
            } else {
                self.requeue_joined(session, joined, true);
            }
        }
        // A failure on a bound route names the route and its fallback
        // (route_switch.rs), in the error's data and the turn result.
        let route_info = match &result {
            Err(e) => self.route_failure(session, &e.message).await,
            Ok(_) => None,
        };
        // A Claude agent that is not signed in: say what it had, how the
        // person's terminal signs in, and the fix (`claude_auth.rs`).
        let mut signed_out = false;
        let cloud_host = result.is_err() && self.config.read().await.cloud_host;
        let claude_cloud_token_rejected = cloud_host
            && result.as_ref().err().is_some_and(|error| {
                let rejected = error.code == 401
                    || crate::turn_errors::has_status(&error.message, "401")
                    || crate::claude_auth::is_revoked_token(&error.message)
                    || crate::claude_auth::is_expired_credential(&error.message);
                rejected
                    && !crate::turn_errors::says_unreachable(&error.message)
                    && session
                        .credential
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .as_ref()
                        .is_some_and(crate::agent_credentials::AgentCredential::uses_claude_subscription_token)
            });
        // On a Cloud machine, the card's third way in: cmux's gateway, when the image says the
        // machine's team has an account for Claude there (`agent_login::Machine::gateway_access`).
        // Asked only for a sign-in failure it explains.
        let gateway = match &result {
            Err(e) if cloud_host && crate::claude_auth::would_explain(&session.id, &e.message) => {
                let machine = crate::agent_login::Machine {
                    root: self.vm_marker_root(),
                    home: dirs::home_dir().unwrap_or_default(),
                };
                machine.gateway_access(crate::agent_login::Agent::Claude).await == Some(true)
            }
            _ => false,
        };
        // A Cloud machine's Claude that started before the machine's model route resolved (the
        // provider's edge rule for a machine made a moment ago; production cloud-chat-replies,
        // 2026-11-26: every "has no model route" failure read `edge_routed` false): the route is
        // asked again, fresh, waiting while the machine is young (`cloud_model_plane::route_arrives`).
        // Once it resolves, the agent restarts on it after this turn and the first send goes again
        // there (`auto_resume/first_send.rs`), so Sign in shows only where no route is coming.
        let route_arrived = match &result {
            Err(e)
                if cloud_host
                    && crate::claude_auth::would_explain(&session.id, &e.message)
                    && crate::claude_auth::spawned(&session.id)
                        .is_some_and(|s| crate::claude_auth::find(&s.env).endpoint.is_none()) =>
            {
                tokio::task::spawn_blocking(crate::cloud_model_plane::route_arrives)
                    .await
                    .unwrap_or(false)
            }
            _ => false,
        };
        if let Err(e) = &mut result
            && let Some(text) =
                crate::claude_auth::explain(&session.id, &e.message, cloud_host, gateway)
        {
            tracing::warn!(session = %session.id, "Claude agent is not signed in");
            // The gateway fallback (off by default, `agent_login::GATEWAY_FALLBACK_ENV`): a chat
            // with no credential on a team the gateway serves uses it without asking. The agent
            // restarts on it once this turn ends, and the first send goes again there
            // (`auto_resume/first_send.rs`).
            let fell_back = !route_arrived
                && gateway
                && crate::agent_login::gateway_fallback_on()
                && crate::claude_auth::spawned(&session.id)
                    .is_some_and(|s| !crate::claude_auth::find(&s.env).signed_in())
                && self.use_gateway_now(session).await;
            e.message = if route_arrived {
                tracing::info!(session = %session.id, "Claude started before this machine's model route resolved: the agent restarts on it");
                self.restart_agent_after_turn(session);
                crate::claude_auth::route_arrived_text(&e.message)
            } else if fell_back {
                tracing::info!(session = %session.id, "Claude has no credential: the chat uses cmux's gateway");
                crate::claude_auth::gateway_fallback_text(&e.message)
            } else {
                text
            };
            signed_out = true;
        }
        // A Codex with no sign-in and no team plane: say so, typed as a sign-in failure, never
        // codex's bare missing env var (`codex_cloud_auth::explain_missing_key`). Only a Codex
        // session's text names Codex; another harness's stays as it said it (still typed).
        if let Err(e) = &mut result
            && session.meta().harness.to_ascii_lowercase().contains("codex")
            && let Some(text) = crate::codex_cloud_auth::explain_missing_key(&e.message)
        {
            tracing::warn!(session = %session.id, "Codex agent is not signed in");
            e.message = text;
            signed_out = true;
        }
        if let (Err(e), Some(Value::Object(info))) = (&mut result, &route_info) {
            // An agent's string or list data moves under `agentData`, so the route still shows.
            crate::recovery::object_data(e);
            if let Some(Value::Object(data)) = &mut e.data {
                data.extend(info.clone());
            }
        }
        // A failure acpmux knows the remedy for says it (`recovery.rs`): a full disk, an agent
        // that exited, a harness that cannot start. A sign-in failure already says its fix.
        if let Err(e) = &mut result {
            crate::recovery::annotate_as(e, Some(&session.meta().cwd), dead && !signed_out);
            // After the agent's own reason: its fallback could not take the turn, and why.
            super::fallback_start::say_fallback(e);
        }
        let mut git = super::turn_git::turn_git(session).await;
        // The folder as this turn left it, for a rewind or a fork (`turn_checkpoint.rs`; off by
        // default).
        git.extend(super::turn_checkpoint::turn_checkpoint(session, turn_id).await);
        // The folder's work leaves this machine at each turn end (`wip_ref.rs`; off by default).
        self.save_wip_in_background(session);
        // The end is written from here with no wait, under the shutdown's lock: a shutdown that
        // settled the turn meanwhile wrote its end (Quit Everything) or handed it on, and its
        // sweep finds this one either written or still to settle (`shutdown.rs` `settle_ends`).
        // In a block of its own: a guard only dropped would still count as held at the awaits
        // below, and the prompt futures that end here are spawned (`Send`).
        let stopped_early = {
            let ends = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
            if ends.contains(turn_id) {
                drop(ends);
                if self.hands_off(session) {
                    super::digest::forget_joined(joined);
                }
                return result;
            }
            ending.clear();
            // A Stop kept the prompt from the fallback a failover started (`stopped_before_prompt`),
            // or the agent of a turn a Stop was stopping ended it with an error (it exited, its
            // cancel failed, or it reported one): the turn ends as the Stop's, cancelled, and holds
            // no queue as a failure does; the prompt's caller still hears why.
            let stopped_early = result
                .as_ref()
                .err()
                .filter(|e| is_stopped_before_prompt(e) || (was_stopping && !carries_on))
                .cloned();
            if stopped_early.is_some() {
                result = Ok(stopped_answer());
            }
            // The turn's wrap-up answer, taken whatever the turn's end (`wrap_up_suggestion.rs`).
            // The facts it offered for the project's instructions (`memory_inbox.rs`), first.
            let learned = crate::wrap_up_suggestion::take_learned(&session.id);
            // Whether it taught something, taken however it ended: a turn's signals never carry
            // into the next one.
            let taught = crate::memory_inbox::take(&session.id);
            let wrap_up_answer = crate::wrap_up_suggestion::take(&session.id);
            match &result {
                Ok(v) => {
                    self.note_reply_refusal(session);
                    let stop = v.get("stopReason").cloned().unwrap_or(Value::Null);
                    // Its last reply's claims, checked against its own runs (`claim_check.rs`).
                    self.append_claim_checks(session, turn_id);
                    self.append(
                        session,
                        "mux",
                        "turn_end",
                        json!({"stopReason": stop, "turnId": turn_id, "turnSeq": turn_seq}),
                    );
                    // A turn a Stop was stopping ended as the Stop's, whatever stop reason its agent
                    // gave: an adapter that answers the cancel `end_turn` still stopped, so clients
                    // offer Continue on it. Not one whose agent runs on into the next turn.
                    let stopped =
                        stop.as_str() == Some("cancelled") || (was_stopping && !carries_on);
                    let status = if stopped { "cancelled" } else { "completed" };
                    let mut msg = json!({"status": status, "stopReason": stop, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
                    // What the turn spent, where its harness says, for a goal's token budget:
                    // its input as reported (the cache's reads in it, for an ACP harness that
                    // counts them there) and its output (`turn_usage::as_reported`).
                    let (usage, spent) = super::turn_usage::turn_usage(session, v);
                    if let Some(o) = msg.as_object_mut() {
                        o.extend(self.turn_error_fields(session, None));
                        // acpmux ended a turn whose agent did not answer the cancel (`cancel`).
                        if v.pointer("/_meta/acpmux/cancelForced") == Some(&Value::Bool(true)) {
                            o.insert("cancelForced".into(), Value::Bool(true));
                        }
                        o.extend(usage);
                        // Context surgery's counters (`surgery.rs`).
                        o.extend(super::surgery::turn_fields(&session.id));
                        // What the task cost, model and compute, and the chat's total so far.
                        super::turn_cost::add_turn_cost(session, o, started_at, ended);
                        // Its spend checks during the turn, and their warnings (`spend_burn.rs`).
                        o.extend(super::spend_burn::turn_fields(&session.id, turn_id));
                        // Harness magic's counts for the turn (`claude_stdio/dedupe.rs`).
                        if let Some(hm) = v.pointer("/_meta/harnessMagic").filter(|m| m.is_object())
                        {
                            o.insert("harnessMagic".into(), hm.clone());
                        }
                        if let Some(to) = carried_to() {
                            o.insert("carriedTo".into(), to);
                        }
                    }
                    self.write_turn_result(session, msg, git);
                    if status == "completed"
                        && let Some(answer) = wrap_up_answer
                    {
                        self.offer_wrap_up_suggestion(session, &answer);
                    }
                    if status == "completed" && taught {
                        self.offer_learned(session, learned);
                    }
                    // A chat that took several corrections, kept now (`prompt_coach.rs`): settled
                    // by this turn's own prompt only.
                    self.coach_turn_ended(session, prompt_id, status == "completed");
                    // A goal set with goal_set goes on, or stops at its budget (`goal_tools.rs`).
                    if status == "completed" {
                        self.continue_goal(session, spent);
                    }
                    // A Codex chat's open goal left idle is nudged, then told (`goal_watch.rs`).
                    self.goal_turn_ended(session, prompt_id, status == "completed");
                    // The chat works again: agent messages a failed turn held go in (`digest.rs`).
                    // Not while a person's Stop that came after this turn began holds them
                    // (`cancel.rs`): only a turn begun under that hold, or a resume, ends it.
                    let hold = session.stop_hold.load(Ordering::SeqCst);
                    if status == "completed"
                        && (hold == 0 || hold == session.turn_hold.load(Ordering::SeqCst))
                    {
                        self.release_held_agent_messages(session, hold);
                    }
                }
                Err(e) => {
                    let mut record = json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": turn_seq});
                    if let Some(o) = record.as_object_mut() {
                        o.extend(crate::recovery::fields(e));
                    }
                    self.append(session, "mux", "turn_error", record);
                    self.note_model_refusal(session, &e.message);
                    self.goal_turn_ended(session, prompt_id, false);
                    if !detached {
                        self.pause_queue(session, turn_id);
                    }
                    let mut msg = json!({"status": "failed", "error": e.message, "code": e.code, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
                    if let Some(o) = msg.as_object_mut() {
                        let agent_error =
                            (!harness_failed).then(|| (e.message.as_str(), json!(e.code)));
                        o.extend(self.turn_error_fields(session, agent_error));
                        if let Some(Value::Object(info)) = &route_info {
                            o.extend(info.clone());
                        }
                        o.extend(crate::recovery::fields(e));
                        if claude_cloud_token_rejected {
                            o.insert("errorCode".into(), json!("claude_cloud_token_rejected"));
                        } else if crate::turn_errors::model_not_available(&e.message) {
                            o.insert("errorCode".into(), json!("model_not_found"));
                        } else if turn == 1
                            && crate::turn_errors::has_status(
                                &e.message.to_ascii_lowercase(),
                                "403",
                            )
                            && session
                                .launch_env
                                .lock()
                                .unwrap_or_else(|p| p.into_inner())
                                .as_ref()
                                .is_some_and(|env| {
                                    env.contains_key(crate::subscriptions::grok_hook::COMMAND)
                                })
                        {
                            o.insert("errorCode".into(), json!("subscription.no_supergrok_access"));
                        }
                        if let Some(to) = carried_to() {
                            o.insert("carriedTo".into(), to);
                        }
                        // Ended by acpmux, not the agent (`stalled_turn.rs`).
                        if let Some(data) = e.data.as_ref().filter(|d| d["detail"] == "stalled") {
                            o.insert("detail".into(), data["detail"].clone());
                            o.insert("stalledMs".into(), data["stalledMs"].clone());
                            o.insert("errorSource".into(), json!("acpmux"));
                        }
                    }
                    self.write_turn_result(session, msg, git);
                }
            }
            stopped_early
        };
        // Its harness wrote the turn's spend: read it (`usage_view.rs`).
        self.refresh_usage_stats_of(session);
        if trigger {
            self.end_trigger_background(session, turn_id);
        }
        self.reset_stream(session);
        // Nobody attending it (not shown, or shown to a person who is away, `seen.rs`): the
        // sidebar dot and `wait --until done` see it. While work it started still runs (a
        // background subagent, a working sub-session) the task is not done: the dot waits for
        // that work to end (`work_below.rs`, manaflow-ai/cmux#25563).
        if !trigger {
            self.note_turn_end(session);
        }
        if session.status() != SessionStatus::Closed {
            // A link that broke on an entry it could not store (a full disk) leaves its host
            // running: the next request reattaches, so the chat is not disconnected.
            let alive = child.is_alive().await || (child.is_broken() && !child.has_exited());
            // A subagent or background shell still waiting on the person
            // keeps the chat waiting after its turn (cx-jo8yo). The lock is
            // held across the write, so an answer in between cannot leave it
            // waiting on nothing.
            let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let asking = self.open_ask(session, &state);
            // An agent MDM's off ended leaves the chat idle; read under the lock its end marks it
            // under (`end_managed_full_access`, reviews 2 and 3 of #26034).
            let ended = child.ended_on_purpose();
            match (ended, alive, asking) {
                // The next turn runs already (`carried_turn.rs`).
                (false, true, _) if carries_on => self.set_status(session, NotWaiting::Running),
                (true, _, _) => self.set_status(session, NotWaiting::Idle),
                (false, false, _) => self.set_status(session, NotWaiting::Disconnected),
                (false, true, Some(reason)) => self.set_waiting(session, reason),
                (false, true, None) => self.set_status(session, NotWaiting::Ready),
            }
            drop(state);
        }
        self.save_meta(session);
        // The chat's settled view, for the shape its pane opens with (`settled_view.rs`).
        self.settle_view_at_turn_end(session);
        // Where the next daemon's adoption of its host reads the log from (`hosts/checkpoint.rs`).
        self.checkpoint_at_turn_end(session, child);
        self.send_offer_result(session);
        self.lane_turn_ended(session, true, turn);
        self.inbox_turn_ended(session, turn_id, turn, true);
        match stopped_early {
            Some(e) => Err(e),
            None => result,
        }
    }

    /// A turn refused after it was accepted (dispatch check, remote floor): failed unstarted.
    pub(super) fn refuse_started_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
        joined: &super::digest::DigestTurn,
        rules: &super::auto_resume::RefusedRules<'_>,
    ) {
        self.fail_unstarted_turn(session, prompt_id, turn_id, e, joined, Some(rules));
        // Its before picture has no after coming (`turn_shots.rs`).
        super::turn_shots::turn_refused(session, turn_id);
        super::turn_frames::turn_refused(session, turn_id);
        if session.status() == SessionStatus::Disconnected {
            self.set_status(session, NotWaiting::Ready);
        }
    }

    /// A prompt that left the queue (`dequeued`, `waiting`) refused before its turn: the log
    /// settles it with `prompt_refused`, so a restart does not queue it again (`restore_queue`).
    pub(super) fn refuse_dequeued(
        &self,
        session: &Arc<Session>,
        waiting: bool,
        prompt_id: &str,
        turn_id: &str,
        client: &str,
        e: &RpcError,
    ) {
        if waiting {
            let msg = json!({"promptId": prompt_id, "turnId": turn_id, "client": client, "error": e.message, "data": e.data});
            self.append(session, "mux", "prompt_refused", msg);
        }
    }

    /// A recorded prompt whose agent could not start: the turn ends failed, so every client
    /// sees the prompt settle instead of a turn that never starts. It fails alone: the prompts
    /// behind it are not held (`pause_queue`), each gets its own try, as after a Stop. Only a turn
    /// whose prompt reached its agent and failed holds them (`finish_turn`).
    ///
    /// One a Stop kept from its agent ([`stopped_before_prompt`], a Stop while the agent started
    /// or the prompt's copies were made) ends as the Stop's turn: cancelled, so clients offer
    /// Continue on it, as on any stopped turn.
    pub(in crate::hub) fn fail_unstarted_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
        joined: &super::digest::DigestTurn,
        rules: Option<&super::auto_resume::RefusedRules<'_>>,
    ) {
        let turn = session.meta().turn_count;
        let trigger = session.turn().is_some_and(|t| t.trigger && t.turn_id == turn_id);
        // Who drives the turn now (a Web steer while its agent started made it a Web turn).
        let control = session.turn().filter(|t| t.turn_id == turn_id).map(|t| t.control);
        self.end_trigger_background(session, turn_id);
        *session.turn.lock().unwrap() = None;
        // It no longer reads `stopping`: a Stop that came while its agent started (`cancel.rs`)
        // ends it as stopped, also when the start then failed.
        let was_stopping = take_if_turn(&session.stopping, turn_id);
        // The prompt behind it waits for no turn now (`queue_turn`).
        session.queue_moved.notify_waiters();
        // The agent messages that joined it never reached the agent either: back unheld, unless
        // a person's Stop holds them (`requeue_joined`).
        self.requeue_joined(session, joined, false);
        let stopped_early = is_stopped_before_prompt(e);
        if stopped_early || was_stopping {
            let stop = stopped_answer().get("stopReason").cloned().unwrap_or_default();
            self.append(
                session,
                "mux",
                "turn_end",
                json!({"stopReason": stop, "turnId": turn_id, "turnSeq": 0}),
            );
            let msg = json!({"status": "cancelled", "stopReason": stop, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
            self.record_last_turn(session, &msg);
            self.append(session, "mux", "turn_result", msg);
            self.reset_stream(session);
            // Its agent started (a Stop kept the prompt from it), or failed to: the chat waits
            // for the next prompt, or says its agent is not running.
            if session.status() != SessionStatus::Closed {
                let status =
                    if stopped_early { NotWaiting::Ready } else { NotWaiting::Disconnected };
                self.set_status(session, status);
            }
            self.save_meta(session);
            self.settle_view_at_turn_end(session);
            self.lane_turn_ended(session, false, turn);
            self.inbox_turn_ended(session, turn_id, turn, false);
            return;
        }
        let mut e = e.clone();
        crate::recovery::annotate(&mut e, Some(&session.meta().cwd));
        let typed = crate::recovery::fields(&e);
        let mut record =
            json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": 0});
        if let Some(o) = record.as_object_mut() {
            o.extend(typed.clone());
        }
        self.append(session, "mux", "turn_error", record);
        // `errorText` as a started turn's failure has it: its `lastTurn` and its parent's
        // `turn_ended` say why.
        let mut msg = json!({"status": "failed", "error": e.message, "errorText": e.message, "code": e.code, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
        if let Some(o) = msg.as_object_mut() {
            o.extend(typed);
        }
        // A store that refused the turn (a full disk) says nothing of its agent: the chat
        // waits for the next prompt rather than reading disconnected.
        let refused = msg["errorKind"] == crate::recovery::kind::DISK_FULL;
        self.record_last_turn(session, &msg);
        self.append(session, "mux", "turn_result", msg);
        self.reset_stream(session);
        if session.status() != SessionStatus::Closed {
            let status = if refused { NotWaiting::Ready } else { NotWaiting::Disconnected };
            self.set_status(session, status);
        }
        self.save_meta(session);
        self.settle_view_at_turn_end(session);
        // The turn was counted: its lane's parent hears it failed, with no reply of its own
        // (`lane_reports.rs`).
        self.lane_turn_ended(session, false, turn);
        self.inbox_turn_ended(session, turn_id, turn, false);
        // A full disk clears by itself: the refused turn goes on once it has room, as a turn a
        // full disk cut does (`auto_resume/disk_wait.rs`), instead of leaving the chat stranded.
        if refused
            && !trigger
            && let Some(rules) = rules
        {
            let rules = super::auto_resume::RefusedRules {
                control: control.unwrap_or(rules.control),
                ..*rules
            };
            self.resume_refused_turn(session, prompt_id, turn_id, &e.message, &rules);
        }
    }

    /// Waits until the inbound loop handled every agent message queued before
    /// now. Bounded: a loop that is gone (closed channel) or stuck never holds
    /// a turn's settlement past the bound.
    pub(in crate::hub) async fn drain_inbound(session: &Session) -> bool {
        // No channel yet: nothing was ever sent to the chat, so nothing is left to handle.
        let Some(channel) = session.inbound.get() else {
            return true;
        };
        let (done, handled) = tokio::sync::oneshot::channel();
        let queued = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            channel.tx.send(crate::agent::Inbound::Barrier(done)),
        )
        .await;
        matches!(queued, Ok(Ok(())))
            && matches!(
                tokio::time::timeout(std::time::Duration::from_secs(5), handled).await,
                Ok(Ok(()))
            )
    }

    /// Keep the outcome of the last turn on the session (`lastTurn` in the
    /// summary), so `wait` can report a failed turn after it resolves.
    pub(in crate::hub) fn record_last_turn(&self, session: &Session, turn_result: &Value) {
        let last = last_turn_of(turn_result, now_ms());
        self.lane_report_record_result(&session.id, turn_result);
        if turn_result.get("trigger") != Some(&Value::Bool(true)) {
            let mut meta = session.meta.lock().unwrap();
            if last["errorCode"] == "claude_cloud_token_rejected"
                && meta.claude_token_recovery.is_none()
            {
                meta.claude_token_recovery =
                    Some(crate::store::ClaudeTokenRecovery::LegacyRejected);
            }
            meta.last_turn = Some(last);
        } else if turn_result.get("status").and_then(Value::as_str) == Some("completed") {
            // A trigger turn that completed proves the chat works (`background_turn.rs`).
            super::super::background_turn::recover_last_turn(
                &mut session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_turn,
                last["endedAt"].as_u64().unwrap_or_else(now_ms),
            );
        }
        // Every turn's end passes here once: its parent hears it (`subsession_results.rs`).
        self.subsession_turn_ended(session, turn_result);
        // Opt-in team usage sharing (`usage_share.rs`): nothing while it is off.
        super::usage_share::turn_ended(session, turn_result);
    }
}
