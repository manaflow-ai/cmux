use super::*;

fn message(kind: Kind, op: Option<&str>) -> OutMessage {
    OutMessage {
        to: Target::default(),
        from: Sender::default(),
        kind,
        op: op.map(str::to_owned),
        body: String::new(),
        mode: Mode::Now,
        idempotency_key: "mesh-test-1".into(),
    }
}

#[test]
fn control_wire_requires_a_known_operation_and_prompts_have_none() {
    assert!(message(Kind::Control, Some("start")).validate().is_ok());
    assert!(message(Kind::Control, None).validate().is_err());
    assert!(message(Kind::Control, Some("pause")).validate().is_err());
    assert!(message(Kind::Prompt, None).validate().is_ok());
    assert!(message(Kind::Prompt, Some("start")).validate().is_err());
}
