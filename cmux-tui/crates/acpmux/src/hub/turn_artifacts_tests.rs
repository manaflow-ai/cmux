use super::*;

fn update(u: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"update": u}})
}

/// Gathers `records` for a fresh chat and returns its stamped `turn_result`.
fn turn(session: &str, records: &[Value]) -> Value {
    begin(session, true);
    for r in records {
        gather(session, r);
    }
    let g = all().remove(session).unwrap_or_default();
    let mut msg = json!({"status": "completed"});
    stamp_card(g, &mut msg);
    msg
}

#[test]
fn the_card_is_off_unless_its_setting_is_true() {
    assert!(!enabled_with(None, None));
    let on = json!({"agents": {"harnessMagic": {"artifactCard": {"enabled": true}}}});
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    let off = json!({"agents": {"harnessMagic": {"artifactCard": {"enabled": false}}}});
    assert!(!enabled_with(Some(&off), None));
}

#[test]
fn a_turn_started_with_the_card_off_gathers_nothing() {
    begin("artifact-off", false);
    gather(
        "artifact-off",
        &update(json!({"toolCallId": "e", "status": "completed", "content": [
        {"type": "diff", "path": "/w/a", "oldText": "", "newText": "x\n"}]})),
    );
    let mut msg = json!({});
    stamp("artifact-off", &mut msg);
    assert!(msg.get("artifacts").is_none());
    // A turn this daemon never saw start gathers nothing either.
    gather("artifact-unseen", &update(json!({"toolCallId": "e", "status": "completed"})));
    assert!(!all().contains_key("artifact-unseen"));
}

#[test]
fn a_turn_with_nothing_to_show_gets_no_card() {
    let msg = turn(
        "artifact-none",
        &[update(json!({"toolCallId": "a", "status": "completed",
            "rawInput": {"command": "ls"}, "content": []}))],
    );
    assert!(msg.get("artifacts").is_none());
    assert!(msg.get("harnessMagic").is_none());
}

#[test]
fn edits_tests_and_a_pr_make_one_card() {
    let edit = |id: &str, old: &str, new: &str| {
        update(json!({"toolCallId": id, "status": "completed", "content": [
            {"type": "diff", "path": "/w/src/a.rs", "oldText": old, "newText": new}]}))
    };
    let msg = turn(
        "artifact-full",
        &[
            // The same call's record twice counts once.
            edit("e1", "a\nb\nc\n", "a\nB\nc\nd\n"),
            edit("e1", "a\nb\nc\n", "a\nB\nc\nd\n"),
            update(json!({"toolCallId": "w1", "status": "completed", "content": [
                {"type": "diff", "path": "/w/new.md", "oldText": null, "newText": "x\ny\n"}]})),
            update(json!({"toolCallId": "t1", "status": "pending",
                "rawInput": {"command": "cd cmux-tui && cargo test -p acpmux --lib -- ci_log"}})),
            update(json!({"toolCallId": "t1", "status": "completed", "content": [
                {"type": "content", "content": {"type": "text", "text":
                "test result: ok. 30 passed; 0 failed; 0 ignored\n\
                 test result: ok. 4 passed; 0 failed; 0 ignored"}}]})),
            update(json!({"toolCallId": "p1", "status": "pending",
                "rawInput": {"command": "gh pr create --title T --body-file F"}})),
            update(json!({"toolCallId": "p1", "status": "completed", "content": [
                {"type": "content", "content": {"type": "text", "text":
                "https://github.com/manaflow-ai/cmux/pull/60317\n"}}]})),
            // A PR merely read is not one the turn opened.
            update(json!({"toolCallId": "v1", "status": "completed",
                "rawInput": {"command": "gh pr view 1"}, "content": [
                {"type": "content", "content": {"type": "text", "text":
                "https://github.com/manaflow-ai/cmux/pull/1"}}]})),
        ],
    );
    let card = &msg["artifacts"];
    assert_eq!(card["diff"], json!({"files": 2, "added": 4, "removed": 1}));
    assert_eq!(card["files"][0], json!({"path": "/w/new.md", "added": 2, "removed": 0}));
    assert_eq!(card["files"][1], json!({"path": "/w/src/a.rs", "added": 2, "removed": 1}));
    assert_eq!(card["tests"][0]["passed"], 34);
    assert_eq!(card["tests"][0]["failed"], 0);
    assert_eq!(card["tests"][0]["ok"], true);
    assert_eq!(card["prs"], json!(["https://github.com/manaflow-ai/cmux/pull/60317"]));
    assert_eq!(
        msg["harnessMagic"]["artifactCard"],
        json!({"cards": 1, "files": 2, "tests": 1, "prs": 1})
    );
}

