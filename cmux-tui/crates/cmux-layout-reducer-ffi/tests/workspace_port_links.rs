//! `workspace_port_links` through the C ABI: a workspace's hover card sends
//! its `ports` status entry once per card show and draws one link per port it
//! gets back; a click opens the link's URL in a browser tab of that workspace.

use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn ask(request: Value) -> Value {
    let request = request.to_string();
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"workspace_port_links".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_eq!(code, OK, "workspace_port_links refused {request}");
    serde_json::from_slice(&output[..len]).unwrap()
}

#[test]
fn workspace_port_links_the_daemons_ports_entry_opens_each_port_on_localhost() {
    assert_eq!(
        ask(json!({"ports": ":3000, :5173"})),
        json!([
            {"port": 3000, "label": "localhost:3000", "url": "http://localhost:3000/"},
            {"port": 5173, "label": "localhost:5173", "url": "http://localhost:5173/"},
        ])
    );
}

#[test]
fn workspace_port_links_an_entry_that_names_no_loopback_port_has_no_link() {
    assert_eq!(ask(json!({"ports": "web, 192.168.1.5:3000"})), json!([]));
    assert_eq!(ask(json!({})), json!([]));
}
