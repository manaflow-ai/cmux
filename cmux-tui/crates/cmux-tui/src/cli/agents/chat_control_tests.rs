use super::{
    CODEX_AGENT_CHAT_STOP_CONDITION, on_target_words, parse_new, session_meta, take_attach,
};
use serde_json::json;

#[test]
fn attach_flags_come_before_the_text_and_repeat() {
    let words = ["--attach", "a.png", "--attach=b.txt", "--", "look"];
    let (attach, rest) = take_attach(&words, "agents chat send").unwrap();
    assert_eq!(attach, ["a.png", "b.txt"]);
    assert_eq!(rest, ["--", "look"]);
    let (attach, rest) = take_attach(&["look"], "agents chat send").unwrap();
    assert!(attach.is_empty());
    assert_eq!(rest, ["look"]);
    for bad in [&["--attach"][..], &["--attach="], &["--attach", "--"]] {
        assert!(take_attach(bad, "agents chat send").is_err(), "{bad:?}");
    }
}

#[test]
fn chat_new_takes_files_only_with_a_first_prompt() {
    let chat = parse_new(&["--attach", "a.png", "--attach=b.txt", "--", "look"]).unwrap();
    assert_eq!(chat.attach, ["a.png", "b.txt"]);
    assert_eq!(chat.prompt.as_deref(), Some("look"));
    assert!(parse_new(&["--attach", "a.png"]).is_err());
}

/// `--peer` starts the chat on that machine through this acpmux: the peer goes in
/// `_meta.acpmux.peer` and no session env goes with it (a peer refuses one from another
/// daemon); a chat here keeps its workspace env and names no peer.
#[test]
fn a_peer_chat_names_the_peer_and_carries_no_env() {
    let key = "0123456789abcdef0123456789abcdef";
    let here = parse_new(&["--harness", "codex", "--", "go"]).unwrap();
    let meta = session_meta(&here, key);
    assert_eq!(meta.get("peer"), None);
    assert_eq!(
        meta.get("env"),
        Some(&json!({"CMUX_WORKSPACE_ID": "01234567-89ab-cdef-0123-456789abcdef"}))
    );
    let there = parse_new(&["--peer", "studio", "--harness", "codex", "--", "go"]).unwrap();
    assert_eq!(there.peer.as_deref(), Some("studio"));
    let meta = session_meta(&there, key);
    assert_eq!(meta.get("peer"), Some(&json!("studio")));
    assert_eq!(meta.get("harness"), Some(&json!("codex")));
    assert_eq!(meta.get("env"), None);
    assert!(parse_new(&["--peer"]).is_err());
    assert!(parse_new(&["--peer="]).is_err());
}

#[test]
fn a_codex_agent_chat_keeps_working_until_it_reports_completion() {
    let chat = parse_new(&[
        "--harness",
        "codex",
        "--",
        "fix the gateway and report the commit when it is done",
    ])
    .unwrap();
    let meta = session_meta(&chat, "0123456789abcdef0123456789abcdef");
    assert_eq!(
        meta.get("stopCondition"),
        Some(&json!(CODEX_AGENT_CHAT_STOP_CONDITION))
    );
}

fn strings(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// cmux#46701: `agents chat new --on TARGET` is `chat new --on TARGET`, globals kept, so a
/// Cloud chat starts from either name with the composer's picks.
#[test]
fn a_chat_on_a_target_is_the_chat_start() {
    let args = strings(&[
        "--json",
        "agents",
        "chat",
        "new",
        "--on",
        "cloud",
        "--harness",
        "codex",
        "--effort",
        "high",
        "--no-folder",
        "--",
        "1+1?",
    ]);
    assert_eq!(
        on_target_words(&args).unwrap().unwrap(),
        strings(&[
            "--json",
            "chat",
            "new",
            "--on",
            "cloud",
            "--harness",
            "codex",
            "--effort",
            "high",
            "--no-folder",
            "--",
            "1+1?",
        ])
    );
    let inline = strings(&["agents", "chat", "new", "--on=vm:new", "go"]);
    assert_eq!(
        on_target_words(&inline).unwrap().unwrap()[..3],
        strings(&["chat", "new", "--on=vm:new"])
    );
    // No `--on` (a `--on` in the prompt is text): the chat here, as before.
    assert!(on_target_words(&strings(&["agents", "chat", "new", "--", "--on"])).is_none());
    assert!(on_target_words(&strings(&["agents", "chat", "send", "--on", "x"])).is_none());
    for placed in ["--workspace", "--pane", "--policy", "--peer"] {
        let args = strings(&["agents", "chat", "new", "--on", "cloud", placed, "x", "go"]);
        let error = on_target_words(&args).unwrap().unwrap_err();
        assert!(error.0.contains(placed), "{}", error.0);
    }
    let top = strings(&["agents", "chat", "new", "--top", "--on", "cloud", "go"]);
    assert!(on_target_words(&top).unwrap().is_err());
}
