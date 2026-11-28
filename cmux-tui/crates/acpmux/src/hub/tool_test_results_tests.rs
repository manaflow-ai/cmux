use super::*;

fn tally(output: &str) -> Tally {
    let mut t = Tally::default();
    t.feed(output);
    t.finish();
    t
}

/// The same output fed in pieces cut at every `step` bytes (on char boundaries).
fn tally_in_pieces(output: &str, step: usize) -> Tally {
    let mut t = Tally::default();
    let mut at = 0;
    while at < output.len() {
        let mut end = (at + step).min(output.len());
        while !output.is_char_boundary(end) {
            end += 1;
        }
        t.feed(&output[at..end]);
        at = end;
    }
    t.finish();
    t
}

const CARGO: &str = "\
running 3 tests
test tests::adds ... ok
test tests::skips ... ignored
test tests::breaks ... FAILED

failures:

---- tests::breaks stdout ----

thread 'tests::breaks' panicked at src/lib.rs:12:9:
assertion `left == right` failed
  left: 1
 right: 2

failures:
    tests::breaks

test result: FAILED. 1 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
";

#[test]
fn cargo_counts_and_failure_location() {
    let t = tally(CARGO);
    assert_eq!(t.counts(), (1, 1, 1));
    assert_eq!(
        t.failures,
        vec![Failure {
            name: "tests::breaks".into(),
            path: Some("src/lib.rs".into()),
            line: Some(12),
            message: Some("assertion `left == right` failed".into()),
        }]
    );
}

#[test]
fn any_split_reads_the_same() {
    for step in [1, 2, 3, 7, 64, 1000] {
        let t = tally_in_pieces(CARGO, step);
        assert_eq!(t.counts(), (1, 1, 1), "step {step}");
        assert_eq!(t.failures.len(), 1, "step {step}");
        assert_eq!(t.failures[0].line, Some(12), "step {step}");
    }
}

#[test]
fn cargo_counts_tick_before_the_summary() {
    let t = tally("running 3 tests\ntest a ... ok\ntest b ... ok\ntest c ... FAILED\n");
    assert_eq!(t.counts(), (2, 1, 0));
}

#[test]
fn cargo_sums_binaries_and_reads_old_panics_and_thread_ids() {
    let t = tally(
        "test a ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n\
         test b ... FAILED\nthread 'b' panicked at 'boom', src/b.rs:3:1\n\
         test c ... FAILED\nthread 'c' (4242) panicked at src/c.rs:8:2:\nbad c\n\
         test result: FAILED. 4 passed; 2 failed; 0 ignored;\n",
    );
    assert_eq!(t.counts(), (5, 2, 0));
    assert_eq!(t.failures[0].message.as_deref(), Some("boom"));
    assert_eq!(t.failures[0].path.as_deref(), Some("src/b.rs"));
    assert_eq!((t.failures[1].path.as_deref(), t.failures[1].line), (Some("src/c.rs"), Some(8)));
    assert_eq!(t.failures[1].message.as_deref(), Some("bad c"));
}

#[test]
fn nextest_lines_and_summary() {
    let t = tally(
        "        PASS [   0.004s] acpmux hub::a\n        FAIL [   0.010s] acpmux hub::b\n\
         ------------\n     Summary [   0.2s] 3 tests run: 2 passed, 1 failed, 4 skipped\n",
    );
    assert_eq!(t.counts(), (2, 1, 4));
    assert_eq!(t.failures[0].name, "acpmux hub::b");
}

#[test]
fn go_test_failures_take_their_log_line() {
    let t = tally(
        "=== RUN   TestA\n--- PASS: TestA (0.00s)\n=== RUN   TestB\n--- FAIL: TestB (0.00s)\n\
         \x20   b_test.go:14: want 2, got 1\n--- SKIP: TestC (0.00s)\nFAIL\nFAIL\texample.com/m\t0.1s\n",
    );
    assert_eq!(t.counts(), (1, 1, 1));
    assert_eq!(
        t.failures[0],
        Failure {
            name: "TestB".into(),
            path: Some("b_test.go".into()),
            line: Some(14),
            message: Some("want 2, got 1".into()),
        }
    );
}

#[test]
fn pytest_progress_traceback_and_summary() {
    let t = tally(
        "tests/test_a.py ..F.s                                        [100%]\n\
         =================================== FAILURES ===================================\n\
         _________________________________ test_three _________________________________\n\
         \n    def test_three():\n>       assert 1 == 2\nE       assert 1 == 2\n\n\
         tests/test_a.py:9: AssertionError\n\
         =========================== short test summary info ============================\n\
         FAILED tests/test_a.py::test_three - assert 1 == 2\n\
         ===================== 1 failed, 3 passed, 1 skipped in 0.12s =====================\n",
    );
    assert_eq!(t.counts(), (3, 1, 1));
    assert_eq!(t.failures.len(), 1);
    assert_eq!(t.failures[0].name, "test_three");
    assert_eq!(
        (t.failures[0].path.as_deref(), t.failures[0].line),
        (Some("tests/test_a.py"), Some(9))
    );
    assert_eq!(t.failures[0].message.as_deref(), Some("AssertionError"));
}

