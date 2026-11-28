use super::*;

fn task(id: &str, command: &str, description: Option<&str>) -> Record {
    Record {
        id: id.into(),
        command: command.into(),
        description: description.map(Into::into),
        pid: 1,
        ..Record::default()
    }
}

#[test]
fn nothing_running_and_a_clean_checkout_interrupt_nothing() {
    let p = Parts { session_id: "s1".into(), ports_complete: true, ..Parts::default() };
    let v = render(&p);
    assert_eq!(v["schema"], SCHEMA);
    assert_eq!(v["nothing"], true);
    assert_eq!(v["lines"], json!([]));
    assert_eq!(v["turn"], Value::Null);
    assert_eq!(v["files"]["changed"], Value::Null);
}

#[test]
fn each_thing_the_move_interrupts_is_named_once_in_the_order_a_person_weighs_them() {
    let p = Parts {
        session_id: "s1".into(),
        turn: Some((5, "fix the build\nsecond line".into())),
        processes: vec![
            ("bun run dev".into(), Some("dev server".into()), "/w".into(), 1),
            ("cargo test".into(), None, "/w".into(), 2),
        ],
        tasks: vec![task("t1", "npm run watch", None)],
        ports: vec![Port { port: 3000, pid: Some(9) }, Port { port: 5173, pid: None }],
        ports_complete: true,
        cwd: "/w".into(),
        files: Files { checkout: true, changed: Some(3), unpushed: Some(1) },
    };
    let v = render(&p);
    assert_eq!(v["nothing"], false);
    let lines: Vec<&str> =
        v["lines"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert_eq!(lines.len(), 6, "{lines:?}");
    assert!(lines[0].starts_with("a running turn (\"fix the build\")"), "{lines:?}");
    assert!(
        lines[1].starts_with("2 background processes the agent started (dev server and 1 more)")
    );
    assert!(lines[2].starts_with("1 background task (npm run watch)"));
    assert!(lines[3].starts_with("2 listening ports it serves (3000, 5173)"));
    assert!(lines[4].starts_with("3 changed files not committed"));
    assert!(lines[5].starts_with("1 commit no remote holds"));
    assert_eq!(v["backgroundTasks"][0]["id"], "t1");
    assert_eq!(v["ports"][0], json!({"port": 3000, "pid": 9}));
    assert_eq!(v["files"]["unpushedCommits"], 1);
}

#[test]
fn a_port_found_in_the_tree_and_in_a_processes_output_is_one_port_with_its_pid() {
    let tree = vec![Port { port: 3000, pid: Some(7) }, Port { port: 3000, pid: Some(8) }];
    let printed = vec![Port { port: 3000, pid: None }, Port { port: 8080, pid: None }];
    assert_eq!(
        merge_ports(tree, printed),
        vec![Port { port: 3000, pid: Some(7) }, Port { port: 8080, pid: None }]
    );
}

/// A listener this test process holds is found from its own pid, as a chat's tree is.
#[cfg(target_os = "linux")]
#[test]
fn a_listening_socket_in_the_tree_is_found_by_its_port() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let found = tree_ports(&[std::process::id()]).expect("Linux reads the tree's sockets");
    assert!(found.iter().any(|p| p.port == port && p.pid == Some(std::process::id())), "{found:?}");
}

#[test]
fn a_checkouts_changes_and_commits_no_remote_holds_are_counted() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(files_of(dir.path()), Files::default(), "a plain folder is no checkout");
    let git = |args: &[&str]| super::super::wip_ref::git(dir.path(), None, args);
    git(&["init", "-q"]).unwrap();
    std::fs::write(dir.path().join("a"), "1").unwrap();
    git(&["add", "a"]).unwrap();
    git(&["commit", "-qm", "one"]).unwrap();
    let f = files_of(dir.path());
    assert_eq!(f, Files { checkout: true, changed: Some(0), unpushed: None }, "no remote");
    git(&["remote", "add", "origin", "https://example.invalid/r.git"]).unwrap();
    std::fs::write(dir.path().join("b"), "2").unwrap();
    let f = files_of(dir.path());
    assert_eq!(f.changed, Some(1));
    assert_eq!(f.unpushed, Some(1), "the one commit is on no remote-tracking ref");
}
