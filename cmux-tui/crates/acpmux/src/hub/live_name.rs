//! Part of `Hub`; see `hub/mod.rs`. A renamed session's running Claude Code takes the new name
//! (`claude_stdio::RENAME`, `claude_stdio/live_name.rs`), so its peer list and a held message's
//! "From:" follow `acpmux ls` without waiting for its next start, which passes `--name`
//! (`agent/command.rs`). Between turns now; while a turn runs, when it ends. A host older than this
//! answers method-not-found, and its Claude Code takes the name at its next start; an update
//! restarts such hosts between turns (`stale_host_respawn.rs`).

use super::*;
use std::time::Duration;

/// How long one rename may take: a local command, answered in milliseconds.
const ANSWER_WITHIN: Duration = Duration::from_secs(10);
/// How long a refused rename waits for a turn to end before it asks again anyway.
const TURN_WAIT: Duration = Duration::from_secs(600);
/// How long a rename refused behind an unanswered one waits before it asks again.
const IN_FLIGHT_WAIT: Duration = Duration::from_secs(2);
/// Asks at most this often for one rename: a chat that never goes idle keeps its old name until
/// its next start.
const MAX_ASKS: usize = 50;

impl Hub {
    /// After `rename`: the session's running Claude Code takes its name. Never starts one.
    pub(super) fn rename_live_claude(&self, session: &Arc<Session>) {
        let claude = {
            let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            !meta.remote_origin && crate::claude_stdio::steers_by_info(meta.agent_info.as_ref())
        };
        if !claude {
            return;
        }
        // Subscribed before the first ask: a turn that ends after a refusal is never missed.
        let mut events = self.subscribe();
        let session = session.clone();
        tokio::spawn(async move {
            for _ in 0..MAX_ASKS {
                if session.closing.load(Ordering::SeqCst) {
                    return;
                }
                let Some(child) = session.child.lock().await.clone() else { return };
                if !child.is_alive().await {
                    return;
                }
                let name = session.meta().name;
                let params = json!({"sessionId": session.id, "name": name});
                match child.request_within(crate::claude_stdio::RENAME, params, ANSWER_WITHIN).await
                {
                    // Renamed again meanwhile: that name too.
                    Some(Ok(_)) if session.meta().name == name => return,
                    Some(Ok(_)) => continue,
                    // The last `/rename` is unanswered, or given up on after a while: soon again.
                    Some(Err(e)) if e.message == crate::claude_stdio::RENAME_IN_FLIGHT => {
                        tokio::time::sleep(IN_FLIGHT_WAIT).await;
                    }
                    Some(Err(e)) if e.message == crate::claude_stdio::RENAME_BUSY => {
                        let ended = async {
                            loop {
                                match events.recv().await {
                                    Ok(ev)
                                        if ev.session_id == session.id
                                            && ev.record.dir == "mux"
                                            && ev.record.kind == "turn_result" =>
                                    {
                                        return true;
                                    }
                                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                                    Err(broadcast::error::RecvError::Closed) => return false,
                                }
                            }
                        };
                        if tokio::time::timeout(TURN_WAIT, ended).await == Ok(false) {
                            return;
                        }
                    }
                    Some(Err(e)) => {
                        tracing::debug!(session = %session.id, "live rename refused: {}", e.message);
                        return;
                    }
                    None => {
                        tracing::debug!(session = %session.id, "live rename timed out");
                        return;
                    }
                }
            }
        });
    }
}
