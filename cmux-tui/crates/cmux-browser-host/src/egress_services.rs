//! Which loopback ports belong to cmux's own services (crate::egress_scope):
//! an isolated machine's browsers may reach its loopback dev servers, never
//! the daemon, acpmux, this host's listener or another cmux service.
//!
//! cmux service ports are mostly chosen at run time (the daemon's WebSocket
//! control port, acpmux's web port, the egress listener), so a fixed port
//! list would go stale. The check asks the kernel instead (Linux): the
//! listening sockets on the port (`/proc/net/tcp`, `/proc/net/tcp6`), the
//! processes that hold them (`/proc/<pid>/fd`), and their executables
//! (`/proc/<pid>/exe`). A port held by a cmux executable is refused; a port
//! whose holder cannot be read is refused too (fail closed); a port nobody
//! listens on is allowed (the dial fails by itself).

use std::net::SocketAddr;
use std::sync::Arc;

/// Why a loopback address is a cmux service's (`Some`), or `None`.
pub type ServiceCheck = Arc<dyn Fn(SocketAddr) -> Option<String> + Send + Sync>;

/// Executable names of cmux services. Anything named `cmux-*` counts too.
/// Chrome counts: the daemon's CDP browsers listen on a loopback DevTools
/// port (`--remote-debugging-port=0`), whose HTTP endpoints a page could
/// read; an agent's own dev servers are never Chrome.
const SERVICE_NAMES: &[&str] = &[
    "cmux",
    "acpmux",
    "chatmux-relay",
    "chrome",
    "chromium",
    "chromium-browser",
    "chrome-headless-shell",
];

/// Whether an executable file name is a cmux service.
pub fn is_service_name(name: &str) -> bool {
    let name = name.strip_suffix(" (deleted)").unwrap_or(name);
    SERVICE_NAMES.contains(&name) || name.starts_with("cmux-")
}

/// This machine's check.
pub fn system_check() -> ServiceCheck {
    Arc::new(|addr| service_refusal(addr.port()))
}

#[cfg(target_os = "linux")]
fn service_refusal(port: u16) -> Option<String> {
    let Some(inodes) = listening_inodes(port) else {
        return Some(format!(
            "loopback port {port} cannot be checked: the kernel's socket tables are unreadable"
        ));
    };
    if inodes.is_empty() {
        return None;
    }
    let (held, exes) = holders(&inodes);
    if let Some(name) = exes.iter().flatten().find(|name| is_service_name(name)) {
        return Some(format!("loopback port {port} is the cmux service {name}"));
    }
    if held < inodes.len() || exes.iter().any(Option::is_none) {
        return Some(format!(
            "the process that listens on loopback port {port} cannot be identified"
        ));
    }
    None
}

#[cfg(not(target_os = "linux"))]
fn service_refusal(port: u16) -> Option<String> {
    // Isolated scope runs on Linux machines; elsewhere the holder cannot be
    // read, so the port is refused (fail closed).
    Some(format!("loopback port {port} cannot be checked on this system"))
}

/// The inodes of TCP sockets in LISTEN on `port` (any address); `None`
/// when neither table can be read (the caller refuses: fail closed).
#[cfg(target_os = "linux")]
fn listening_inodes(port: u16) -> Option<Vec<u64>> {
    let mut inodes = Vec::new();
    let mut read = false;
    for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(text) = std::fs::read_to_string(table) else { continue };
        read = true;
        inodes.extend(parse_listening(&text, port));
    }
    inodes.sort_unstable();
    inodes.dedup();
    read.then_some(inodes)
}

/// `/proc/net/tcp{,6}` rows in LISTEN (`0A`) whose local port is `port`.
pub fn parse_listening(table: &str, port: u16) -> Vec<u64> {
    table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let local = fields.get(1)?;
            let local_port = u16::from_str_radix(local.rsplit(':').next()?, 16).ok()?;
            (local_port == port && *fields.get(3)? == "0A").then_some(())?;
            fields.get(9)?.parse().ok()
        })
        .collect()
}

/// The holders of `inodes`: how many of the inodes some readable process
/// holds, and each holder's executable name (`None`: unreadable).
#[cfg(target_os = "linux")]
fn holders(inodes: &[u64]) -> (usize, Vec<Option<String>>) {
    let wanted: Vec<String> = inodes.iter().map(|inode| format!("socket:[{inode}]")).collect();
    let mut held = vec![false; wanted.len()];
    let mut exes = Vec::new();
    let Ok(procs) = std::fs::read_dir("/proc") else { return (0, exes) };
    for entry in procs.flatten() {
        let pid = entry.file_name();
        let Some(pid) = pid.to_str().filter(|p| p.bytes().all(|b| b.is_ascii_digit())) else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
        let mut holds = false;
        for fd in fds.flatten() {
            let Ok(link) = std::fs::read_link(fd.path()) else { continue };
            if let Some(at) = wanted.iter().position(|w| link.as_os_str() == w.as_str()) {
                held[at] = true;
                holds = true;
            }
        }
        if holds {
            exes.push(
                std::fs::read_link(format!("/proc/{pid}/exe"))
                    .ok()
                    .and_then(|path| Some(path.file_name()?.to_string_lossy().into_owned())),
            );
        }
    }
    (held.iter().filter(|h| **h).count(), exes)
}

#[cfg(test)]
#[path = "egress_services_tests.rs"]
mod tests;
