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

/// One version to start. This machine's agent starts it, as its unprivileged app user, never
/// as the publisher: the publisher's processes hold its credentials and reach the agent.
#[derive(Clone, Copy, Debug)]
pub struct Start<'a> {
    pub slug: &'a str,
    pub version: u32,
    /// The staged version directory (`.../apps/<slug>/v<n>`), whose `src.tar` is the source.
    pub version_dir: &'a Path,
    /// The app's directory in the source tree (`""` for its top).
    pub subdir: &'a str,
    pub command: &'a str,
    /// `service.setup`, run first in the same process, bounded.
    pub setup: Option<&'a str>,
    pub port: u16,
    /// `PATH`, `LANG`, `TZ`, the `service.env` literals, and this app's own secrets (the
    /// platform's `process-env`, held only in memory); the agent adds `HOME` and `PORT` and
    /// nothing else.
    pub env: &'a [(String, String)],
    /// A restart (rollback) runs the tree the version first started from; a fresh start
    /// replaces it with the staged archive.
    pub restart: bool,
}

/// A started version.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Started {
    pub pid: u32,
    /// The process's start time (`/proc/<pid>/stat` field 22): with the pid, its identity.
    pub start_time: u64,
    /// Where it runs, owned by the app user.
    pub run_dir: PathBuf,
    pub log: PathBuf,
    /// The account it runs as.
    pub user: String,
}

/// App processes, through this machine's agent, and loopback ports.
pub trait Procs {
    fn start(&self, start: &Start<'_>) -> Result<Started, String>;
    /// Whether the version's process still runs (the same pid and start time).
    fn alive(&self, slug: &str, version: u32) -> bool;
    /// Ends the version's process group.
    fn stop(&self, slug: &str, version: u32);
    /// A loopback port nothing listens on now.
    fn free_port(&self) -> Result<u16, String>;
    fn port_free(&self, port: u16) -> bool;
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
