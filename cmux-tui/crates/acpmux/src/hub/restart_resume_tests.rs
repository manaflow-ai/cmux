use super::*;
use crate::config::{Config, StoreMode};
use crate::store::EventRecord;

/// A hub holding one chat whose last turn a restart cut, with `delays` as
/// `autoResumeDelaysMs` (`None`: the key is unset). `done` continuations ran for it already,
/// as its prompt id's attempt suffix records. The caller removes `root` when it is done.
fn cut_turn(delays: Option<Vec<u64>>, done: usize) -> (std::path::PathBuf, Arc<Hub>, Arc<Session>) {
    let root = std::env::temp_dir().join(format!("acpmux-restart-resume-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    cfg.auto_resume_delays_ms = delays;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
        // `idle`: no child process, which is what a daemon restart leaves behind. "open" is
        // not a SessionStatus, and serde refused it before the fixture was even built.
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("c1").unwrap();
    let prompt_id = if done == 0 { "p1".to_owned() } else { format!("p1{SUFFIX}{done}") };
    hub.append(&session, "in", "turn_started", json!({"turnId": "t1", "promptId": prompt_id}));
    hub.append(&session, "in", "user_message", json!({"turnId": "t1", "text": "do the thing"}));
    (root, hub, session)
}

/// Why the chat logged `auto_resume_exhausted`, if it did.
fn exhausted(hub: &Hub) -> Vec<Value> {
    hub.events("c1", 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "auto_resume_exhausted")
        .map(|e| e.msg)
        .collect()
}

/// What one cut turn's chain does with `delays` configured and `done` continuations behind
/// it: the continuation's prompt id if one goes out, and what it logged as exhausted.
async fn chain(delays: Option<Vec<u64>>, done: usize) -> (Option<String>, Vec<Value>) {
    let (root, hub, session) = cut_turn(delays, done);
    let id = hub.log_restart_continuation(&session, "t1");
    let gave_up = exhausted(&hub);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
    (id, gave_up)
}

/// A daemon that crashed after it queued the continuation and before it settled the cut turn
/// finds the turn open again: the next one queues the continuation once, not twice.
#[tokio::test]
async fn a_crash_before_the_cut_turn_settles_queues_its_continuation_once() {
    let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
    let first = hub.log_restart_continuation(&session, "t1");
    let again = hub.log_restart_continuation(&session, "t1");
    assert_eq!(first, Some(format!("p1{SUFFIX}1")));
    assert_eq!(again, first);
    let events = hub.events("c1", 0, 10_000).unwrap();
    let queued = events.iter().filter(|e| e.kind == "queued").count();
    assert_eq!(queued, 1, "{events:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// One continuation per configured wait, for a chain of restarts as for a transport cut:
/// `autoResumeDelaysMs` is the whole loop, not only its waits.
#[tokio::test]
async fn the_configured_waits_set_how_many_restart_continuations_run() {
    // One wait: the first continuation goes out.
    let (id, gave_up) = chain(Some(vec![10_000]), 0).await;
    assert_eq!(id, Some(format!("p1{SUFFIX}1")));
    assert!(gave_up.is_empty(), "{gave_up:?}");

    // The second has no wait left, so the chain gives up instead of running a fixed four.
    let (id, gave_up) = chain(Some(vec![10_000]), 1).await;
    assert_eq!(id, None);
    // The fields the record is for, not the whole object: a field added to the record later
    // is not this test's business.
    assert_eq!(gave_up.len(), 1, "{gave_up:?}");
    let msg = &gave_up[0];
    assert_eq!(
        (&msg["promptId"], &msg["attempts"], &msg["turnId"], &msg["reason"]),
        (&json!("p1"), &json!(1), &json!("t1"), &json!("daemon_restart")),
        "{msg}"
    );

    // A configured six-attempt loop runs all of its attempts.
    let (id, gave_up) = chain(Some(vec![10_000; 6]), 5).await;
    assert_eq!(id, Some(format!("p1{SUFFIX}6")));
    assert!(gave_up.is_empty(), "{gave_up:?}");
}

/// A move is not a failed attempt: a turn moved more times than the waits configured still
/// goes on where it lands, and the moves behind a restart use up none of its attempts.
#[tokio::test]
async fn a_move_spends_no_attempt_and_is_never_refused_for_the_count() {
    let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
    let (mut prompt, mut said) = ("p1".to_owned(), String::new());
    for hop in 1..=10 {
        let turn = format!("t{hop}");
        if hop > 1 {
            hub.append(&session, "in", "turn_started", json!({"turnId": turn, "promptId": prompt}));
            hub.append(&session, "in", "user_message", json!({"turnId": turn, "text": said}));
        }
        let id = hub.log_continuation(&session, &turn, Cut::Move);
        assert_eq!(id, Some(format!("p1{SUFFIX}{hop}")), "move {hop}");
        // Each continuation quotes what the person asked, once, never the one before it.
        let events = hub.events("c1", 0, 10_000).unwrap();
        let queued = events.iter().rfind(|e| e.kind == "queued").expect("queued").msg.clone();
        said = queued["text"].as_str().unwrap().to_owned();
        assert_eq!(said.matches("<message>").count(), 1, "move {hop}: {said}");
        assert!(said.contains("<message>\ndo the thing\n</message>"), "move {hop}: {said}");
        hub.append(&session, "in", "turn_result", json!({"turnId": turn}));
        prompt = id.unwrap();
    }
    assert_eq!(hub.moves_behind(&session, "p1"), 10);
    // Ten moves behind it, the one configured attempt is still unspent: a restart continues.
    hub.append(&session, "in", "turn_started", json!({"turnId": "t11", "promptId": prompt}));
    hub.append(&session, "in", "user_message", json!({"turnId": "t11", "text": "on"}));
    let id = hub.log_restart_continuation(&session, "t11");
    assert_eq!(id, Some(format!("p1{SUFFIX}11")));
    hub.append(&session, "in", "turn_result", json!({"turnId": "t11"}));
    // The second restart has no wait left.
    hub.append(&session, "in", "turn_started", json!({"turnId": "t12", "promptId": id.unwrap()}));
    hub.append(&session, "in", "user_message", json!({"turnId": "t12", "text": "on"}));
    assert_eq!(hub.log_restart_continuation(&session, "t12"), None);
    assert_eq!(exhausted(&hub).len(), 1);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A move at a tool boundary marks its continuation as one the harness may run from its own
/// transcript; a move that cut the turn anywhere (`--interrupt`) does not. Both keep the
/// text, the reason and the id, which every other harness and every record reader use.
#[tokio::test]
async fn only_a_boundary_moves_continuation_may_run_with_no_prompt() {
    for (cut, want) in [(Cut::MoveAtBoundary, true), (Cut::Move, false), (Cut::Restart, false)] {
        let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
        let id = hub.log_continuation(&session, "t1", cut);
        assert_eq!(id, Some(format!("p1{SUFFIX}1")), "{cut:?}");
        let events = hub.events("c1", 0, 10_000).unwrap();
        let queued = events.iter().rfind(|e| e.kind == "queued").expect("queued").msg.clone();
        let provenance = queued.pointer("/_meta/provenance");
        assert_eq!(silent(provenance), want, "{cut:?}: {queued}");
        let text = queued.pointer("/text").and_then(|v| v.as_str()).unwrap();
        assert!(text.starts_with(cut.opening()), "{cut:?}: {text}");
        assert_eq!(Cut::MoveAtBoundary.opening(), Cut::Move.opening());
        assert_eq!(Cut::MoveAtBoundary.reason(), Cut::Move.reason());
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
    assert!(!silent(None));
    assert!(!silent(Some(&json!({"kind": "person", "silent": true}))));
}

/// The key unset keeps the default waits' attempts, and `[]` still turns it off.
#[tokio::test]
async fn an_unset_key_keeps_the_default_attempts_and_an_empty_list_turns_it_off() {
    let attempts = DEFAULT_DELAYS_MS.len();
    let (id, _) = chain(None, attempts - 1).await;
    assert_eq!(id, Some(format!("p1{SUFFIX}{attempts}")));

    let (id, gave_up) = chain(None, attempts).await;
    assert_eq!(id, None);
    assert_eq!(gave_up.len(), 1, "{gave_up:?}");

    // Off is not a chain that ran out: it logs nothing.
    let (id, gave_up) = chain(Some(vec![]), 0).await;
    assert_eq!(id, None);
    assert!(gave_up.is_empty(), "{gave_up:?}");
}

/// A carried turn (`carried_turn.rs`) the restart cut: its continuation quotes the steers it
/// carried, logged in the turn before it, and attaches their images; not an older turn's.
#[tokio::test]
async fn a_carried_turns_continuation_quotes_the_steers_it_carried() {
    let (root, hub, session) = cut_turn(Some(vec![10_000]), 0);
    let image = json!({"mimeType": "image/png", "data": "aGk="});
    let steer = json!({"turnId": "t1", "promptId": "p-late", "text": "late ask", "steer": true, "images": [image]});
    hub.append(&session, "mux", "user_message", steer);
    let other = json!({"turnId": "t1", "promptId": "p-read", "text": "read in t1", "steer": true});
    hub.append(&session, "mux", "user_message", other);
    let started = json!({"turnId": "t2", "promptId": "p-late", "trustGate": true, "carried": {"fromTurnId": "t1", "promptIds": ["p-late"]}});
    hub.append(&session, "mux", "turn_started", started);
    let id = hub.log_restart_continuation(&session, "t2");
    assert_eq!(id, Some(format!("p-late{SUFFIX}1")));
    let events = hub.events("c1", 0, 10_000).unwrap();
    let queued = events.iter().rfind(|e| e.kind == "queued").expect("queued").msg.clone();
    let text = queued["text"].as_str().unwrap();
    assert!(text.contains("late ask"), "{text}");
    assert!(!text.contains("read in t1") && !text.contains("do the thing"), "{text}");
    assert_eq!(queued["images"], json!([image]), "{queued}");
    assert_eq!(queued["trustGate"], true, "{queued}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn the_continuation_quotes_the_cut_prompt_and_its_steers() {
    let text = continue_text(&["do the thing".into(), "also this".into()], &[], ToolOmission::None);
    assert!(text.contains("Its prompt:\n<message>\ndo the thing\n</message>"), "{text}");
    assert!(text.contains("A message sent into it:\n<message>\nalso this\n</message>"));
    assert!(text.ends_with("Do not redo work that completed."));
    let long = continue_text(&["x".repeat(MAX_QUOTE_CHARS + 10)], &[], ToolOmission::None);
    assert!(!long.contains(&"x".repeat(MAX_QUOTE_CHARS + 1)));
}

#[test]
fn a_restart_prompt_lists_tool_calls_that_have_not_finished() {
    let update = |fields| {
        json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"update": fields}
        })
    };
    let records = vec![
        EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: update(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": "call-1",
                "status": "in_progress"
            })),
            host_seq: None,
        },
        EventRecord {
            seq: 2,
            at: 2,
            dir: "in".into(),
            kind: "tool_call_update".into(),
            msg: update(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call-1",
                "title": "Run tests",
                "rawInput": {"command": "cargo test -p acpmux"}
            })),
            host_seq: None,
        },
        EventRecord {
            seq: 3,
            at: 3,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: update(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": "call-2",
                "title": "Finished",
                "status": "in_progress"
            })),
            host_seq: None,
        },
        EventRecord {
            seq: 4,
            at: 4,
            dir: "in".into(),
            kind: "tool_call_update".into(),
            msg: update(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call-2",
                "status": "completed"
            })),
            host_seq: None,
        },
    ];
    let (tools, omitted) = unfinished_tools(&records);
    let text = continue_text(&[], &tools, omitted);
    assert!(text.contains("Tool calls started but not finished:"), "{text}");
    assert!(text.contains("Run tests (id: call-1)"), "{text}");
    assert!(text.contains("input: {\"command\":\"cargo test -p acpmux\"}"), "{text}");
    assert!(!text.contains("Finished (id: call-2)"), "{text}");
}

