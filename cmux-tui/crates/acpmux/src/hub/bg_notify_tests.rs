use super::*;

/// The body names the task and carries only its last lines; a cut first line goes.
#[test]
fn a_notice_body_carries_the_last_lines() {
    let dir = cmux_unix_socket::short_test_dir("bg-notice");
    let mut spool = bg_run::Spool::create(dir.path(), "t", 1 << 20).unwrap();
    let out: String = (0..30).map(|i| format!("line-{i}\n")).collect();
    spool.write(out.as_bytes()).unwrap();
    let record = Record { id: "t".into(), command: "make  test\n".into(), ..Record::default() };
    let (body, wrote) = notice_body(dir.path(), &record);
    assert!(wrote);
    assert!(body.starts_with("Task t: make test\nLast 20 lines"), "{body}");
    assert!(body.contains("line-10\n") && body.contains("line-29\n"), "{body}");
    assert!(!body.contains("line-9\n"), "{body}");
    let quiet = Record { id: "none".into(), command: "true".into(), ..Record::default() };
    let (body, wrote) = notice_body(dir.path(), &quiet);
    assert!(!wrote);
    assert!(body.ends_with("It wrote no output."));
}

/// A task end whose subagent ended draws nothing when it went well with no output, one quiet
/// line otherwise; the chat's own task end keeps its row.
#[test]
fn an_orphan_task_end_is_quiet() {
    let ok = json!({"severity": "info"});
    let failed = json!({"severity": "warn"});
    assert_eq!(orphan_display(true, false, &ok), Some("none"));
    assert_eq!(orphan_display(true, true, &ok), Some("line"));
    assert_eq!(orphan_display(true, false, &failed), Some("line"));
    assert_eq!(orphan_display(false, false, &ok), None);
}
