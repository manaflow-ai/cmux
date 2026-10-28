//! Launch to a live terminal: a replacement owner (after an update's quiet
//! handoff, a crash or a stuck owner's replacement) answers its clients
//! before it has adopted every surviving terminal host. Each host adopts on
//! its own; its terminal is listed as adopting until then, and runs once its
//! host answers. Adopting every host inline before the first answer held the
//! app's whole connection for every host's handshake and replay (5 s with 24
//! workspaces on a capture Mac, plans/cmux-next/service-start-PERF.md 5b).

use super::*;

#[test]
fn a_replacement_owner_answers_before_its_stalled_hosts_are_adopted() {
    let mut harness = RecoveryHarness::start("answers-before-adoption");
    let mut terminals = Vec::new();
    for index in 0..3u64 {
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id": 1 + index,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("stalled-{index}"),
            }),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    let hosts: Vec<libc::pid_t> = wait_for_host_records(&harness.host_root(), 3)
        .iter()
        .map(|(_, record)| record.host_pid as libc::pid_t)
        .collect();
    // A stopped host accepts the connection but never answers its handshake:
    // each one costs an inline adoption its full handshake bound.
    for &host in &hosts {
        // SAFETY: the durable record names a live terminal host of this harness.
        assert_eq!(unsafe { libc::kill(host, libc::SIGSTOP) }, 0);
        wait_until_stopped(host);
    }
    harness.sigkill();

    let started = Instant::now();
    harness.restart();
    let listed = request(&harness.socket, serde_json::json!({"id": 10, "cmd": "list-terminals"}));
    let answered = started.elapsed();
    for &host in &hosts {
        // SAFETY: resumes the hosts stopped above, before any assertion can fail.
        assert_eq!(unsafe { libc::kill(host, libc::SIGCONT) }, 0);
    }

    // Adopting inline costs every stalled host its 2 s handshake bound (6 s
    // here); the bound leaves room for a loaded runner's daemon start.
    assert!(
        answered < Duration::from_millis(3_000),
        "the replacement owner answered after {answered:?}: it adopted its stalled hosts first"
    );
    for terminal_id in &terminals {
        let terminal = listed["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["terminal_id"] == terminal_id.as_str())
            .unwrap_or_else(|| panic!("{terminal_id} is not listed while it adopts: {listed}"));
        assert!(
            terminal["lifecycle"] == "adopting" || terminal["lifecycle"] == "running",
            "{terminal_id} must be adopting or running, not ended: {terminal}"
        );
    }
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let mut pending: std::collections::HashSet<&String> = terminals.iter().collect();
    while !pending.is_empty() {
        pending.retain(|terminal_id| {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id": 11, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
            );
            resolved["lifecycle"] != "running" || resolved["surface"].as_u64().is_none()
        });
        assert!(Instant::now() < deadline, "{} resumed hosts were never adopted", pending.len());
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// An attach to a terminal that still adopts goes first and waits for it.
#[path = "attach_first.rs"]
mod attach_first;
