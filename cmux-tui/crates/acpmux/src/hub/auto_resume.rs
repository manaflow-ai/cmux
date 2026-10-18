//! A turn a connection error cut off goes on by itself (cmuxterm-hq#2503). On 2026-10-18 one
//! relay host went dark for 24 minutes and every Codex turn streaming through it failed with
//! "stream disconnected"; each chat then sat idle until a person typed "continue".
//!
//! When a turn fails with a transport error ([`is_transport_error`]), the hub waits, then sends
//! the same chat one prompt that tells the agent its last turn was cut off and to check what
//! finished before it goes on. The prompt runs through the ordinary prompt path, so the agent is
//! started or resumed as for any prompt (Claude `--resume`, Codex `thread/resume`, else the
//! restored transcript) and the turn's rules (`control`, trust gate) are checked again.
//!
//! - `autoResumeDelaysMs` in the config sets the wait before each attempt; the default
//!   [`DEFAULT_DELAYS_MS`] spans about 26 minutes. `[]` turns it off.
//! - Attempt `n` of the prompt `P` has the prompt id `P~resume-n`, so it runs once, across
//!   restarts too, and a continuation that fails the same way schedules attempt `n + 1`.
//! - It is skipped when anything else ran in the chat meanwhile (a person's prompt, a cancel
//!   that started a turn), when the chat is closed or moving, or when a turn is running.
//! - Its `user_message` carries `_meta.provenance = {kind: "auto_resume", promptId, attempt,
//!   turnId}` so a client can show it as acpmux's, not the person's.
//! - A continuation that completes resumes the prompts the failed turn held (`pause_queue`):
//!   they waited only because of the connection.
//! - Usage limits and sign-in failures are not transport errors: the fallback profile handles
//!   those (`turns.rs`). A daemon restart mid-turn stays `outcome_unknown` (`mod.rs`).
//! - A wait in progress is not persisted: a daemon restart during it drops the attempt.

use super::{Control, Hub, PromptOptions, Session, SessionStatus};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// Waits before attempts 1, 2, 3 and 4, in milliseconds.
pub const DEFAULT_DELAYS_MS: [u64; 4] = [10_000, 60_000, 300_000, 1_200_000];

/// The prompt-id suffix of an automatic continuation, before its attempt number.
const SUFFIX: &str = "~resume-";

/// Longest error text quoted to the agent, in characters.
const MAX_ERROR_CHARS: usize = 300;

/// Does an agent error mean the connection to the model dropped, not that the prompt or the
/// account was at fault? Limit and sign-in errors are excluded: another account solves those.
pub fn is_transport_error(message: &str) -> bool {
    if super::turns::is_limit_error(message) {
        return false;
    }
    let m = message.to_lowercase();
    const PHRASES: &[&str] = &[
        "stream disconnected",
        "connection error",
        "connection reset",
        "connection refused",
        "connection closed",
        "connection aborted",
        "econnreset",
        "econnrefused",
        "etimedout",
        "socket hang up",
        "fetch failed",
        "network error",
        "error sending request",
        "broken pipe",
        "bad gateway",
        "service unavailable",
        "gateway timeout",
        "upstream connect error",
        "request timed out",
    ];
    PHRASES.iter().any(|p| m.contains(p))
        || (m.contains("websocket")
            && (m.contains("handshake") || m.contains("closed") || m.contains("disconnect")))
}

/// The prompt a continuation answers for, and the attempt it is (0 for a prompt of its own).
fn split_attempt(prompt_id: &str) -> (&str, usize) {
    if let Some((root, n)) = prompt_id.rsplit_once(SUFFIX)
        && let Ok(n) = n.parse::<usize>()
        && !root.is_empty()
    {
        return (root, n);
    }
    (prompt_id, 0)
}

/// The text the agent gets.
fn continue_text(error: &str) -> String {
    let error: String = error.chars().take(MAX_ERROR_CHARS).collect();
    format!(
        "Your previous turn was cut off by a connection error ({error}). Check what already \
         finished (files, commands, messages), then continue from where it stopped. Do not \
         redo work that completed."
    )
}

