//! How a coding agent's CLI gets installed on this machine (the target machine: the one acpmux runs
//! on), decided here once for every client: the routes its vendor supports (npm, the vendor's own
//! native installer, Homebrew), which of them this machine can run now, what is missing for the
//! others, and the one Install runs.
//!
//! - npm first where this machine has it: an npm setup keeps its channel (the route Install took
//!   before this resolver, unchanged).
//! - Else the vendor's native installer, which needs no Node (Claude Code's
//!   `curl -fsSL https://claude.ai/install.sh | bash`, Codex's
//!   `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, both from the vendors' install pages).
//! - Else Homebrew where the vendor publishes a formula or cask and this machine has `brew`.
//! - Else no route: the plan names the first missing prerequisite and what fixes it.
//!
//! An agent already installed gets no install route at all: the plan names where it is and the
//! channel it came from (`channel::detect`), and its updates stay that channel's
//! (`update_plan`). Nothing here replaces an installation.
//!
//! `classify_failure` turns an installer's output in a phase (prerequisites, download, install,
//! verify) into the cause and the one action that fixes it.

use super::channel::{self, Channel};
use serde::Serialize;
use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Free space an install needs in the home folder: Claude Code's native build is about 200 MB, and
/// an npm install holds its download and its unpacked copy at once.
pub const MIN_FREE_BYTES: u64 = 512 * 1024 * 1024;

/// The tools a route may need, looked up on PATH.
const TOOLS: &[&str] = &["npm", "brew", "curl", "bash", "sh"];

/// One agent's install routes, as its vendor documents them.
struct Vendor {
    id: &'static str,
    name: &'static str,
    /// The program the CLI installs (looked up on PATH and in `native_bins`).
    program: &'static str,
    /// Where the native installer puts the program, under the home, when PATH does not have it yet.
    native_bins: &'static [&'static str],
    npm: Option<&'static str>,
    native: Option<Native>,
    /// `brew install` arguments (a formula, or `--cask NAME`).
    brew: Option<&'static str>,
    /// The server whose answer means the network is back (the page's retry wrapper).
    probe: &'static str,
    docs: &'static str,
}

struct Native {
    command: &'static str,
    /// Tools the installer pipe runs.
    needs: &'static [&'static str],
}

const MAC_LINUX: &[&str] = &["macos", "linux"];
const ARCHES: &[&str] = &["x86_64", "aarch64"];

const VENDORS: &[Vendor] = &[
    Vendor {
        id: "claude",
        name: "Claude Code",
        program: "claude",
        native_bins: &[".local/bin/claude"],
        npm: Some("@anthropic-ai/claude-code"),
        // https://code.claude.com/docs/en/setup: "Native Install (Recommended)".
        native: Some(Native {
            command: "curl -fsSL https://claude.ai/install.sh | bash",
            needs: &["curl", "bash"],
        }),
        brew: Some("--cask claude-code"),
        probe: "https://claude.ai",
        docs: "https://code.claude.com/docs/en/setup",
    },
    Vendor {
        id: "codex",
        name: "Codex",
        program: "codex",
        native_bins: &[".local/bin/codex"],
        npm: Some("@openai/codex"),
        // https://github.com/openai/codex README. No tty here: never ask to start Codex or to
        // remove another install.
        native: Some(Native {
            command: "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh",
            needs: &["curl", "sh"],
        }),
        brew: Some("--cask codex"),
        probe: "https://chatgpt.com",
        docs: "https://developers.openai.com/codex/cli",
    },
    Vendor {
        id: "opencode",
        name: "OpenCode",
        program: "opencode",
        native_bins: &[".opencode/bin/opencode"],
        npm: Some("opencode-ai"),
        native: Some(Native {
            command: "curl -fsSL https://opencode.ai/install | bash",
            needs: &["curl", "bash"],
        }),
        brew: Some("opencode"),
        probe: "https://opencode.ai",
        docs: "https://opencode.ai",
    },
    Vendor {
        id: "gemini",
        name: "Gemini CLI",
        program: "gemini",
        native_bins: &[],
        npm: Some("@google/gemini-cli"),
        native: None,
        brew: Some("gemini-cli"),
        probe: "https://registry.npmjs.org",
        docs: "https://github.com/google-gemini/gemini-cli",
    },
];

