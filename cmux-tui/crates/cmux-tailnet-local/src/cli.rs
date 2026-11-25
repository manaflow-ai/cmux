//! Fallback when no LocalAPI endpoint answered: `tailscale status --json`
//! prints the same `ipnstate.Status` document. Bounded like a socket call;
//! the child is killed at the deadline.

use std::path::PathBuf;

use crate::Error;
use crate::transport::Limits;

/// Candidate CLI paths: `CMUX_TAILSCALE_BIN`, then `PATH`, then each
/// platform's install locations. Only existing files are returned.
pub fn cli_candidates() -> Vec<PathBuf> {
    if let Some(bin) = std::env::var_os("CMUX_TAILSCALE_BIN").filter(|v| !v.is_empty()) {
        return vec![PathBuf::from(bin)];
    }
    let name = if cfg!(windows) { "tailscale.exe" } else { "tailscale" };
    let mut out: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).map(|d| d.join(name)).collect())
        .unwrap_or_default();
    if cfg!(target_os = "macos") {
        out.push("/Applications/Tailscale.app/Contents/MacOS/Tailscale".into());
        out.push("/opt/homebrew/bin/tailscale".into());
        out.push("/usr/local/bin/tailscale".into());
    } else if cfg!(windows) {
        out.push(r"C:\Program Files\Tailscale\tailscale.exe".into());
    }
    out.retain(|p| p.is_file());
    out
}

/// Runs `tailscale status --json` with the first CLI found.
#[cfg(target_os = "ios")]
pub fn cli_status(_: &Limits) -> Result<Vec<u8>, Error> {
    Err(Error::Unavailable("no tailscale CLI on iOS"))
}

/// Runs `tailscale status --json` with the first CLI found.
#[cfg(not(target_os = "ios"))]
pub fn cli_status(limits: &Limits) -> Result<Vec<u8>, Error> {
    let bin = cli_candidates()
        .into_iter()
        .next()
        .ok_or(Error::Unavailable("no tailscaled LocalAPI and no tailscale CLI"))?;
    run_bounded(cmux_process::Command::new(bin).args(["status", "--json"]), limits)
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn run_bounded(
    cmd: &mut cmux_process::Command,
    limits: &Limits,
) -> Result<Vec<u8>, Error> {
    use std::io::Read;

    use cmux_process::Stdio;

    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error::Io(format!("spawn tailscale: {e}")))?;
    let mut stdout = child.stdout.take().ok_or_else(|| Error::Io("no stdout".into()))?;
    let cap = u64::try_from(limits.max_body).unwrap_or(u64::MAX).saturating_add(1);
    // Drains stdout while the child runs (a full pipe would stall it); ends
    // when the child exits or is killed and the pipe closes.
    let reader = std::thread::Builder::new()
        .name("tailnet-cli-read".into())
        .spawn(move || {
            let mut out = Vec::new();
            let _ = (&mut stdout).take(cap).read_to_end(&mut out);
            out
        })
        .map_err(|e| Error::Io(format!("spawn: {e}")))?;
    // Dropping `child` on the timeout path kills and reaps it (cmux-process).
    let status = child
        .wait_timeout(limits.timeout)
        .map_err(|e| Error::Io(e.to_string()))?
        .ok_or(Error::Timeout)?;
    let out = reader.join().map_err(|_| Error::Io("reader panicked".into()))?;
    if out.len() > limits.max_body {
        return Err(Error::TooLarge);
    }
    if !status.success() {
        return Err(Error::Io(format!("tailscale status exited with {status}")));
    }
    Ok(out)
}
