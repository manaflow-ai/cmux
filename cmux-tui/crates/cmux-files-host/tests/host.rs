//! The host and the launcher as processes: who is whose child, which process macOS charges a
//! privacy check to (`responsibility_get_pid_responsible_for_pid`, the call Chromium and
//! scripts/cmux-next/tcc/responsible_pid.c use), descriptors, signals and exits.
#![cfg(target_os = "macos")]

use cmux_process::{Command, Stdio};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_cmux-files-host");

/// The program a fake DEV app carries: writes "<pid> <ppid>" to $OUT, says "ready" on fd 3 and
/// closes it when $READY_FD is set, exits 42 on TERM, else 7 once $GO exists (15 s at most).
const PROGRAM: &str = r#"#!/bin/sh
echo "$$ $PPID" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
if [ -n "$READY_FD" ]; then echo ready >&3; exec 3>&-; fi
trap 'exit 42' TERM
i=0
while [ ! -f "$GO" ] && [ $i -lt 300 ]; do sleep 0.05; i=$((i+1)); done
exit 7
"#;

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    out: PathBuf,
    go: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let out = root.join("pids");
        let go = root.join("go");
        Self { _dir: dir, root, out, go }
    }

    /// A fake app `<name>` with the program, embedding `helper` (a bundle) or the test binary.
    fn app(&self, name: &str, helper: Option<&Path>) -> (PathBuf, PathBuf) {
        let app = self.root.join(name);
        let embedded = app.join(cmux_files_host::EMBEDDED_EXECUTABLE);
        let bundle = embedded.parent().unwrap().parent().unwrap().parent().unwrap();
        std::fs::create_dir_all(bundle.parent().unwrap()).unwrap();
        match helper {
            Some(signed) => {
                let status = std::process::Command::new("/usr/bin/ditto")
                    .arg(signed)
                    .arg(bundle)
                    .status()
                    .unwrap();
                assert!(status.success());
            }
            None => {
                std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
                std::fs::copy(HELPER, &embedded).unwrap();
            }
        }
        (app.clone(), self.program(&app))
    }

    fn program(&self, app: &Path) -> PathBuf {
        let program = app.join("Contents/Resources/bin/program");
        std::fs::create_dir_all(program.parent().unwrap()).unwrap();
        std::fs::write(&program, PROGRAM).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program
    }

    fn command(&self, executable: &Path, role: &str, program: &Path) -> Command {
        let mut command = Command::new(executable);
        command
            .arg(role)
            .arg("--")
            .arg(program)
            .env("OUT", &self.out)
            .env("GO", &self.go)
            .env("HOME", &self.root)
            .stdin(Stdio::null());
        command
    }

    /// The program's (pid, ppid), once it wrote them.
    fn pids(&self) -> (i32, i32) {
        let started = Instant::now();
        loop {
            if let Ok(text) = std::fs::read_to_string(&self.out)
                && let Some((pid, ppid)) = text.trim().split_once(' ')
            {
                return (pid.parse().unwrap(), ppid.parse().unwrap());
            }
            assert!(started.elapsed() < Duration::from_secs(10), "the program never started");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn release(&self) {
        std::fs::write(&self.go, "").unwrap();
    }
}

fn responsible(pid: i32) -> i32 {
    unsafe extern "C" {
        fn responsibility_get_pid_responsible_for_pid(pid: libc::pid_t) -> libc::pid_t;
    }
    // SAFETY: a read of the kernel's responsibility record for `pid`.
    unsafe { responsibility_get_pid_responsible_for_pid(pid) }
}

fn executable_of(pid: i32) -> PathBuf {
    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: proc_pidpath writes at most the buffer's size.
    let length =
        unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    assert!(length > 0, "no executable for pid {pid}");
    buffer.truncate(length as usize);
    PathBuf::from(String::from_utf8(buffer).unwrap())
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[test]
fn host_runs_the_program_as_its_child_and_answers_for_it() {
    let fixture = Fixture::new();
    let (_, program) = fixture.app("cmux DEV one.app", None);
    let mut host = fixture
        .command(Path::new(HELPER), "host", &program)
        .disclaim_responsibility()
        .spawn()
        .unwrap();
    let host_pid = host.id() as i32;
    let (pid, ppid) = fixture.pids();
    assert_ne!(pid, host_pid, "the host runs the program as its child, never in its place");
    assert_eq!(ppid, host_pid);
    assert_eq!(responsible(host_pid), host_pid, "a disclaimed host answers for itself");
    assert_eq!(responsible(pid), host_pid, "macOS charges the program's checks to the host");
    fixture.release();
    assert_eq!(host.wait().unwrap().code(), Some(7), "the host exits with the program's status");
}

#[test]
fn host_refuses_a_program_of_an_app_without_the_same_helper() {
    let fixture = Fixture::new();
    let program = fixture.program(&fixture.root.join("Other.app"));
    fixture.release();
    let mut host = fixture.command(Path::new(HELPER), "host", &program).spawn().unwrap();
    assert_eq!(host.wait().unwrap().code(), Some(cmux_files_host::REFUSED_STATUS));
    assert!(!fixture.out.exists(), "a refused program never runs");
}

#[test]
fn descriptors_reach_the_program_and_only_the_program_holds_them() {
    use std::os::fd::AsFd;
    let fixture = Fixture::new();
    let (_, program) = fixture.app("cmux DEV one.app", None);
    let (mut reader, writer) = std::io::pipe().unwrap();
    let mut command = fixture.command(Path::new(HELPER), "host", &program);
    command.env("READY_FD", "1").inherit_fd(writer.as_fd(), 3).unwrap();
    let mut host = command.spawn().unwrap();
    drop(writer);
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = reader.read_to_string(&mut text);
        let _ = sender.send(text);
    });
    // End of file while the program still runs: the host kept no copy of fd 3.
    let text = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    assert_eq!(text, "ready\n");
    fixture.release();
    assert_eq!(host.wait().unwrap().code(), Some(7));
}

