use super::*;

/// A start carries this Mac's answer over whatever its caller put there; its other fields stay.
#[test]
fn a_start_carries_this_macs_answer_not_the_callers() {
    let caller = json!({"cwd": "/w", "_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
    let params = start_params(&caller, "off").unwrap();
    assert_eq!(params["_meta"]["acpmux"]["cmuxTools"], "off");
    assert_eq!(params["_meta"]["acpmux"]["harness"], "codex");
    assert_eq!(params["cwd"], "/w");
    assert_eq!(
        start_params(&json!({"cwd": "/w"}), "on").unwrap()["_meta"]["acpmux"]["cmuxTools"],
        "on"
    );
    assert!(start_params(&json!("x"), "on").is_err());
}