fn tool_record(id: usize, status: &str) -> EventRecord {
    EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "tool_call_update".into(),
        msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update",
            "toolCallId": format!("call-{id}"), "status": status}}}),
        host_seq: None,
    }
}

#[test]
fn overflow_completion_replays_preserve_exact_retained_histories() {
    let mut records = Vec::new();
    for id in 0..200 {
        records.push(tool_record(id, "in_progress"));
        records.push(tool_record(id, "in_progress"));
    }
    let (tools, omitted) = unfinished_tools(&records);
    assert_eq!(tools.len(), MAX_UNFINISHED_TOOLS);
    assert_eq!(omitted, ToolOmission::Unfinished);
    let retained = tools[0].id.clone();
    for id in 0..200 {
        if format!("call-{id}") == retained {
            continue;
        }
        records.push(tool_record(id, "completed"));
        records.push(tool_record(id, "completed"));
        records.push(tool_record(id, "in_progress"));
    }
    records.push(tool_record(999, "completed"));
    let (tools, omitted) = unfinished_tools(&records);
    assert!(tools.len() <= 1);
    assert!(tools.iter().all(|tool| tool.id == retained));
    assert_eq!(omitted, ToolOmission::Unknown);
    for id in 0..200 {
        records.push(tool_record(id, "failed"));
    }
    let (tools, omitted) = unfinished_tools(&records);
    assert!(tools.is_empty());
    assert_eq!(omitted, ToolOmission::Unknown);
    let text = continue_text(&[], &tools, omitted);
    assert!(!text.contains("Tool calls started"));
    assert!(!text.contains("unfinished tool calls omitted"));
    assert!(text.contains("completion status is unknown"));
}

