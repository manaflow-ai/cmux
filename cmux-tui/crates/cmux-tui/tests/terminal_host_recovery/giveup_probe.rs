//! PROBE, a proof branch only (never for a merge): the daemon of a test
//! writes its stderr to a file next to the test folder, and a red assert of
//! the host replacement tests prints the probe lines of that file, the loss
//! log and the time of the kill.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{SystemTime, UNIX_EPOCH};

fn stderr_path(dir: &Path) -> PathBuf {
    PathBuf::from(format!("{}.stderr", dir.display()))
}

/// The stderr of a daemon whose test folder is `dir`: a file that each
/// start of the daemon appends to.
pub(crate) fn stderr_file(dir: &Path) -> Stdio {
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(stderr_path(dir))
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null())
}

/// Wall time in ms, the unit of the daemon's probe lines.
pub(crate) fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_millis()).unwrap_or_default()
}

/// The text of a red assert: when the test sent the kill, the probe lines of
/// the daemon, the last lines of its stderr, and the loss log.
pub(crate) fn report(dir: &Path, host_root: &Path, kill_ms: u128) -> String {
    let stderr = fs::read_to_string(stderr_path(dir)).unwrap_or_default();
    let lines: Vec<&str> = stderr.lines().collect();
    let probe: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| {
            line.contains("host-replacement-probe") || line.contains("kept its host loss")
        })
        .collect();
    let tail: Vec<&str> = lines.iter().rev().take(20).rev().copied().collect();
    let losses = host_root
        .parent()
        .map(|root| fs::read_to_string(root.join("terminal-losses.jsonl")).unwrap_or_default())
        .unwrap_or_default();
    format!(
        "\nPROBE: the test sent the kill at t={kill_ms} and reads this at t={}\n\
         PROBE: {} probe lines of the daemon ({} stderr lines in all):\n{}\n\
         PROBE: the last stderr lines:\n{}\n\
         PROBE: terminal-losses.jsonl:\n{}\nPROBE: end",
        now_ms(),
        probe.len(),
        lines.len(),
        probe.join("\n"),
        tail.join("\n"),
        losses.trim_end(),
    )
}
