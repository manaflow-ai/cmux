//! Wire tests for the daemon's build identity in `identify`
//! (plans/cmux-next/version-skew.md step 2).

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

#[test]
fn identify_reports_the_daemon_build_id_and_its_cli_path() {
    let cli = std::env::current_exe().unwrap().canonicalize().unwrap();
    install_daemon_build(DaemonBuild::new("0123abcd-test", cli.clone()));
    let mux = Mux::new_for_test("daemon-build", crate::SurfaceOptions::default());
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert_eq!(identity["build_id"], "0123abcd-test");
    assert_eq!(identity["cli_path"], cli.to_str().unwrap());
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == DAEMON_BUILD_CAPABILITY));
}

#[test]
fn a_cli_path_that_is_not_absolute_is_never_reported() {
    assert!(DaemonBuild::new("x", std::path::PathBuf::from("bin/cmux")).cli_path().is_none());
    assert!(DaemonBuild::new("x", std::path::PathBuf::from("/a/cmux")).cli_path().is_some());
}
