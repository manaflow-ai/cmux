//! D3 (plans/cmux-next/app-daemon-connection-DESIGN.md 3.3): an attach-surface
//! is accepted once its view is registered. A sizing op of the same surface sent
//! right after it is applied at once, while the attach's own reply still waits
//! for the hosted resize, here a host that is stopped and cannot answer.

use super::*;

#[test]
fn a_sizing_op_after_an_attach_runs_while_the_attach_waits_for_its_hosted_resize() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("attach-acceptance");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "printf 'ready\\r\\n'; sleep 600"],
            "new_workspace": true,
            "name": "attach-acceptance",
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, "ready").contains("ready"));
    let records = wait_for_host_records(&harness.host_root(), 1);
    let host_pid = records[0].1.host_pid as libc::pid_t;
    // SAFETY: the durable record names this harness's live terminal host.
    assert_eq!(unsafe { libc::kill(host_pid, libc::SIGSTOP) }, 0);
    wait_until_stopped(host_pid);

    let stream = transport::connect(&harness.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut send = |value: serde_json::Value| {
        writeln!(writer, "{value}").unwrap();
        writer.flush().unwrap();
    };
    send(serde_json::json!({"id": 1, "cmd": "set-client-info", "name": "acceptance",
                            "kind": "frontend", "capabilities": ["attach-streams-v1"]}));
    // A byte attach at a new size: its reply waits for the stopped host's resize.
    send(serde_json::json!({"id": 2, "cmd": "attach-surface", "attach_stream": 1,
                            "surface": surface, "cols": 100, "rows": 30}));
    // A sizing op of the same surface on the control lane, right after it.
    let sent_at = Instant::now();
    send(serde_json::json!({"id": 3, "cmd": "resize-surface", "surface": surface,
                            "cols": 90, "rows": 28}));
    let mut order = Vec::new();
    let mut resize_after = None;
    while order.len() < 3 {
        let mut line = String::new();
        reader.read_line(&mut line).expect("replies in time");
        let value: serde_json::Value = serde_json::from_str(&line).expect("a JSON line");
        let Some(id) = value["id"].as_u64() else { continue };
        if id == 3 {
            resize_after = Some(sent_at.elapsed());
            assert_eq!(value["ok"], true, "{value}");
        }
        order.push(id);
    }
    // SAFETY: resumes the host stopped above.
    assert_eq!(unsafe { libc::kill(host_pid, libc::SIGCONT) }, 0);
    harness.sigkill();
    assert_eq!(
        order,
        [1, 3, 2],
        "the sizing op waited for the attach's hosted resize (replied after {resize_after:?})"
    );
    eprintln!("sizing op after an attach that waits for its hosted resize: {resize_after:?}");
}
