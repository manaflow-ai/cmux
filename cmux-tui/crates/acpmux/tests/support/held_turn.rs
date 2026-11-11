//! When a test may count a held turn (a stand-in agent's `gate:` prompt) as running, so that what
//! it does next comes after that turn's prompt (`tests/forum.rs` `Gate::hold`). Shared with the
//! hub's own test of that moment (`src/hub/forum_held_turn_tests.rs`).

use serde_json::Value;

/// Whether `summary` (`Hub::session_summary`) shows the turn's prompt sent to its agent.
pub fn prompt_sent(summary: &Value) -> bool {
    let status = summary["status"].as_str().unwrap_or_default();
    status == "running" || status == "waiting" || !summary["turn"].is_null()
}
