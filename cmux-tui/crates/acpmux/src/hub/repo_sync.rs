//! A Cloud seed must finish before the harness or its file-write tools run.
use super::*;

#[cfg(unix)]
pub(super) type Ready = cmux_git::sync_barrier::Ready;
#[cfg(not(unix))]
pub(super) type Ready = ();

/// Only an active sync retries. Failure, cancellation, unreadable state and the
/// deadline refuse the operation; none turns a partial checkout into ready.
pub(super) async fn wait(
    session: &Session,
    path: std::path::PathBuf,
    cancelled: impl Fn() -> bool,
) -> Result<Ready, RpcError> {
    #[cfg(not(unix))]
    {
        let _ = (session, path, cancelled);
        Ok(())
    }
    #[cfg(unix)]
    {
        use cmux_git::sync_barrier::{Probe, probe};
        let started = tokio::time::Instant::now();
        let deadline = started + std::time::Duration::from_secs(10 * 60);
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
                    return Ok(ready);
                }
                Probe::Incomplete => {
                    return Err(refusal(
                        "repository sync did not complete; retry syncing the repository",
                    ));
                }
                Probe::Syncing => {}
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(refusal("repository sync is still running; retry when it finishes"));
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
