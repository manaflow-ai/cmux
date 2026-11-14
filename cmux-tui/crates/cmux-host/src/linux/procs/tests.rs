use super::*;

/// Security review P2-3: outside the real root only recorded terminal
/// hosts stop; a same-user host of another test survives.
#[test]
fn recorded_scope_stops_only_recorded_terminal_hosts() {
    use std::io::BufRead;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, Stdio};
    let dir = tempfile::tempdir().unwrap();
    // The host announces itself on stdout once `sh` runs the script.
    // `spawn` can return while the child is still inside execve (a
    // CLONE_VFORK parent resumes when the new mm is installed, before
    // the kernel publishes the new argv), and a scan in that window
    // reads an empty cmdline (1 in 60 runs under load). The line is
    // the explicit signal that exec finished.
    fs::write(dir.path().join("__terminal-host"), "echo exec\nsleep 600\n").unwrap();
    // `sh` with argv `.../cmux-tui __terminal-host` runs that script.
    let spawn = || -> Child {
        let mut child = Command::new("/bin/sh")
            .arg0(dir.path().join("cmux-tui"))
            .arg("__terminal-host")
            .current_dir(dir.path())
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        assert_eq!(line, "exec\n", "the host script did not start");
        child
    };
    let mut foreign = spawn();
    let mut ours = spawn();
    let home = dir.path().join("home");
    let records = home.join(".local/state/cmux-tui/sessions/s/terminal-hosts-x");
    fs::create_dir_all(&records).unwrap();
    fs::write(records.join("h.json"), format!(r#"{{"host_pid":{}}}"#, ours.id())).unwrap();
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let killed = stop_terminal_hosts(uid, &[], TerminalHostScope::Recorded(&home));
    let foreign_alive = foreign.try_wait().unwrap().is_none();
    let kept = stop_terminal_hosts(uid, &[ours.id()], TerminalHostScope::Recorded(&home));
    for child in [&mut foreign, &mut ours] {
        // SAFETY: kill of the process group this test started.
        unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
        let _ = child.wait();
    }
    assert_eq!(killed, [ours.id()]);
    assert!(foreign_alive, "a host outside the daemon home was stopped");
    assert!(kept.is_empty(), "{kept:?}");
}
