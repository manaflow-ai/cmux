//! The brain's tools socket path (`CMUX_TUI_CHIEF_TOOLS_SOCKET`, chief-inspect)
//! is taken from the daemon's environment at startup, so no child the daemon
//! spawns (terminal shells, agents, hooks: all inherit the process
//! environment) learns it. One test in its own binary: it changes the
//! process environment before any other thread exists.

#[cfg(unix)]
#[test]
fn a_spawned_child_never_sees_the_tools_socket() {
    const KEY: &str = "CMUX_TUI_CHIEF_TOOLS_SOCKET";
    // SAFETY: the only test in this binary; no other thread reads the environment yet.
    unsafe { std::env::set_var(KEY, "/tmp/brain/mux/optchat/tools.sock") };
    // SAFETY: as above (the daemon calls it first thing in main).
    unsafe { cmux_tui_core::server::take_chief_tools_socket_from_env() };
    assert!(std::env::var_os(KEY).is_none(), "the variable left the process environment");
    let child = std::process::Command::new("/usr/bin/env").output().expect("run env");
    let printed = String::from_utf8_lossy(&child.stdout);
    assert!(child.status.success());
    assert!(!printed.contains(KEY), "a spawned child inherited {KEY}");
    assert!(printed.contains("PATH="), "the child got the rest of the environment");
}
