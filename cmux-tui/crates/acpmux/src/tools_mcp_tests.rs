use super::*;

fn server(name: &'static str) -> Served {
    Served {
        name,
        session: "s".into(),
        tools: json!([]),
        instructions: None,
        call: boxed(|_, _| async { json!({}) }),
    }
}

#[test]
fn a_request_names_its_server_and_the_call_keeps_the_rest_of_its_meta() {
    let servers = [server("cmux-forum"), server("acpmux")];
    let mut params =
        json!({"name": "ls", "_meta": {SERVER_META: "acpmux", "claudecode/toolUseId": "t1"}});
    assert_eq!(pick(&servers, &mut params).unwrap().name, "acpmux");
    assert_eq!(params, json!({"name": "ls", "_meta": {"claudecode/toolUseId": "t1"}}));
    // Only the selector in `_meta`: the call sees no `_meta`, as before.
    let mut params = json!({"name": "rules", "_meta": {SERVER_META: "cmux-forum"}});
    assert_eq!(pick(&servers, &mut params).unwrap().name, "cmux-forum");
    assert_eq!(params, json!({"name": "rules"}));
    // Several servers and none named, or one it does not serve: refused, never guessed.
    assert!(pick(&servers, &mut json!({"name": "ls"})).is_err());
    assert!(pick(&servers, &mut json!({"_meta": {SERVER_META: "cmux-secrets"}})).is_err());
    // A process of one server needs no name.
    let one = [server("cmux-forum")];
    assert_eq!(pick(&one, &mut json!({})).unwrap().name, "cmux-forum");
}

#[test]
fn it_owns_only_acpmux_s_own_server_commands() {
    let args = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
    assert!(owns("cmux-forum", &args(&["forum-mcp"])));
    assert!(owns("acpmux", &args(&["acp", "acpmux-mcp"])));
    assert!(!owns("cmux-forum", &args(&["acpmux-mcp"])));
    assert!(!owns("cmux-repo", &args(&["repo-mcp"])));
    assert!(!owns("cmux-cua", &args(&["cua-mcp"])));
}
