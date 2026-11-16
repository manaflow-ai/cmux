//! A Cloud seed must finish before the harness or its file-write tools run.
//!
//! One exception, for a harness start ([`wait_for_start`]): a Claude Code session runs every tool
//! through the `cmux-repo-sync` PreToolUse callback (`claude_stdio/hook_callback.rs`), which waits
//! for the whole checkout. Its start may go ahead once the seed says the head is in place
//! (`Probe::HeadReady`), so its first prompt waits on the root and instruction files only, never on
//! the whole clone (cmuxterm-hq goals/cloud-no-network-wait.md). Every other harness, and every
//! tool and write, still waits for the whole checkout.
use super::*;

#[cfg(unix)]
pub(super) type Ready = cmux_git::sync_barrier::Ready;
#[cfg(not(unix))]
pub(super) type Ready = ();

/// Only an active sync retries, for as long as it runs: its producer holds the marker's lock
/// while it lives, and a failed or dead one leaves the checkout incomplete. Failure,
/// cancellation and unreadable state refuse the operation; none turns a partial checkout into
/// ready. No deadline fails a wait while the seed is alive (the timer rule).
pub(super) async fn wait(
    session: &Session,
    path: std::path::PathBuf,
    cancelled: impl Fn() -> bool,
) -> Result<Ready, RpcError> {
    wait_until(session, path, false, cancelled)
        .await?
        .ok_or_else(|| RpcError::internal("a whole-checkout wait ended at the head"))
}

/// [`wait`] for a harness start. `head_ok`: the harness gates each of its tools on the whole
/// checkout itself, so the start goes ahead at the head (`None`: no lease, the seed runs on).
pub(super) async fn wait_for_start(
    session: &Session,
    path: std::path::PathBuf,
    head_ok: bool,
    cancelled: impl Fn() -> bool,
) -> Result<Option<Ready>, RpcError> {
    wait_until(session, path, head_ok, cancelled).await
}

/// Whether a harness of this kind runs every tool through the sync gate itself: Claude Code over
/// its stream registers the `cmux-repo-sync` PreToolUse callback for every tool (matcher `*`,
/// `claude_stdio::outbound::initialize_request`, on unix). Another harness may run a read or a
/// full-access tool that no permission request shows, so it waits for the whole checkout.
pub(super) fn gates_its_tools(kind: crate::config::HarnessKind) -> bool {
    cfg!(unix) && kind == crate::config::HarnessKind::ClaudeStdio
}

/// [`gates_its_tools`] for a running agent, from what it speaks rather than the profile: a
/// reload may change the profile's harness without replacing the agent. Only a stream it
/// translates itself registers the callback; a hosted agent's is not known here, so it waits.
pub(super) fn child_gates_its_tools(child: &crate::agent::ChildAgent) -> bool {
    cfg!(unix) && child.translator.is_some()
}

async fn wait_until(
    session: &Session,
    path: std::path::PathBuf,
    head_ok: bool,
    cancelled: impl Fn() -> bool,
) -> Result<Option<Ready>, RpcError> {
    #[cfg(not(unix))]
    {
        let _ = (session, path, head_ok, cancelled);
        Ok(Some(()))
    }
    #[cfg(unix)]
    {
        use cmux_git::sync_barrier::{Probe, probe};
        let started = tokio::time::Instant::now();
        loop {
            if cancelled() {
                return Err(super::turns::stopped_before_prompt());
            }
            let path = path.clone();
            let state = tokio::task::spawn_blocking(move || probe(&path))
                .await
                .map_err(|error| RpcError::internal(error.to_string()))?
                .map_err(|error| refusal(format!("cannot read repository sync state: {error}")))?;
            if cancelled() {
                return Err(super::turns::stopped_before_prompt());
            }
            match state {
                Probe::Ready(ready) => {
                    let waited_ms = started.elapsed().as_millis();
                    if waited_ms >= 100 {
                        tracing::info!(session = %session.id, waited_ms, "repository sync completed before agent operation");
                    }
                    return Ok(Some(ready));
                }
                Probe::HeadReady if head_ok => {
                    let waited_ms = started.elapsed().as_millis();
                    tracing::info!(
                        session = %session.id,
                        waited_ms,
                        "repository head in place; the harness starts while the rest arrives"
                    );
                    return Ok(None);
                }
                Probe::Incomplete => {
                    return Err(refusal(
                        "repository sync did not complete; retry syncing the repository",
                    ));
                }
                Probe::HeadReady | Probe::Syncing => {}
            }
            // No timer remains after ready/cancel/failure. Unlike a blocking
            // flock, this wait cannot strand a worker after the turn is stopped.
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    }
}

#[cfg(unix)]
fn refusal(message: impl Into<String>) -> RpcError {
    RpcError::new(-32000, message).with_data(json!({"reason": "repo_sync_incomplete"}))
}