#[test]
fn pytest_verbose_ticks() {
    let t = tally(
        "tests/test_a.py::test_one PASSED    [ 50%]\ntests/test_a.py::test_two FAILED    [100%]\n",
    );
    assert_eq!(t.counts(), (1, 1, 0));
    assert_eq!(t.failures[0].path.as_deref(), Some("tests/test_a.py"));
}

#[test]
fn jest_names_failures_by_suite_and_opens_the_test_line() {
    let t = tally(
        " FAIL  src/math.test.ts\n  math\n    ✓ adds (2 ms)\n    ✕ subtracts (3 ms)\n    ○ skipped later\n\n\
         \x20 ● math › subtracts\n\n    expect(received).toBe(expected) // Object.is equality\n\n\
         \x20     at Object.<anonymous> (src/math.test.ts:10:19)\n\
         Tests:       1 failed, 1 skipped, 1 passed, 3 total\n",
    );
    assert_eq!(t.counts(), (1, 1, 1));
    assert_eq!(
        t.failures,
        vec![Failure {
            name: "math › subtracts".into(),
            path: Some("src/math.test.ts".into()),
            line: Some(10),
            message: Some("expect(received).toBe(expected) // Object.is equality".into()),
        }]
    );
}

#[test]
fn vitest_files_failure_and_summary() {
    let t = tally(
        " ✓ src/a.test.ts (3 tests) 5ms\n ❯ src/b.test.ts (2 tests | 1 failed) 7ms\n\
         \n FAIL  src/b.test.ts > b > breaks\nAssertionError: expected 1 to be 2\n ❯ src/b.test.ts:8:15\n\
         \n Test Files  1 failed | 1 passed (2)\n      Tests  1 failed | 4 passed (5)\n",
    );
    assert_eq!(t.counts(), (4, 1, 0));
    assert_eq!(
        t.failures[0],
        Failure {
            name: "b > breaks".into(),
            path: Some("src/b.test.ts".into()),
            line: Some(8),
            message: Some("AssertionError: expected 1 to be 2".into()),
        }
    );
}

#[test]
fn bun_stack_before_its_failure() {
    let t = tally(
        "a.test.ts:\n(pass) adds [0.10ms]\nerror: expect(received).toBe(expected)\n\
         \x20     at <anonymous> (/w/a.test.ts:7:12)\n(fail) breaks [0.30ms]\n(skip) later\n\
         \n 1 pass\n 1 skip\n 1 fail\nRan 3 tests across 1 files.\n",
    );
    assert_eq!(t.counts(), (1, 1, 1));
    assert_eq!(
        (t.failures[0].path.as_deref(), t.failures[0].line),
        (Some("/w/a.test.ts"), Some(7))
    );
}

#[test]
fn xctest_and_swift_testing() {
    let t = tally(
        "Test Case '-[M.T testA]' started.\nTest Case '-[M.T testA]' passed (0.001 seconds).\n\
         /w/Tests/T.swift:21: error: -[M.T testB] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")\n\
         Test Case '-[M.T testB]' failed (0.002 seconds).\n\
         ✔ Test ok() passed after 0.001 seconds.\n\
         ✘ Test bad() recorded an issue at S.swift:5:3: Expectation failed: 1 == 2\n\
         ✘ Test bad() failed after 0.001 seconds with 1 issue.\n\
         ✘ Test run with 2 tests failed after 0.002 seconds with 1 issue.\n",
    );
    assert_eq!(t.counts(), (2, 2, 0));
    assert_eq!(t.failures[0].name, "-[M.T testB]");
    assert_eq!(
        (t.failures[0].path.as_deref(), t.failures[0].line),
        (Some("/w/Tests/T.swift"), Some(21))
    );
    assert_eq!(t.failures[1].name, "bad()");
    assert_eq!(t.failures[1].line, Some(5));
}

#[test]
fn failures_and_lines_stay_bounded() {
    let mut out = String::new();
    for i in 0..500 {
        out.push_str(&format!("test t{i} ... FAILED\n"));
    }
    out.push_str(&"x".repeat(1 << 20));
    out.push_str("\ntest last ... ok\n");
    let t = tally(&out);
    assert_eq!(t.failures.len(), MAX_FAILURES);
    assert_eq!(t.more_failures, 500 - MAX_FAILURES as u64);
    assert_eq!(t.counts(), (1, 500, 0));
    let json = t.to_json("cargo", true).unwrap();
    assert_eq!(json["moreFailures"], 450);
}

#[test]
fn long_messages_are_cut() {
    let t = tally(&format!("--- FAIL: TestX (0s)\n    x_test.go:1: {}\n", "m".repeat(1000)));
    let message = t.failures[0].message.as_deref().unwrap();
    assert_eq!(message.chars().count(), MAX_MESSAGE_CHARS + 1);
}

// The record path: snapshots, deltas, the cached command and the end.

