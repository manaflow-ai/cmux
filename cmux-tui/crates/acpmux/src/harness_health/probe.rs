//! What runs on this machine: a program's `--version`, a profile's `auth.check`,
//! and how two versions compare. Blocking; the service calls these off the
//! async threads.

use std::collections::BTreeMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

const TIMEOUT: Duration = Duration::from_secs(10);

/// Runs `argv` with the login environment plus `env`, no input and a timeout.
/// Returns its exit status and output, or why it did not finish. The pipes
/// are read as the program writes, and a timeout ends its whole process
/// group, so a child that keeps the output open cannot hold the check.
pub(super) fn run(
    argv: &[String],
    env: &BTreeMap<String, String>,
    limit: Duration,
) -> Result<(bool, String), String> {
    let (program, args) = argv.split_first().ok_or("no command")?;
    let mut cmd = Command::new(program);
    crate::login_env::apply_std(&mut cmd);
    crate::config::scrub_nested_claude_env(&mut cmd);
    cmd.envs(env).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
    let (tx, rx) = std::sync::mpsc::channel();
    for pipe in [
        child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>),
        child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut pipe = pipe;
            let mut out = Vec::new();
            // Keep the first 64 KiB, and keep reading so the program never waits on a full pipe.
            let _ = (&mut pipe).take(64 * 1024).read_to_end(&mut out);
            let _ = std::io::copy(&mut pipe, &mut std::io::sink());
            let _ = tx.send(out);
        });
    }
    drop(tx);
    let started = Instant::now();
    let did_not_finish = || format!("`{}` did not finish in {}s", argv.join(" "), limit.as_secs());
    // Woken by the child's exit (SIGCHLD), not a polling tick.
    let status = match child.wait_timeout(limit) {
        Ok(Some(status)) => status,
        Ok(None) => {
            end_group(&mut child);
            return Err(did_not_finish());
        }
        Err(e) => return Err(e.to_string()),
    };
    let mut text = Vec::new();
    for _ in 0..2 {
        match rx.recv_timeout(limit.saturating_sub(started.elapsed())) {
            Ok(part) => text.extend(part),
            // Both pipes closed.
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            // Something it started still holds the output.
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                end_group(&mut child);
                return Err(did_not_finish());
            }
        }
    }
    Ok((status.success(), String::from_utf8_lossy(&text).into_owned()))
}

/// Ends `child` and everything in its process group.
fn end_group(child: &mut std::process::Child) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        // SAFETY: signals the group this module made for the child.
        unsafe { libc::killpg(pid, libc::SIGKILL) };
    }
    let _ = child.kill();
    let _ = child.wait();
}

static VERSION: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?").expect("version pattern") // crash-allow: constant pattern
});

/// The first version number in a `--version` answer (`codex-acp 0.3.1`,
/// `2.0.5 (Claude Code)`, `v1.2.3`).
pub fn parse_version(text: &str) -> Option<String> {
    VERSION.find(text).map(|m| m.as_str().to_owned())
}

/// `path --version`: the version, or why there is none.
pub fn installed_version(path: &str) -> Result<String, String> {
    let (ok, text) = run(&[path.to_owned(), "--version".into()], &BTreeMap::new(), TIMEOUT)?;
    match parse_version(&text) {
        Some(v) => Ok(v),
        None if ok => Err(format!("`{path} --version` printed no version")),
        None => {
            Err(format!("`{path} --version` failed: {}", text.lines().next().unwrap_or("").trim()))
        }
    }
}

/// A profile's `auth.check` command, with the profile's `env`: exit 0 means
/// signed in.
pub fn auth_check(argv: &[String], env: &BTreeMap<String, String>) -> Result<bool, String> {
    run(argv, env, TIMEOUT).map(|(ok, _)| ok)
}

/// Whether `latest` is newer than `installed`, by their numeric parts. A
/// version that does not parse is never called outdated.
pub fn is_newer(latest: &str, installed: &str) -> bool {
    fn parts(v: &str) -> Option<Vec<u64>> {
        let core = v.trim().trim_start_matches('v').split(['-', '+', ' ']).next()?;
        core.split('.').map(|p| p.parse().ok()).collect()
    }
    let (Some(mut a), Some(mut b)) = (parts(latest), parts(installed)) else { return false };
    let n = a.len().max(b.len());
    a.resize(n, 0);
    b.resize(n, 0);
    a > b
}