#[test]
fn a_failed_test_run_is_not_ok() {
    let msg = turn(
        "artifact-red",
        &[
            update(json!({"toolCallId": "t", "status": "pending",
                "rawInput": {"command": "pytest -q tests"}})),
            update(json!({"toolCallId": "t", "status": "failed", "content": [
                {"type": "content", "content": {"type": "text", "text":
                "Exit code 1\n==== 2 failed, 40 passed in 3.1s ===="}}]})),
        ],
    );
    let t = &msg["artifacts"]["tests"][0];
    assert_eq!(t["ok"], false);
    assert_eq!(t["exitCode"], 1);
    assert_eq!(t["passed"], 40);
    assert_eq!(t["failed"], 2);
}

#[test]
fn test_commands_and_counts_are_read() {
    assert!(is_test_command("cmux-ci test --timeout 2400 -- bash -c x"));
    assert!(is_test_command("cargo nextest run -p x"));
    assert!(is_test_command("bun run test"));
    assert!(!is_test_command("cargo build"));
    assert!(!is_test_command("cat tests/a.rs"));
    assert_eq!(
        counts("Summary [ 1.2s] 12 tests run: 11 passed, 1 failed, 0 skipped"),
        (Some(11), Some(1))
    );
    assert_eq!(counts("Tests:       1 failed, 5 passed, 6 total"), (Some(5), Some(1)));
    assert_eq!(counts("no numbers"), (None, None));
}

/// The gather's cost a record, so a long turn costs nothing a person feels (printed for the PR).
#[test]
fn gathering_a_long_turn_stays_cheap() {
    let session = "artifact-bench";
    begin(session, true);
    let old: String = (0..200).map(|i| format!("line {i}\n")).collect();
    let new: String =
        (0..200).map(|i| format!("line {}\n", if i % 10 == 0 { i * 7 } else { i })).collect();
    let records: Vec<Value> = (0..2000)
        .map(|i| match i % 4 {
            0 => update(json!({"toolCallId": format!("c{i}"), "status": "completed", "content": [
                {"type": "diff", "path": format!("/w/f{}.rs", i % 40), "oldText": old, "newText": new}]})),
            1 => update(json!({"toolCallId": format!("c{i}"), "status": "pending",
                "rawInput": {"command": "cargo test -p x"}})),
            2 => update(json!({"toolCallId": format!("c{}", i - 1), "status": "completed", "content": [
                {"type": "content", "content": {"type": "text", "text": "test result: ok. 9 passed; 0 failed"}}]})),
            _ => update(json!({"toolCallId": format!("c{i}"), "status": "completed",
                "rawInput": {"command": "ls"}, "content": []})),
        })
        .collect();
    let start = std::time::Instant::now();
    for r in &records {
        gather(session, r);
    }
    let g = all().remove(session).unwrap_or_default();
    let mut msg = json!({});
    stamp_card(g, &mut msg);
    let per_record = start.elapsed() / records.len() as u32;
    let bytes = msg["artifacts"].to_string().len();
    println!(
        "artifactCard: {} records, {per_record:?} a record, card {bytes} bytes",
        records.len()
    );
    // Every fourth record is an edit, of `f{i % 40}`: ten distinct files.
    assert_eq!(msg["artifacts"]["diff"]["files"], 10);
    assert_eq!(msg["artifacts"]["testRuns"], 500);
    assert_eq!(msg["artifacts"]["tests"].as_array().map(Vec::len), Some(MAX_ITEMS));
    assert!(per_record < std::time::Duration::from_millis(5), "{per_record:?} a record");
}

/// The patterns are built without a panic, so a typo would read nothing: each must compile.
#[test]
fn every_pattern_compiles() {
    for re in [
        &*TEST_COMMAND,
        &*PR_COMMAND,
        &*PR_URL,
        &*CARGO_RESULT,
        &*NEXTEST_RESULT,
        &*PASSED,
        &*FAILED,
        &*EXIT_LINE,
    ] {
        assert!(re.is_some());
    }
}