fn update(session: &str, fields: Value) -> Value {
    let mut msg =
        json!({"method": "session/update", "params": {"sessionId": session, "update": fields}});
    let kind = if msg["params"]["update"]["sessionUpdate"] == "tool_call" {
        "tool_call"
    } else {
        "tool_call_update"
    };
    add_test_results(session, kind, &mut msg);
    msg["params"]["update"]["_meta"]["acpmux"]["testResults"].take()
}

#[test]
fn snapshots_tick_and_the_end_drops_the_call() {
    let s = "tr-snapshots";
    let start = update(
        s,
        json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "status": "in_progress",
               "rawInput": {"command": "cargo test -p acpmux"}}),
    );
    assert_eq!(start["runner"], "cargo");
    assert_eq!(start["done"], false);
    let mut so_far = String::new();
    let mut last = Value::Null;
    for line in CARGO.split_inclusive('\n') {
        so_far.push_str(line);
        // No command: later updates leave it out.
        last = update(
            s,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "in_progress",
                   "rawOutput": {"output": so_far}}),
        );
        if line.starts_with("test tests::adds") {
            assert_eq!(last["passed"], 1);
        }
    }
    assert_eq!((last["passed"].clone(), last["failed"].clone()), (json!(1), json!(1)));
    let end = update(
        s,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "failed",
               "rawOutput": {"output": so_far}}),
    );
    assert_eq!(end["done"], true);
    assert_eq!(end["failed"], 1);
    assert_eq!(end["failures"][0]["path"], "src/lib.rs");
    assert_eq!(end["failures"][0]["line"], 12);
    assert!(!calls().contains_key(&(s.to_owned(), "c1".to_owned())));
}

#[test]
fn pi_deltas_add_up() {
    let s = "tr-pi";
    update(
        s,
        json!({"sessionUpdate": "tool_call", "toolCallId": "p1", "status": "in_progress",
               "rawInput": {"command": "go test ./..."}}),
    );
    let mut last = Value::Null;
    for part in ["--- PASS: TestA (0s)\n--- PA", "SS: TestB (0s)\n", "--- FAIL: TestC (0s)\n"] {
        last = update(
            s,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "p1", "status": "in_progress",
                   "_meta": {"terminal_output": {"data": part}}}),
        );
    }
    assert_eq!((last["passed"].clone(), last["failed"].clone()), (json!(2), json!(1)));
    assert_eq!(last["runner"], "go");
}

#[test]
fn a_snapshot_cut_from_the_front_is_found_by_its_tail() {
    let mut call =
        Call { born: 0, runner: "cargo", tally: Tally::default(), read: 0, tail: String::new() };
    let first: String = (0..40).map(|i| format!("test a{i} ... ok\n")).collect();
    call.read_snapshot(&first);
    let more: String = (40..60).map(|i| format!("test a{i} ... ok\n")).collect();
    // The agent kept only the output's end.
    let cut = format!("{}{more}", &first[first.len() / 2..]);
    call.read_snapshot(&cut);
    assert_eq!(call.tally.counts(), (60, 0, 0));
}

#[test]
fn a_replaced_snapshot_is_read_again() {
    let mut call =
        Call { born: 0, runner: "cargo", tally: Tally::default(), read: 0, tail: String::new() };
    call.read_snapshot("test a ... ok\ntest b ... ok\n");
    call.read_snapshot("test c ... FAILED\n");
    assert_eq!(call.tally.counts(), (0, 1, 0));
}

#[test]
fn other_commands_and_records_are_left_alone() {
    let s = "tr-other";
    let none = update(
        s,
        json!({"sessionUpdate": "tool_call", "toolCallId": "o1", "status": "completed",
               "rawInput": {"command": "ls"}, "rawOutput": {"output": "test a ... ok\n"}}),
    );
    assert!(none.is_null());
    // A finished test run that printed no result gets nothing.
    let quiet = update(
        s,
        json!({"sessionUpdate": "tool_call", "toolCallId": "o2", "status": "completed",
               "rawInput": {"command": "cargo test"}, "rawOutput": {"output": "error: no such package"}}),
    );
    assert!(quiet.is_null());
    // A record that already has results (replayed) keeps them.
    let mut msg = json!({"params": {"update": {"sessionUpdate": "tool_call_update", "toolCallId": "o3",
        "rawInput": {"command": "cargo test"}, "rawOutput": {"output": "test a ... ok\n"},
        "_meta": {"acpmux": {"testResults": {"passed": 9}}}}}});
    add_test_results(s, "tool_call_update.replay", &mut msg);
    assert_eq!(msg["params"]["update"]["_meta"]["acpmux"]["testResults"]["passed"], 9);
}

#[test]
fn claude_one_shot_result_reads_whole() {
    let end = update(
        "tr-claude",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "k1", "status": "completed",
               "rawInput": {"command": "bun test"},
               "content": [{"type": "content", "content": {"type": "text",
                 "text": "(pass) a\n(fail) b\n 1 pass\n 1 fail"}}]}),
    );
    assert_eq!(
        (end["passed"].clone(), end["failed"].clone(), end["done"].clone()),
        (json!(1), json!(1), json!(true))
    );
}
