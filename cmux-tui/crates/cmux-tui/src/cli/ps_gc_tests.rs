use super::*;

#[test]
fn human_ps_names_state_stream_and_place() {
    let census = json!({
        "source": "daemon",
        "state_root": "/s",
        "daemon": {"pid": 10, "pgid": 10, "session": "main", "record_root": "/s/r"},
        "hosts": [{
            "host_pid": 42, "pgid": 42, "state": "in-use", "stream_held": true,
            "terminal_id": "t1", "reason": "this daemon shows it",
            "placements": [{"surface": 1, "pane": "pane:1", "workspace_name": "main"}],
            "gc": {"candidate": false, "refusal": "a live daemon holds its stream"}
        }],
        "helpers": [],
        "state": {"roots": [], "stale_records": [], "exit_records": [], "unnamed_sockets": []}
    });
    let out = human_ps(&census);
    assert!(out.contains("in-use"), "{out}");
    assert!(out.contains("held"), "{out}");
    assert!(out.contains("main/pane:1"), "{out}");
    assert!(!out.contains("gc candidate"), "{out}");
}

#[test]
fn human_gc_says_dry_run_until_applied() {
    let report = json!({"applied": false, "state_root": "/s", "candidates": [], "refused": []});
    assert!(human_gc(&report).contains("dry run"));
}

#[test]
fn human_gc_receipt_names_outcomes_refusals_logs_and_errors() {
    let report = json!({
        "applied": true, "state_root": "/s", "ended": 1, "failed": 0,
        "candidates": [{
            "host_pid": 42, "terminal_id": "t1", "reason": "no live daemon owns its session",
            "outcome": "ended"
        }],
        "refused": [{
            "host_pid": 43, "state": "orphaned", "terminal_id": "t2",
            "refusal": "referenced by an unrestored workspace"
        }],
        "logs": ["/s/terminal-host-gc.jsonl"],
        "errors": ["gc log for t3 (/s/r/t3.json): permission denied"],
        "stale_records": 0
    });
    let out = human_gc(&report);
    assert!(!out.contains("dry run"), "{out}");
    assert!(out.contains("t1") && out.contains("-> ended"), "{out}");
    assert!(out.contains("referenced by an unrestored workspace"), "{out}");
    assert!(out.contains("ended 1, failed 0"), "{out}");
    assert!(out.contains("logged to /s/terminal-host-gc.jsonl"), "{out}");
    assert!(out.contains("1 error(s)") && out.contains("permission denied"), "{out}");
}

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_string).collect()
}

fn run_request(line: &str) -> (Verb, OutputMode, Option<PathBuf>) {
    match parse(&words(line)) {
        Some(Request::Run { global, verb, state_dir }) => (verb, global.output, state_dir),
        other => panic!("{line}: {other:?}"),
    }
}

#[test]
fn gc_is_a_dry_run_unless_apply_is_given() {
    assert_eq!(run_request("gc").0, Verb::Gc { apply: false });
    assert_eq!(run_request("gc --apply").0, Verb::Gc { apply: true });
    let (verb, output, state_dir) = run_request("gc --json --apply --state-dir /x");
    assert_eq!(verb, Verb::Gc { apply: true });
    assert_eq!(output, OutputMode::Json);
    assert_eq!(state_dir, Some(PathBuf::from("/x")));
}

#[test]
fn ps_takes_json_and_a_state_dir_but_never_apply() {
    let (verb, output, state_dir) = run_request("ps --json --state-dir /y");
    assert_eq!(verb, Verb::Ps);
    assert_eq!(output, OutputMode::Json);
    assert_eq!(state_dir, Some(PathBuf::from("/y")));
    assert!(matches!(parse(&words("ps --apply")), Some(Request::Usage(PS_USAGE))));
    assert!(matches!(parse(&words("gc --state-dir")), Some(Request::Usage(GC_USAGE))));
    assert!(matches!(parse(&words("gc --help")), Some(Request::Help(GC_USAGE))));
    assert!(parse(&words("list-workspaces")).is_none());
}

#[test]
fn state_root_prefers_the_flag() {
    assert_eq!(state_root(Some(PathBuf::from("/x"))), Some(PathBuf::from("/x")));
}
