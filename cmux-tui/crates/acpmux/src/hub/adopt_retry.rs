//! The retry of agent host adoptions whose hello missed the start's pass (cmuxterm-hq#5545).
//! Red: only the test seam; the retry is the next commit.

use crate::agent_host;

/// The start's adoption pass, run under the hello budget a debug build's test sets:
/// `ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS` makes every first hello of that pass miss as on a loaded
/// Mac, so a retry is what adopts. Release builds have no seam.
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
