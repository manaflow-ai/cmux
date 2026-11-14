use std::io::Write;

use cmux_process::{Command, Stdio};

const NAME: &str = "remote_host::join_tests::the_enable_before_a_join_gets_no_ticket";
const FAKE: &str = "CMUX_TEST_JOIN_ENABLE_FAKE";

/// `join --serve` runs `cmux host enable` first, with the ticket waiting
/// on this process's stdin for the join: that child carries no ticket in
/// its argv and reads none of stdin, so it can neither show the ticket in
/// `ps` nor take it from the join. This test runs itself again with a
/// ticket on stdin; the copy starts the enable child, which records its
/// argv and what it read.
#[test]
fn the_enable_before_a_join_gets_no_ticket() {
    if let Some(fake) = std::env::var_os(FAKE) {
        let status = super::enable_before_join(fake).status().unwrap();
        assert!(status.success());
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-join-enable-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let fake = dir.join("cmux");
    std::fs::write(&fake, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$0.args\"\ncat > \"$0.stdin\"\n")
        .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut parent = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", NAME, "--test-threads=1"])
        .env(FAKE, &fake)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    parent.stdin.take().unwrap().write_all(b"cmxt1.ticket-for-the-join\n").unwrap();
    let out = parent.wait_with_output().unwrap();
    let args = std::fs::read_to_string(dir.join("cmux.args")).unwrap_or_default();
    let stdin = std::fs::read_to_string(dir.join("cmux.stdin")).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(args, "host enable\n");
    assert_eq!(stdin, "", "the enable child read the join's stdin");
}