#[test]
fn completed_tool_histories_are_visited_once() {
    let mut records: Vec<_> = (0..10_000).map(|id| tool_record(id, "in_progress")).collect();
    records.extend((0..10_000).map(|id| tool_record(id, "completed")));
    let mut scans = 0;
    let mut visits = 0;
    let (tools, _) = collect_unfinished(|page| {
        scans += 1;
        for record in &records {
            visits += 1;
            page.note(tool_update(record, None).unwrap());
            assert!(page.calls.len() <= TOOL_PAGE_SIZE);
        }
    });
    assert!(tools.is_empty());
    eprintln!("restart-tool-fold: scans={scans} decoded_updates={visits}");
    assert_eq!((scans, visits), (1, records.len()));
}

#[test]
fn discarded_later_active_tool_is_reported_as_unknown_not_unfinished() {
    let mut identities: Vec<_> = (0..200)
        .map(|id| {
            let digest: [u8; 32] = Sha256::digest(format!("call-{id}").as_bytes()).into();
            (digest, id)
        })
        .collect();
    identities.sort();
    let later = identities.last().unwrap().1;
    let mut records = Vec::new();
    for (_, id) in &identities[..TOOL_PAGE_SIZE] {
        records.push(tool_record(*id, "in_progress"));
        records.push(tool_record(*id, "completed"));
    }
    records.push(tool_record(later, "in_progress"));
    let (tools, omitted) = unfinished_tools(&records);
    assert!(tools.is_empty());
    assert_eq!(omitted, ToolOmission::Unknown);
    assert!(continue_text(&[], &tools, omitted).contains("completion status is unknown"));
}

