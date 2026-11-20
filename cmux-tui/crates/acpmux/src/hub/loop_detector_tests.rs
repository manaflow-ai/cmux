use super::*;
use serde_json::json;

fn start(id: &str, command: &str) -> Value {
    json!({"sessionUpdate":"tool_call", "toolCallId":id, "kind":"execute",
           "title":command, "rawInput":{"command":command}, "status":"in_progress"})
}

fn end(id: &str, status: &str, error: &str) -> Value {
    json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
           "status":status, "rawOutput":{"stderr":error}})
}

#[test]
fn diagnosis_names_the_command_instead_of_a_generic_tool_title() {
    let mut detector = LoopDetector::default();
    for id in ["a", "b", "c"] {
        let mut update = start(id, "cargo test");
        update["title"] = json!("Bash");
        detector.observe(&update);
        let mut result = end(id, "failed", "auth.rs:88");
        result["title"] = json!("Bash");
        detector.observe(&result);
    }
    assert!(detector.active().unwrap().diagnosis.starts_with("Ran cargo test 3 times"));
}

#[test]
fn partial_terminal_uses_start_cwd_for_failure_fingerprint() {
    let mut detector = LoopDetector::default();
    for (id, cwd) in [("a", "/repo/a"), ("b", "/repo/b"), ("c", "/repo/c")] {
        detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":"execute", "title":"cargo test",
            "rawInput":{"command":"cargo test", "cwd":cwd}, "status":"in_progress"}));
        assert!(
            detector
                .observe(&json!({"sessionUpdate":"tool_call_update",
            "toolCallId":id, "status":"failed",
            "rawInput":{"command":"cargo test"}}))
                .is_none()
        );
    }
    assert!(detector.active().is_none());
    for (id, cwd) in [("d", "/repo/a"), ("e", "/repo/a")] {
        detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":"execute", "title":"cargo test",
            "rawInput":{"command":"cargo test", "cwd":cwd}, "status":"in_progress"}));
        let event = detector.observe(&json!({"sessionUpdate":"tool_call_update",
            "toolCallId":id, "status":"failed",
            "rawInput":{"command":"cargo test"}}));
        assert_eq!(matches!(event, Some(LoopEvent::Detected(_))), id == "e");
    }
}

#[test]
fn title_only_output_delta_preserves_started_metadata() {
    let mut detector = LoopDetector::default();
    detector.observe(&start("a", "cargo test"));
    detector.observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":"a",
        "title":"streaming output", "content":[{"type":"content", "content":{"type":"text", "text":"chunk"}}]}));
    assert_eq!(detector.pending[0].title, "cargo test");
    assert_eq!(
        detector.pending[0].fingerprint,
        fingerprint(&start("a", "cargo test"), "execute", &Cwd::Unspecified)
    );
}

#[test]
fn command_and_cwd_boundaries_are_distinct() {
    let first = json!({"rawInput":{"command":"ab"}});
    let second = json!({"rawInput":{"command":"a"}});
    assert_ne!(
        fingerprint(&first, "execute", &Cwd::Known(hash_bounded("c").unwrap())),
        fingerprint(&second, "execute", &Cwd::Known(hash_bounded("bc").unwrap()))
    );
    assert_ne!(
        fingerprint(&first, "execute", &Cwd::Unspecified),
        fingerprint(&first, "execute", &Cwd::Known(hash_bounded("").unwrap()))
    );
}

#[test]
fn quoted_command_and_directory_whitespace_are_significant() {
    let mut commands = LoopDetector::default();
    let mut directories = LoopDetector::default();
    for (id, spaces) in [("a", " "), ("b", "  "), ("c", "   ")] {
        commands.observe(&start(id, &format!("test 'a{spaces}b' = 'ab'")));
        assert!(commands.observe(&end(id, "failed", "comparison failed")).is_none());

        let mut update = start(id, "cargo test");
        update["rawInput"]["cwd"] = json!(format!("/repo/a{spaces}b"));
        directories.observe(&update);
        assert!(directories.observe(&end(id, "failed", "auth.rs:88")).is_none());
    }
    assert!(commands.active().is_none());
    assert!(directories.active().is_none());
}
#[test]
fn recorded_shape_partial_updates_and_duplicate_terminals() {
    let mut detector = LoopDetector::default();
    let transcript = include_str!("../../tests/fixtures/looping-tool-updates.jsonl");
    let events: Vec<_> = transcript
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).expect("fixture update"))
        .filter_map(|update| detector.observe(&update))
        .collect();
    let [LoopEvent::Detected(episode), LoopEvent::Cleared { episode_id }] = events.as_slice()
    else {
        panic!("expected one detected and one cleared event: {events:?}");
    };
    assert_eq!(episode.count, 3);
    assert!(episode.diagnosis.contains("auth.rs:88"));
    assert_eq!(*episode_id, episode.episode_id);
    assert!(detector.active().is_none());
}

