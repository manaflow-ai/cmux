#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

fn command() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("LC_ALL", "C")
        .env_remove("CMUX_SOCKET_CAPABILITY")
        .env_remove("CMUX_SOCKET_PASSWORD")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_SOCKET")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET");
    command
}

fn exchange(args: &[&str], result: Value) -> (Output, Value) {
    // A short socket path also fits Darwin's sockaddr_un limit.
    let root = tempfile::Builder::new().prefix("cmux-vm-").tempdir_in("/tmp").unwrap();
    let socket = root.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "VM command did not contact the app");
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept failed: {error}"),
            }
        };
        // Darwin inherits O_NONBLOCK from the listener on accept. This test
        // server uses blocking reads with a deadline on both platforms.
        stream.set_nonblocking(false).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        writeln!(reader.get_mut(), "{}", json!({"id":request["id"],"ok":true,"result":result}))
            .unwrap();
        request
    });
    let output = command().arg("--socket").arg(&socket).args(args).output().unwrap();
    let request = server.join().unwrap();
    (output, request)
}

fn success(output: &Output) {
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn cloud_vm_cli_lists_owned_vms_through_the_app() {
    let payload = json!({"vms":[{"id":"vm-test","name":"Test","status":"running"}]});
    let (output, request) = exchange(&["vm", "ls", "--json"], payload.clone());
    success(&output);
    assert_eq!(request["method"], "vm.list");
    assert_eq!(request["params"], json!({}));
    assert_eq!(serde_json::from_slice::<Value>(&output.stdout).unwrap(), payload);
}

#[test]
fn cloud_vm_cli_reads_an_existing_terminal_without_opening_a_pane() {
    let (output, request) = exchange(
        &["vm", "terminal", "read", "vm-test", "term-test"],
        json!({"text":"cmux-userspace-ok\n"}),
    );
    success(&output);
    assert_eq!(request["method"], "vm.terminal_read");
    assert_eq!(request["params"], json!({"id":"vm-test","terminal_id":"term-test"}));
    assert_eq!(output.stdout, b"cmux-userspace-ok\n");
}

#[test]
fn cloud_vm_cli_sends_literal_text_and_keys_without_shell_interpolation() {
    let literal = "printf '%s\\n' '$HOME `id` --help --json'";
    let (output, request) = exchange(
        &["vm", "terminal", "send", "vm-test", "term-test", "--keys", "enter", "--", literal],
        json!({"wrote":literal.len()}),
    );
    success(&output);
    assert_eq!(request["method"], "vm.terminal_write");
    assert_eq!(
        request["params"],
        json!({"id":"vm-test","terminal_id":"term-test","text":literal,"keys":["enter"]})
    );
}

#[test]
fn cloud_vm_cli_creates_a_terminal_without_a_local_workspace() {
    let (output, request) = exchange(
        &["vm", "terminal", "new", "vm-test", "--name", "wireguard-proof", "--json"],
        json!({"terminal_id":"term-new"}),
    );
    success(&output);
    assert_eq!(request["method"], "vm.terminal_new");
    assert_eq!(request["params"], json!({"id":"vm-test","name":"wireguard-proof","open":false}));
}

#[test]
fn cloud_vm_cli_refreshes_the_requested_machine_catalog() {
    let (output, request) = exchange(
        &["vm", "tree", "vm-test", "--refresh", "--json"],
        json!({"machines":[],"resources":[]}),
    );
    success(&output);
    assert_eq!(request["method"], "surface.catalog");
    assert_eq!(request["params"], json!({"machine":"vm-test","refresh":true}));
}

#[test]
fn cloud_vm_cli_tui_refuses_a_route_without_the_userspace_hub() {
    let (output, request) = exchange(
        &["vm", "tui", "vm-test"],
        json!({"route":"ws://10.0.0.1:1337/v1/link","trusted_carrier":true}),
    );
    assert!(!output.status.success());
    assert_eq!(request["method"], "vm.cmux_remote_info");
    assert_eq!(request["params"]["id"], "vm-test");
    assert!(
        request["params"]["client_capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("wireguard-hub"))
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("userspace"));
}

#[test]
fn cloud_vm_cli_tui_refuses_untrusted_access() {
    let (output, _) = exchange(
        &["vm", "tui", "vm-test"],
        json!({"route":"ws://10.0.0.1:1337/v1/link","trusted_carrier":false,"wireguard_hub_socket":"/tmp/missing.sock"}),
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("trusted"));
}

#[test]
fn cloud_vm_cli_rejects_local_session_selection_and_noninteractive_tui() {
    for args in [
        vec!["--session", "local", "vm", "ls"],
        vec!["vm", "tui", "vm-test", "--json"],
        vec!["vm", "terminal", "send", "vm-test", "term-test"],
    ] {
        let output = command().args(args).output().unwrap();
        assert_eq!(output.status.code(), Some(2));
    }
}
