//! Real-bwrap G1b persistence and process-lifetime regressions.
//! Each child has a 30-second timeout; timeout kills and reaps the keeper.
//! Fixture and shell loops stop after their fixed path lists.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Starts no agent: the keeper runs a fixed `/bin/sh` script. CI sets
// `ACPMUX_REQUIRE_BWRAP` so a missing bwrap fails instead of skipping.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&["ACPMUX_REQUIRE_BWRAP"]);

use acpmux::hub::Hub;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        use std::os::unix::fs::DirBuilderExt;
        let root = PathBuf::from(format!("/tmp/acpmux-supwire-{}", uuid::Uuid::now_v7()));
        // All roots and ancestors are private; the lock directory is outside
        // the policy's writable roots. This matches the supervisor preconditions.
        for dir in [
            "",
            "home",
            "cwd",
            "tmp",
            "scratch",
            "state",
            "state/memory",
            "runtime",
            "cwd/.git",
            "cwd/.git/hooks",
            "cwd/sub",
            "cwd/.claude",
        ] {
            std::fs::DirBuilder::new().mode(0o700).create(root.join(dir)).unwrap();
        }
        Self(root)
    }
    fn command(&self, script: &str) -> Command {
        let mut command = Command::new(daemon_env::bin());
        command.arg("__remote-sandbox-keeper");
        for (flag, dir) in [
            ("--cwd", "cwd"),
            ("--tmpdir", "tmp"),
            ("--home", "home"),
            ("--claude-tmp-project", "scratch"),
            ("--claude-project", "state"),
        ] {
            command.arg(flag).arg(self.0.join(dir));
        }
        command
            .args(["--proxy-port", "8118", "--", "/bin/sh", "-c", script])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("XDG_RUNTIME_DIR", self.0.join("runtime"))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        command
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn available() -> bool {
    match Hub::linux_sandbox_probe_for_tests() {
        Ok(()) => true,
        Err(reason) => {
            assert!(
                std::env::var_os("ACPMUX_REQUIRE_BWRAP").is_none(),
                "bwrap unavailable: {reason}"
            );
            eprintln!("linux_sandbox_keeper: skipped ({reason})");
            false
        }
    }
}

async fn run(fixture: &Fixture, script: &str) -> (std::process::ExitStatus, String, String) {
    let mut child = fixture.command(script).spawn().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let (mut out, mut err) = (String::new(), String::new());
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        tokio::try_join!(
            child.wait(),
            stdout.read_to_string(&mut out),
            stderr.read_to_string(&mut err)
        )
    })
    .await;
    if result.is_err() {
        child.kill().await.unwrap(); // Tokio kill also reaps; bwrap dies with its parent.
    }
    let (status, _, _) =
        result.expect("keeper or supervisor failed to stop in 30 seconds").unwrap();
    (status, out, err)
}

#[tokio::test]
async fn keeper_enforces_persistence_through_real_bwrap() {
    if !available() {
        return;
    }
    let fixture = Fixture::new();
    let (status, out, err) = run(
        &fixture,
        r#"
fail=0
for name in .git/hooks/x sub/CLAUDE.md .claude/settings.json; do
  if (printf escaped > "$name") 2>/dev/null; then echo "allowed $name"; fail=1; fi
done
printf ordinary > ok || exit 71
if mv ok sub/CLAUDE.md 2>/dev/null; then echo 'allowed persistence rename'; fail=1; fi
[ "$fail" = 0 ] || exit 72
printf 'persistence held\n'
"#,
    )
    .await;
    assert!(status.success(), "{status}: stdout={out:?}, stderr={err:?}");
    assert_eq!(out, "persistence held\n");
    assert_eq!(std::fs::read_to_string(fixture.0.join("cwd/ok")).unwrap(), "ordinary");
    for name in [".git/hooks/x", "sub/CLAUDE.md"] {
        assert!(!fixture.0.join("cwd").join(name).exists(), "denied path landed: {name}");
    }
}

#[tokio::test]
async fn keeper_and_supervisor_exit_with_the_agent() {
    if !available() {
        return;
    }
    let fixture = Fixture::new();
    let (status, out, err) = run(&fixture, "printf ordinary > ok; sleep 120 & exit 7").await;
    assert_eq!(status.code(), Some(7), "stdout={out:?}, stderr={err:?}");
    assert_eq!(std::fs::read_to_string(fixture.0.join("cwd/ok")).unwrap(), "ordinary");
}
