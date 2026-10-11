//! What runs on this machine: a program's `--version`, a profile's `auth.check`,
//! and how two versions compare. Blocking; the service calls these off the
//! async threads.

use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::time::Duration;
use wait_timeout::ChildExt;

const TIMEOUT: Duration = Duration::from_secs(10);

/// Runs `argv` with the login environment, no input and a timeout. Returns its
/// exit status and output, or why it did not finish.
fn run(argv: &[String]) -> Result<(bool, String), String> {
    let (program, args) = argv.split_first().ok_or("no command")?;
    let mut cmd = Command::new(program);
    crate::login_env::apply_std(&mut cmd);
    crate::config::scrub_nested_claude_env(&mut cmd);
    cmd.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
    // Woken by the child's exit (SIGCHLD), not a polling tick.
    match child.wait_timeout(TIMEOUT) {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("`{}` did not finish in {}s", argv.join(" "), TIMEOUT.as_secs()));
        }
        Err(e) => return Err(e.to_string()),
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    Ok((out.status.success(), text))
}

static VERSION: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?").expect("version pattern")
});

/// The first version number in a `--version` answer (`codex-acp 0.3.1`,
/// `2.0.5 (Claude Code)`, `v1.2.3`).
pub fn parse_version(text: &str) -> Option<String> {
    VERSION.find(text).map(|m| m.as_str().to_owned())
}

/// `path --version`: the version, or why there is none.
pub fn installed_version(path: &str) -> Result<String, String> {
    let (ok, text) = run(&[path.to_owned(), "--version".into()])?;
    match parse_version(&text) {
        Some(v) => Ok(v),
        None if ok => Err(format!("`{path} --version` printed no version")),
        None => {
            Err(format!("`{path} --version` failed: {}", text.lines().next().unwrap_or("").trim()))
        }
    }
}

/// A profile's `auth.check` command: exit 0 means signed in.
pub fn auth_check(argv: &[String]) -> Result<bool, String> {
    run(argv).map(|(ok, _)| ok)
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
