use super::*;

/// A group's "Chiefs Reply" setting (plans/cmux-next/chief-group-chats-DESIGN.md) goes to the
/// owner as `conversation.settings.set {wake_policy}`: the daemon forwards it unchanged.
#[test]
fn conversation_settings_set_is_forwarded() {
    let request = OpRequest {
        conversation: Some("conv_0Y05MEWEFMQQB63VDHQB9MXAJT".into()),
        idempotency_key: "k1".into(),
        origin: Some("user".into()),
        op: json!({"kind": "conversation.settings.set", "wake_policy": "all"}),
    };
    let body = op_body(&request).expect("forwarded");
    assert_eq!(body["op"], "conversation.settings.set");
    assert_eq!(body["params"]["wake_policy"], "all");
    assert_eq!(body["params"]["conversation"], "conv_0Y05MEWEFMQQB63VDHQB9MXAJT");
}
