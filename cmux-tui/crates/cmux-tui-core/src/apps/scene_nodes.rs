//! The scene node cap of one mount, counted in the daemon (extensions DESIGN.md section 5,
//! "Scene nodes per mount"). The in-VM runtime (`cmux-app-host/js/src/materialize.ts`
//! `LIMITS.nodesPerMount`) checks the same number, but code in the VM can reach the native
//! scene call past it; the host's count is the one that holds.
//!
//! The count follows the ops the client applies: `create` adds a node, `children` sets a
//! node's child list, `remove` drops a node and its whole subtree (the runtime sends one
//! `remove` per subtree). Ids it never saw are ignored, and a child list is only kept for a
//! node that exists, so whatever the app sends, the record holds at most [`MAX_NODES`]
//! nodes plus one batch.

use std::collections::HashMap;

use serde_json::Value;

/// Scene nodes one mount may hold.
pub(super) const MAX_NODES: usize = 4096;

/// What a mount over the cap fails with (the runtime's own message, so both read the same).
pub(super) fn over_cap_reason() -> String {
    format!("app.limit: more than {MAX_NODES} scene nodes")
}

/// The live nodes of one mount's scene and each one's children.
#[derive(Debug, Default)]
pub(super) struct SceneNodes {
    children: HashMap<String, Vec<String>>,
}

impl SceneNodes {
    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.children.len()
    }

    /// Forgets the tree (the next batch starts a fresh one: a host restart or a remount).
    pub(super) fn clear(&mut self) {
        self.children.clear();
    }

    /// Applies one batch. False when the mount now holds more than [`MAX_NODES`] nodes.
    pub(super) fn apply(&mut self, ops: &[Value]) -> bool {
        for op in ops {
            let Some(id) = op.get("id").and_then(Value::as_str) else { continue };
            match op.get("op").and_then(Value::as_str) {
                Some("create") => {
                    self.children.entry(id.to_string()).or_default();
                    if self.children.len() > MAX_NODES {
                        return false;
                    }
                }
                Some("children") => {
                    if let Some(kids) = self.children.get_mut(id) {
                        *kids = op
                            .get("children")
                            .and_then(Value::as_array)
                            .map(|list| {
                                list.iter().filter_map(Value::as_str).map(str::to_string).collect()
                            })
                            .unwrap_or_default();
                    }
                }
                Some("remove") => self.remove_subtree(id),
                _ => {}
            }
        }
        true
    }

    /// Drops `id` and every node under it. A node is visited once (it leaves the map when it
    /// is), so a cycle in hostile child lists ends.
    fn remove_subtree(&mut self, id: &str) {
        let mut stack = vec![id.to_string()];
        while let Some(next) = stack.pop() {
            if let Some(kids) = self.children.remove(&next) {
                stack.extend(kids);
            }
        }
    }
}

#[cfg(test)]
#[path = "scene_nodes_tests.rs"]
mod tests;
