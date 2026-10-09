//! Which loopback ports belong to cmux's own services (crate::egress_scope):
//! an isolated machine's browsers may reach its loopback dev servers, never
//! the daemon, acpmux, this host's listener or another cmux service.
//!
//! cmux service ports are mostly chosen at run time (the daemon's WebSocket
//! control port, acpmux's web port, the egress listener), so a fixed port
//! list would go stale. The check asks the kernel instead (Linux): the
//! listening sockets on the port (`/proc/net/tcp`, `/proc/net/tcp6`), the
//! processes that hold them (`/proc/<pid>/fd`), and their executables
//! (`/proc/<pid>/exe`); on macOS the kernel socket table and libproc
//! (crate::egress_listeners). A port held by
//! a cmux executable is refused; a port
//! whose holder cannot be read is refused too (fail closed); a port nobody
//! listens on is allowed (the dial fails by itself).

use std::net::SocketAddr;
use std::sync::Arc;

/// Why a loopback address is a cmux service's (`Some`), or `None`.
pub type ServiceCheck = Arc<dyn Fn(SocketAddr) -> Option<String> + Send + Sync>;

/// Executable names of cmux services. Anything named `cmux-*` counts too.
/// Chrome counts: cmux launches no Chrome with a DevTools port (cx-2u5k),
/// but an agent's own automation does (agent-browser, Playwright,
/// Puppeteer: `--remote-debugging-port`), and a page that reaches that port
/// could read or drive that browser. An agent's dev servers are never Chrome.
const SERVICE_NAMES: &[&str] = &[
    "cmux",
    "acpmux",
    "chatmux-relay",
    "chrome",
    "chromium",
    "chromium-browser",
    "chrome-headless-shell",
    "headless_shell",
    "msedge",
    "brave",
    "electron",
];

/// Whether an executable file name is a cmux service.
pub fn is_service_name(name: &str) -> bool {
    let name = name.strip_suffix(" (deleted)").unwrap_or(name);
    SERVICE_NAMES.contains(&name) || name.starts_with("cmux-") || name.starts_with("cmuxd")
}

/// This machine's check before a dial (a listener may not exist yet).
pub fn system_check() -> ServiceCheck {
    Arc::new(|addr| service_refusal(addr, false))
}

/// This machine's check of a connected peer: a listener exists, so one
/// this host cannot see refuses the port (fail closed).
pub fn system_connected_check() -> ServiceCheck {
    Arc::new(|addr| service_refusal(addr, true))
}

#[cfg(target_os = "linux")]
fn service_refusal(addr: SocketAddr, connected: bool) -> Option<String> {
    let port = addr.port();
    let Some(inodes) = listening_inodes(port) else {
        return Some(format!(
            "loopback port {port} cannot be checked: the kernel's socket tables are unreadable"
        ));
    };
    if inodes.is_empty() {
        // A connect proved a listener: one the tables do not show refuses.
        return connected
            .then(|| format!("loopback port {port} is held by a socket this host cannot see"));
    }
    let (held, holders) = holders(&inodes);
    for holder in holders.iter().flatten() {
        let family = crate::egress_holders::dir_is_chromium_family(&holder.path);
        if let Some(why) = crate::egress_holders::holder_refusal(holder, port, family) {
            return Some(why);
        }
    }
    if held < inodes.len() || holders.iter().any(Option::is_none) {
        return Some(format!(
            "the process that listens on loopback port {port} cannot be identified"
        ));
    }
    None
}

/// App bundle executable names (macOS names them with spaces): cmux
/// (`cmux DEV <tag>`), Chrome, Chromium, other Chromium-based browsers and
/// Electron, and their helpers: any of them can serve a DevTools port.
pub(crate) fn is_app_service_name(name: &str) -> bool {
    name == "cmux"
        || name.starts_with("cmux ")
        || ["Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser", "Electron"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

/// macOS: the listeners that cover the target address come from the kernel's
/// socket table, their holders from libproc, with no process spawn
/// (crate::egress_listeners).
#[cfg(target_os = "macos")]
fn service_refusal(addr: SocketAddr, connected: bool) -> Option<String> {
    use crate::egress_listeners::{system_listeners, system_own_listeners, verdict};
    // SAFETY: geteuid has no preconditions.
    let own_uid = unsafe { libc::geteuid() };
    let (Some(table), Some(own)) = (system_listeners(), system_own_listeners(own_uid)) else {
        return Some(format!(
            "loopback {addr} cannot be checked: the socket tables are unreadable"
        ));
    };
    verdict(addr, &table, &own, own_uid, connected)
}

#[cfg(target_os = "macos")]
pub(crate) fn executable_path(pid: i32) -> Option<String> {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let size = buffer.len() as u32;
    // SAFETY: the buffer is writable for its whole length, which is passed.
    let written = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), size) };
    if written <= 0 {
        return None;
    }
    buffer.truncate(written as usize);
    String::from_utf8(buffer).ok()
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn service_refusal(addr: SocketAddr, _connected: bool) -> Option<String> {
    let port = addr.port();
    // The holder cannot be read here, so the port is refused (fail closed).
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
/// holds, and each holder (`None`: unreadable).
#[cfg(target_os = "linux")]
fn holders(inodes: &[u64]) -> (usize, Vec<Option<crate::egress_holders::Holder>>) {
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
            exes.push(crate::egress_holders::system_holder(pid));
        }
    }
    (held.iter().filter(|h| **h).count(), exes)
}

#[cfg(test)]
#[path = "egress_services_tests.rs"]
mod tests;
