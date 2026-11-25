use super::*;

/// The parent of a process is read whatever bytes the name of its
/// program has.
#[cfg(target_os = "linux")]
#[test]
fn the_parent_of_an_ancestor_is_read_for_each_program_name() {
    let child = crate::CutNameChild::start("codex-parent").expect("child");
    assert_eq!(parent_process_id(child.id()), Some(std::process::id()));
}

#[test]
fn codex_app_server_daemon_is_recognized_only_by_its_daemon_argv() {
    let argv = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    assert!(is_codex_app_server_daemon(&argv(&[
        "/home/me/.codex/packages/app-server-daemon/releases/0.162.1/bin/codex",
        "app-server",
        "--listen",
        "unix://",
        "--analytics-default-enabled",
        "--managed-daemon",
    ])));
    // An older managed binary without the startup flag.
    assert!(is_codex_app_server_daemon(&argv(&[
        "/home/me/.codex/packages/app-server-daemon/releases/0.161.0/bin/codex",
        "app-server",
        "--listen",
        "unix://",
    ])));
    // The embedded TUI, an editor's own app-server, and a prompt that
    // merely mentions the words.
    assert!(!is_codex_app_server_daemon(&argv(&["codex", "--enable", "hooks", "-c", "x=1"])));
    assert!(!is_codex_app_server_daemon(&argv(&["/opt/codex", "app-server"])));
    assert!(!is_codex_app_server_daemon(&argv(&["app-server", "--managed-daemon"])));
    assert!(!is_codex_app_server_daemon(&argv(&["codex", "explain app-server"])));
}
