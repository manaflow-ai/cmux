use super::*;

#[test]
fn exceptions_map_to_evaluation_errors_with_names() {
    let error = evaluation_error(
        &json!({"text": "Uncaught", "exception": {"className": "TypeError", "description": "TypeError: a is not a function\n    at x"}}),
    );
    assert_eq!(error.code, ErrorCode::Evaluation);
    assert_eq!(error.message, "a is not a function");
    assert_eq!(error.error_name.as_deref(), Some("TypeError"));
    let thrown = evaluation_error(
        &json!({"text": "Uncaught", "exception": {"type": "string", "value": "plain"}}),
    );
    assert_eq!(thrown.message, "plain");
}

#[test]
fn dead_handles_are_stale() {
    let error = evaluation_error(
        &json!({"exception": {"className": "Error", "description": format!("Error: {STALE_MARKER}h12\n    at y")}}),
    );
    assert_eq!(error.code, ErrorCode::Stale);
    assert!(error.message.contains("h12"));
}

#[test]
fn out_of_process_subtrees_graft_under_their_parent() {
    let mut tree = json!({"frame": {"id": "A"}, "childFrames": [{"frame": {"id": "B"}}]});
    let subtree = json!({"frame": {"id": "X", "parentId": "B"}});
    assert!(graft(&mut tree, "B", &subtree));
    assert_eq!(tree["childFrames"][0]["childFrames"][0]["frame"]["id"], "X");
    assert!(graft(&mut tree, "B", &subtree), "grafting twice replaces, not duplicates");
    assert_eq!(tree["childFrames"][0]["childFrames"].as_array().unwrap().len(), 1);
    assert!(!graft(&mut tree, "nope", &subtree));
    assert!(is_stale_context(&DriverError::invalid("Execution context was destroyed.")));
    assert!(!is_stale_context(&DriverError::invalid("boom")));
}

#[test]
fn parents_are_found_in_the_frame_tree() {
    let tree = json!({"frame": {"id": "A"}, "childFrames": [{"frame": {"id": "B"}, "childFrames": [{"frame": {"id": "C"}}]}]});
    assert_eq!(parent_of(&tree, "C", None).as_deref(), Some("B"));
    assert_eq!(parent_of(&tree, "B", None).as_deref(), Some("A"));
    assert_eq!(parent_of(&tree, "A", None), None);
    assert_eq!(parent_of(&tree, "Z", None), None);
}
