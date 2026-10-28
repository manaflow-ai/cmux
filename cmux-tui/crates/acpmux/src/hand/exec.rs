//! `exec {argv, cwd, timeout_ms}`: sandbox profile only (policy.rs refuses it
//! on a mac hand). The request names the argv and folder; it never sets the
//! environment, PATH or which binary a name means: the program runs with the
//! hand's own environment.

use super::HandError;
use serde_json::{Value, json};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;

const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MAX_TIMEOUT_MS: u64 = 600_000;
const MAX_OUTPUT: usize = 256 * 1024;
/// How long output may still arrive after the program ended.
const DRAIN_GRACE: Duration = Duration::from_secs(5);

async fn drain<R: tokio::io::AsyncRead + Unpin>(mut r: R) -> (String, bool) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut cut = false;
    loop {
        match r.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = MAX_OUTPUT.saturating_sub(buf.len());
                buf.extend_from_slice(chunk.get(..n.min(room)).unwrap_or_default());
                cut |= n > room;
            }
        }
    }
    (String::from_utf8_lossy(&buf).into_owned(), cut)
}

pub async fn run(argv: &[String], cwd: &Path, timeout_ms: Option<u64>) -> Result<Value, HandError> {
    let (program, args) =
        argv.split_first().ok_or_else(|| HandError::new("exec.bad_argv", "argv is empty"))?;
    let timeout =
        Duration::from_millis(timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS).min(MAX_TIMEOUT_MS));
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    cmd.process_group(0);
    let started = std::time::Instant::now();
    let mut child =
        cmd.spawn().map_err(|e| HandError::new("exec.spawn", format!("{program}: {e}")))?;
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill().await;
        return Err(HandError::new("exec.spawn", format!("{program}: no output pipes")));
    };
    let out = tokio::spawn(drain(stdout));
    let err = tokio::spawn(drain(stderr));
    let pgid = child.id();
    let (status, timed_out) = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(s) => (s.ok(), false),
        Err(_) => {
            let _ = child.kill().await;
            (None, true)
        }
    };
    // The whole process group, also after a normal exit: a background child
    // (`sh -c 'x &'`) would hold the pipes open and outlive the request.
    #[cfg(unix)]
    if let Some(pid) = pgid {
        // SAFETY: kill takes no pointers; `-pid` names the group the command leads
        // (process_group(0) above).
        unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
    }
    let _ = pgid;
    let collect = |h: tokio::task::JoinHandle<(String, bool)>| async move {
        tokio::time::timeout(DRAIN_GRACE, h).await.ok().and_then(Result::ok).unwrap_or_default()
    };
    let (stdout, out_cut) = collect(out).await;
    let (stderr, err_cut) = collect(err).await;
    Ok(json!({
        "exit": status.and_then(|s| s.code()),
        "timed_out": timed_out,
        "stdout": stdout,
        "stderr": stderr,
        "truncated": out_cut || err_cut,
        "ms": started.elapsed().as_millis() as u64,
    }))
}