#[test]
fn retained_tool_metadata_updates_are_preserved() {
    let mut records = vec![tool_record(1, "in_progress")];
    let mut metadata = tool_record(1, "in_progress");
    metadata.msg["params"]["update"]["title"] = json!("Last live tool");
    metadata.msg["params"]["update"]["rawInput"] = json!({"command": "cargo check"});
    records.push(metadata);
    let (tools, omitted) = unfinished_tools(&records);
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].name, "Last live tool");
    assert_eq!(tools[0].input.as_deref(), Some("{\"command\":\"cargo check\"}"));
    assert_eq!(omitted, ToolOmission::None);
}

#[test]
fn restart_tool_details_are_single_line_and_mask_secrets_before_truncation() {
    let credential = ["abcd", "1234"].repeat(8).join("");
    let record = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"update": {"sessionUpdate": "tool_call",
            "toolCallId": "call\n\t\u{1b}1", "title": "Run\r\n\t\u{0} tests",
            "status": "in_progress", "rawInput": {"command": format!("curl -H 'Authorization: Bearer {credential}'")}}}}),
        host_seq: None,
    };
    let (tools, omitted) = unfinished_tools(&[record]);
    let text = continue_text(&[], &tools, omitted);
    assert!(text.contains("Run tests (id: call 1)"), "{text}");
    assert!(!text.contains(&credential), "credentials must not enter the continuation");
    assert!(text.contains("[secret]"));
    assert!(!text.contains('\u{1b}') && !text.contains('\u{0}'));
    for prefix in [" ".repeat(270), "x".repeat(240)] {
        let masked = input_prefix(
            &json!({"rawInput": format!("{prefix} Authorization: Bearer {credential}")}),
        )
        .unwrap();
        assert!(!masked.contains(&credential[..24]), "secret straddles display cut");
    }
    let masked = input_prefix(&json!({"rawInput": {"password": credential}})).unwrap();
    assert!(!masked.contains(&credential));
    assert!(masked.contains("[secret]"));
    // A token longer than the scan budget is dropped whole, never exposed as a prefix.
    let huge = credential.repeat(MAX_TOOL_SCAN_BYTES);
    let masked =
        input_prefix(&json!({"rawInput": format!("Authorization: Bearer {huge}")})).unwrap();
    assert!(!masked.contains(&credential[..24]));
    assert!(!bounded_text(&format!("Authorization: Bearer {credential}")).contains(&credential));
}

