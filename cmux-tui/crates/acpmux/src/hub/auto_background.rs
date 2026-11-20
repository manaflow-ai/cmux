//! Part of `Hub`; see `hub/mod.rs`. A Claude Code shell still running in the foreground after
//! [`AUTO_BACKGROUND_AFTER`] goes to the background on its own, through Ctrl-B's
//! `background_tasks` (`processes.rs`), so the turn goes on while it runs. Leo, 2026-11-02, on
//! a session that sat about 80 minutes in one turn of about 40 foreground shell calls (worktree
//! setup, loops of GitHub reads, long remote calls): "but why not in cmux". The plugin's
//! PreToolUse hook (`bg_hook.rs`) turns away the commands known to be slow before they start;
//! this catches every other one, a person's own script included, which no list can know.
//!
//! One timer per foreground Bash call of the chat's own turn (a subagent's calls are not the
//! turn's, `on_update`), armed when its command arrives. It ends when the call is no longer
//! in flight (it finished, or the turn ended), when Claude Code moved it, or when Claude Code
//! refused the request; while the call still waits (a permission card, say) and nothing moved,
//! it asks again one interval later. Weak references only, so it never keeps a chat or the hub
//! alive. What moved is listed like any shell Claude Code moved itself, origin
//! `auto_backgrounded`.
//!
//! Codex needs none of this: its unified exec hands a long command back to the agent as a
//! running process after a short wait (`codex_app_server/background.rs`), so a turn never
//! blocks on one.
//!
//! A call that declares a Bash `timeout` longer than the wait is left alone: the agent chose to
//! block on it (a land-queue wait, a CI watch), and Claude Code ends it at that timeout anyway.
//! Moving it ended the turn on a running shell, and agents that must report at the end of their
//! turn stalled until someone restarted them (a1000, a1001, a994, 2026-11-05).
//!
//! `ACPMUX_AUTO_BACKGROUND_SECS` in the daemon's environment sets the wait; `0` turns it off.
//!
//! The person's message moves work sooner. Claude Code reads a steer only when its current step
//! ends (`claude_stdio/steer_batch.rs`), so a message sent during a long foreground call waited
//! for that call: a coordinator's turn ran a foreground subagent for 11 minutes and none of the
//! person's six messages got an answer. Leo, 2026-11-06: "I feel like ACPMUX should, like, force
//! it ... We should be able to just background a lot of these things for you." So while the
//! person's steer waits unread (`steer_end.rs` `steer_turn`), each Bash or Agent call of the
//! chat's own turn that has run in the foreground for [`MESSAGE_BACKGROUND_AFTER`] goes to the
//! background, with Ctrl-B's `background_tasks` for that call, including a shell that declared a
//! longer `timeout` and a foreground subagent, which the shell timer above leaves alone. Claude
//! Code then hands the call back as running in the background, reads the message and answers it,
//! and the call's own result still comes when it ends (its task notification). One wait a
//! message, no timer per chat: armed when the message is written, it sleeps only until the next
//! call reaches the threshold, and it ends when the agent reads the message, when nothing runs in
//! the foreground any more, or when the turn ends. A call that ends before the threshold is never
//! moved. Another agent's message, a notice or a hub-made prompt moves nothing
//! ([`persons_message`]): those already go in batched and wait for the step. What moved is
//! listed `auto_backgrounded`, as above. Claude Code chats only (`backgrounds_work`); other
//! harnesses keep today's behaviour.

use super::*;

/// How long a foreground shell runs before it goes to the background.
pub(super) const AUTO_BACKGROUND_AFTER: std::time::Duration = std::time::Duration::from_secs(60);

/// How long a foreground call of the chat's own turn has run before the person's message waiting
/// behind it moves it to the background (module docs).
pub(super) const MESSAGE_BACKGROUND_AFTER: std::time::Duration = std::time::Duration::from_secs(30);