/// What a failed turn needs to be continued.
pub(super) struct CutTurn<'a> {
    pub prompt_id: &'a str,
    pub turn_id: &'a str,
    pub control: Control,
    pub trust_gate: bool,
    pub error: &'a str,
}

impl Hub {
    /// Schedules the next continuation of a turn that failed with a transport error. Nothing
    /// for any other failure, or once the configured attempts are used.
    pub(super) async fn schedule_auto_resume(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: CutTurn<'_>,
    ) {
        if !is_transport_error(cut.error) {
            return;
        }
        let delays = {
            let cfg = self.config.read().await;
            cfg.auto_resume_delays_ms.clone().unwrap_or_else(|| DEFAULT_DELAYS_MS.to_vec())
        };
        let (root, done) = split_attempt(cut.prompt_id);
        let Some(&delay) = delays.get(done) else {
            if done > 0 {
                self.append(
                    session,
                    "mux",
                    "auto_resume_exhausted",
                    json!({"promptId": root, "attempts": done, "turnId": cut.turn_id}),
                );
            }
            return;
        };
        let attempt = done + 1;
        let (root, turn_id, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        self.append(
            session,
            "mux",
            "auto_resume_scheduled",
            json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "delayMs": delay}),
        );
        let (hub, session, control, trust_gate) =
            (self.clone(), session.clone(), cut.control, cut.trust_gate);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(delay)).await;
            hub.auto_resume(&session, &root, attempt, &turn_id, &error, control, trust_gate).await;
        });
    }

    /// Sends attempt `attempt` when the chat still ends on the cut turn.
    #[allow(clippy::too_many_arguments)]
    async fn auto_resume(
        self: &Arc<Self>,
        session: &Arc<Session>,
        root: &str,
        attempt: usize,
        cut_turn: &str,
        error: &str,
        control: Control,
        trust_gate: bool,
    ) {
        let skipped = |why: &str| json!({"promptId": root, "attempt": attempt, "turnId": cut_turn, "skipped": why});
        if session.status() == SessionStatus::Closed || session.moving().is_some() {
            self.append(session, "mux", "auto_resume_skipped", skipped("closed"));
            return;
        }
        let last_turn = session.meta().last_turn;
        let still_cut = session.turn().is_none()
            && last_turn.as_ref().and_then(|t| t.get("turnId")).and_then(Value::as_str)
                == Some(cut_turn);
        if !still_cut {
            self.append(session, "mux", "auto_resume_skipped", skipped("superseded"));
            return;
        }
        let provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn});
        let opts = PromptOptions {
            prompt_id: Some(format!("{root}{SUFFIX}{attempt}")),
            resend: true,
            control,
            trust_gate,
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": continue_text(error)})];
        match self.prompt_with(session, blocks, "acpmux", false, opts).await {
            Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") => {
                self.resume_queue(session);
            }
            Ok(_) => {}
            // A failure that is itself a transport error scheduled the next attempt.
            Err(e) => tracing::warn!(session = %session.id, attempt, "auto resume: {}", e.message),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_errors_are_told_from_limits_and_bugs() {
        for m in [
            "stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)",
            "API Error: Connection error.",
            "request to https://api.anthropic.com failed, reason: socket hang up",
            "WebSocket handshake failed: 502",
            "upstream connect error or disconnect/reset before headers",
            "read ECONNRESET",
        ] {
            assert!(is_transport_error(m), "{m}");
        }
        for m in [
            "You've reached your usage limit for this account",
            "Selected model is at capacity. overloaded",
            "simulated internal error",
            "agent process closed",
            "Invalid API key",
        ] {
            assert!(!is_transport_error(m), "{m}");
        }
    }

    #[test]
    fn attempts_are_counted_from_the_prompt_id() {
        assert_eq!(split_attempt("p1"), ("p1", 0));
        assert_eq!(split_attempt("p1~resume-1"), ("p1", 1));
        assert_eq!(split_attempt("p1~resume-3"), ("p1", 3));
        assert_eq!(split_attempt("~resume-2"), ("~resume-2", 0));
        assert_eq!(split_attempt("p1~resume-x"), ("p1~resume-x", 0));
    }
}
