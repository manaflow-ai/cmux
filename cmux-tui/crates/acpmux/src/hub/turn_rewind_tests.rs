use super::*;

#[test]
fn a_wrapped_resource_reply_answers_its_result() {
    let out =
        br#"{"result":{"checkpoint_id":"ckpt_1","complete":true},"revision":"1","replayed":false}"#;
    let Answer::Ok(v) = read_answer(true, out, b"") else { panic!("answered") };
    assert_eq!(v["checkpoint_id"], "ckpt_1");
    assert_eq!(checkpoint_fields(&Answer::Ok(v))["rewindCheckpointId"], "ckpt_1");
}

#[test]
fn a_mutation_reply_answers_its_value() {
    let out = br#"{"result":{"value":{"files_total":2,"safety_checkpoint_id":"ckpt_s"},"generation":"3","revision":"1","replayed":false}}"#;
    let Answer::Ok(v) = read_answer(true, out, b"") else { panic!("answered") };
    assert_eq!(v["files_total"], 2);
    assert_eq!(v["safety_checkpoint_id"], "ckpt_s");
}

#[test]
fn a_bare_reply_is_its_own_result() {
    let Answer::Ok(v) = read_answer(true, br#"{"files_total":3,"files":[]}"#, b"") else {
        panic!("answered")
    };
    assert_eq!(v["files_total"], 3);
}

#[test]
fn a_refusal_reads_its_reason_from_the_details() {
    // `cmux --json`'s refusal on stderr: a bare error, its message the reason word.
    let err = br#"{"code":"operation.failed","message":"base_changed","details":{"operation":"git.checkpoint.restore","reason":"base_changed","extra":{"message":"the branch moved"}},"retryable":false}"#;
    let Answer::Refused { reason, message } = read_answer(false, b"", err) else {
        panic!("refused")
    };
    assert_eq!(reason, "base_changed");
    assert_eq!(message, "the branch moved");
}

#[test]
fn an_unparsable_failure_is_unavailable_with_its_text() {
    let Answer::Refused { reason, message } = read_answer(false, b"", b"cmux: no session host\n")
    else {
        panic!("refused")
    };
    assert_eq!(reason, "unavailable");
    assert_eq!(message, "cmux: no session host");
    let fields = checkpoint_fields(&Answer::Refused { reason, message });
    assert_eq!(fields["rewindCheckpointError"], "cmux: no session host");
    assert!(!fields.contains_key("rewindCheckpointId"));
}

#[test]
fn a_reply_without_an_id_records_an_error() {
    let fields = checkpoint_fields(&Answer::Ok(json!({"complete": true})));
    assert_eq!(fields["rewindCheckpointError"], "no checkpoint id");
}

#[test]
fn a_success_with_no_json_is_a_refusal() {
    assert!(matches!(read_answer(true, b"ok", b""), Answer::Refused { .. }));
}
