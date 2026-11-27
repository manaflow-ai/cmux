//! Families that are a command, not a folder: `docker image prune` (only
//! when docker is installed and answers) and, on macOS, the iOS simulators
//! that no installed runtime runs any more. Every command is bounded.

use std::process::{Command, Stdio};
use std::time::Duration;

use crate::policy::Pressure;

const QUICK: Duration = Duration::from_secs(20);
const PRUNE: Duration = Duration::from_secs(600);

fn docker(args: &[&str], limit: Duration) -> Result<String, String> {
    let mut command = Command::new("docker");
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let output = crate::git::run_within(command, limit)?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Bytes `docker image prune -a` could free: the images' reclaimable size
/// from `docker system df`. `None` when docker is absent or does not answer.
pub fn docker_reclaimable() -> Option<u64> {
    let text = docker(&["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], QUICK).ok()?;
    text.lines().find_map(|line| {
        let (kind, size) = line.split_once('\t')?;
        (kind.trim() == "Images").then(|| parse_size(size))?
    })
}

/// "1.5GB (45%)" -> bytes.
pub fn parse_size(text: &str) -> Option<u64> {
    let word = text.split_whitespace().next()?;
    let split = word.find(|c: char| c.is_ascii_alphabetic())?;
    let (number, unit) = word.split_at(split);
    let number: f64 = number.parse().ok()?;
    let scale = match unit.to_ascii_lowercase().as_str() {
        "b" => 1.0,
        "kb" => 1e3,
        "mb" => 1e6,
        "gb" => 1e9,
        "tb" => 1e12,
        _ => return None,
    };
    Some((number * scale) as u64)
}

/// Removes images no container uses and none made lately; the bytes freed.
pub fn docker_prune(pressure: Pressure) -> Result<u64, String> {
    let before = docker_reclaimable();
    let until = match pressure {
        Pressure::Normal => "until=168h",
        Pressure::High => "until=72h",
        Pressure::Critical => "until=24h",
    };
    docker(&["image", "prune", "-a", "-f", "--filter", until], PRUNE)?;
    let after = docker_reclaimable();
    Ok(before.unwrap_or(0).saturating_sub(after.unwrap_or(0)))
}

/// macOS: simulators whose runtime is gone.
#[cfg(target_os = "macos")]
pub fn simulators_prune() -> Result<u64, String> {
    let mut command = Command::new("xcrun");
    command
        .args(["simctl", "delete", "unavailable"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = crate::git::run_within(command, PRUNE)?;
    if output.status.success() {
        Ok(0)
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

#[cfg(not(target_os = "macos"))]
pub fn simulators_prune() -> Result<u64, String> {
    Err("iOS simulators exist on macOS only".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_sizes_parse() {
        assert_eq!(parse_size("1.5GB (45%)"), Some(1_500_000_000));
        assert_eq!(parse_size("0B"), Some(0));
        assert_eq!(parse_size("12.3MB"), Some(12_300_000));
        assert_eq!(parse_size("n/a"), None);
    }
}
