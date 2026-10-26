//! The `energy_status` tool (p14-energy-033): it reads the app's
//! `debug.energy` and changes nothing.

use super::*;

#[test]
fn energy_status_tool_reads_the_app_and_takes_no_arguments() {
    let mut server = Server::new(Fake::with_actions(), None);
    let tools = server.list();
    let tool = tools.iter().find(|tool| tool["name"] == "energy_status").expect("listed");
    assert_eq!(tool["annotations"]["readOnlyHint"], true);
    let result = call(&mut server, "energy_status", json!({}));
    assert_eq!(result["isError"], false, "{result}");
    let sent = server.backend.last("app");
    assert_eq!(
        (sent["method"].clone(), sent["mutation"].clone()),
        (json!("debug.energy"), json!(false))
    );
    assert_eq!(call(&mut server, "energy_status", json!({"saver": true}))["isError"], true);
}
