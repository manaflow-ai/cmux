use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

#[test]
fn send_takes_its_text_as_a_flag_or_words_and_keeps_the_apps_flags() {
    let send = parse_send(&strings(&["--to", "Codex Chief", "--text=hi there", "--wait"]))
        .expect("parsed");
    assert_eq!(send.to.as_deref(), Some("Codex Chief"));
    assert_eq!(send.text.as_deref(), Some("hi there"));
    assert!(send.wait);
    let words = parse_send(&strings(&["--to", "Austin", "ship", "it", "--focus"])).expect("parsed");
    assert_eq!(words.text.as_deref(), Some("ship it"));
    assert_eq!(words.other, strings(&["--focus"]));
    let dashed =
        parse_send(&strings(&["--to", "chief", "--", "--wait", "is", "text"])).expect("parsed");
    assert_eq!((dashed.text.as_deref(), dashed.wait), (Some("--wait is text"), false));
    assert!(parse_send(&strings(&["--timeout", "soon"])).is_err());
}

#[test]
fn read_and_wait_with_a_session_id_are_an_agent_chats_not_the_chiefs() {
    // Before, `cmux chat read <uuid>` asked the Chief and answered "the Chief is not
    // running" (exit 3) for a chat `cmux chat` itself started.
    let session = "0d4f9a52-8c1e-4b7a-9f3e-2a6b5c7d8e9f";
    for verb in ["read", "wait"] {
        assert!(names_agent_chat(&strings(&[session, "--timeout", "60"])), "{verb}");
        assert_eq!(run_if_requested(&strings(&["chat", verb, session])), None, "{verb}");
        let acp = format!("acp:{session}");
        assert_eq!(run_if_requested(&strings(&["chat", verb, &acp])), None, "{verb}");
    }
    // The Chief's words stay the Chief's: `--to`, a message ref, nothing.
    assert!(!names_agent_chat(&strings(&["--to", "chief"])));
    assert!(!names_agent_chat(&strings(&["#12"])));
    assert!(!names_agent_chat(&strings(&["msg_abc"])));
    assert!(!names_agent_chat(&[]));
}

#[test]
fn a_persons_send_without_wait_is_the_app_action_unchanged() {
    // No agent in this test's own environment is assumed: --as names one only when given.
    let words = strings(&["chat", "send", "--to", "Austin", "--text", "hi"]);
    if caller::current(None, None, None).is_none() {
        assert_eq!(run_if_requested(&words), None);
    }
    assert_eq!(run_if_requested(&strings(&["chat", "create", "--members", "a"])), None);
}
