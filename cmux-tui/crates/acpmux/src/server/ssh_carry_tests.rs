use super::*;

#[test]
fn the_message_goes_on_stdin_and_every_word_is_quoted() {
    let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi; rm -rf ~"}],
        "_meta": {"acpmux": {"promptId": "p-1", "steer": true, "class": "question"}}});
    let m = message(&request, Some("co'ord"), "vm-1").unwrap();
    assert_eq!(m.text, "hi; rm -rf ~");
    let s = script("lane x", &m.flags);
    assert!(!s.contains("rm -rf"), "{s}");
    assert!(s.contains("'--prompt-id=p-1'"), "{s}");
    assert!(s.contains("'--steer'"), "{s}");
    assert!(s.contains("'--class=question'"), "{s}");
    assert!(s.contains(r"'--from=co'\''ord'"), "{s}");
    assert!(s.contains(r"'--relayed-from=vm-1/co'\''ord'"), "{s}");
    assert!(s.contains("'lane x' -;"), "{s}");
    assert!(s.starts_with("for a in \"$HOME/.local/bin/acpmux\" acpmux;"), "{s}");
}

#[test]
fn an_attachment_or_no_prompt_id_is_not_carried() {
    let image = json!({"prompt": [{"type": "text", "text": "x"}, {"type": "image", "data": ""}],
        "_meta": {"acpmux": {"promptId": "p"}}});
    assert_eq!(message(&image, None, "m"), None);
    let bare = json!({"prompt": [{"type": "text", "text": "x"}]});
    assert_eq!(message(&bare, None, "m"), None);
}

#[test]
fn a_key_ssh_could_read_as_an_option_is_never_carried() {
    assert!(!plain_key("-oProxyCommand=x"));
    assert!(!plain_key(""));
    assert!(!plain_key("a\nb"));
    assert!(plain_key("lane-1"));
}

#[test]
fn what_the_far_side_said_decides_the_outbox_next_step() {
    let ok = r#"{"deliveryId": "d-9", "promptId": "p", "sessionId": "s", "status": "queued", "steered": false}"#;
    match outcome(Some(0), ok, "") {
        Carry::Taken(v) => {
            assert_eq!(v["sshDeliveryId"], "d-9");
            assert_eq!(v["via"], "ssh");
        }
        other => panic!("{other:?}"),
    }
    assert!(matches!(outcome(Some(0), "not json", ""), Carry::Maybe(_)));
    assert!(matches!(
        outcome(Some(255), "", "ssh: connect to host box port 22: Connection refused"),
        Carry::NotTaken(_)
    ));
    assert!(matches!(
        outcome(Some(255), "", "Connection to box closed by remote host."),
        Carry::Maybe(_)
    ));
    assert!(matches!(outcome(Some(127), "", "acpmux: not found"), Carry::NotTaken(_)));
    assert!(matches!(outcome(Some(4), "", "no session"), Carry::NotTaken(_)));
    assert!(matches!(outcome(Some(1), "", "boom"), Carry::Maybe(_)));
    assert!(matches!(outcome(None, "", ""), Carry::Maybe(_)));
}
