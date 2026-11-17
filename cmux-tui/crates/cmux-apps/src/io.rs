//! The effects a publish has, one trait each, so the core runs against fakes in tests.

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::infer::Inferred;

/// Files: the version store and its logs (and, in the agent, the process table it reads).
pub trait Fs {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    fn read_link(&self, path: &Path) -> io::Result<PathBuf>;
    /// The names in `dir` (not paths), in any order.
    fn list(&self, dir: &Path) -> io::Result<Vec<String>>;
    /// Replaces `path` whole (write to a sibling, then rename), creating its parents.
    fn write(&self, path: &Path, bytes: &[u8]) -> io::Result<()>;
}

/// The git operations a publish needs, on the repository at `repo`.
pub trait Git {
    /// The work tree's top level that holds `dir`.
    fn toplevel(&self, dir: &Path) -> Result<PathBuf, String>;
    /// `rev` as a full commit id.
    fn resolve(&self, repo: &Path, rev: &str) -> Result<String, String>;
    /// Whether tracked files changed or untracked, unignored files exist.
    fn dirty(&self, repo: &Path) -> Result<bool, String>;
    /// Commits the work tree as it is (untracked, unignored files included) on top of `HEAD`
    /// without touching the index or `HEAD`, and points `refname` at it.
    fn snapshot(&self, repo: &Path, refname: &str, message: &str) -> Result<String, String>;
    /// `git archive <commit>` unpacked into `dest`.
    fn archive(&self, repo: &Path, commit: &str, dest: &Path) -> Result<(), String>;
}

/// One shell command to run in `dir`, its output appended to `log`.
pub struct Launch<'a> {
    pub command: &'a str,
    pub dir: &'a Path,
    /// The process's whole environment: nothing else is inherited from the caller.
    pub env: &'a [(String, String)],
    pub log: &'a Path,
}

/// Processes and ports.
pub trait Procs {
    /// Starts `launch` in a session of its own, so it outlives the shell that published it,
    /// as [`Procs::run_as`] where there is one.
    fn spawn_detached(&self, launch: &Launch<'_>) -> Result<u32, String>;
    /// Runs `launch` to completion within `limit`, as [`Procs::run_as`]; an exit other than 0
    /// or the limit is an error.
    fn run(&self, launch: &Launch<'_>, limit: Duration) -> Result<(), String>;
    fn alive(&self, pid: u32) -> bool;
    /// Ends the process group `pid` leads.
    fn stop(&self, pid: u32);
    /// A loopback port nothing listens on now.
    fn free_port(&self) -> Result<u16, String>;
    fn port_free(&self, port: u16) -> bool;
    /// The unprivileged user app processes run as, `None` when they run as the caller.
    fn run_as(&self) -> Option<String>;
}

/// Wall time, and the bounded wait between probes.
pub trait Clock {
    fn now_ms(&self) -> u64;
    fn sleep(&self, duration: Duration);
}

/// `GET path` on `127.0.0.1:port`: the status code.
pub trait Probe {
    fn get(&self, port: u16, path: &str) -> Result<u16, String>;
}

/// The platform's answer to one apps request: its status and JSON body, and the machine this
/// VM's bound install speaks for (the only machine a version may name).
#[derive(Clone, Debug, PartialEq)]
pub struct Answered {
    pub status: u16,
    pub body: Value,
    pub machine: String,
}

/// An apps request with no platform answer: `code` is the agent's (`vm.unbound`,
/// `request.invalid`) or `app.unreachable` when the answer was lost on the way.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unanswered {
    pub code: String,
    pub message: String,
}

impl Unanswered {
    /// Whether the request may have reached the platform with its answer lost.
    pub fn lost(&self) -> bool {
        self.code.ends_with(".unreachable")
    }
}

/// One request on the platform's apps routes (`/v1/cloud/apps` and under it), sent by this
/// machine's agent as its bound VM install. The agent adds the `vm-self` bearer; the caller
/// never holds it.
pub trait AppsTransport {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        idempotency_key: Option<&str>,
    ) -> Result<Answered, Unanswered>;
}

/// The process listening on a port, as this machine's agent reads it for the asking user.
pub trait Listeners {
    fn holder(&self, port: u16) -> Result<Inferred, String>;
}