/// What this machine has, read once per resolve.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MachineFacts {
    pub os: String,
    pub arch: String,
    pub tools: BTreeSet<String>,
    pub home: PathBuf,
    pub home_writable: bool,
    /// Free bytes in the home folder's file system; None when it could not be read.
    pub free_bytes: Option<u64>,
}

impl MachineFacts {
    /// This machine, with `path` its search path (the login shell's, once acpmux has read it).
    pub fn detect(path: Option<&OsStr>, home: &Path) -> Self {
        let dirs: Vec<PathBuf> =
            path.map(|p| std::env::split_paths(p).collect()).unwrap_or_default();
        let tools = TOOLS
            .iter()
            .filter(|tool| {
                dirs.iter().any(|dir| crate::harness_install::is_executable(&dir.join(tool)))
            })
            .map(|tool| (*tool).to_owned())
            .collect();
        Self {
            os: std::env::consts::OS.to_owned(),
            arch: std::env::consts::ARCH.to_owned(),
            tools,
            home: home.to_path_buf(),
            home_writable: writable(home),
            free_bytes: free_bytes(home),
        }
    }

    fn has(&self, tool: &str) -> bool {
        self.tools.contains(tool)
    }
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    Npm,
    Native,
    Brew,
}

/// A check a route needs to pass on this machine.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Prerequisite {
    /// `npm`, `brew`, `curl`, `bash`, `sh`, `platform`, `homeWritable`, `disk`.
    pub id: String,
    pub met: bool,
    /// What makes it met, for a person.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RouteOption {
    pub route: Route,
    /// The shell command it runs (bash, no single quotes: the page wraps it in its network retry).
    pub command: String,
    pub ready: bool,
    pub prerequisites: Vec<Prerequisite>,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Existing {
    pub channel: Channel,
    pub path: PathBuf,
}

/// Why no route can run here, and the one action that fixes the first missing prerequisite.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Blocked {
    pub phase: Phase,
    pub cause: Cause,
    pub action: String,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstallPlan {
    pub id: String,
    pub name: String,
    /// The route Install runs: the first ready one (npm, then native, then Homebrew). None when
    /// the agent is installed already, or when no route is ready (`blocked`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub route: Option<Route>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Every route the vendor supports, ready or not, in preference order.
    pub routes: Vec<RouteOption>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub existing: Option<Existing>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocked: Option<Blocked>,
    pub probe_url: String,
    pub docs_url: String,
}

/// The agents this resolver knows.
pub fn known(id: &str) -> bool {
    VENDORS.iter().any(|vendor| vendor.id == id)
}

pub fn ids() -> impl Iterator<Item = &'static str> {
    VENDORS.iter().map(|vendor| vendor.id)
}

/// `id`'s install plan on the machine `facts` describe, with `found` the program's path when it
/// is installed already (`find_installed`). None for an agent this resolver does not know.
pub fn resolve(id: &str, facts: &MachineFacts, found: Option<&Path>) -> Option<InstallPlan> {
    let vendor = VENDORS.iter().find(|vendor| vendor.id == id)?;
    let routes = routes(vendor, facts);
    let existing = found.map(|path| {
        let real = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        Existing {
            channel: channel::detect(vendor.program, Some(&real), &facts.home).channel,
            path: path.to_path_buf(),
        }
    });
    let chosen = existing.is_none().then(|| routes.iter().find(|r| r.ready)).flatten();
    let blocked = (existing.is_none() && chosen.is_none()).then(|| blocked(vendor, &routes, facts));
    Some(InstallPlan {
        id: vendor.id.to_owned(),
        name: vendor.name.to_owned(),
        route: chosen.map(|r| r.route),
        command: chosen.map(|r| r.command.clone()),
        routes,
        existing,
        blocked,
        probe_url: vendor.probe.to_owned(),
        docs_url: vendor.docs.to_owned(),
    })
}

