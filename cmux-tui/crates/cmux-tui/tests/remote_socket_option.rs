//! `cmux --socket PATH rpc ...`: the remote commands take a ROUTE, not a
//! local socket, so a global `--socket` is refused with a message that names
//! `--app-socket` for the cmux app's control socket
//! (/tmp/cmux-debug-<tag>.sock), never "unknown option".

use std::process::Command;

fn run(args: &[&str]) -> (Option<i32>, String) {
    let home = std::env::temp_dir().join(format!("cmux-remote-socket-{}", std::process::id()));
    std::fs::create_dir_all(&home).expect("a temp HOME");
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(args)
        .env("HOME", &home)
        .env_remove("CMUX_SOCKET_PATH")
        .output()
        .expect("the cmux-tui binary runs");
    let _ = std::fs::remove_dir_all(&home);
    (output.status.code(), String::from_utf8_lossy(&output.stderr).into_owned())
}

#[test]
fn rpc_with_a_global_socket_names_the_app_socket_option() {
    let socket = "/tmp/cmux-debug-occl1-v1.sock";
    let joined = format!("--socket={socket}");
    for args in [
        vec!["--socket", socket, "rpc", "debug.surfaces", "{}"],
        vec![joined.as_str(), "rpc", "debug.surfaces", "{}"],
    ] {
        let (code, stderr) = run(&args);
        assert_ne!(code, Some(0), "{args:?}: {stderr}");
        assert!(!stderr.contains("unknown option"), "{args:?}: {stderr}");
        assert!(stderr.contains("--app-socket"), "{args:?}: {stderr}");
        assert!(stderr.contains("ROUTE"), "{args:?}: {stderr}");
    }
}
