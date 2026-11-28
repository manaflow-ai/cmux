#[test]
fn every_server_answers_its_connect() {
    // Five servers, two answers each, each well past an empty reply.
    assert!(super::mcp_connect() > 5 * 2 * 100);
}
