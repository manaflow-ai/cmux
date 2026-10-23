//! `_acpmux/protocol`: the daemon serves the protocol IR it was built with
//! (`protocol::ir()`, committed as `spec/acpmux-protocol.json`), so a client
//! or a peer reads the surface of the daemon it talks to.

use super::*;

#[tokio::test]
async fn the_daemon_serves_its_protocol_ir() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let ir = c.request("_acpmux/protocol", json!({})).await.unwrap();
    assert_eq!(ir, acpmux::protocol::ir());
    let names: Vec<&str> =
        ir["methods"].as_array().unwrap().iter().filter_map(|m| m["name"].as_str()).collect();
    for name in ["_acpmux/protocol", "_acpmux/sessions", method::SESSION_PROMPT] {
        assert!(names.contains(&name), "{name} missing from the served IR");
    }
}