/// How long the person's message waits for the translator's list of foreground calls.
const FOREGROUND_ASK: std::time::Duration = std::time::Duration::from_secs(5);

/// The daemon's env knob for [`AUTO_BACKGROUND_AFTER`] (seconds; `0` turns it off).
pub const AUTO_BACKGROUND_ENV: &str = "ACPMUX_AUTO_BACKGROUND_SECS";

/// The wait the daemon starts with: the env's, else [`AUTO_BACKGROUND_AFTER`].
pub(super) fn auto_background_from_env() -> Option<std::time::Duration> {
    after_of(std::env::var(AUTO_BACKGROUND_ENV).ok().as_deref())
}

fn after_of(value: Option<&str>) -> Option<std::time::Duration> {
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        None => Some(AUTO_BACKGROUND_AFTER),
        Some(v) => match v.parse::<u64>() {
            Ok(0) => None,
            Ok(secs) => Some(std::time::Duration::from_secs(secs)),
            Err(_) => Some(AUTO_BACKGROUND_AFTER),
        },
    }
}

/// The foreground shell a `session/update`'s `update` names, if it names one: a call of kind
/// `execute` with a command and without `run_in_background: true`, still running. Its command
/// comes with the `tool_call`, or with the `tool_call_update` that follows a call Claude Code
/// named as its block started (`claude_stdio/early_calls.rs`).
pub(super) fn foreground_shell(update: &Value) -> Option<&str> {
    if !matches!(
        update.get("sessionUpdate").and_then(Value::as_str),
        Some("tool_call" | "tool_call_update")
    ) || update.get("kind").and_then(Value::as_str) != Some("execute")
        || matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"))
    {
        return None;
    }
    let input = update.get("rawInput")?;
    if input.get("run_in_background") == Some(&Value::Bool(true)) {
        return None;
    }
    input.get("command")?.as_str()?;
    update.get("toolCallId")?.as_str()
}

/// The wait the Bash call in `update` declared with its `timeout` (milliseconds), if any.
fn declared_timeout(update: &Value) -> Option<std::time::Duration> {
    let ms = update.get("rawInput")?.get("timeout")?;
    let ms = ms.as_u64().or_else(|| ms.as_f64().filter(|v| *v > 0.0).map(|v| v as u64))?;
    Some(std::time::Duration::from_millis(ms))
}

/// Whether a prompt is the person's own message: no agent sent it (`fromAgent`, a session the
/// connection runs in) and its provenance, if any, names a person (`author.rs`). Every agent's
/// and hub-made kind (an agent message, a notice, a task result, a trigger) is not.
pub(super) fn persons_message(provenance: Option<&Value>, agent: Option<&str>) -> bool {
    agent.is_none()
        && provenance.is_none_or(|p| {
            p.get("kind").and_then(Value::as_str) == Some(crate::author::PERSON_MESSAGE)
        })
}

/// `answer`, running `moving` beside it from when `written` is told until either ends; an answer
/// that comes first (a steer held or refused before it was written) never starts `moving`.
async fn answer_once_written<T>(
    written: &tokio::sync::Notify,
    answer: impl std::future::Future<Output = T>,
    moving: impl std::future::Future<Output = ()>,
) -> T {
    tokio::pin!(answer);
    let moving = async {
        written.notified().await;
        moving.await;
    };
    tokio::pin!(moving);
    tokio::select! {
        biased;
        answer = &mut answer => return answer,
        () = &mut moving => {}
    }
    answer.await
}

impl Hub {
    /// How long a foreground call runs before the person's waiting message moves it; None turns
    /// it off (tests shorten it).
    pub fn set_message_background_after(&self, after: Option<std::time::Duration>) {
        *self.message_background_after.lock().unwrap_or_else(|e| e.into_inner()) = after;
    }

