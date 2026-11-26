use super::*;

fn rules(v: Value) -> Vec<Rule> {
    parse_rules(&v)
}

fn start(r: &[Rule], key: &str, prompt: &str) -> Option<String> {
    start_with(r, key, "s", prompt, "h", false)
}

#[test]
fn a_start_rule_fires_on_its_prompt_and_nothing_fires_otherwise() {
    let r = rules(json!([{"id": "a", "at": "start", "say": "check the cause",
        "if": {"prompt_any": ["fix(ed)? the bug"]}}]));
    assert_eq!(start(&r, "t1", "please do X"), None);
    assert_eq!(
        start(&r, "t1", "Fix the BUG now").as_deref(),
        Some("[turn rule a] check the cause")
    );
}

#[test]
fn one_rule_per_boundary_and_a_cooldown_per_rule() {
    let r = rules(json!([
        {"id": "a", "at": "start", "say": "A", "cooldown": 2},
        {"id": "b", "at": "start", "say": "B", "cooldown": 0},
    ]));
    assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule a] A"));
    // a is cooling down (turn 2 - 1 < 2): b fires instead.
    assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule b] B"));
    assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule a] A"));
    let map = STATES.lock().unwrap();
    assert_eq!(map["t2"].suppressed, 1);
}

#[test]
fn conditions_on_session_host_tools_and_draft() {
    let r = rules(json!([{"id": "e", "at": "end", "say": "E", "if": {
        "draft_any": ["\\bfixed\\b"], "draft_none": ["root cause"],
        "min_tools": 2, "tools_any": ["cargo"], "session_any": ["^lane"], "host_any": ["box"]}}]));
    let tools = vec!["Bash cargo test".to_owned(), "Edit".to_owned()];
    let f = |draft: &'static str, tools: &'static [String], session, host| Facts {
        prompt: "",
        draft,
        tools,
        session,
        host,
        chief: false,
    };
    let tools: &'static [String] = Box::leak(tools.into_boxed_slice());
    assert!(matches(&r[0], &f("it is fixed", tools, "lane-1", "mybox")));
    assert!(!matches(&r[0], &f("it is fixed, root cause x", tools, "lane-1", "mybox")));
    assert!(!matches(&r[0], &f("it is fixed", &tools[..1], "lane-1", "mybox")));
    assert!(!matches(&r[0], &f("it is fixed", tools, "other", "mybox")));
    assert!(!matches(&r[0], &f("it is fixed", tools, "lane-1", "elsewhere")));
}

#[test]
fn an_end_rule_is_said_at_the_next_prompt_not_now() {
    let r = rules(json!([{"id": "e", "at": "end", "say": "E", "if": {"draft_any": ["done"]}}]));
    assert_eq!(start(&r, "t3", "p"), None);
    let mut msg = json!({});
    end_with(&r, "t3", "s", "", "all done", "h", false, &mut msg);
    assert_eq!(msg["harnessMagic"]["turnRules"]["fired"], 1);
    // Nothing was said into this turn's prompt yet: no saidChars.
    assert!(msg["harnessMagic"]["turnRules"].get("saidChars").is_none());
    assert_eq!(start(&r, "t3", "p").as_deref(), Some("[turn rule e] E"));
    assert_eq!(start(&r, "t3", "p"), None);
}

#[test]
fn a_chief_condition_splits_chief_from_every_other_session() {
    let r = rules(json!([
        {"id": "c", "at": "start", "say": "C", "cooldown": 0, "if": {"chief": true}},
        {"id": "o", "at": "start", "say": "O", "cooldown": 0, "if": {"chief": false}},
    ]));
    assert_eq!(start_with(&r, "t5", "n", "p", "h", true).as_deref(), Some("[turn rule c] C"));
    assert_eq!(start_with(&r, "t6", "n", "p", "h", false).as_deref(), Some("[turn rule o] O"));
    let mut msg = json!({});
    end_with(&r, "t5", "n", "", "", "h", true, &mut msg);
    assert_eq!(msg["harnessMagic"]["turnRules"]["saidChars"], 15);
}

#[test]
fn bad_rules_are_dropped_and_a_bad_regex_is_a_substring() {
    let r = rules(json!([{"id": "x", "at": "mid", "say": "s"}, {"say": "s", "at": "end"},
        {"id": "ok", "at": "start", "say": "s", "if": {"prompt_any": ["a(b"]}}]));
    assert_eq!(r.len(), 1);
    assert!(start(&r, "t4", "has a(b in it").is_some());
}

#[tokio::test]
async fn a_hub_turn_end_matches_and_counts() {
    let cfg = crate::config::Config::default();
    let store = Box::new(crate::store::MemoryStore::default());
    let hub = Hub::new(cfg, store);
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "tr-hub", "name": "tr-hub",
        "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    TEST_RULES.lock().unwrap().insert(
        "tr-hub".into(),
        rules(json!([
            {"id": "s", "at": "start", "say": "S", "cooldown": 0},
            {"id": "e", "at": "end", "say": "E", "if": {"draft_any": ["fixed"], "tools_any": ["cargo"]}},
        ])),
    );
    let said = hub.turn_rules_start(&session, "go").unwrap();
    assert_eq!(said, "[turn rule s] S");
    hub.turn_rules_tool(
        &session,
        &json!({"sessionUpdate": "tool_call", "title": "Bash",
        "rawInput": {"command": "cargo test"}}),
    );
    session.stream.lock().unwrap().trailing_text = "It is fixed.".into();
    let mut msg = json!({"status": "completed"});
    hub.turn_rules_end(&session, &mut msg);
    assert_eq!(msg["harnessMagic"]["turnRules"]["fired"], 2);
    assert_eq!(
        hub.turn_rules_start(&session, "next").as_deref(),
        Some("[turn rule e] E\n[turn rule s] S")
    );
    TEST_RULES.lock().unwrap().remove("tr-hub");
    hub.shutdown_all().await;
}
