//! Hot paths the instruction-count bench (`benches/icount.rs`) runs under Callgrind. Not an
//! API: it reaches crate-private code so the bench measures what the daemon runs.

use std::collections::HashMap;
use std::sync::Arc;

/// One MCP connect to a chat's own tool servers, as the gateway answers it (`post_tools` in
/// `mcp_gateway.rs`): the servers made in the chat's tool env (`Chat::tools` on a chat's first
/// request), then for each server its `initialize` and `tools/list` request parsed, pointed at
/// the server, answered and serialized. Returns the answer bytes, so nothing is optimized out.
pub fn mcp_connect() -> usize {
    let session = "icount-session".to_owned();
    let env: HashMap<String, String> = [
        crate::acpmux_mcp_names::SESSION_ENV,
        crate::secret_mcp::SESSION_ENV,
        crate::offer_mcp::SESSION_ENV,
    ]
    .into_iter()
    .map(|key| (key.to_owned(), session.clone()))
    .collect();
    let daemon = Arc::new(crate::tools_mcp::Daemon::at("/nonexistent/icount.sock".into()));
    let servers = crate::tool_env::sync_scope(env, || crate::tools_mcp::servers(&daemon));
    let mut bytes = 0;
    for served in servers.iter() {
        for request in [INITIALIZE, TOOLS_LIST] {
            let Ok(mut message) = serde_json::from_slice::<serde_json::Value>(request) else {
                continue;
            };
            crate::mcp_gateway::for_server(&mut message, served.name);
            if let crate::tools_mcp::Answer::Now(answer) =
                crate::tools_mcp::answer(&servers, &message)
            {
                bytes += answer.to_string().len();
            }
        }
    }
    bytes
}

const INITIALIZE: &[u8] = br#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"claude-code","version":"2.1.0"}}}"#;
const TOOLS_LIST: &[u8] = br#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#;

#[cfg(test)]
mod tests {
    #[test]
    fn every_server_answers_its_connect() {
        // Five servers, two answers each, each well past an empty reply.
        assert!(super::mcp_connect() > 5 * 2 * 100);
    }
}
