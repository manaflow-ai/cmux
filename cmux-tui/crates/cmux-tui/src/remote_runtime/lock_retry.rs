//! Waits for a lock another process holds: the client socket path lock and
//! the predecessor daemon's authorization-state lease. flock has no readiness
//! event, so each attempt after a refusal is spaced by the shared
//! [`Backoff`] (2 ms doubling to its cap), never by a fixed short period.

use super::*;
use cmux_tui_core::backoff::Backoff;

const CLIENT_SOCKET_LOCK_RETRY_FIRST: Duration = Duration::from_millis(2);
/// The client lock wait has no deadline (it ends with the lock or shutdown).
const CLIENT_SOCKET_LOCK_RETRY_MAX: Duration = Duration::from_millis(100);
const DAEMON_AUTH_LEASE_RETRY_FIRST: Duration = Duration::from_millis(2);
/// A handoff is bounded by `DAEMON_AUTH_LEASE_RETRY_TIMEOUT`; a lower cap
/// keeps the successor close behind the predecessor's release.
const DAEMON_AUTH_LEASE_RETRY_MAX: Duration = Duration::from_millis(50);

#[cfg(unix)]
pub(super) async fn acquire_client_socket_lock(
    path: &Path,
    shutdown: Option<&mut watch::Receiver<bool>>,
) -> anyhow::Result<OwnerFileLock> {
    let mut backoff = Backoff::new(CLIENT_SOCKET_LOCK_RETRY_FIRST, CLIENT_SOCKET_LOCK_RETRY_MAX);
    acquire_client_socket_lock_spaced(path, shutdown, &mut backoff).await
}

#[cfg(unix)]
async fn acquire_client_socket_lock_spaced(
    path: &Path,
    mut shutdown: Option<&mut watch::Receiver<bool>>,
    backoff: &mut Backoff,
) -> anyhow::Result<OwnerFileLock> {
    use std::os::fd::AsRawFd;

    let file = open_owner_lock_file(path, "client socket lock")?;

    loop {
        // SAFETY: `file` is open for the call and flock takes no pointer.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(OwnerFileLock { file });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(error)
                .with_context(|| format!("could not lock client socket path {}", path.display()));
        }
        // wakeup-allow: backoff flock refused while another client holds the path; doubles to 100 ms, shutdown ends it.
        let retry = tokio::time::sleep(backoff.next_delay());
        match shutdown.as_deref_mut() {
            Some(shutdown) => {
                tokio::select! {
                    _ = retry => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote client startup was cancelled"));
                    }
                }
            }
            None => retry.await,
        }
    }
}

pub(super) async fn load_daemon_auth_during_handoff(
    state_dir: &Path,
    daemon_name: &str,
    shutdown: &mut watch::Receiver<bool>,
    retry_timeout: Duration,
) -> anyhow::Result<Arc<AuthDatabase>> {
    let mut backoff = Backoff::new(DAEMON_AUTH_LEASE_RETRY_FIRST, DAEMON_AUTH_LEASE_RETRY_MAX);
    load_daemon_auth_spaced(state_dir, daemon_name, shutdown, retry_timeout, &mut backoff).await
}

async fn load_daemon_auth_spaced(
    state_dir: &Path,
    daemon_name: &str,
    shutdown: &mut watch::Receiver<bool>,
    retry_timeout: Duration,
    backoff: &mut Backoff,
) -> anyhow::Result<Arc<AuthDatabase>> {
    let deadline = tokio::time::Instant::now() + retry_timeout;
    loop {
        match AuthDatabase::load_or_create(state_dir, daemon_name.to_owned(), true) {
            Ok(auth) => return Ok(auth),
            Err(IdentityError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if *shutdown.borrow() {
                    return Err(anyhow!("remote daemon startup was cancelled"));
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err(anyhow::Error::new(IdentityError::Io(error)).context(
                        "remote daemon authorization state is still owned by another process",
                    ));
                }
                // wakeup-allow: backoff the predecessor still holds the lease; doubles to 50 ms within the handoff deadline.
                let retry = tokio::time::sleep(backoff.next_delay().min(remaining));
                tokio::select! {
                    _ = retry => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote daemon startup was cancelled"));
                    }
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    use super::*;

    fn locked(path: &Path) -> fs::File {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(path)
            .unwrap();
        // SAFETY: `lock` is open for the call and flock takes no pointer.
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        lock
    }

    #[tokio::test]
    async fn client_socket_lock_wait_backs_off_while_another_client_holds_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("client.sock.lock");
        let holder = locked(&path);
        let release = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            drop(holder);
        });
        let mut backoff =
            Backoff::new(CLIENT_SOCKET_LOCK_RETRY_FIRST, CLIENT_SOCKET_LOCK_RETRY_MAX);

        let lock = acquire_client_socket_lock_spaced(&path, None, &mut backoff).await;

        assert!(lock.is_ok(), "the lock was not taken after its holder released it");
        release.await.unwrap();
        // The fixed 10 ms retry tried about 30 times in this window.
        let attempts = backoff.attempts();
        assert!(attempts <= 12, "the client lock was tried {attempts} times in 300 ms");
    }

    #[tokio::test]
    async fn daemon_auth_handoff_backs_off_while_the_predecessor_holds_its_lease() {
        let directory = tempfile::tempdir().unwrap();
        let auth_state = directory.path().join("auth");
        fs::create_dir_all(&auth_state).unwrap();
        let holder = locked(&auth_state.join("devices.json.lock"));
        let (_shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let mut backoff = Backoff::new(DAEMON_AUTH_LEASE_RETRY_FIRST, DAEMON_AUTH_LEASE_RETRY_MAX);

        let result = load_daemon_auth_spaced(
            &auth_state,
            "spaced-handoff",
            &mut shutdown_rx,
            Duration::from_millis(300),
            &mut backoff,
        )
        .await;

        drop(holder);
        assert!(result.is_err(), "the lease was taken while its predecessor held it");
        // The fixed 10 ms retry tried about 30 times in this window.
        let attempts = backoff.attempts();
        assert!(attempts <= 14, "the auth lease was tried {attempts} times in 300 ms");
    }
}