    /// `answer`, the agent's answer to the person's steer into `session`'s turn; once the steer
    /// is `written` and until the answer comes, the calls that block the turn go to the
    /// background as they reach the threshold (module docs). A steer held or refused before it
    /// is written moves nothing, and the wait ends with the answer, so nothing outlives the
    /// message.
    pub(super) async fn answer_moving_work<T>(
        &self,
        session: &Arc<Session>,
        child: &ChildAgent,
        written: &tokio::sync::Notify,
        answer: impl std::future::Future<Output = T>,
    ) -> T {
        let after = *self.message_background_after.lock().unwrap_or_else(|e| e.into_inner());
        let Some(after) = after.filter(|_| session.backgrounds_work.load(Ordering::SeqCst)) else {
            return answer.await;
        };
        answer_once_written(written, answer, self.move_blocking_work(session, child, after)).await
    }

    /// Moves each foreground call of `session`'s turn that has run `after` to the background, then
    /// sleeps until the next one would; returns when none runs in the foreground (or the agent
    /// does not say).
    async fn move_blocking_work(
        &self,
        session: &Arc<Session>,
        child: &ChildAgent,
        after: std::time::Duration,
    ) {
        let params = json!({"sessionId": session.meta().agent_session_id});
        loop {
            let ask = child.request(crate::claude_stdio::FOREGROUND_WORK, params.clone());
            let Ok(Ok(answer)) = tokio::time::timeout(FOREGROUND_ASK, ask).await else { return };
            let mut next: Option<std::time::Duration> = None;
            for call in answer.get("work").and_then(Value::as_array).into_iter().flatten() {
                let Some(tool) = call.get("toolCallId").and_then(Value::as_str) else { continue };
                let ran = std::time::Duration::from_millis(
                    call.get("runningMs").and_then(Value::as_u64).unwrap_or(0),
                );
                if ran < after {
                    next = Some(next.map_or(after - ran, |n| n.min(after - ran)));
                    continue;
                }
                tracing::info!(session = %session.id, tool, ran_ms = ran.as_millis() as u64, "the person's message waits: moving the call to the background");
                if let Err(e) = self.background_session(session, Some(tool), true).await {
                    tracing::debug!(tool, error = %e.message, "background for a waiting message refused");
                }
            }
            let Some(wait) = next else { return };
            tokio::time::sleep(wait).await;
        }
    }

    /// How long a foreground shell runs before it goes to the background; None turns it off
    /// (tests shorten it).
    pub fn set_auto_background_after(&self, after: Option<std::time::Duration>) {
        *self.auto_background_after.lock().unwrap_or_else(|e| e.into_inner()) = after;
    }