/// The program `id` installs, on `path` or where its native installer puts it.
pub fn find_installed(id: &str, path: Option<&OsStr>, home: &Path) -> Option<PathBuf> {
    let vendor = VENDORS.iter().find(|vendor| vendor.id == id)?;
    path.into_iter()
        .flat_map(std::env::split_paths)
        .map(|dir| dir.join(vendor.program))
        .chain(vendor.native_bins.iter().map(|bin| home.join(bin)))
        .find(|candidate| crate::harness_install::is_executable(candidate))
}

/// Every known agent's plan on this machine, for the `_acpmux/harnesses` view.
pub fn plans_here(path: Option<&OsStr>, home: &Path) -> Vec<InstallPlan> {
    let facts = MachineFacts::detect(path, home);
    ids().filter_map(|id| resolve(id, &facts, find_installed(id, path, home).as_deref())).collect()
}

fn routes(vendor: &Vendor, facts: &MachineFacts) -> Vec<RouteOption> {
    let space = space_checks(facts);
    let tool = |name: &str, fix: &str| Prerequisite {
        id: name.to_owned(),
        met: facts.has(name),
        fix: (!facts.has(name)).then(|| fix.to_owned()),
    };
    let mut out = Vec::new();
    if let Some(package) = vendor.npm {
        let mut prerequisites =
            vec![tool("npm", "Install Node.js (it includes npm), or use another route")];
        prerequisites.extend(space.iter().filter(|p| p.id == "disk").cloned());
        out.push(option(Route::Npm, format!("npm install -g {package}"), prerequisites));
    }
    if let Some(native) = &vendor.native {
        let supported =
            MAC_LINUX.contains(&facts.os.as_str()) && ARCHES.contains(&facts.arch.as_str());
        let mut prerequisites = vec![Prerequisite {
            id: "platform".into(),
            met: supported,
            fix: (!supported).then(|| {
                format!(
                    "{} has no native installer for {} on {}: install it from {}",
                    vendor.name, facts.os, facts.arch, vendor.docs
                )
            }),
        }];
        for need in native.needs {
            prerequisites
                .push(tool(need, &format!("Install {need} with this machine's package manager")));
        }
        prerequisites.extend(space.iter().cloned());
        out.push(option(Route::Native, native.command.to_owned(), prerequisites));
    }
    if let Some(args) = vendor.brew {
        let mut prerequisites = vec![tool("brew", "Install Homebrew from https://brew.sh")];
        prerequisites.extend(space.iter().filter(|p| p.id == "disk").cloned());
        out.push(option(Route::Brew, format!("brew install {args}"), prerequisites));
    }
    out
}

fn option(route: Route, command: String, prerequisites: Vec<Prerequisite>) -> RouteOption {
    let ready = prerequisites.iter().all(|p| p.met);
    RouteOption { route, command, ready, prerequisites }
}

/// The home folder checks the native installers need (they write under it).
fn space_checks(facts: &MachineFacts) -> Vec<Prerequisite> {
    // An unreadable free count is not evidence of a full disk.
    let room = facts.free_bytes.is_none_or(|free| free >= MIN_FREE_BYTES);
    vec![
        Prerequisite {
            id: "homeWritable".into(),
            met: facts.home_writable,
            fix: (!facts.home_writable)
                .then(|| format!("Make {} writable by this user", facts.home.display())),
        },
        Prerequisite {
            id: "disk".into(),
            met: room,
            fix: (!room).then(|| {
                format!(
                    "Free at least {} MB on the disk holding {}",
                    MIN_FREE_BYTES / (1024 * 1024),
                    facts.home.display()
                )
            }),
        },
    ]
}

/// The first missing prerequisite of the route closest to ready: the native one when the vendor
/// has it (it needs the least), else the first.
fn blocked(vendor: &Vendor, routes: &[RouteOption], facts: &MachineFacts) -> Blocked {
    let pick = routes.iter().find(|r| r.route == Route::Native).or_else(|| routes.first());
    let missing = pick.and_then(|r| r.prerequisites.iter().find(|p| !p.met));
    let cause = match missing.map(|p| p.id.as_str()) {
        Some("platform") => Cause::Architecture,
        Some("homeWritable") => Cause::Permission,
        Some("disk") => Cause::Disk,
        _ => Cause::Prerequisite,
    };
    let action = missing.and_then(|p| p.fix.clone()).unwrap_or_else(|| {
        format!("Install {} from {} ({} {})", vendor.name, vendor.docs, facts.os, facts.arch)
    });
    Blocked { phase: Phase::Prerequisites, cause, action }
}