#[test]
fn a_term_to_the_host_reaches_the_program() {
    let fixture = Fixture::new();
    let (_, program) = fixture.app("cmux DEV one.app", None);
    let mut host = fixture.command(Path::new(HELPER), "host", &program).spawn().unwrap();
    let _ = fixture.pids();
    // SAFETY: a signal to the child this test started.
    unsafe { libc::kill(host.id() as i32, libc::SIGTERM) };
    assert_eq!(host.wait().unwrap().code(), Some(42));
}

#[test]
fn the_program_ends_when_the_launcher_above_the_host_is_killed() {
    let fixture = Fixture::new();
    let (_, program) = fixture.app("cmux DEV one.app", None);
    // A launcher stand-in that waits for the host, like `run` does.
    let mut launcher = Command::new("/bin/sh");
    launcher
        .arg("-c")
        .arg(r#""$0" host -- "$1"; :"#)
        .arg(HELPER)
        .arg(&program)
        .env("OUT", &fixture.out)
        .env("GO", &fixture.go)
        .stdin(Stdio::null());
    let mut launcher = launcher.spawn().unwrap();
    let (pid, _) = fixture.pids();
    // Only the launcher: a group kill would take the host down with it before it can act.
    // SAFETY: a signal to the child this test started.
    unsafe { libc::kill(launcher.id() as i32, libc::SIGKILL) };
    let _ = launcher.wait();
    let started = Instant::now();
    while alive(pid) && started.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(20));
    }
    let still = alive(pid);
    fixture.release();
    assert!(!still, "the host kills its program once the process that waits for it is gone");
}

