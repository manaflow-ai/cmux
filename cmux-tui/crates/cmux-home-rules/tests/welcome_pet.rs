//! Parity with `ChiefPetNoticeTests` (the notice text and reply kind) and `ChiefMascotPicks`.

use cmux_home_rules::call;
use cmux_home_rules::welcome::pet::{Kind, Level, NoticeRequest, ReplyKind, notice};
use serde_json::{Value, json};

/// A terminal tab "New chat" in workspace "api-server", as the Swift harness builds it.
fn terminal(title: &str, body: &str, level: Level, source: &str, reply: bool) -> NoticeRequest {
    NoticeRequest {
        level: Some(level),
        title: title.into(),
        source: Some(source.into()),
        reply,
        tab_title: "New chat".into(),
        tab_is_pty: true,
        workspace: Some("api-server".into()),
        body: body.into(),
        ..NoticeRequest::default()
    }
}

#[test]
fn notice_reads_as_the_banner() {
    let n = notice(&terminal("Claude needs approval", "", Level::Warning, "agent", false));
    assert_eq!(n.title, "Claude needs approval");
    assert_eq!(n.detail, "api-server", "no text, no subtitle: the workspace");
    assert_eq!(n.kind, Kind::NeedsYou);
    assert_eq!(n.reply, ReplyKind::Type, "a terminal takes a typed reply");
}

#[test]
fn untitled_notice_says_which_chat_and_what_happened() {
    let n = notice(&terminal("", "Ran command", Level::Info, "agent", false));
    assert_eq!(n.title, "New chat finished");
    assert_eq!(n.detail, "api-server · Ran command");
    let n = notice(&terminal("", "Allow rm -rf build?", Level::Warning, "agent", false));
    assert_eq!(n.title, "New chat needs your input");
    let n = notice(&terminal("", "", Level::Error, "agent", false));
    assert_eq!(n.title, "New chat failed");
    assert_eq!(n.detail, "api-server");
    // A titleless line that is not an agent's (an OSC 9 from a shell) did not "finish" anything.
    let n = notice(&terminal("", "build done", Level::Info, "terminal", false));
    assert_eq!(n.title, "New chat");
    assert_eq!(n.detail, "api-server · build done");
}

#[test]
fn only_agents_and_asked_for_replies_take_typed_text() {
    assert_eq!(
        notice(&terminal("printed by tail -f", "", Level::Info, "terminal", false)).reply,
        ReplyKind::OpenTab
    );
    assert_eq!(
        notice(&terminal("asked for a reply", "", Level::Info, "cli", true)).reply,
        ReplyKind::Type
    );
    assert_eq!(
        notice(&terminal("Claude needs approval", "", Level::Warning, "agent", false)).reply,
        ReplyKind::Type
    );
}

#[test]
fn a_chat_tab_opens_its_chat_and_the_body_takes_its_first_line() {
    let out = call(
        "welcome.petNotice",
        &json!({"title": "", "tabTitle": "Ada", "tabHasAgentSession": true, "body": "\n\nfirst\nsecond", "source": "agent"}),
    )
    .unwrap();
    assert_eq!(
        out,
        json!({"title": "Ada finished", "detail": "first", "kind": "done", "reply": "openChat"})
    );
    let named = call(
        "welcome.petNotice",
        &json!({"title": "", "tabTitle": "x", "name": "Bob", "programTitle": "Claude"}),
    )
    .unwrap();
    assert_eq!(named["title"], "Claude", "the program's own title wins");
}

fn mascots() -> Value {
    json!({"values": ["cat", "dog"], "default": "cat", "path": ["home", "chiefPet", "mascot"]})
}

#[test]
fn picks_keep_only_named_characters_and_the_default_chief_reads_the_settings() {
    let out = call(
        "welcome.mascotPicksLoad",
        &json!({"stored": {"a": "dog", "b": "unicorn", "c": 3}, "mascots": mascots()}),
    )
    .unwrap();
    assert_eq!(out["picks"], json!({"a": "dog"}));
    let req = |chief: Value| {
        json!({"chief": chief, "defaultChief": "main", "picks": {"a": "dog"}, "mascots": mascots(),
               "snapshotMascot": "dog", "file": {"home": {"chiefPet": {"mascot": "dog"}}}})
    };
    assert_eq!(call("welcome.mascot", &req(json!("main"))).unwrap()["mascot"], "dog");
    assert_eq!(call("welcome.mascot", &req(json!("other"))).unwrap()["mascot"], "cat");
    assert_eq!(call("welcome.mascot", &req(json!("a"))).unwrap()["mascot"], "dog");
    assert_eq!(call("welcome.mascotPicked", &req(json!(null))).unwrap()["picked"], "dog");
    assert_eq!(call("welcome.mascotPicked", &req(json!("other"))).unwrap()["picked"], Value::Null);
}

#[test]
fn remember_writes_only_a_change_for_a_non_default_chief() {
    let base = |chief: &str, mascot: &str| json!({"chief": chief, "defaultChief": "main", "picks": {"a": "dog"}, "mascots": mascots(), "mascot": mascot});
    let out = call("welcome.mascotRemember", &base("b", "cat")).unwrap();
    assert_eq!(out["picks"], json!({"a": "dog", "b": "cat"}));
    assert_eq!(
        out["write"],
        json!({"key": "home.chief.mascots", "value": {"a": "dog", "b": "cat"}})
    );
    assert_eq!(call("welcome.mascotRemember", &base("a", "dog")).unwrap()["write"], Value::Null);
    assert_eq!(call("welcome.mascotRemember", &base("main", "dog")).unwrap()["write"], Value::Null);
    assert_eq!(
        call("welcome.mascotRemember", &base("b", "unicorn")).unwrap()["write"],
        Value::Null
    );
}
