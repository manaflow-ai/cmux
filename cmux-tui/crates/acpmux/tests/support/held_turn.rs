//! When a test may count a held turn (a stand-in agent's `gate:` prompt) as running, so that what
//! it does next comes after that turn's prompt (`tests/forum.rs` `Gate::hold`). Shared with the
//! hub's own test of that moment (`src/hub/forum_held_turn_tests.rs`).

use serde_json::Value;

/// Whether `summary` (`Hub::session_summary`) shows the turn's prompt sent to its agent: the
/// status turns `running` only once the prompt, rules block included, is built (`turns.rs`).
/// A turn that shows is not enough (`wait --until running` resolves on it): it shows before
/// its prompt is built, and a rule posted in that moment goes in with the held prompt.
pub fn prompt_sent(summary: &Value) -> bool {
    summary["status"] == "running"
}
