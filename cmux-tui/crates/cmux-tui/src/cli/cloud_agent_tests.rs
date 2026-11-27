use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|w| (*w).to_owned()).collect()
}

#[test]
fn chat_and_computer_words_become_the_tools_arguments() {
    let Ok(Command::Tool { name, arguments, .. }) = parse(
        "chat",
        &words(&["send", "--target", "machine:vm-1", "--session", "s-1", "--prompt", "-"]),
        || Ok("from stdin".into()),
    ) else {
        panic!()
    };
    assert_eq!(name, "cloud_chat_send");
    assert_eq!(
        Value::Object(arguments),
        json!({"machine": "machine:vm-1", "session": "s-1", "prompt": "from stdin"})
    );
    let Ok(Command::Tool { name, arguments, .. }) = parse(
        "chat",
        &words(&[
            "status",
            "--target",
            "machine:vm-1",
            "--session",
            "s-1",
            "--wait",
            "20",
            "--after",
            "3",
        ]),
        || Err(String::new()),
    ) else {
        panic!()
    };
    assert_eq!(name, "cloud_chat_status");
    assert_eq!(arguments["wait_s"], 20);
    assert_eq!(arguments["after"], 3);

    let Ok(Command::Tool { name, arguments, out, .. }) = parse(
        "computer",
        &words(&["screenshot", "--target", "machine:vm-1", "--out", "/tmp/s.png"]),
        || Err(String::new()),
    ) else {
        panic!()
    };
    assert_eq!((name, out.as_deref()), ("cloud_computer", Some("/tmp/s.png")));
    assert_eq!(Value::Object(arguments), json!({"op": "screenshot", "machine": "machine:vm-1"}));
    let Ok(Command::Tool { arguments, .. }) =
        parse("computer", &words(&["click", "--x", "10", "--y=20", "--button", "right"]), || {
            Err(String::new())
        })
    else {
        panic!()
    };
    assert_eq!(
        Value::Object(arguments),
        json!({"op": "click", "x": 10, "y": 20, "button": "right"})
    );
    let Ok(Command::Tool { name, arguments, .. }) =
        parse("computer", &words(&["control", "request", "--reason", "Sign in"]), || {
            Err(String::new())
        })
    else {
        panic!()
    };
    assert_eq!(name, "cloud_computer_control");
    assert_eq!(Value::Object(arguments), json!({"action": "request_human", "reason": "Sign in"}));

    assert!(
        parse("chat", &words(&["send", "--target", "machine:vm-1"]), || Err(String::new()))
            .is_err()
    );
    assert!(parse("computer", &words(&["click", "--x", "ten"]), || Err(String::new())).is_err());
    assert!(matches!(
        parse("computer", &words(&["--help"]), || Err(String::new())),
        Ok(Command::Help(_))
    ));
}