/// Where an install stopped.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Prerequisites,
    Download,
    Install,
    Verify,
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Cause {
    Prerequisite,
    Network,
    Permission,
    Disk,
    Architecture,
    Other,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Recovery {
    pub phase: Phase,
    pub cause: Cause,
    pub action: String,
}

/// The cause of a failed install `phase` from the installer's `output`, and its fix. A verify
/// failure is its own cause: the installer finished but the program it should have put in place
/// does not run.
pub fn classify_failure(phase: Phase, output: &str, docs: &str) -> Recovery {
    let text = output.to_ascii_lowercase();
    let any = |needles: &[&str]| needles.iter().any(|n| text.contains(n));
    let (cause, action) = if any(&["no space left", "enospc", "disk full", "quota exceeded"]) {
        (
            Cause::Disk,
            format!(
                "Free at least {} MB of disk, then install again",
                MIN_FREE_BYTES / (1024 * 1024)
            ),
        )
    } else if any(&[
        "permission denied",
        "eacces",
        "eperm",
        "operation not permitted",
        "read-only file system",
    ]) {
        (Cause::Permission, "The install folder is not writable by this user: choose another route or fix its owner, then install again (never with sudo npm)".to_owned())
    } else if any(&[
        "unsupported architecture",
        "unsupported platform",
        "unsupported os",
        "exec format error",
        "no prebuilt",
        "not supported on",
    ]) {
        (
            Cause::Architecture,
            format!("This machine's platform has no build on this route: install from {docs}"),
        )
    } else if any(&[
        "could not resolve",
        "resolve host",
        "timed out",
        "connection refused",
        "connection reset",
        "failed to connect",
        "econnreset",
        "econnrefused",
        "etimedout",
        "enotfound",
        "eai_again",
        "getaddrinfo",
        "network is unreachable",
        "ssl",
        "tls",
    ]) {
        (Cause::Network, "The download did not reach the vendor's server: check this machine's network or proxy, then install again".to_owned())
    } else if any(&[
        "command not found",
        "not found: npm",
        "npm: not found",
        "curl: not found",
        "bash: not found",
    ]) {
        (
            Cause::Prerequisite,
            "A tool this route needs is missing: install it, or choose another route".to_owned(),
        )
    } else if phase == Phase::Verify {
        (
            Cause::Other,
            format!(
                "The installer finished but the program does not run: open a new terminal and run it, or reinstall from {docs}"
            ),
        )
    } else {
        (Cause::Other, format!("Install again, or install it by hand from {docs}"))
    };
    Recovery { phase, cause, action }
}

#[cfg(unix)]
fn writable(dir: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(c) = std::ffi::CString::new(dir.as_os_str().as_bytes()) else { return false };
    // SAFETY: `c` is a valid NUL-terminated path for the call's duration.
    unsafe { libc::access(c.as_ptr(), libc::W_OK) == 0 }
}

#[cfg(not(unix))]
fn writable(dir: &Path) -> bool {
    std::fs::metadata(dir).is_ok_and(|m| !m.permissions().readonly())
}

#[cfg(unix)]
fn free_bytes(dir: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    // SAFETY: an all-zero statvfs is a valid value of this plain C struct.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is NUL-terminated and `st` is a valid out pointer for the call.
    if unsafe { libc::statvfs(c.as_ptr(), &raw mut st) } != 0 {
        return None;
    }
    #[allow(clippy::unnecessary_cast)]
    Some(st.f_bavail as u64 * st.f_frsize as u64)
}

#[cfg(not(unix))]
fn free_bytes(_dir: &Path) -> Option<u64> {
    None
}

#[cfg(test)]
#[path = "install_route_tests.rs"]
mod tests;
