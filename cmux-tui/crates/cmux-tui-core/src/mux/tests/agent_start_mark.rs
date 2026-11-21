//! `session.snapshot` marks the terminals that run a `cmux agent start`
//! launch (`extra.agent_start`) from the stored spawn argv (W5-Q review, PR C:
//! agent start evens only its own panes and never reads a process).

use serde_json::{Value, json};

use super::*;

fn snapshot(mux: &Arc<Mux>) -> Value {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"snapshot",
        "operation":"session.snapshot","params":{"machine":"current","session":"current"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn leaf(command: &[&str]) -> LayoutSpec {
    LayoutSpec::Leaf(LayoutLeafSpec {
        cwd: None,
        command: Some(command.iter().map(|word| (*word).to_owned()).collect()),
    })
}

/// The marks of the snapshot's terminals, in order.
fn marks(snapshot: &Value) -> Vec<Value> {
    snapshot["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|terminal| terminal["extra"]["agent_start"].clone())
        .collect()
}

#[test]
fn w5q_the_snapshot_marks_only_agent_start_terminals() {
    let mux = test_mux();
    // A person's shell beside an agent start launch, in one layout.
    let layout = split_spec(
        SplitDir::Right,
        0.5,
        leaf(&["/bin/sh", "-l"]),
        leaf(&["/bin/sh", "-lc", "claude \"$@\"", crate::agent_start_launch::ARG0]),
    );
    mux.apply_layout(None, None, &layout, None).unwrap();
    let snapshot = snapshot(&mux);
    let marks = marks(&snapshot);
    // Exactly the agent start terminal is marked; the shell has no mark.
    assert_eq!(marks.iter().filter(|mark| **mark == json!(true)).count(), 1, "{snapshot}");
    assert!(marks.iter().any(Value::is_null), "{snapshot}");
    assert!(marks.iter().all(|mark| mark.is_null() || *mark == json!(true)), "{snapshot}");
}
