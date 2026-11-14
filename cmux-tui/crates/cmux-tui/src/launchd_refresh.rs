//! A launchd agent the CLI installed follows the build at its program path.
//!
//! `cmux link install-agent` (`com.cmuxterm.link`) and `cmux host enable`
//! (`com.cmuxterm.host-remote`) write a plist whose program is the `cmux`
//! that ran them, often the one inside an app bundle. launchd starts that
//! file once and keeps the process: after an update wrote a new binary at
//! the path, the agent kept serving from the old one until the next login;
//! after the app was deleted, the agent kept running (and launchd kept
//! trying to start a file that was gone) forever.
//!
//! So a `serve` that launchd runs for one of these labels (the plist's
//! [`AGENT_ENV`], or launchd's `XPC_SERVICE_NAME`, is the label) holds its
//! executable open from the start of `serve` and looks every
//! [`RECHECK`]. Once no name links to that file any more for two looks in a
//! row (one update replaces a bundle in steps; the second look rides it out):
//!
//! - [`Outcome::Replaced`]: a file is at the program path again (an update or
//!   rebuild). The serve exits non-zero and launchd starts the new binary.
//! - [`Outcome::Removed`]: nothing is at the program path and no app bundle
//!   around it (or around its symlink's target) is left: the app was deleted.
//!   The agent removes its plist when the plist still names this program,
//!   then boots its job out, waiting for launchd (which ends this process).
//!   A plist a later install rewrote is left with its job.
//!
//! A moved, touched or re-signed binary keeps its file (see
//! `acpmux`'s `daemon/app_orphan.rs` for why only the link count is read). A
//! `serve` not run by launchd for its label (a detached one, a shell's) is
//! never changed. Test seam, debug builds only: `CMUX_TUI_TEST_LAUNCHD_RECHECK_MS`.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// How often the agent looks at its executable.
pub(crate) const RECHECK: Duration = Duration::from_secs(60);
#[cfg(debug_assertions)]
const TEST_RECHECK_ENV: &str = "CMUX_TUI_TEST_LAUNCHD_RECHECK_MS";

/// What became of the agent's program.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// A new file is at the program path: restart on it.
    Replaced,
    /// The program and its app bundle are gone: remove the agent.
    Removed,
}

/// What one look saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Look {
    /// No name links to the running executable any more.
    pub(crate) unlinked: bool,
    /// A file is at the program path.
    pub(crate) path_exists: bool,
    /// An app bundle around the program path is still there (false when
    /// the program is in no bundle).
    pub(crate) bundle_exists: bool,
}

/// The outcome of one look, before the two-in-a-row rule.
pub(crate) fn judge(look: Look) -> Option<Outcome> {
    if !look.unlinked {
        return None;
    }
    if look.path_exists {
        Some(Outcome::Replaced)
    } else if look.bundle_exists {
        // A bundle with no program at the path: mid-update, look again.
        None
    } else {
        Some(Outcome::Removed)
    }
}

/// The two-in-a-row rule: an outcome counts once two looks in a row saw it.
#[derive(Debug, Default)]
pub(crate) struct Debounce {
    last: Option<Outcome>,
}

impl Debounce {
    pub(crate) fn push(&mut self, seen: Option<Outcome>) -> Option<Outcome> {
        let settled = seen.filter(|outcome| self.last == Some(*outcome));
        self.last = seen;
        settled
    }
}

/// The running program, held open from the start.
pub(crate) struct Program {
    path: PathBuf,
    /// `path` with its symlinks resolved at start (`~/.local/bin/cmux` linked into an app
    /// bundle): the bundle is looked for around this one.
    resolved: PathBuf,
    file: Option<std::fs::File>,
}

impl Program {
    pub(crate) fn open(path: PathBuf) -> Self {
        let file = std::fs::File::open(&path).ok();
        let resolved = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        Self { path, resolved, file }
    }

    /// Whether `program` (a plist's `ProgramArguments[0]`) names this program, as launched or
    /// with its links resolved.
    fn is(&self, program: &Path) -> bool {
        program == self.path || program == self.resolved
    }

    pub(crate) fn look(&self) -> Look {
        use std::os::unix::fs::MetadataExt;
        let unlinked =
            self.file.as_ref().and_then(|f| f.metadata().ok()).is_some_and(|m| m.nlink() == 0);
        Look {
            unlinked,
            path_exists: self.path.exists(),
            bundle_exists: app_bundle(&self.path)
                .or_else(|| app_bundle(&self.resolved))
                .is_some_and(|bundle| bundle.exists()),
        }
    }
}