#[test]
fn run_without_a_signed_copy_runs_the_program_in_its_place() {
    let fixture = Fixture::new();
    let (app, program) = fixture.app("cmux DEV one.app", None);
    fixture.release();
    let embedded = app.join(cmux_files_host::EMBEDDED_EXECUTABLE);
    let mut launcher = fixture.command(&embedded, "run", &program).spawn().unwrap();
    let launcher_pid = launcher.id() as i32;
    let (pid, _) = fixture.pids();
    assert_eq!(pid, launcher_pid, "an unsigned helper execs the program, as cmux did before");
    assert_eq!(launcher.wait().unwrap().code(), Some(7));
    let root = cmux_files_host::staging_root(&fixture.root);
    let staged = std::fs::read_dir(&root)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .any(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        })
        .unwrap_or(false);
    assert!(!staged, "nothing unsigned is staged");
}

/// The pinned, team-signed bundle: CMUX_FILES_HOST_SIGNED_APP, else the asset of
/// scripts/cmux-next/files-host-dev.pin.json through ensure-signed-pinned-asset.sh (its cache, the
/// fleet store or R2), unzipped into a temporary folder.
fn signed_app() -> Option<(Option<tempfile::TempDir>, PathBuf)> {
    if let Some(app) = std::env::var_os("CMUX_FILES_HOST_SIGNED_APP") {
        return Some((None, PathBuf::from(app)));
    }
    // affected-reads: scripts/cmux-next/files-host-dev.pin.json scripts/cmux-next/ensure-signed-pinned-asset.sh
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let pin = repo.join("scripts/cmux-next/files-host-dev.pin.json");
    if !pin.exists() {
        return None;
    }
    let output = std::process::Command::new("/bin/bash")
        .arg(repo.join("scripts/cmux-next/ensure-signed-pinned-asset.sh"))
        .arg(&pin)
        .arg("--optional")
        .output()
        .ok()?;
    let zip = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    if zip.is_empty() {
        eprintln!("the pinned asset is unavailable: {}", String::from_utf8_lossy(&output.stderr));
        return None;
    }
    let dir = tempfile::tempdir().ok()?;
    let status = std::process::Command::new("/usr/bin/ditto")
        .args(["-x", "-k"])
        .arg(&zip)
        .arg(dir.path())
        .status()
        .ok()?;
    let app = dir.path().join(cmux_files_host::BUNDLE_NAME);
    (status.success() && app.is_dir()).then_some((Some(dir), app))
}

/// With the pinned, team-signed bundle, two different DEV apps run their programs under one
/// staged host executable: one macOS identity.
#[test]
fn two_dev_apps_share_one_staged_host_with_the_signed_pin() {
    let Some((_unzipped, signed)) = signed_app() else {
        eprintln!("skipped: no signed cmux Files (dev).app (no pin, or the asset is unavailable)");
        return;
    };
    let fixture = Fixture::new();
    let mut hosts = Vec::new();
    for name in ["cmux DEV tag-one.app", "cmux DEV tag-two.app"] {
        let _ = std::fs::remove_file(&fixture.out);
        let _ = std::fs::remove_file(&fixture.go);
        let (app, program) = fixture.app(name, Some(&signed));
        let embedded = app.join(cmux_files_host::EMBEDDED_EXECUTABLE);
        let mut launcher = fixture.command(&embedded, "run", &program).spawn().unwrap();
        let launcher_pid = launcher.id() as i32;
        let (pid, host_pid) = fixture.pids();
        assert_ne!(host_pid, launcher_pid, "{name}: the launcher spawned a host");
        assert_eq!(responsible(host_pid), host_pid, "{name}: the host answers for itself");
        assert_eq!(responsible(pid), host_pid, "{name}: the program answers to the host");
        let host = executable_of(host_pid);
        assert!(
            host.starts_with(cmux_files_host::staging_root(&fixture.root)),
            "{name}: the host runs from the staged copy, not from {}",
            host.display()
        );
        fixture.release();
        assert_eq!(launcher.wait().unwrap().code(), Some(7));
        eprintln!("{name}: program {pid} -> host {host_pid} {}", host.display());
        hosts.push(host);
    }
    assert_eq!(hosts[0], hosts[1], "both DEV apps share one staged host executable");
}
