//! The daemon's sidebar tree (`list-workspaces`) and find bar (`terminal-find`) in the mux
//! protocol's own words: a tab is the object with a numeric `surface`, and `terminal-find`
//! names its terminal by that number. `cmux search` reads them here and prints only the
//! resource-v2 IDs the tree also carries (`terminal_id`, `tab_resource_id`), never the
//! number.

use serde_json::{Value, json};

/// The mux's number for a tab, when `node` is one.
pub(in crate::cli) fn tab_number(node: &Value) -> Option<u64> {
    node.get("surface").and_then(Value::as_u64)
}

/// One `terminal-find` page request for the terminal the mux numbers `tab`.
pub(in crate::cli) fn terminal_find_request(tab: u64, query: &str, max_matches: usize) -> Value {
    json!({
        "cmd": "terminal-find",
        "surface": tab,
        "query": query,
        "max_matches": max_matches,
    })
}
