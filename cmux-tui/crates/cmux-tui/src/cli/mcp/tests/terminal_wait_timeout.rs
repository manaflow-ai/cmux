//! `terminal_wait` and `terminal_wait_exit` say `timed_out` the way the CLI's
//! `screen wait` and `process wait` do: a wait whose time ran out (no match,
//! a process still running) has `timed_out: true` and `waited_ms`, so an agent
//! never reads "still running" as "done".

use serde_json::{Value, json};

use super::{Fake, call};
use crate::cli::mcp::Server;

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

fn answer(tool: &str, daemon: Value, arguments: Value) -> Value {
    let fake = Fake { resource_result: Some(daemon), ..Fake::default() };
    let mut server = Server::new(fake, None);
    let result = call(&mut server, tool, arguments);
    assert_eq!(result["isError"], false, "a timeout is an answer, not an error: {result}");
    result["structuredContent"].clone()
}

#[test]
fn a_terminal_wait_that_ran_out_of_time_says_timed_out() {
    let arguments = json!({"terminal": TERMINAL, "pattern": "ready", "timeout_ms": "500"});
    let missed =
        answer("terminal_wait", json!({"matched": false, "text": "$ "}), arguments.clone());
    assert_eq!(missed["matched"], false, "{missed}");
    assert_eq!(missed["timed_out"], true, "{missed}");
    assert_eq!(missed["waited_ms"], "500", "{missed}");
    assert_eq!(missed["text"], "$ ", "{missed}");

    let found = answer("terminal_wait", json!({"matched": true, "text": "ready"}), arguments);
    assert_eq!(found["timed_out"], false, "{found}");
    assert!(found.get("waited_ms").is_none(), "{found}");
}

#[test]
fn a_process_wait_on_a_running_process_says_timed_out() {
    let arguments = json!({"terminal": TERMINAL, "timeout_ms": "500"});
    let pending = json!({
        "state": "pending", "terminal_id": TERMINAL, "lifecycle": "running", "revision": "4"
    });
    let running = answer("terminal_wait_exit", pending, arguments.clone());
    assert_eq!(running["state"], "pending", "{running}");
    assert_eq!(running["timed_out"], true, "{running}");
    assert_eq!(running["waited_ms"], "500", "{running}");

    let exited = json!({
        "state": "exited", "terminal_id": TERMINAL, "lifecycle": "exited",
        "outcome": {"kind": "exit", "code": 5}, "exited_at": "1", "revision": "5"
    });
    let exited = answer("terminal_wait_exit", exited, arguments);
    assert_eq!(exited["outcome"]["code"], 5, "{exited}");
    assert_eq!(exited["timed_out"], false, "{exited}");
}
