//! Argument names read against each acpmux MCP tool's own schema (`mcp_args.rs`), with the
//! calls agents made that bounced (`~/tool-call-bounces/mine.py`, 2026-11-21).

use super::*;

fn call(tools: &Value, name: &str, arguments: Value) -> (Value, ArgsRead) {
    let mut params = json!({"name": name, "arguments": arguments});
    let read = normalize(tools, &mut params);
    (params["arguments"].clone(), read)
}

#[test]
fn last_info_and_search_read_session_as_name() {
    let tools = crate::acpmux_mcp::tools();
    for tool in ["last", "info", "search"] {
        for key in ["session", "sessionId", "session_id"] {
            let (args, read) = call(&tools, tool, json!({key: "leo-coord-asks"}));
            assert_eq!(args, json!({"name": "leo-coord-asks"}), "{tool} {key}");
            assert_eq!(read.renamed, vec![Renamed { given: key.into(), canonical: "name".into() }]);
            assert!(read.unimplemented.is_empty(), "{tool} {key}");
        }
    }
}

#[test]
fn subsessions_send_message_reads_session_and_message() {
    let tools = crate::subsession_mcp::tools();
    let (args, read) = call(&tools, "send_message", json!({"session": "coord/x", "message": "hi"}));
    assert_eq!(args, json!({"sessionId": "coord/x", "text": "hi"}));
    assert_eq!(read.renamed.len(), 2);
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
    let (args, read) = call(&tools, "last", json!({"name": "s", "coutn": 3}));
    assert_eq!(args, json!({"name": "s", "count": 3}));
    assert_eq!(read.renamed, vec![Renamed { given: "coutn".into(), canonical: "count".into() }]);
    // A listed key the call gives is kept, and a synonym never overwrites it.
    let (args, read) = call(&tools, "last", json!({"name": "a", "session": "b"}));
    assert_eq!(args, json!({"name": "a", "session": "b"}));
    assert!(read.renamed.is_empty() && read.unimplemented.is_empty());
    // run_wait lists id and timeoutSeconds (#48988): a bg- id's `timeout` reads as the latter.
    let (args, read) = call(&tools, "run_wait", json!({"id": "bg-1", "timeout": "600"}));
    assert_eq!(args, json!({"id": "bg-1", "timeoutSeconds": "600"}));
    assert_eq!(
        read.renamed,
        vec![Renamed { given: "timeout".into(), canonical: "timeoutSeconds".into() }]
    );
    // Every acpmux tool's canonical call is left as it is.
    for tool in crate::mcp_hint::names(&tools) {
        let props = tools.as_array().unwrap().iter().find(|t| t["name"] == tool).unwrap()
            ["inputSchema"]["properties"]
            .clone();
        let args: Map<String, Value> =
            props.as_object().unwrap().keys().map(|k| (k.clone(), json!("v"))).collect();
        let (got, read) = call(&tools, tool, Value::Object(args.clone()));
        assert_eq!(got, Value::Object(args), "{tool}");
        assert!(read.renamed.is_empty(), "{tool}");
        assert!(read.unimplemented.is_empty(), "{tool}");
    }
}

#[test]
fn the_result_tells_each_rename_in_one_line() {
    let read = ArgsRead {
        renamed: vec![
            Renamed { given: "session".into(), canonical: "sessionId".into() },
            Renamed { given: "message".into(), canonical: "text".into() },
        ],
        unimplemented: Vec::new(),
        tool: "send_message".into(),
        listed: vec!["sessionId".into(), "text".into()],
    };
    let mut result =
        json!({"content": [{"type": "text", "text": "Sent."}], "structuredContent": {}});
    tell(&mut result, &read);
    let line =
        "(read argument session as sessionId, message as text; the schema's names are canonical)";
    assert_eq!(result["content"][1]["text"], line);
    assert_eq!(result["structuredContent"]["argumentsRead"], line);
    assert!(result["structuredContent"].get("argumentsNotImplemented").is_none());
    let mut untouched = json!({"content": []});
    tell(&mut untouched, &ArgsRead::default());
    assert_eq!(untouched, json!({"content": []}));
}

/// The defect this file's `unimplemented` half fixes, measured on 2026-11-22: `bg_output` called
/// with `tail_lines: 40` answered the whole 1438-byte log, and `tail_lines` is in no schema in
/// this crate. The call still runs (a bounce would cost a round trip); what changes is that the
/// answer names the argument that did nothing and the bounds `bg_output` does implement.
#[test]
fn bg_output_names_tail_lines_and_the_bounds_it_does_implement() {
    let tools = crate::acpmux_mcp::tools();
    let (args, read) = call(&tools, "bg_output", json!({"id": "bg-1", "tail_lines": 40}));
    // A line count is not read as a byte count: 40 bytes would be a different wrong answer.
    assert_eq!(args, json!({"id": "bg-1", "tail_lines": 40}));
    assert!(read.renamed.is_empty());
    assert_eq!(read.unimplemented, vec!["tail_lines".to_owned()]);
    let mut result =
        json!({"content": [{"type": "text", "text": "the log"}], "structuredContent": {}});
    tell(&mut result, &read);
    let line = "(bg_output does not implement argument tail_lines, so it did nothing; \
its arguments are description, fromByte, id, maxBytes)";
    assert_eq!(result["content"][1]["text"], line);
    assert_eq!(result["structuredContent"]["argumentsNotImplemented"], line);
    assert!(result["structuredContent"].get("argumentsRead").is_none());
    // The bounds it does implement are untouched, and such a call is told nothing.
    let bounded = json!({"id": "bg-1", "fromByte": 0, "maxBytes": 4096});
    let (args, read) = call(&tools, "bg_output", bounded.clone());
    assert_eq!(args, bounded);
    assert!(read.renamed.is_empty() && read.unimplemented.is_empty());
    let mut untold = json!({"content": [], "structuredContent": {}});
    tell(&mut untold, &read);
    assert_eq!(untold, json!({"content": [], "structuredContent": {}}));
}

/// Every tool, not just `bg_output`: an argument no listed key stands for is named, whatever the
/// tool, because [`normalize`] is the one place every acpmux `tools/call` passes through.
#[test]
fn an_argument_no_listed_key_stands_for_is_named_by_every_tool() {
    let tools = crate::acpmux_mcp::tools();
    let (args, read) = call(&tools, "last", json!({"name": "s", "verbosity": "high"}));
    assert_eq!(args, json!({"name": "s", "verbosity": "high"}));
    assert_eq!(read.unimplemented, vec!["verbosity".to_owned()]);
    assert!(unimplemented_line(&read).is_some_and(|l| l.starts_with("(last does not implement")));
    // Several of them go in one line, as they were given.
    let (_, read) =
        call(&tools, "bg_start", json!({"command": "ls", "umask": "077", "stdin": "x"}));
    assert_eq!(read.unimplemented, vec!["umask".to_owned(), "stdin".to_owned()]);
    assert_eq!(
        unimplemented_line(&read).as_deref(),
        Some(
            "(bg_start does not implement arguments umask, stdin, so they did nothing; \
its arguments are command, cwd, description, notify)"
        )
    );
    // The keys the daemon and the harness read themselves are not a mistake and are not named.
    let (_, read) = call(
        &tools,
        "bg_start",
        json!({"command": "ls", "sessionId": "s", "callerSubagent": "a", "_meta": {}}),
    );
    assert!(read.unimplemented.is_empty(), "{:?}", read.unimplemented);
}
