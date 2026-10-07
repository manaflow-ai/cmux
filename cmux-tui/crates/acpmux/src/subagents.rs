//! Subagent attribution for session updates.

use serde_json::Value;

#[derive(Debug, Default)]
pub struct SubagentTree;

impl SubagentTree {
    pub fn annotate(&mut self, _params: &mut Value) -> Option<String> {
        None
    }
}