#[test]
fn restart_inputs_mask_decoded_quoted_assignments_before_json_escaping() {
    let password = ["open", "sesame", "42"].join("_");
    let command = format!("PASSWORD=\"{password}\" ./deploy");
    for raw in [json!(command), json!({"command": command}), json!([{"nested": command}])] {
        let masked = input_prefix(&json!({"rawInput": raw})).unwrap();
        assert!(!masked.contains(&password), "quoted assignment leaked into restart input");
        assert!(masked.contains("[secret]"), "{masked}");
        assert!(!masked.contains("./deploy"), "suffix must be redacted: {masked}");
    }
}

#[test]
fn restart_inputs_mask_whole_quoted_assignment_values() {
    for command in [
        r#"PASSWORD="correct horse battery staple" ./deploy"#,
        r#"PASSWORD="open sesame" ./deploy"#,
        r#"PASSWORD='open sesame' ./deploy"#,
        r#"PASSWORD="open \"sesame\" again" ./deploy"#,
        r#"PASSWORD="open\\ sesame" ./deploy"#,
        r#"PASSWORD='open '\''sesame' ./deploy"#,
        r#"PASSWORD="open sesame"' extra words' ./deploy"#,
        r#"PASSWORD="open sesame"suffix ./deploy"#,
        r#"PASSWORD="x" API_KEY='y z' ./deploy"#,
    ] {
        let expected = r#""PASSWORD=[secret]""#;
        assert_eq!(input_prefix(&json!({"rawInput": command})).unwrap(), expected);
        let nested = input_prefix(&json!({"rawInput": {"command": command}})).unwrap();
        assert_eq!(nested, format!("{{\"command\":{expected}}}"));
        let array = input_prefix(&json!({"rawInput": [command]})).unwrap();
        assert_eq!(array, format!("[{expected}]"));
    }
    // A harmless quoted argument remains useful context.
    let plain = r#"echo "correct horse battery staple""#;
    assert_eq!(mask_input_assignments(plain), plain);
}

#[test]
fn restart_inputs_mask_concatenated_and_escaped_shell_assignments() {
    for command in [
        r#"PASSWORD=x"open sesame" ./deploy"#,
        r#"PASSWORD=$'open sesame' ./deploy"#,
        r#"PASSWORD=$"open sesame" ./deploy"#,
        r#"PASSWORD=prefix'open '"sesame"suffix ./deploy"#,
        r#"PASSWORD=x$'open '\"sesame\" ./deploy"#,
        r#"PASSWORD=open\ sesame ./deploy"#,
        r#"PASSWORD=open\ sesame' extra words' ./deploy"#,
        r#"PASSWORD=$'open\' sesame' ./deploy"#,
        r#"PASSWORD='open '\''sesame' ./deploy"#,
        r#"PASSWORD="open "sesame\ again ./deploy"#,
        r#"PASSWORD=x"open sesame" API_KEY=$'another secret' ./deploy"#,
        r#"PASSWORD=abc,correcthorse ./deploy"#,
        r#"PASSWORD=abc}correcthorse ./deploy"#,
        r#"PASSWORD=abc]correcthorse ./deploy"#,
        r#"PASSWORD=abc{correcthorse,more}[tail] ./deploy"#,
    ] {
        let expected = "PASSWORD=[secret]";
        assert_eq!(mask_input_assignments(command), expected, "{command}");
        for (value, masked) in [
            (json!(command), json!(expected)),
            (json!({"command": command}), json!({"command": expected})),
            (json!([command]), json!([expected])),
        ] {
            assert_eq!(
                input_prefix(&json!({"rawInput": value})).unwrap(),
                masked.to_string(),
                "{command}"
            );
        }
    }
}

