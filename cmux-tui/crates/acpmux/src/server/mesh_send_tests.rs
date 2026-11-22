use super::*;

#[test]
fn host_and_a_session_id_name_that_session_by_id() {
    let id = "01a1acb2-5bb4-75a3-b5eb-a0eeea1d59d5";
    let to = recipient(&format!("machine-b/{id}"));
    assert_eq!(
        (to.session_id.as_deref(), to.name, to.host.as_deref()),
        (Some(id), None, Some("machine-b"))
    );
    let to = recipient("machine-b/own-e2e");
    assert_eq!((to.name.as_deref(), to.session_id), (Some("own-e2e"), None));
}

/// cmuxterm-hq#17418: `class: question` to 9 sessions reached only through the relay sent 0
/// of 9 ("cannot carry --class"). The class now goes as the text's first line, the sender's
/// row says so, and a send with no class (or result) is the text it always was.
#[test]
fn a_class_the_relay_cannot_carry_goes_as_the_first_line() {
    let request = |class: Option<&str>| {
        json!({"sessionId": "host-b/lane-a", "prompt": [{"type": "text", "text": "ship it?"}],
            "_meta": {"acpmux": {"class": class, "promptId": "0190f2a4-7c1e-7d3a-9f00-0123456789ab"}}})
    };
    let sent = carried(&request(Some("question")), "host-b/lane-a").unwrap();
    assert_eq!(sent.body, "[question]\n\nship it?");
    assert_eq!(sent.inline, Some(PromptClass::Question));
    let sent = carried(&request(Some("blocker")), "host-b/lane-a").unwrap();
    assert!(sent.body.starts_with("[block]\n\n"), "{}", sent.body);
    for class in [None, Some("result"), Some("action")] {
        let sent = carried(&request(class), "host-b/lane-a").unwrap();
        assert_eq!((sent.body.as_str(), sent.inline), ("ship it?", None), "{class:?}");
    }
    let mut row = json!({"status": "queued"});
    class_note(&mut row, Some(PromptClass::Question));
    assert_eq!(row["classInline"], "question");
    assert!(row["note"].as_str().unwrap().contains("[question]"), "{row}");
    // What it still cannot carry is still refused, by name.
    let mut attach = request(None);
    attach["prompt"] = json!([{"type": "image", "data": "x"}]);
    assert!(carried(&attach, "host-b/lane-a").is_err());
}

#[test]
fn a_prompt_id_the_hub_would_refuse_as_a_key_is_digested() {
    let id = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";
    assert_eq!(idempotency_key(id), id);
    let short = idempotency_key("abc");
    assert!(short.starts_with("p:") && short.len() == 42, "{short}");
    assert_eq!(idempotency_key("has space in it"), idempotency_key("has space in it"));
    assert_eq!(recipient("huge-blue/dep-land").host.as_deref(), Some("huge-blue"));
    assert_eq!(recipient("dep-land").host, None);
    assert_eq!(
        recipient("@lawrence/coordinator").team_address.as_deref(),
        Some("@lawrence/coordinator")
    );
    assert!(valid_team_address("@team/role"));
    assert!(valid_team_address("@member/reviewer:backend"));
    assert!(!valid_team_address("@team"));
}
