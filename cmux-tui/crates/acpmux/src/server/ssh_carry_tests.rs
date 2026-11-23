use super::*;

#[test]
fn the_message_goes_on_stdin_and_every_word_is_quoted() {
    let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi; rm -rf ~"}],
        "_meta": {"acpmux": {"promptId": "p-1", "steer": true, "class": "question"}}});
    let m = message(&request, &Sender::Named("co'ord".into()), "vm-1").unwrap();
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
    assert_eq!(message(&image, &Sender::Person, "m"), None);
    let bare = json!({"prompt": [{"type": "text", "text": "x"}]});
    assert_eq!(message(&bare, &Sender::Person, "m"), None);
}

/// A delivery with `mux` as its request's `_meta.acpmux`.
fn delivery(mux: Value) -> Delivery {
    let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi"}],
        "_meta": {"acpmux": mux}});
    serde_json::from_value(json!({"id": "d-1", "target": "box/lane", "request": request,
        "state": "queued", "createdAt": 0, "updatedAt": 0}))
    .unwrap()
}

/// Only the person's own send is carried with no sender: every other one names its sender
/// or, with no name to give, this machine as its relay, so the far daemon never records an
/// agent's message as its owner's terminal send.
#[test]
fn only_the_persons_own_send_is_carried_with_no_sender() {
    let name_of = |id: &str| format!("name-of-{id}");
    let flags = |d: &Delivery| message(&d.request, &sender(d, name_of), "vm-1").unwrap().flags;
    let relayed = |flags: &[String]| flags.iter().any(|f| f.starts_with("--relay="));

    let person = delivery(json!({"promptId": "p"}));
    assert_eq!(sender(&person, name_of), Sender::Person);
    assert!(!relayed(&flags(&person)), "{:?}", flags(&person));

    let mut proven = delivery(json!({"promptId": "p"}));
    proven.caller = Some("s1".into());
    assert_eq!(sender(&proven, name_of), Sender::Named("name-of-s1".into()));

    // The case of 2026-11-22: a stale caller token, so the session is named and unproven.
    let mut unproven = delivery(json!({"promptId": "p"}));
    unproven.unproven_caller = Some("s2".into());
    assert_eq!(sender(&unproven, name_of), Sender::Named("name-of-s2".into()));
    let f = flags(&unproven);
    assert!(f.contains(&"--from=name-of-s2".to_owned()), "{f:?}");
    assert!(f.contains(&"--relayed-from=vm-1/name-of-s2".to_owned()), "{f:?}");

    // An agent's shell that declared no terminal and named no one.
    let mut no_terminal = delivery(json!({"promptId": "p"}));
    no_terminal.not_terminal = true;
    assert_eq!(sender(&no_terminal, name_of), Sender::Program);
    let f = flags(&no_terminal);
    assert!(f.contains(&"--relay=acpmux-ssh".to_owned()), "{f:?}");
    assert!(f.contains(&"--relayed-from=vm-1".to_owned()), "{f:?}");
    assert!(!f.iter().any(|flag| flag.starts_with("--from=")), "{f:?}");

    // Each claim that makes a direct send a program's does the same for a carried one.
    for key in ["fromHarness", "senderHarness", "fromRelay", "via"] {
        let claimed = delivery(json!({"promptId": "p", key: {"harness": "claude-code"}}));
        assert_eq!(sender(&claimed, name_of), Sender::Program, "{key}");
        assert!(relayed(&flags(&claimed)), "{key}");
    }
    let named = delivery(json!({"promptId": "p", "fromAgent": "vm-9/lane", "via": "x"}));
    assert_eq!(sender(&named, name_of), Sender::Named("vm-9/lane".into()));
    // A blank name is no name, and still not the person's.
    let blank = delivery(json!({"promptId": "p", "fromAgent": "  "}));
    assert_eq!(sender(&blank, name_of), Sender::Program);
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