#[test]
fn restart_inputs_hide_ambiguous_shell_substitution_boundaries() {
    for command in [
        r#"PASSWORD=$(printf 'open sesame') ./deploy"#,
        r#"PASSWORD=prefix`printf 'open sesame'` ./deploy"#,
        r#"PASSWORD=${unset:-open sesame} ./deploy"#,
        r#"PASSWORD="${unset:-open sesame}" ./deploy"#,
        r#"PASSWORD=<(printf 'open sesame') ./deploy"#,
        r#"PASSWORD=>(printf 'open sesame') ./deploy"#,
    ] {
        let expected = "PASSWORD=[secret]";
        assert_eq!(mask_input_assignments(command), expected, "{command}");
        for (raw, masked) in [
            (json!(command), json!(expected)),
            (json!({"command": command}), json!({"command": expected})),
            (json!([command]), json!([expected])),
        ] {
            assert_eq!(input_prefix(&json!({"rawInput": raw})).unwrap(), masked.to_string());
        }
    }
}

#[test]
fn quoted_assignments_redact_literal_and_ansi_c_backslashes() {
    for command in [
        r#"PASSWORD='prefix\'"it's open sesame" ./deploy"#,
        r#"PASSWORD='prefix\'"open sesame" ./deploy"#,
        r#"PASSWORD=\$'prefix\'"it's open sesame" ./deploy"#,
        r#"PASSWORD=$'prefix\' open sesame' ./deploy"#,
        r#"PASSWORD=$'prefix\\'"it's open sesame" ./deploy"#,
    ] {
        for (raw, expected) in [
            (json!(command), r#""PASSWORD=[secret]""#),
            (json!({"command": command}), r#"{"command":"PASSWORD=[secret]"}"#),
            (json!([command]), r#"["PASSWORD=[secret]"]"#),
        ] {
            assert_eq!(input_prefix(&json!({"rawInput": raw})).unwrap(), expected, "{command}");
        }
    }
}

#[test]
fn colon_delimited_quoted_values_redact_ambiguous_data_escapes() {
    let code = r#"config = {'password': 'prefix\' open sesame'}"#;
    let safe = "config = {'password': [secret]";
    for (raw, expected) in [
        (json!(code), json!(safe)),
        (json!({"code": code}), json!({"code": safe})),
        (json!([code]), json!([safe])),
    ] {
        let prefix = input_prefix(&json!({"rawInput": raw})).unwrap();
        assert_eq!(prefix, expected.to_string());
        assert!(!prefix.contains("open sesame"));
    }
}

#[test]
fn restart_inputs_mask_unclosed_and_scan_boundary_quoted_assignments() {
    for command in [
        "PASSWORD=\"open sesame".to_owned(),
        format!("PASSWORD=\"{}\" ./deploy", "open sesame ".repeat(MAX_TOOL_SCAN_BYTES)),
        format!("PASSWORD=\"{}\" ./deploy", "世 界 ".repeat(MAX_TOOL_SCAN_BYTES)),
    ] {
        let prefix = input_prefix(&json!({"rawInput": command})).unwrap();
        for secret_fragment in ["open", "sesame", "世", "界"] {
            assert!(!prefix.contains(secret_fragment), "quoted secret leaked: {prefix}");
        }
    }
}

#[test]
fn restart_inputs_keep_password_field_context_when_masking_structured_input() {
    let password = "open_sesame42";
    let masked = input_prefix(&json!({
        "rawInput": {"password": format!("\"{password}\"")}
    }))
    .unwrap();
    assert!(!masked.contains(password), "structured password leaked: {masked}");
    assert!(masked.contains("[secret]"), "{masked}");
    let masked = input_prefix(&json!({
        "rawInput": {"password": [password]}
    }))
    .unwrap();
    assert!(!masked.contains(password), "nested structured password leaked: {masked}");
    let masked = input_prefix(&json!({
        "rawInput": {"password": "let me in"}
    }))
    .unwrap();
    assert!(!masked.contains("let me in"), "plain structured password leaked: {masked}");
    assert!(masked.contains("[secret]"), "{masked}");
}

#[test]
fn restart_inputs_mask_sensitive_numeric_and_boolean_fields() {
    let masked = input_prefix(&json!({
        "rawInput": {"password": 12345678, "token": true, "secret": null}
    }))
    .unwrap();
    assert!(!masked.contains("12345678"), "numeric password leaked: {masked}");
    assert!(!masked.contains("true"), "boolean token leaked: {masked}");
    assert!(masked.matches("[secret]").count() >= 3, "{masked}");
    let masked = input_prefix(&json!({
        "rawInput": {"apiKey": 12345678, "credentials": "let me in", "authorization": false}
    }))
    .unwrap();
    assert!(!masked.contains("12345678") && !masked.contains("let me in"), "{masked}");
    let long_key = format!("{}password", "x".repeat(MAX_TOOL_FIELD_CHARS));
    let masked = input_prefix(&json!({"rawInput": {long_key: "open_sesame42"}})).unwrap();
    assert!(!masked.contains("open_sesame42"), "long sensitive key leaked: {masked}");
}

#[test]
fn structured_secret_keys_follow_the_assignment_scanner() {
    for key in [
        "apiKey",
        "api_key",
        "api-key",
        "SECRET",
        "accessToken",
        "passwd",
        "password",
        "credentials",
        "private_key",
        "privateKey",
        "access_key",
    ] {
        let assignment = format!("{key}=open_sesame42");
        assert_ne!(crate::secret_scan::mask(&assignment), assignment, "{key}");
        for value in [json!("x"), json!(7), json!(false), json!([{"inside": "x"}])] {
            let input = json!({"rawInput": {key: value}});
            let prefix = input_prefix(&input).unwrap();
            assert!(prefix.contains("[secret]"), "{key}: {prefix}");
        }
    }
    for key in ["authorization", "AUTH", "cookie", "key"] {
        assert!(sensitive_key(key), "{key}");
    }
    // Entire key inspection must not be needed to decide that an oversized key
    // is opaque, including when no sensitive word appears in its prefix.
    assert!(sensitive_key(&"x".repeat(MAX_TOOL_FIELD_CHARS + 1)));
}

#[test]
fn child_tool_updates_are_ignored_and_metadata_is_bounded() {
    let child = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"_meta": {"acpmux": {"subagent": {"id": "child"}}}, "update": {"sessionUpdate": "tool_call", "toolCallId": "child-call", "status": "in_progress"}}}),
        host_seq: None,
    };
    assert!(tool_update(&child, None).is_none());

    let mut page = ToolPage::default();
    let huge = "x".repeat(MAX_TOOL_FIELD_CHARS + 100);
    page.note(&json!({"toolCallId": huge, "title": huge, "status": "in_progress",
        "rawInput": {"body": "x".repeat(10_000)}}));
    let open = page.calls.values().flatten().next().unwrap();
    assert_eq!(open.id.chars().count(), MAX_TOOL_FIELD_CHARS);
    assert_eq!(open.name.chars().count(), MAX_TOOL_FIELD_CHARS);
    assert!(open.input.as_ref().unwrap().len() <= MAX_TOOL_INPUT_CHARS);
    page.note(&json!({"toolCallId": format!("{huge}2"), "status": "in_progress"}));
    assert_eq!(page.calls.values().flatten().count(), 2);
    page.note(&json!({"toolCallId": huge, "status": "completed"}));
    assert_eq!(page.calls.values().flatten().count(), 1);
    page.note(&json!({"toolCallId": format!("{huge}2"), "status": "failed"}));
    assert_eq!(page.calls.values().flatten().count(), 0);
}

