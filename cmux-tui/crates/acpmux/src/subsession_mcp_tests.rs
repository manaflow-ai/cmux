use super::*;

/// What the tools promise about where the user sees a sub-session:
/// listed under the parent chat in the chat list, and its own chat only once
/// it is opened, so the text names how to open it.
#[test]
fn the_tools_say_where_the_user_sees_a_sub_session() {
    let tools = tools();
    let start = tools
        .as_array()
        .and_then(|t| t.iter().find(|t| t["name"] == "start_session"))
        .and_then(|t| t["description"].as_str())
        .expect("start_session")
        .to_owned();
    assert!(!start.contains("sees under yours in the sidebar"), "{start}");
    assert!(start.contains("under your chat in the chat list"), "{start}");
    assert!(start.contains(CMUX_APP_TOOL), "{start}");
    let rules = instructions();
    assert!(rules.contains(&format!("cmux.{CMUX_APP_TOOL}(")), "{rules}");
    assert!(rules.contains(&format!("cmux.{CMUX_APP_TAB_TOOL}(")), "{rules}");
    assert!(!rules.contains("agent_report"), "agent.report needs a terminal: {rules}");
}

/// `retry_session` takes the contract's `{session, subagent?}` and sends `_acpmux/subsession/retry`'s
/// `{sessionId, subagentId?}`.
#[test]
fn retry_session_names_the_session_and_maps_its_arguments() {
    let tools = tools();
    let retry = tools
        .as_array()
        .and_then(|t| t.iter().find(|t| t["name"] == "retry_session"))
        .expect("retry_session")
        .clone();
    assert_eq!(retry["inputSchema"]["required"], json!(["session"]), "{retry}");
    assert!(retry["inputSchema"]["properties"]["subagent"].is_object(), "{retry}");
    assert_eq!(
        retry_params(&json!({"session": "s1", "subagent": "a1"})),
        json!({"sessionId": "s1", "subagentId": "a1"})
    );
    assert_eq!(retry_params(&json!({"sessionId": "s2"})), json!({"sessionId": "s2"}));
    let text = retried_text(&json!({"promptId": "p~resume-1", "turnId": "t2", "kind": "turn"}));
    assert!(text.starts_with("Retrying: prompt p~resume-1 started turn t2."), "{text}");
}

/// `host` documents `auto` and `auto-build`, and a placed start says why
/// in `new --host auto`'s words.
#[test]
fn start_session_documents_host_auto_and_says_where_it_was_placed() {
    let tools = tools();
    let host = tools
        .as_array()
        .and_then(|t| t.iter().find(|t| t["name"] == "start_session"))
        .and_then(|t| t["inputSchema"]["properties"]["host"]["description"].as_str())
        .expect("start_session host")
        .to_owned();
    assert!(host.contains("\"auto\"") && host.contains("\"auto-build\""), "{host}");
    assert!(host.contains("acpmux new --machine auto") && host.contains("placed on "), "{host}");
    let placed = "placed on box: 40 GB RAM free, room for 4";
    let r = json!({"shortName": "t", "sessionId": "s", "depth": 1, "placed": placed});
    let text = started_text(&r);
    assert!(
        text.starts_with("Started sub-session t") && text.ends_with(&format!("\n{placed}")),
        "{text}"
    );
    let r = json!({"shortName": "t", "sessionId": "s", "depth": 1});
    assert!(!started_text(&r).contains("placed on"));
}
