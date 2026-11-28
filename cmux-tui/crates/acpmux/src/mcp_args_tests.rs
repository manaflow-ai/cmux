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
    tell(&mut result, &renamed, &[]);
    let line =
        "(read argument session as sessionId, message as text; the schema's names are canonical)";
    assert_eq!(result["content"][1]["text"], line);
    assert_eq!(result["structuredContent"]["argumentsRead"], line);
    let mut untouched = json!({"content": []});
    tell(&mut untouched, &[], &[]);
    assert_eq!(untouched, json!({"content": []}));
}

fn read_values(tools: &Value, name: &str, arguments: Value) -> (Value, Vec<Reread>) {
    let mut params = json!({"name": name, "arguments": arguments});
    normalize(tools, &mut params);
    let reread = values(tools, &mut params);
    (params["arguments"].clone(), reread)
}

#[test]
fn a_filter_word_that_means_every_one_of_them_is_no_filter() {
    // The round trip this saves: `bg_list {"state": "all"}` refused with "state is one of
    // running, exited, stopped, killed, lost, ok, failed" (2026-11-22). `all` is no filter.
    let tools = crate::acpmux_mcp::tools();
    for word in ["all", "ALL", "any", "every", "*", "everything"] {
        let (args, reread) = read_values(&tools, "bg_list", json!({"state": word, "limit": 30}));
        assert_eq!(args, json!({"limit": 30}), "state {word:?} still filters");
        assert_eq!(
            reread,
            vec![Reread { key: "state".into(), given: word.into(), read_as: None }],
            "state {word:?}"
        );
    }
    // And through the key synonym the same call used: `status` reads as `state`, then `all` drops.
    let (args, _) = read_values(&tools, "bg_list", json!({"status": "all"}));
    assert_eq!(args, json!({}));
    // The line says both.
    let mut params = json!({"name": "bg_list", "arguments": {"status": "all"}});
    let renamed = normalize(&tools, &mut params);
    let reread = values(&tools, &mut params);
    assert_eq!(
        line(&renamed, &reread).as_deref(),
        Some(
            "(read argument status as state, state \"all\" as every one of them (no filter); \
the schema's names are canonical)"
        )
    );
}

#[test]
fn a_value_the_schema_lists_under_another_spelling_is_read_as_it() {
    let tools = crate::acpmux_mcp::tools();
    let (args, reread) = read_values(&tools, "search", json!({"query": "q", "role": "Assistant"}));
    assert_eq!(args, json!({"query": "q", "role": "assistant"}));
    assert_eq!(
        reread,
        vec![Reread {
            key: "role".into(),
            given: "Assistant".into(),
            read_as: Some("assistant".into())
        }]
    );
    // A near miss too (one tool's own reader already did this for its own key; now every tool's).
    let (args, _) = read_values(&tools, "bg_list", json!({"state": "runnning"}));
    assert_eq!(args, json!({"state": "running"}));
    // A list of listed values is read entry by entry.
    let (args, _) = read_values(&tools, "watch_add", json!({"sessions": ["a"], "until": "Done"}));
    assert_eq!(args, json!({"sessions": ["a"], "until": ["done"]}));
}

#[test]
fn a_required_value_and_an_unknown_one_are_left_for_the_tool_to_judge() {
    let tools = crate::acpmux_mcp::tools();
    // goal_update requires status: dropping it would leave the tool nothing to do.
    let (args, reread) = read_values(&tools, "goal_update", json!({"status": "all"}));
    assert_eq!(args, json!({"status": "all"}));
    assert!(reread.is_empty());
    // A value no listed one is close to stays as it was: the tool refuses it, saying its own words.
    let (args, reread) = read_values(&tools, "send", json!({"to": "lane", "class": "urgent"}));
    assert_eq!(args, json!({"to": "lane", "class": "urgent"}));
    assert!(reread.is_empty());
    // Every tool's canonical call is left as it is, value for value.
    for tool in crate::mcp_hint::names(&tools) {
        let props = tools.as_array().unwrap().iter().find(|t| t["name"] == tool).unwrap()
            ["inputSchema"]["properties"]
            .clone();
        let args: Map<String, Value> = props
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, p)| {
                let (listed, per_entry) = match p.get("enum") {
                    Some(e) => (e.clone(), false),
                    None => (
                        p.get("items").and_then(|i| i.get("enum")).cloned().unwrap_or(json!([])),
                        true,
                    ),
                };
                let one = listed.as_array().and_then(|a| a.first()).cloned();
                let value = match (one, per_entry) {
                    (Some(v), true) => json!([v]),
                    (Some(v), false) => v,
                    (None, _) => json!("v"),
                };
                (k.clone(), value)
            })
            .collect();
        let (got, reread) = read_values(&tools, tool, Value::Object(args.clone()));
        assert_eq!(got, Value::Object(args), "{tool}");
        assert!(reread.is_empty(), "{tool}: {reread:?}");
    }
}