#[test]
fn root_tool_updates_with_subagent_metadata_are_retained() {
    let record = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "tool_call".into(),
        msg: json!({"params": {"sessionId": "root", "_meta": {"acpmux": {"subagent": "child-1"}},
            "update": {"sessionUpdate": "tool_call", "toolCallId": "root-call", "title": "Own build", "status": "in_progress"}}}),
        host_seq: None,
    };
    assert!(tool_update(&record, Some("root")).is_some());
    assert!(tool_update(&record, Some("other")).is_none());
    let mut child = record;
    child.msg["params"]["_meta"] = Value::Null;
    assert!(tool_update(&child, Some("other")).is_none());
}

#[test]
fn input_serialization_stops_at_the_prefix_budget() {
    use serde::Serialize;
    struct Unvisited;
    impl Serialize for Unvisited {
        fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
            panic!("serialization must stop before the next value");
        }
    }
    let mut bytes = Vec::with_capacity(MAX_TOOL_INPUT_CHARS);
    let mut writer = BoundedJsonWriter { bytes: &mut bytes, limit: MAX_TOOL_INPUT_CHARS };
    assert!(serde_json::to_writer(&mut writer, &("x".repeat(10_000), Unvisited)).is_err());
    assert_eq!(bytes.len(), MAX_TOOL_INPUT_CHARS);
    let prefix = input_prefix(&json!({"rawInput": "世".repeat(10_000)})).unwrap();
    assert!(prefix.len() <= MAX_TOOL_INPUT_CHARS);
    assert!(!prefix.contains('\u{fffd}'));
}