#[test]
fn inverse_edit_requires_actual_content() {
    let mut detector = LoopDetector::default();
    let edit = |id: &str, before: &str, after: &str| {
        json!({"sessionUpdate":"tool_call", "toolCallId":id,
        "kind":"edit", "title":"Edit auth.rs", "rawInput":{"file_path":"auth.rs",
        "old_string":before,"new_string":after}, "status":"completed"})
    };
    assert!(detector.observe(&edit("a", "old", "new")).is_none());
    assert!(detector.observe(&edit("b", "new", "other")).is_none());
    assert!(matches!(detector.observe(&edit("c", "other", "new")), Some(LoopEvent::Detected(_))));
    assert!(detector.observe(&edit("d", "new", "other")).is_none());
}

#[test]
fn recorded_file_change_diff_can_prove_inverse() {
    let mut detector = LoopDetector::default();
    let change = |detector: &mut LoopDetector, id: &str, before: &str, after: &str| {
        detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":"edit", "title":"Edit auth.rs", "status":"in_progress"}));
        detector.observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
            "status":"completed", "content":[{"type":"diff", "path":"auth.rs",
                "oldText":before, "newText":after}]}))
    };
    assert!(change(&mut detector, "a", "old\n", "new\n").is_none());
    assert!(matches!(change(&mut detector, "b", "new\n", "old\n"), Some(LoopEvent::Detected(_))));
}

#[test]
fn recorded_edit_failed_validation_inverse_is_one_episode() {
    let mut detector = LoopDetector::default();
    let transcript = include_str!("../../tests/fixtures/edit-validation-revert.jsonl");
    let events: Vec<_> = transcript
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).expect("fixture update"))
        .filter_map(|update| detector.observe(&update))
        .collect();
    let [LoopEvent::Detected(episode)] = events.as_slice() else {
        panic!("expected one edit loop episode: {events:?}");
    };
    assert_eq!(episode.count, 2);
    assert!(episode.diagnosis.contains("Edit auth.rs"));
}

#[test]
fn successful_unrelated_tool_breaks_edit_history() {
    let mut detector = LoopDetector::default();
    let edit = |id: &str, before: &str, after: &str| {
        json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":"edit", "title":"Edit auth.rs", "status":"completed",
            "rawInput":{"file_path":"auth.rs", "old_string":before, "new_string":after}})
    };
    detector.observe(&edit("apply", "old", "new"));
    detector.observe(&end("validation", "failed", "auth.rs:88"));
    detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":"progress",
        "kind":"execute", "title":"different command", "status":"completed",
        "rawInput":{"command":"different command"}}));
    assert!(detector.observe(&edit("revert", "new", "old")).is_none());
    assert!(detector.active().is_none());
}

#[test]
fn partial_terminal_keeps_the_started_tool_kind() {
    let mut detector = LoopDetector::default();
    for (id, kind) in [("a", "execute"), ("b", "execute"), ("c", "other")] {
        detector.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":id,
            "kind":kind, "title":"cargo test", "rawInput":{"command":"cargo test"},
            "status":"in_progress"}));
        assert!(
            detector
                .observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":id,
            "status":"failed", "rawInput":{"command":"cargo test"}}))
                .is_none()
        );
    }
    assert!(detector.active().is_none());
}

#[test]
fn successful_call_breaks_the_failure_run_before_detection() {
    let mut detector = LoopDetector::default();
    for (id, status) in
        [("a", "failed"), ("b", "completed"), ("c", "failed"), ("d", "completed"), ("e", "failed")]
    {
        detector.observe(&start(id, "cargo test"));
        assert!(
            detector
                .observe(&json!({"sessionUpdate":"tool_call_update",
            "toolCallId":id, "status":status}))
                .is_none()
        );
    }
    assert!(detector.active().is_none());
}

#[test]
fn memory_is_bounded_and_oversize_input_is_ignored() {
    let mut detector = LoopDetector::default();
    for i in 0..100 {
        detector.observe(&start(&format!("pending-{i}"), "cargo test"));
    }
    assert_eq!(detector.pending.len(), PENDING);
    for i in 0..100 {
        let id = format!("done-{i}");
        detector.observe(&start(&id, &"x".repeat(MAX_INPUT + 1)));
        detector.observe(&end(&id, "failed", "error"));
    }
    assert_eq!(detector.recent_ids.len(), RECENT_IDS);
    assert_eq!(detector.attempts.len(), WINDOW);
    assert!(detector.active().is_none());
}
