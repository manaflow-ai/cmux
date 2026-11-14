use super::*;

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn a_send_is_the_clis_chat_send_with_its_wait_and_sender() {
    let words = words(
        SEND,
        &args(json!({"to": "codex", "text": "status?", "wait": true,
            "timeout_seconds": 99_999, "class": "question"})),
    );
    assert_eq!(
        words,
        Some(Ok([
            "chat",
            "send",
            "--to",
            "codex",
            "--text",
            "status?",
            "--wait",
            "--timeout",
            "1800",
            "--class",
            "question"
        ]
        .map(str::to_owned)
        .to_vec()))
    );
    // The app's Send Message To… takes the same path.
    let app = words_of(APP_SEND, json!({"to": "Austin", "text": "hi"}));
    assert_eq!(app, ["chat", "send", "--to", "Austin", "--text", "hi"].map(str::to_owned).to_vec());
}

fn words_of(name: &str, value: Value) -> Vec<String> {
    words(name, &args(value)).and_then(Result::ok).unwrap_or_default()
}

#[test]
fn a_client_that_gave_no_name_still_sends_as_an_agent_never_as_the_person() {
    assert_eq!(sender_app(None), UNNAMED_CLIENT);
    assert_eq!(sender_app(Some(&"Grok bot".to_owned())), "Grok bot");
    // The CLI reads the app it is given as an agent's sender, not the person's.
    let env = |key: &str| {
        (key == super::super::super::chief::caller::SENDER_APP_ENV)
            .then(|| UNNAMED_CLIENT.to_owned())
    };
    let sent = super::super::super::chief::caller::sender(None, None, None, &env, &|| None);
    assert_eq!(sent.expect("an agent's sender").shown(), UNNAMED_CLIENT);
}

#[test]
fn read_and_list_are_the_clis_and_bad_arguments_are_refused() {
    assert_eq!(
        words_of(READ, json!({"to": "muse", "last": 5})),
        ["chat", "read", "--to", "muse", "--last", "5"].map(str::to_owned).to_vec()
    );
    assert_eq!(words_of(LIST, json!({})), ["chat", "list"].map(str::to_owned).to_vec());
    assert!(matches!(words(SEND, &args(json!({"to": "chief"}))), Some(Err(_))));
    assert!(matches!(words(LIST, &args(json!({"x": 1}))), Some(Err(_))));
    assert_eq!(words("agents_snapshot", &args(json!({}))), None);
}
