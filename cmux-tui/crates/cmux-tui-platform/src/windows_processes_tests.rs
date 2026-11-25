use super::*;

const ME: &str = "S-1-5-21-1-2-3-1002";

/// A terminal child this daemon started (in its job, our user and
/// session) is read: its cwd, usage and name; it is the foreground of
/// itself; a process outside the job is not.
#[test]
fn a_terminal_child_is_read() {
    let dir = std::env::temp_dir().join(format!("cwp-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let pty =
        cmux_pty::open(cmux_pty::PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .unwrap();
    let mut command = cmux_pty::PtyCommand::new("cmd.exe");
    command.args(["/d", "/c", "ping -n 30 127.0.0.1 > NUL"]);
    command.cwd(&dir);
    let spawned = pty.spawn(command).unwrap();
    let mut child = spawned.child;
    let pid = child.process_id().unwrap();
    let mut found = None;
    for _ in 0..50 {
        found = cwd(pid);
        if found.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let expected = dir.canonicalize().unwrap();
    let got = found.expect("the cwd of a terminal child");
    assert!(
        std::path::Path::new(&got).canonicalize().unwrap() == expected,
        "{got} is {}",
        expected.display()
    );
    assert!(usage(pid).is_some_and(|(_, memory)| memory > 0));
    assert!(image_path(pid).is_some_and(|p| p.to_ascii_lowercase().ends_with("cmd.exe")));
    assert!(foreground(pid).is_some());
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
