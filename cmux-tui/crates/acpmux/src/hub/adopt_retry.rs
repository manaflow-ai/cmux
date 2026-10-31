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

/// The start's adoption pass, run under the hello budget a debug build's test sets:
/// `ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS` makes every first hello of that pass miss as on a loaded
/// Mac, so the retry ([`Hub::retry_missed_adoptions`]) is what adopts. Release builds have no seam.
pub(super) async fn adoption_hello_scope<F: std::future::Future>(work: F) -> F::Output {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        return agent_host::link::with_hello_budget(std::time::Duration::from_millis(ms), work)
            .await;
    }
    work.await
}
