//! The wrapper's exec of the real Claude, run end to end.

use std::ffi::OsString;
use std::fs;
use std::os::fd::AsFd as _;
use std::path::Path;

use cmux_process::Command;

/// The wrapper is transparent to descriptors: one the person's shell gave
/// the `claude` command (`3<file`, `--mcp-config <(...)`) is still open in
/// the real Claude it execs. The wrapper runs in a re-run of this test
/// binary, which the fake Claude replaces.
#[test]
fn claude_wrapper_passes_the_callers_descriptors_to_the_real_claude() {
    const FIXTURE: &str = "CMUX_TUI_CLAUDE_WRAPPER_FD_FIXTURE";
    if std::env::var_os(FIXTURE).is_some() {
        std::process::exit(super::run(&[OsString::from("/dev/fd/3")]));
    }
    let root = tempfile::tempdir().unwrap();
    let real = root.path().join("real");
    fs::create_dir_all(&real).unwrap();
    crate::test_exec::write_executable(real.join("claude"), "#!/bin/sh\nexec cat \"$1\"\n");
    let given = root.path().join("given.txt");
    fs::write(&given, "from-fd-three\n").unwrap();
    let given = fs::File::open(&given).unwrap();
    let path =
        std::env::join_paths([real.as_path(), Path::new("/usr/bin"), Path::new("/bin")]).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "claude_wrapper::exec_tests::claude_wrapper_passes_the_callers_descriptors_to_the_real_claude",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(FIXTURE, "1")
        .env("PATH", path)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SOCKET")
        .inherit_fd(given.as_fd(), 3)
        .unwrap()
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{output:?}");
    assert!(stdout.contains("from-fd-three"), "Claude could not read /dev/fd/3: {output:?}");
}
