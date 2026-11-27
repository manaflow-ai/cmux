//! `cmux vm runner|pool ...` reach their own handlers, never the app's Cloud action (`vm VERB` is
//! `cloud VERB` for every word `vm` does not own). Run as the built binary, with no app and no
//! CMUX_* environment: a live end-to-end run once answered `usage: cmux cloud <action>` (exit 2)
//! for both words.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn run(args: &[&str]) -> (i32, String, String) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cxr-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("cmux")).unwrap();
    let mut command = Command::new(dir.join("cmux"));
    command.args(args).current_dir(&dir).env("HOME", &dir).env("TMPDIR", &dir);
    for (name, _) in std::env::vars() {
        if name.starts_with("CMUX") {
            command.env_remove(name);
        }
    }
    let out = command.output().unwrap();
    let _ = fs::remove_dir_all(&dir);
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn vm_runner_help_prints_the_runner_help_with_no_app() {
    for args in [&["vm", "runner", "--help"][..], &["vm", "runner", "new", "--help"]] {
        let (code, stdout, stderr) = run(args);
        assert_eq!(code, 0, "{args:?}: {stderr}");
        assert!(stdout.contains("usage: cmux vm runner <verb>"), "{args:?}: {stdout}{stderr}");
        assert!(!stderr.contains("cmux cloud <action>"), "{args:?}: {stderr}");
    }
}

#[test]
fn vm_pool_is_not_sent_to_the_cloud_action() {
    let (_, stdout, stderr) = run(&["vm", "pool", "--help"]);
    assert!(!format!("{stdout}{stderr}").contains("cmux cloud <action>"), "{stdout}{stderr}");
}

/// `vm runner new` stuck on a GitHub that never answers stops on SIGTERM and on SIGINT, exit 130, with a
/// line saying so: a live `--wait` run once ignored both and had to be SIGKILLed.
#[test]
fn vm_runner_new_stops_on_sigterm_and_sigint() {
    use std::io::Read;
    use std::net::TcpListener;
    use std::time::{Duration, Instant};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let mut held = Vec::new();
        for s in listener.incoming().flatten() {
            held.push(s);
        }
    });
    for sig in ["TERM", "INT"] {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cxs-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("cmux")).unwrap();
        let mut command = Command::new(dir.join("cmux"));
        command
            .args(["vm", "runner", "new", "--owner", "signal-test", "--wait", "--json"])
            .current_dir(&dir)
            .env("HOME", &dir)
            .env("TMPDIR", &dir)
            .env("GITHUB_TOKEN", "not-a-token")
            .env("FREESTYLE_API_KEY", "not-a-key")
            .env("GITHUB_API_URL", format!("http://127.0.0.1:{port}"))
            .env("FREESTYLE_API_URL", format!("http://127.0.0.1:{port}"))
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        for (name, _) in std::env::vars() {
            if name.starts_with("CMUX") {
                command.env_remove(name);
            }
        }
        let mut child = command.spawn().unwrap();
        std::thread::sleep(Duration::from_secs(2));
        assert!(child.try_wait().unwrap().is_none(), "SIG{sig}: exited before the signal");
        let killed = Command::new("kill")
            .args([&format!("-{sig}"), &child.id().to_string()])
            .status()
            .unwrap();
        assert!(killed.success());
        let deadline = Instant::now() + Duration::from_secs(20);
        let status = loop {
            if let Some(s) = child.try_wait().unwrap() {
                break s;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                panic!("SIG{sig}: still running 20s after the signal");
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        let mut stdout = String::new();
        let mut stderr = String::new();
        child.stdout.take().unwrap().read_to_string(&mut stdout).unwrap();
        child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(status.code(), Some(130), "SIG{sig}: {stdout}{stderr}");
        assert!(
            stdout.contains(&format!("\"interrupted\":\"SIG{sig}\"")),
            "SIG{sig}: {stdout}{stderr}"
        );
        assert!(stderr.contains("stopped before a VM was ready"), "SIG{sig}: {stderr}");
    }
}
