//! Which loopback ports belong to cmux's own services (crate::egress_scope):
//! an isolated machine's browsers may reach its loopback dev servers, never
//! the daemon, acpmux, this host's listener or another cmux service.
//!
//! cmux service ports are mostly chosen at run time (the daemon's WebSocket
//! control port, acpmux's web port, the egress listener), so a fixed port
//! list would go stale. The check asks the kernel instead (Linux): the
//! listening sockets on the port (`/proc/net/tcp`, `/proc/net/tcp6`), the
//! processes that hold them (`/proc/<pid>/fd`), and their executables
//! (`/proc/<pid>/exe`); on macOS `lsof` and `proc_pidpath`. A port held by
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
];

/// Whether an executable file name is a cmux service.
pub fn is_service_name(name: &str) -> bool {
    let name = name.strip_suffix(" (deleted)").unwrap_or(name);
    SERVICE_NAMES.contains(&name) || name.starts_with("cmux-") || name.starts_with("cmuxd")
}

/// This machine's check before a dial (a listener may not exist yet).
pub fn system_check() -> ServiceCheck {
    Arc::new(|addr| service_refusal(addr.port(), false))
}

/// This machine's check of a connected peer: a listener exists, so one
/// this host cannot see refuses the port (fail closed).
pub fn system_connected_check() -> ServiceCheck {
    Arc::new(|addr| service_refusal(addr.port(), true))
}

#[cfg(target_os = "linux")]
fn service_refusal(port: u16, connected: bool) -> Option<String> {
    let Some(inodes) = listening_inodes(port) else {
        return Some(format!(
            "loopback port {port} cannot be checked: the kernel's socket tables are unreadable"
        ));
    };
    if inodes.is_empty() {
        // A connect proved a listener: one the tables do not show refuses.
        return connected.then(|| {
            format!("loopback port {port} is held by a socket this host cannot see")
        });
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

/// One `lsof` run: the pids it listed and its exit code (`None`: it timed
/// out, was killed, or could not start).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) struct Lsof {
    pub(crate) pids: Vec<i32>,
    pub(crate) exit: Option<i32>,
}

/// The verdict for a loopback `port` from one `lsof` run (pure, every OS):
/// `connected` means a connect to the port just succeeded, so a listener
/// exists. lsof lists only the processes this user may inspect: a listener
/// of another user or of root is invisible, and with `connected` it refuses
/// the port (fail closed). Before a dial, nothing visible is "nobody
/// listens" (allowed; the dial fails by itself, and the connected check runs
/// after it). A failed lsof, or one that listed holders and then failed,
/// refuses. A holder whose executable cannot be read refuses.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn lsof_verdict(
    port: u16,
    lsof: &Lsof,
    connected: bool,
    executable: impl Fn(i32) -> Option<String>,
) -> Option<String> {
    let failed = || Some(format!("loopback port {port} cannot be checked: lsof failed"));
    match (lsof.pids.is_empty(), lsof.exit) {
        (_, None) => return failed(),
        (true, Some(1)) if connected => {
            return Some(format!(
                "loopback port {port} is held by a process this host cannot inspect"
            ));
        }
        (true, Some(0 | 1)) => return None,
        (true, Some(_)) | (false, Some(1..)) => return failed(),
        _ => {}
    }
    for &pid in &lsof.pids {
        let Some(path) = executable(pid) else {
            return Some(format!(
                "the process that listens on loopback port {port} cannot be identified"
            ));
        };
        let name = path.rsplit('/').next().unwrap_or(&path);
        if is_service_name(name) || is_app_service_name(name) {
            return Some(format!("loopback port {port} is the cmux service {name}"));
        }
    }
    None
}

/// App bundle executable names (macOS names them with spaces): cmux
/// (`cmux DEV <tag>`), Chrome, Chromium, other Chromium-based browsers and
/// Electron, and their helpers: any of them can serve a DevTools port.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn is_app_service_name(name: &str) -> bool {
    name == "cmux"
        || name.starts_with("cmux ")
        || ["Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser", "Electron"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

/// macOS: the listeners on the port come from `lsof` (always installed;
/// bounded, killed after [`LSOF_DEADLINE`]), each holder's executable from
/// `proc_pidpath`; the decision is [`lsof_verdict`]'s.
#[cfg(target_os = "macos")]
fn service_refusal(port: u16, connected: bool) -> Option<String> {
    lsof_verdict(port, &run_lsof(port), connected, executable_path)
}

/// How long one `lsof` run may take before the port is refused.
#[cfg(target_os = "macos")]
const LSOF_DEADLINE: std::time::Duration = std::time::Duration::from_secs(2);

#[cfg(target_os = "macos")]
fn run_lsof(port: u16) -> Lsof {
    use std::io::Read;
    let failed = Lsof { pids: Vec::new(), exit: None };
    let Ok(mut child) = std::process::Command::new("/usr/sbin/lsof")
        .args(["-nPw", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-Fp"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return failed;
    };
    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return failed;
    };
    let (sent, received) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        let _ = sent.send(out);
    });
    let Ok(out) = received.recv_timeout(LSOF_DEADLINE) else {
        let _ = child.kill();
        let _ = child.wait();
        return failed;
    };
    let exit = child.wait().ok().and_then(|status| status.code());
    let pids = String::from_utf8_lossy(&out)
        .lines()
        .filter_map(|line| line.strip_prefix('p')?.parse().ok())
        .collect();
    Lsof { pids, exit }
}

#[cfg(target_os = "macos")]
fn executable_path(pid: i32) -> Option<String> {
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
fn service_refusal(port: u16, _connected: bool) -> Option<String> {
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

#[cfg(test)]
mod lsof_tests {
    use super::*;

    fn exe(name: &'static str) -> impl Fn(i32) -> Option<String> {
        move |_| Some(format!("/Applications/x.app/Contents/MacOS/{name}"))
    }

    /// A connect proved a listener exists: no holder lsof can see (another
    /// user's or root's) refuses the port. Before the dial, nothing seen is
    /// "nobody listens" (allowed).
    #[test]
    fn a_hidden_listener_refuses_a_connected_port() {
        let nobody = Lsof { pids: Vec::new(), exit: Some(1) };
        assert!(lsof_verdict(3000, &nobody, true, exe("node")).is_some());
        assert!(lsof_verdict(3000, &nobody, false, exe("node")).is_none());
    }

    /// lsof that failed (timeout, signal, an exit other than 0/1), or that
    /// listed holders and then failed, refuses the port.
    #[test]
    fn a_failed_or_partial_lsof_refuses() {
        let timed_out = Lsof { pids: Vec::new(), exit: None };
        assert!(lsof_verdict(3000, &timed_out, false, exe("node")).is_some());
        let partial = Lsof { pids: vec![7], exit: Some(1) };
        assert!(lsof_verdict(3000, &partial, false, exe("node")).is_some());
    }

    /// A visible dev server is allowed; a cmux service, Chrome or another
    /// Chromium-based browser is refused.
    #[test]
    fn holders_are_checked_by_executable_name() {
        let one = Lsof { pids: vec![7], exit: Some(0) };
        assert!(lsof_verdict(3000, &one, true, exe("node")).is_none());
        let services = [
            "cmux DEV tag",
            "Google Chrome",
            "Chromium",
            "Microsoft Edge",
            "Brave Browser",
            "Electron",
            "cmuxd-remote",
        ];
        for name in services {
            assert!(lsof_verdict(3000, &one, true, exe(name)).is_some(), "{name}");
        }
        assert!(lsof_verdict(3000, &one, true, |_| None).is_some(), "an unreadable holder");
    }
}
