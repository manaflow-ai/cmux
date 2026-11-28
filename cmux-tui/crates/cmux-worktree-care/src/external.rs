//! Families that are a command, not a folder: `docker image prune` (only
//! when docker is installed, answers, and its daemon is this user's own: a
//! unix socket the user owns, as Docker Desktop, OrbStack or rootless docker
//! give; a shared system daemon's images belong to others too) and, on macOS, the iOS simulators
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
    own_daemon().ok()?;
    let text = docker(&["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], QUICK).ok()?;
    text.lines().find_map(|line| {
        let (kind, size) = line.split_once('\t')?;
        (kind.trim() == "Images").then(|| parse_size(size))?
    })
}

/// `Ok` when the docker daemon the CLI talks to is this user's own; why not
/// otherwise.
fn own_daemon() -> Result<(), String> {
    let host = docker(&["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], QUICK)?;
    daemon_is_mine(host.trim())
}

/// Whether the daemon at `host` (`unix:///...`) listens on a socket this
/// user owns.
fn daemon_is_mine(host: &str) -> Result<(), String> {
    let Some(socket) = host.strip_prefix("unix://") else {
        return Err(format!("docker daemon at {host} is not a local socket of this user's"));
    };
    let meta = std::fs::metadata(socket).map_err(|e| format!("{socket}: {e}"))?;
    if !owned_by_me(&meta) {
        return Err(format!("docker daemon at {socket} is shared, not this user's"));
    }
    Ok(())
}

#[cfg(unix)]
fn owned_by_me(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: geteuid has no preconditions and cannot fail.
    meta.uid() == unsafe { libc::geteuid() }
}

#[cfg(not(unix))]
fn owned_by_me(_meta: &std::fs::Metadata) -> bool {
    false
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
    own_daemon()?;
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

/// Whether this Mac can have iOS simulators to prune: macOS with developer tools installed. On a
/// Mac without them, `xcrun` is Apple's stub that opens "Install Command Line Developer Tools", so
/// a clean Mac's first cmux launch showed that installer unasked: the daemon's startup pass ran
/// `xcrun simctl delete unavailable` (first-run findings). Only the paths `xcrun` itself resolves
/// a developer folder from are checked; nothing runs.
pub fn simulators_present() -> bool {
    cfg!(target_os = "macos")
        && developer_tools_installed(std::env::var_os("DEVELOPER_DIR"), &|path| path.exists())
}

/// `xcrun`'s developer folder: `DEVELOPER_DIR`, else `xcode-select`'s link, else Xcode in
/// Applications, else the Command Line Tools. `exists` reads the disk (a test's fake in tests).
fn developer_tools_installed(
    developer_dir: Option<std::ffi::OsString>,
    exists: &dyn Fn(&std::path::Path) -> bool,
) -> bool {
    use std::path::Path;
    if developer_dir.is_some_and(|dir| !dir.is_empty() && exists(Path::new(&dir))) {
        return true;
    }
    ["/var/db/xcode_select_link", "/Applications/Xcode.app", "/Library/Developer/CommandLineTools"]
        .iter()
        .any(|path| exists(Path::new(path)))
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

    /// A clean Mac has no developer folder: no `xcrun`, so no simulator pass (it would open
    /// Apple's developer tools installer). Any one of `xcrun`'s folders is enough.
    #[test]
    fn simulators_are_pruned_only_with_developer_tools_installed() {
        use std::path::Path;
        let none = |_: &Path| false;
        assert!(!developer_tools_installed(None, &none));
        let only_empty = |p: &Path| p.as_os_str().is_empty();
        assert!(!developer_tools_installed(Some("".into()), &only_empty), "an empty DEVELOPER_DIR");
        for folder in [
            "/var/db/xcode_select_link",
            "/Applications/Xcode.app",
            "/Library/Developer/CommandLineTools",
        ] {
            assert!(
                developer_tools_installed(None, &|p: &Path| p == Path::new(folder)),
                "{folder}"
            );
        }
        let dir = "/opt/Xcode-beta.app/Contents/Developer";
        assert!(developer_tools_installed(Some(dir.into()), &|p: &Path| p == Path::new(dir)));
        assert!(
            !developer_tools_installed(Some(dir.into()), &none),
            "a DEVELOPER_DIR that is gone"
        );
        if !cfg!(target_os = "macos") {
            assert!(!simulators_present());
        }
    }

    #[test]
    fn only_a_daemon_on_a_socket_of_this_users_is_pruned() {
        let mine = crate::store::care_tests::scratch("docker-own");
        let socket = mine.join("docker.sock");
        std::fs::write(&socket, b"").unwrap();
        assert!(daemon_is_mine(&format!("unix://{}", socket.display())).is_ok());
        assert!(daemon_is_mine("tcp://10.0.0.1:2375").is_err());
        assert!(daemon_is_mine("unix:///nonexistent/docker.sock").is_err());
        #[cfg(unix)]
        if unsafe { libc::geteuid() } != 0 {
            // Root's file, as a system daemon's socket is.
            assert!(daemon_is_mine("unix:///etc/passwd").unwrap_err().contains("shared"));
        }
        let _ = std::fs::remove_dir_all(&mine);
    }

    #[test]
    fn docker_sizes_parse() {
        assert_eq!(parse_size("1.5GB (45%)"), Some(1_500_000_000));
        assert_eq!(parse_size("0B"), Some(0));
        assert_eq!(parse_size("12.3MB"), Some(12_300_000));
        assert_eq!(parse_size("n/a"), None);
    }
}