    /// Arms the timer for the foreground shell `params`' update starts, in a Claude Code chat's
    /// own running turn (module docs). History a load replays starts nothing.
    pub(super) fn arm_auto_background(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Option<&Value>,
        replayed: bool,
    ) {
        if replayed || !session.backgrounds_work.load(Ordering::SeqCst) {
            return;
        }
        let Some(after) = *self.auto_background_after.lock().unwrap_or_else(|e| e.into_inner())
        else {
            return;
        };
        let Some(params) = params else { return };
        let Some(update) = params.get("update") else { return };
        let Some(tool) = foreground_shell(update) else { return };
        if declared_timeout(update).is_some_and(|wait| wait > after) {
            return;
        }
        let sid = params.get("sessionId").and_then(Value::as_str);
        if sid.is_some_and(|sid| {
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).owns(sid)
        }) {
            return;
        }
        // One timer a call: its command may come twice (the call, then an update).
        let key = format!("{}/{tool}", session.id);
        if !self.auto_background_armed.lock().unwrap_or_else(|e| e.into_inner()).insert(key.clone())
        {
            return;
        }
        let tool = tool.to_owned();
        let (hub, chat) = (Arc::downgrade(self), Arc::downgrade(session));
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(after).await;
                let Some(hub) = hub.upgrade() else { return };
                let disarm = || {
                    hub.auto_background_armed
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&key);
                };
                let Some(chat) = chat.upgrade() else { return disarm() };
                let in_flight = chat
                    .turn
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .as_ref()
                    .is_some_and(|t| t.doing.open_tools.contains(&tool));
                if !in_flight {
                    return disarm();
                }
                match hub.background_session(&chat, Some(&tool), true).await {
                    Ok(answer) if answer.get("backgrounded") == Some(&Value::Bool(false)) => {}
                    Ok(_) => return disarm(),
                    Err(e) => {
                        tracing::debug!(tool, error = %e.message, "auto-background refused");
                        return disarm();
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_json::JsonSet as _;

    /// A steer answered before it was written (held, or refused) moves nothing; one written moves
    /// work only from then on, while its answer is still to come.
    #[tokio::test]
    async fn work_moves_only_once_the_steer_is_written() {
        let moved = std::sync::atomic::AtomicBool::new(false);
        let mover = || async { moved.store(true, Ordering::SeqCst) };
        let written = tokio::sync::Notify::new();
        let held = async {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            "held"
        };
        assert_eq!(answer_once_written(&written, held, mover()).await, "held");
        assert!(!moved.load(Ordering::SeqCst), "a steer never written moved work");

        let (tx, rx) = tokio::sync::oneshot::channel::<&str>();
        let answer = async {
            written.notify_one();
            tokio::task::yield_now().await;
            assert!(moved.load(Ordering::SeqCst), "the written steer moved nothing");
            rx.await.unwrap()
        };
        tx.send("read").unwrap();
        assert_eq!(answer_once_written(&written, answer, mover()).await, "read");
    }

    #[test]
    fn the_wait_comes_from_the_env_and_zero_turns_it_off() {
        assert_eq!(after_of(None), Some(AUTO_BACKGROUND_AFTER));
        assert_eq!(after_of(Some("")), Some(AUTO_BACKGROUND_AFTER));
        assert_eq!(after_of(Some("90")), Some(std::time::Duration::from_secs(90)));
        assert_eq!(after_of(Some("0")), None);
        assert_eq!(after_of(Some("soon")), Some(AUTO_BACKGROUND_AFTER));
    }

    #[test]
    fn a_declared_timeout_is_read_in_milliseconds() {
        let call = |input: Value| json!({"rawInput": input});
        assert_eq!(declared_timeout(&call(json!({"command": "x"}))), None);
        assert_eq!(
            declared_timeout(&call(json!({"command": "x", "timeout": 600000}))),
            Some(std::time::Duration::from_secs(600))
        );
        assert_eq!(
            declared_timeout(&call(json!({"command": "x", "timeout": 1500.0}))),
            Some(std::time::Duration::from_millis(1500))
        );
        assert_eq!(declared_timeout(&call(json!({"command": "x", "timeout": "soon"}))), None);
    }

    #[test]
    fn only_a_new_foreground_shell_arms_it() {
        let call = |input: Value| {
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute",
                "status": "in_progress", "rawInput": input})
        };
        assert_eq!(foreground_shell(&call(json!({"command": "make"}))), Some("t1"));
        assert_eq!(
            foreground_shell(&call(json!({"command": "make", "run_in_background": false}))),
            Some("t1")
        );
        assert_eq!(
            foreground_shell(&call(json!({"command": "npm run dev", "run_in_background": true}))),
            None
        );
        // Announced before its input streamed: no command yet, nothing to time.
        assert_eq!(foreground_shell(&call(json!({}))), None);
        let mut read = call(json!({"command": "x"}));
        read.set("kind", json!("read"));
        assert_eq!(foreground_shell(&read), None);
        // A call named early gets its command in the update that follows.
        let mut update = call(json!({"command": "make"}));
        update.set("sessionUpdate", json!("tool_call_update"));
        assert_eq!(foreground_shell(&update), Some("t1"));
        update.set("status", json!("completed"));
        assert_eq!(foreground_shell(&update), None);
    }
}
