//! Argument names read against each acpmux MCP tool's own schema (`mcp_args.rs`), with the
//! calls agents made that bounced (`~/tool-call-bounces/mine.py`, 2026-11-21).

use super::*;

fn call(tools: &Value, name: &str, arguments: Value) -> (Value, Vec<Renamed>) {
    let mut params = json!({"name": name, "arguments": arguments});
    let renamed = normalize(tools, &mut params);
    (params["arguments"].clone(), renamed)
}

#[test]
fn last_info_and_search_read_session_as_name() {
    let tools = crate::acpmux_mcp::tools();
    for tool in ["last", "info", "search"] {
        for key in ["session", "sessionId", "session_id"] {
            let (args, renamed) = call(&tools, tool, json!({key: "leo-coord-asks"}));
            assert_eq!(args, json!({"name": "leo-coord-asks"}), "{tool} {key}");
            assert_eq!(renamed, vec![Renamed { given: key.into(), canonical: "name".into() }]);
        }
    }
}

#[test]
fn subsessions_send_message_reads_session_and_message() {
    let tools = crate::subsession_mcp::tools();
    let (args, renamed) =
        call(&tools, "send_message", json!({"session": "coord/x", "message": "hi"}));
    assert_eq!(args, json!({"sessionId": "coord/x", "text": "hi"}));
    assert_eq!(renamed.len(), 2);
    for key in ["name", "session_id", "sessionid"] {
        for body in ["prompt", "body"] {
            let (args, _) = call(&tools, "send_message", json!({key: "s", body: "t"}));
            assert_eq!(args, json!({"sessionId": "s", "text": "t"}), "{key} {body}");
        }
    }
    // retry_session lists `session`: `sessionId` reads as it.
    let (args, _) = call(&tools, "retry_session", json!({"sessionId": "s"}));
    assert_eq!(args, json!({"session": "s"}));
}

#[test]
fn send_watch_team_and_bg_tools_read_their_synonyms() {
    let tools = crate::acpmux_mcp::tools();
    let (args, _) = call(&tools, "send", json!({"session": "lane", "message": "m"}));
    assert_eq!(args, json!({"to": "lane", "text": "m"}));
    let (args, _) = call(&tools, "team_send", json!({"to": "@t/r", "message": "m"}));
    assert_eq!(args, json!({"to": "@t/r", "body": "m"}));
    let (args, _) = call(&tools, "inbox_reply", json!({"thread": "t1", "message": "m"}));
    assert_eq!(args, json!({"thread": "t1", "text": "m"}));
    // One session for a list of them becomes the list.
    let (args, _) = call(&tools, "watch_add", json!({"session": "w"}));
    assert_eq!(args, json!({"sessions": ["w"]}));
    let (args, _) = call(&tools, "watch_add", json!({"names": ["a", "b"], "session_id": "me"}));
    assert_eq!(args, json!({"sessions": ["a", "b"], "to": "me"}));
    for tool in ["bg_output", "bg_stop"] {
        for key in ["task", "task_id", "taskId"] {
            let (args, _) = call(&tools, tool, json!({key: "bg-1"}));
            assert_eq!(args, json!({"id": "bg-1"}), "{tool} {key}");
        }
    }
    let (args, _) = call(&tools, "run_wait", json!({"repository": "o/r", "number": 7}));
    assert_eq!(args, json!({"repo": "o/r", "pr": 7}));
}

#[test]
fn a_typo_with_one_close_key_is_read_as_it_and_nothing_else_moves() {
    let tools = crate::acpmux_mcp::tools();
    let (args, renamed) = call(&tools, "last", json!({"name": "s", "coutn": 3}));
    assert_eq!(args, json!({"name": "s", "count": 3}));
    assert_eq!(renamed, vec![Renamed { given: "coutn".into(), canonical: "count".into() }]);
    // A listed key the call gives is kept, and a synonym never overwrites it.
    let (args, renamed) = call(&tools, "last", json!({"name": "a", "session": "b"}));
    assert_eq!(args, json!({"name": "a", "session": "b"}));
    assert!(renamed.is_empty());
    // A key with no match stays for the tool to judge.
    let (args, renamed) = call(&tools, "last", json!({"name": "s", "verbosity": "high"}));
    assert_eq!(args, json!({"name": "s", "verbosity": "high"}));
    assert!(renamed.is_empty());
    // run_wait lists id and timeoutSeconds (#48988): a bg- id's `timeout` reads as the latter.
    let (args, renamed) = call(&tools, "run_wait", json!({"id": "bg-1", "timeout": "600"}));
    assert_eq!(args, json!({"id": "bg-1", "timeoutSeconds": "600"}));
    assert_eq!(
        renamed,
        vec![Renamed { given: "timeout".into(), canonical: "timeoutSeconds".into() }]
    );
    // Every acpmux tool's canonical call is left as it is.
    for tool in crate::mcp_hint::names(&tools) {
        let props = tools.as_array().unwrap().iter().find(|t| t["name"] == tool).unwrap()
            ["inputSchema"]["properties"]
            .clone();
        let args: Map<String, Value> =
            props.as_object().unwrap().keys().map(|k| (k.clone(), json!("v"))).collect();
        let (got, renamed) = call(&tools, tool, Value::Object(args.clone()));
        assert_eq!(got, Value::Object(args), "{tool}");
        assert!(renamed.is_empty(), "{tool}");
    }
}

#[test]
fn the_result_tells_each_rename_in_one_line() {
    let renamed = vec![
        Renamed { given: "session".into(), canonical: "sessionId".into() },
        Renamed { given: "message".into(), canonical: "text".into() },
    ];
    let mut result =
        json!({"content": [{"type": "text", "text": "Sent."}], "structuredContent": {}});
    tell(&mut result, &renamed);
    let line =
        "(read argument session as sessionId, message as text; the schema's names are canonical)";
    assert_eq!(result["content"][1]["text"], line);
    assert_eq!(result["structuredContent"]["argumentsRead"], line);
    let mut untouched = json!({"content": []});
    tell(&mut untouched, &[]);
    assert_eq!(untouched, json!({"content": []}));
}
