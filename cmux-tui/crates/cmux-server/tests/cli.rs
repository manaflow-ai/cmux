//! CLI parsing, exit codes and the install / status / upgrade / rollback /
//! pin / uninstall flow against a recorded service manager and an
//! in-memory channel.

mod common;

use cmux_server::cli::{Context, dispatch, parse};
use cmux_server::exec::RecordingExec;
use cmux_server::host;
use cmux_server::process::RecordingRunner;
use common::*;

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

struct Env {
    tmp: tempfile::TempDir,
    runner: RecordingRunner,
    fetcher: MapFetcher,
    exec: RecordingExec,
    signer: Signer,
    guard: Option<String>,
}

impl Env {
    fn new() -> Env {
        Env {
            tmp: tempfile::tempdir().unwrap(),
            runner: RecordingRunner::new(),
            fetcher: MapFetcher::default(),
            exec: RecordingExec::default(),
            signer: Signer::new(3),
            guard: None,
        }
    }

    fn ctx(&self) -> Context<'_> {
        Context {
            runner: &self.runner,
            fetcher: Some(&self.fetcher),
            exec: &self.exec,
            keys: vec![self.signer.key("current")],
            running_cmux: "1.0.0".to_owned(),
            reexec_guard: self.guard.clone(),
            env: env_for(self.tmp.path()),
            now_ms: NOW_MS,
        }
    }

    /// Publishes one `cmux` package with `archive`.
    fn publish_archive(
        &self,
        sequence: u64,
        version: &'static str,
        min_cmux: &str,
        archive: Vec<u8>,
    ) -> Pkg {
        let pkg = Pkg { name: "cmux", version, archive };
        self.fetcher.serve(&pkg);
        let m = manifest(sequence, "2027-01-01T00:00:00Z", min_cmux, &[&pkg]);
        let sig = self.signer.sign(&m);
        for path in ["latest.json".to_owned(), format!("v/{version}.json")] {
            let url = format!("https://chan.example.test/stable/{}/{path}", host::TARGET);
            self.fetcher.put(&url, m.clone());
            self.fetcher.put(&format!("{url}.sig"), sig.clone());
        }
        pkg
    }
}

const CHAN: &str = "--channel-url https://chan.example.test";

/// Set in the child process of `the_reexec_really_execs_the_server_binary`
/// to the directory it works in.
#[cfg(unix)]
const EXEC_CHILD: &str = "CMUX_SERVER_TEST_EXEC_CHILD";

#[cfg(unix)]
#[test]
fn the_reexec_really_execs_the_server_binary() {
    if cmux_server::sys::is_root() {
        return;
    }
    if let Ok(dir) = std::env::var(EXEC_CHILD) {
        // Child: stage a package whose bin/cmux is a script that
        // records its argv and the guard, then exec it for real.
        let out = std::path::Path::new(&dir).join("exec.out");
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{0}'\nprintf 'guard=%s\\n' \"$CMUX_SERVER_REEXEC\" >> '{0}'\n",
            out.display()
        );
        let mut env = Env::new();
        env.tmp = tempfile::tempdir_in(&dir).unwrap();
        env.publish_archive(1, "9.0.0", "9.0.0", files_package(&[("cmux", script.as_bytes())]));
        let mut ctx = env.ctx();
        let system = cmux_server::exec::SystemExec;
        ctx.exec = &system;
        let result = dispatch(&ctx, &parse(&words(&format!("upgrade --json {CHAN}"))).unwrap());
        panic!("the exec returned: {:?}", result.err());
    }
    let tmp = tempfile::tempdir().unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["the_reexec_really_execs_the_server_binary", "--exact", "--nocapture"])
        .env(EXEC_CHILD, tmp.path())
        .env("CMUX_SERVER_REEXEC", "stale")
        .status()
        .unwrap();
    assert!(status.success(), "{status}");
    let out = std::fs::read_to_string(tmp.path().join("exec.out")).unwrap();
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines[..4],
        ["server", "upgrade", "--channel-url=https://chan.example.test", "--json"]
    );
    assert!(lines[4].starts_with("guard=1:"), "{out}");
    assert_eq!(lines.len(), 5, "{out}");
}
