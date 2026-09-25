use super::*;
use std::os::unix::fs::PermissionsExt;

#[test]
fn cloud_bootstrap_real_first_open_preserves_input_and_reuses_the_terminal() {
    let mut harness = RecoveryHarness::start_unstarted("cloud-first-open");
    let renderer = harness.dir.join("cmux-fixture");
    let rendered = harness.dir.join("rendered");
    let instance = harness.dir.join("instance");
    fs::write(&instance, "fixture-instance\n").unwrap();
    fs::write(
        &renderer,
        format!("#!/bin/sh\nprintf x >> '{}'\nprintf 'CLOUD-GUIDE\\n'\n", rendered.display()),
    )
    .unwrap();
    fs::set_permissions(&renderer, fs::Permissions::from_mode(0o755)).unwrap();
    let mut command = harness.daemon_command();
    command
        .args(["--remote-ws", "127.0.0.1:0", "--remote-ws-trusted-carrier", "--remote-state-dir"])
        .arg(harness.dir.join("remote"))
        .env("CMUX_CLOUD_WELCOME", "1")
        .env("CMUX_CLOUD_WELCOME_SHOWN", "")
        .env("CMUX_CLOUD_WELCOME_CLI", &renderer)
        .env("CMUX_CLOUD_WELCOME_INSTANCE_PATH", &instance)
        .env("SHELL", "/bin/sh");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let snapshot = resource_request(
        &harness.socket,
        "before-open",
        "session.snapshot",
        serde_json::json!({"machine":"current", "session":"current"}),
        None,
    );
    assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
    assert!(snapshot["terminals"].as_array().unwrap().is_empty());
    assert!(!rendered.exists(), "headless startup must be quiet");
    let workspace = snapshot["workspaces"][0]["id"].as_str().unwrap().to_owned();
    let open = serde_json::json!({
        "cmd":"cloud-first-workspace", "machine_id":"vm_fixture",
        "workspace":workspace, "welcome":true,
    });
    let receipts = std::thread::scope(|scope| {
        let handles = (0..8)
            .map(|_| {
                let socket = &harness.socket;
                let open = open.clone();
                scope.spawn(move || request(socket, open))
            })
            .collect::<Vec<_>>();
        handles.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>()
    });
    for receipt in &receipts {
        assert_eq!(receipt["created_path"], receipts[0]["created_path"]);
    }
    assert_eq!(fs::read_to_string(&rendered).unwrap(), "x");
    let terminal = receipts[0]["created_path"]["terminal_id"].as_str().unwrap().to_owned();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal", "terminal_id":terminal}),
    );
    let surface = resolved["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({
            "cmd":"send", "surface":surface, "text":"printf 'USER-%s\\n' 'INPUT'\n",
        }),
    );
    let screen = wait_for_screen(&harness.socket, surface, "USER-INPUT");
    assert_eq!(screen.matches("CLOUD-GUIDE").count(), 1, "{screen}");
    assert!(screen.find("CLOUD-GUIDE").unwrap() < screen.find("USER-INPUT").unwrap());

    let later = resource_request(
        &harness.socket,
        "later-shell",
        "workspace.run",
        serde_json::json!({"machine":"current", "session":"current", "workspace":workspace,
            "argv":["/bin/sh"]}),
        Some("later-shell"),
    );
    assert_ne!(later["value"]["terminal_id"], terminal);
    assert_eq!(fs::read_to_string(&rendered).unwrap(), "x");

    harness.sigkill();
    harness.restart();
    let replay = request(&harness.socket, open.clone());
    assert_eq!(replay["created_path"], receipts[0]["created_path"]);
    assert_eq!(fs::read_to_string(&rendered).unwrap(), "x");
    let manual = Command::new(&renderer).arg("welcome").output().unwrap();
    assert!(manual.status.success());
    assert_eq!(manual.stdout, b"CLOUD-GUIDE\n");
    request(&harness.socket, open);
    assert_eq!(fs::read_to_string(&rendered).unwrap(), "xx");
}
