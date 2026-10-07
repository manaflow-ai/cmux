//! cx-6so.49 L1, with hq-ed's DEV owner idle exit: an idle exit stops only
//! the owner daemon. Its terminal hosts keep running, and the next owner
//! re-adopts the same terminal (id, incarnation, host PID, screen, input).

use super::*;

#[test]
fn owner_idle_exit_leaves_hosted_terminals_alive_and_the_next_owner_readopts_them() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("owner-idle-exit");
    // The idle exit applies to a DEV `cmux-app-<tag>` owner whose own
    // executable is gone: run the daemon from a copy and delete the copy.
    harness.session = "cmux-app-idleexit".into();
    let copy = harness.dir.join("cmux-tui-copy");
    fs::copy(bin(), &copy).unwrap();
    let template = harness.daemon_command();
    let mut command = {
        let mut copied = Command::new(&copy);
        copied.args(template.get_args());
        for (key, value) in template.get_envs() {
            match value {
                Some(value) => copied.env(key, value),
                None => copied.env_remove(key),
            };
        }
        copied.stdout(Stdio::null()).stderr(Stdio::null());
        copied
    };
    command
        .env("CMUX_TUI_TEST_DEV_ORPHAN_OWNER", "1")
        .env("CMUX_TUI_TEST_DEV_ORPHAN_DELAY_MS", "500")
        .env("CMUX_TUI_TEST_DEV_ORPHAN_RECHECK_MS", "200");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);

    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"idle"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"before-idle-exit\n"}),
    );
    assert!(
        wait_for_screen(&harness.socket, surface, "before-idle-exit").contains("before-idle-exit")
    );
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    // No client stays connected (each request above is a short connection);
    // with its executable gone the owner exits by itself.
    fs::remove_file(&copy).unwrap();
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    while daemon.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            let _ = daemon.kill();
            let _ = daemon.wait();
            panic!("the DEV orphan owner did not exit by itself");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
        "the owner idle exit ended its terminal host"
    );

    let _ = fs::remove_file(&harness.socket);
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (resolved, surface) = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break (resolved, surface);
        }
        assert!(Instant::now() < deadline, "terminal was not re-adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    assert!(
        wait_for_screen(&harness.socket, surface, "before-idle-exit").contains("before-idle-exit")
    );
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"after-idle-exit\n"}),
    );
    assert!(
        wait_for_screen(&harness.socket, surface, "after-idle-exit").contains("after-idle-exit")
    );
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.host_pid, record.host_pid, "the terminal got a new host");
}