#[test]
fn multibyte_text_is_cut_on_char_boundaries() {
    // "世" is 3 bytes: a 4-byte budget keeps one, never half of the second.
    assert_eq!(char_prefix("世世", 4), "世");
    assert_eq!(char_prefix("世世", 6), "世世");
    assert_eq!(char_prefix("世", 2), "");
    // 7-byte units: the scan cut (4096 = 7 * 585 + 1) lands inside a 3-byte char, and the
    // word crossing it is dropped back to the last space.
    let long = "世世 ".repeat(MAX_TOOL_SCAN_BYTES);
    assert_eq!(masked_scan(&long), "世世 ".repeat(585).trim_end());
    // The truncated tail is cut at a multibyte space (U+3000), not a byte inside it.
    assert_eq!(safe_tool_text("世\u{3000}世世", true, 100), "世");
    // Multibyte text before a sensitive assignment keeps its prefix whole.
    assert_eq!(mask_input_assignments("世 PASSWORD=世世"), "世 PASSWORD=[secret]");
}

#[tokio::test]
async fn restart_journal_ignores_children_and_honors_replayed_completion() {
    use crate::config::{Config, StoreMode};
    let root = std::env::temp_dir().join(format!("acpmux-restart-tools-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    store.save(&serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
    })).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("chat").unwrap();
    let tool = |id: &str, state: &str| {
        json!({"params": {"update": {
            "sessionUpdate": "tool_call", "toolCallId": id, "title": id, "status": state
        }}})
    };
    // Historical inputs must not enter the interrupted turn's summary.
    for _ in 0..100 {
        hub.append(&session, "in", "tool_call", tool("historical", "in_progress"));
    }
    hub.append(
        &session,
        "mux",
        "turn_started",
        json!({"turnId": "cut", "promptId": "p", "control": "local", "trustGate": false}),
    );
    // More child calls than the display cap, including replayed calls and an ID
    // shared with the parent, cannot consume or remove the parent's entries.
    for n in 0..=MAX_UNFINISHED_TOOLS {
        let mut child = tool(&format!("child-{n}"), "in_progress");
        child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
        hub.append(&session, "in", "tool_call.replay", child);
    }
    hub.append(&session, "in", "tool_call", tool("finished", "in_progress"));
    let mut completion = tool("finished", "completed");
    completion["params"]["update"]["sessionUpdate"] = json!("tool_call_update");
    hub.append(&session, "in", "tool_call_update.replay", completion);
    hub.append(&session, "in", "tool_call.replay", tool("own", "in_progress"));
    let mut child = tool("own", "completed");
    child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
    hub.append(&session, "in", "tool_call_update", child);
    assert!(hub.log_restart_continuation(&session, "cut").is_some());
    let records = hub.events("chat", 0, usize::MAX).unwrap();
    let text = records.iter().find(|e| e.kind == "queued").unwrap().msg["text"].as_str().unwrap();
    assert!(text.contains("own (id: own)"), "{text}");
    for absent in ["child-", "historical", "finished (id:", "omitted"] {
        assert!(!text.contains(absent), "{text}");
    }
    hub.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn replayed_terminal_tool_update_closes_the_call() {
    let update = |kind: &str, status: &str| EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": status}}}),
        host_seq: None,
    };
    let records = vec![
        EventRecord {
            kind: "tool_call".into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "call-1", "status": "in_progress"}}}),
            ..update("tool_call", "in_progress")
        },
        update("tool_call_update.replay", "completed"),
    ];
    let (tools, omitted) = unfinished_tools(&records);
    assert!(tools.is_empty());
    assert_eq!(omitted, ToolOmission::None);
}
