//! The retry of agent host adoptions whose hello missed the start's pass (cmuxterm-hq#5545).

use super::*;
use crate::agent_host;
use futures_util::StreamExt;

impl Hub {
    /// Adopt again, once and with [`agent_host::link::ADOPT_HELLO_BUDGET`], the hosts whose hello
    /// missed the start's pass. A host that is only slow (a loaded Mac) was otherwise left running
    /// with its agent and every MCP server under it, and no daemon controlling it, until a prompt
    /// reached its chat (cmuxterm-hq#5545: 9 of 85 hosts at load 118).
    ///
    /// Each attempt holds the full-access family gate through its hello (`adopt_one`), so an MDM
    /// off pushed while a host stays silent waits up to that budget, not 5 s. Accepted: the off
    /// still ends that host once the hello settles, and only a wedged host costs the full 30 s.
    pub(super) async fn retry_missed_adoptions(self: &Arc<Self>, sessions: Vec<String>) {
        if self.shutting_down() {
            return;
        }
        let dir = agent_host::hosts_dir();
        let Ok((good, _)) = agent_host::load_records(&dir) else { return };
        let off = self.off_latch();
        let retry: Vec<_> =
            good.into_iter().filter(|(_, r)| sessions.contains(&r.session_id)).collect();
        tracing::info!(count = retry.len(), "retrying agent host adoptions whose hello was late");
        futures_util::stream::iter(retry)
            .for_each_concurrent(8, |(_, record)| {
                let (dir, off) = (&dir, &off);
                async move {
                    if self.shutting_down() {
                        return;
                    }
                    let session = record.session_id.clone();
                    let late = agent_host::link::with_hello_budget(
                        agent_host::link::ADOPT_HELLO_BUDGET,
                        self.adopt_record(dir, record, off),
                    )
                    .await;
                    if late {
                        tracing::warn!(session = %session, "agent host still did not answer hello; a prompt to its chat tries again");
                    }
                }
            })
            .await;
    }
}

/// The start's adoption pass, run under [`agent_host::link::START_HELLO_BUDGET`]: a host that
/// accepts the connection and never answers its hello must not hold the daemon's startup, and so
/// every new session, forever; it is retried ([`Hub::retry_missed_adoptions`]) off the startup
/// path. A debug build's test may set the budget: `ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS` makes every
/// first hello of that pass miss as on a loaded Mac, so the retry is what adopts. Release builds
/// have no seam.
pub(super) async fn adoption_hello_scope<F: std::future::Future>(work: F) -> F::Output {
    agent_host::link::with_hello_budget(start_hello_budget(), work).await
}

/// The first adoption pass's hello budget: [`agent_host::link::START_HELLO_BUDGET`], or a debug
/// build's test value.
pub(super) fn start_hello_budget() -> std::time::Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        return std::time::Duration::from_millis(ms);
    }
    agent_host::link::START_HELLO_BUDGET
}

// The wedged host is a Unix socket listener (agent hosts on Windows use another transport).
#[cfg(all(test, unix))]
mod tests {
    use crate::agent_host::{self, HostRecord};

    /// A host that accepts the connection and never reads it (its event loop wedged, 2026-11-06):
    /// the start's pass gives up on it after its budget, so the start, and every new session
    /// waiting on it, goes on. Before, the release pass had no budget and waited forever.
    #[tokio::test(start_paused = true)]
    async fn the_start_pass_gives_up_on_a_host_that_never_answers_hello() {
        // Short, so the socket stays under SUN_LEN (104 bytes on macOS) under a long TMPDIR.
        let dir = cmux_unix_socket::short_test_dir("acpmux-h");
        let socket = dir.path().join("host.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        // Accepts and keeps every connection, never reads one.
        let wedged = tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });
        let record = HostRecord {
            record_version: 1,
            session_id: "wedged".into(),
            incarnation: "i".into(),
            host_pid: std::process::id(),
            start_nonce: "00".into(),
            harness_pid: None,
            owner_token: "t".into(),
            caller_token: None,
            protocol_min: agent_host::PROTOCOL_MIN,
            protocol_max: agent_host::PROTOCOL_MAX,
            host_build: "test".into(),
            socket,
        };
        let started = tokio::time::Instant::now();
        let result = super::adoption_hello_scope(agent_host::link::connect(record, 0)).await;
        let error = result.err().expect("a host that never answers is not adopted");
        assert!(agent_host::link::missed_hello(&error), "{error:#}");
        let waited = started.elapsed();
        let budget = agent_host::link::START_HELLO_BUDGET;
        assert!(waited >= budget && waited < budget * 2, "waited {waited:?}");
        wedged.abort();
    }
}
