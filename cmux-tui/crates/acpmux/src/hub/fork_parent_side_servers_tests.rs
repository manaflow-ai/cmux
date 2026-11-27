use super::parent_side_servers;
use serde_json::json;

/// OpenCode's parent process gets no servers with its `session/fork` (they would replace the
/// parent's own); every other agent gets the fork's list as before.
#[test]
fn only_opencode_forks_without_servers() {
    let servers =
        json!([{"name": "acpmux", "type": "http", "url": "http://x/mcp/fork/tools/acpmux"}]);
    assert_eq!(parent_side_servers(true, servers.clone()), json!([]));
    assert_eq!(parent_side_servers(false, servers.clone()), servers);
}