/// The `<X>.app` around `exe` (`<X>.app/Contents/...`).
pub(crate) fn app_bundle(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))
        .map(Path::to_path_buf)
}

/// The program a plist runs (its `ProgramArguments[0]`). Only a plist that
/// runs this program is this agent's to remove: one a later install wrote
/// for another program is never touched.
pub(crate) fn plist_program(plist: &Path) -> Option<PathBuf> {
    let value = plist::Value::from_file(plist).ok()?;
    value
        .as_dictionary()
        .and_then(|d| d.get("ProgramArguments"))
        .and_then(|a| a.as_array())
        .and_then(|a| a.first())
        .and_then(|p| p.as_string())
        .map(PathBuf::from)
}

/// Set in the plists `cmux link install-agent` and `cmux host enable` write
/// (`EnvironmentVariables`): the label of the job launchd runs this process
/// for. launchd also sets `XPC_SERVICE_NAME` to the label; either one counts,
/// so an agent installed before this marker is still followed.
pub(crate) const AGENT_ENV: &str = "CMUX_LAUNCHD_AGENT";

/// Whether launchd runs this process as the job `label`.
pub(crate) fn run_by_launchd(label: &str) -> bool {
    [AGENT_ENV, "XPC_SERVICE_NAME"]
        .iter()
        .any(|key| std::env::var(key).is_ok_and(|name| name == label))
}

fn recheck() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var(TEST_RECHECK_ENV).ok().and_then(|v| v.parse::<u64>().ok()) {
        return Duration::from_millis(ms);
    }
    RECHECK
}

/// The agent `label` (plist at `plist`) for this process: `Some` only when
/// launchd runs it for that label. Opens the executable at once: call it
/// first thing in `serve`, before any setup, so an update during the setup
/// is still seen (one before the process opened its file is not).
pub(crate) fn for_agent(label: &'static str, plist: PathBuf) -> Option<Agent> {
    if !run_by_launchd(label) {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    Some(Agent { label, plist, program: Program::open(exe) })
}

/// A launchd agent's watch on its program.
pub(crate) struct Agent {
    label: &'static str,
    plist: PathBuf,
    program: Program,
}

impl Agent {
    /// Blocks until the program is replaced or removed for two looks in a
    /// row; then, for [`Outcome::Removed`], removes the plist (when it still
    /// names this program) and asks launchd to boot the job out, which stops
    /// this process.
    pub(crate) fn wait(self) -> Outcome {
        let mut debounce = Debounce::default();
        let interval = recheck();
        let outcome = loop {
            std::thread::sleep(interval);
            if let Some(outcome) = debounce.push(judge(self.program.look())) {
                break outcome;
            }
        };
        match outcome {
            Outcome::Replaced => eprintln!(
                "cmux: {} restarts on the new build at {}",
                self.label,
                self.program.path.display()
            ),
            Outcome::Removed => {
                eprintln!(
                    "cmux: {} removes itself: {} and its app are gone",
                    self.label,
                    self.program.path.display()
                );
                self.remove();
            }
        }
        outcome
    }

    /// Removes the plist, then boots the job out, waiting for launchd.
    ///
    /// The plist goes first: launchd ends this process during the bootout
    /// (SIGTERM, which `link serve` answers by returning), so nothing may be
    /// left to do after it. With the plist gone, the bootout unloads the job
    /// for good, and `KeepAlive` cannot start it again from the gone path.
    /// When the plist now runs another program, a later install owns the
    /// label (its own bootout already stopped this process, or will): this
    /// agent touches neither the plist nor the job. A plist already gone
    /// still has its loaded job booted out.
    fn remove(&self) {
        match plist_program(&self.plist) {
            Some(program) if !self.program.is(&program) => {
                eprintln!("cmux: {} belongs to another install now; left as it is", self.label);
                return;
            }
            Some(_) => {
                let _ = std::fs::remove_file(&self.plist);
            }
            None => {}
        }
        // SAFETY: getuid has no preconditions.
        let job = format!("gui/{}/{}", unsafe { libc::getuid() }, self.label);
        let booted = cmux_process::Command::new("/bin/launchctl")
            .args(["bootout", job.as_str()])
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .status();
        if let Err(error) = booted {
            eprintln!("cmux: {} could not boot itself out: {error}", self.label);
        }
    }
}

#[cfg(test)]
mod tests;
