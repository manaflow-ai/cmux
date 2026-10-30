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
//! So a `serve` that launchd runs for one of these labels (`XPC_SERVICE_NAME`
//! is the label) holds its executable open from the start and looks every
//! [`RECHECK`]. Once no name links to that file any more for two looks in a
//! row (one update replaces a bundle in steps; the second look rides it out):
//!
//! - [`Outcome::Replaced`]: a file is at the program path again (an update or
//!   rebuild). The serve exits non-zero and launchd starts the new binary.
//! - [`Outcome::Removed`]: nothing is at the program path and no app bundle
//!   around it is left (the app was deleted). The agent removes its plist,
//!   when the plist still names this program, and boots its job out.
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
    file: Option<std::fs::File>,
}

impl Program {
    pub(crate) fn open(path: PathBuf) -> Self {
        let file = std::fs::File::open(&path).ok();
        Self { path, file }
    }

    pub(crate) fn look(&self) -> Look {
        use std::os::unix::fs::MetadataExt;
        let unlinked =
            self.file.as_ref().and_then(|f| f.metadata().ok()).is_some_and(|m| m.nlink() == 0);
        Look {
            unlinked,
            path_exists: self.path.exists(),
            bundle_exists: app_bundle(&self.path).is_some_and(|bundle| bundle.exists()),
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

/// Whether the plist at `plist` runs `program` (its `ProgramArguments[0]`):
/// only then is it this agent's to remove. A plist a later install wrote for
/// another program is never touched.
pub(crate) fn plist_runs(plist: &Path, program: &Path) -> bool {
    let Ok(value) = plist::Value::from_file(plist) else { return false };
    value
        .as_dictionary()
        .and_then(|d| d.get("ProgramArguments"))
        .and_then(|a| a.as_array())
        .and_then(|a| a.first())
        .and_then(|p| p.as_string())
        .is_some_and(|p| Path::new(p) == program)
}

/// Whether launchd runs this process as the job `label`.
pub(crate) fn run_by_launchd(label: &str) -> bool {
    std::env::var("XPC_SERVICE_NAME").is_ok_and(|name| name == label)
}

fn recheck() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var(TEST_RECHECK_ENV).ok().and_then(|v| v.parse::<u64>().ok()) {
        return Duration::from_millis(ms);
    }
    RECHECK
}

/// The agent `label` (plist at `plist`) for this process: `Some` only when
/// launchd runs it for that label. Opens the executable at once.
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

    fn remove(&self) {
        if plist_runs(&self.plist, &self.program.path) {
            let _ = std::fs::remove_file(&self.plist);
        }
        // SAFETY: getuid has no preconditions.
        let job = format!("gui/{}/{}", unsafe { libc::getuid() }, self.label);
        // launchd stops this process; the caller exits on its own if it does not.
        let _ = cmux_process::Command::new("/bin/launchctl")
            .args(["bootout", job.as_str()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn look(unlinked: bool, path_exists: bool, bundle_exists: bool) -> Look {
        Look { unlinked, path_exists, bundle_exists }
    }

    #[test]
    fn a_linked_program_is_never_changed() {
        assert_eq!(judge(look(false, true, true)), None);
        assert_eq!(judge(look(false, false, false)), None, "unreadable: never gone");
    }

    #[test]
    fn a_new_file_at_the_path_is_a_restart() {
        assert_eq!(judge(look(true, true, true)), Some(Outcome::Replaced));
        assert_eq!(judge(look(true, true, false)), Some(Outcome::Replaced), "~/.local/bin");
    }

    #[test]
    fn a_gone_program_and_bundle_is_a_removal_mid_update_is_not() {
        assert_eq!(judge(look(true, false, false)), Some(Outcome::Removed));
        assert_eq!(judge(look(true, false, true)), None, "the bundle is still there");
    }

    #[test]
    fn an_outcome_counts_after_two_looks_in_a_row() {
        let mut debounce = Debounce::default();
        assert_eq!(debounce.push(Some(Outcome::Removed)), None);
        assert_eq!(debounce.push(Some(Outcome::Replaced)), None, "it changed");
        assert_eq!(debounce.push(Some(Outcome::Replaced)), Some(Outcome::Replaced));
        assert_eq!(debounce.push(None), None);
        assert_eq!(debounce.push(Some(Outcome::Removed)), None);
        assert_eq!(debounce.push(Some(Outcome::Removed)), Some(Outcome::Removed));
    }

    #[test]
    fn the_bundle_is_the_app_around_the_program() {
        let exe = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
        assert_eq!(app_bundle(exe), Some(PathBuf::from("/Applications/cmux NIGHTLY.app")));
        assert_eq!(app_bundle(Path::new("/Users/a/.local/bin/cmux")), None);
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-lr-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn looks_follow_an_update_a_deletion_and_a_move() {
        let dir = scratch("look");
        let bundle = dir.join("cmux.app");
        let bin = bundle.join("Contents/Resources/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let exe = bin.join("cmux");
        std::fs::write(&exe, b"one").unwrap();
        let program = Program::open(exe.clone());
        assert_eq!(judge(program.look()), None);
        // Touched or re-signed in place: the same file.
        std::fs::write(&exe, b"one, signed").unwrap();
        assert_eq!(judge(program.look()), None);
        // An update writes a new file over the name.
        let next = bin.join("cmux.next");
        std::fs::write(&next, b"two").unwrap();
        std::fs::rename(&next, &exe).unwrap();
        assert_eq!(judge(program.look()), Some(Outcome::Replaced));
        // The app is deleted.
        let second = Program::open(exe.clone());
        std::fs::remove_dir_all(&bundle).unwrap();
        assert_eq!(judge(second.look()), Some(Outcome::Removed));
        // Moved: the file keeps a name elsewhere.
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(&exe, b"three").unwrap();
        let third = Program::open(exe.clone());
        std::fs::rename(&bundle, dir.join("moved.app")).unwrap();
        assert_eq!(judge(third.look()), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn only_a_plist_that_runs_this_program_is_removed() {
        let dir = scratch("plist");
        let plist = dir.join("agent.plist");
        let ours = Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux");
        let write = |program: &str| {
            let mut d = plist::Dictionary::new();
            d.insert(
                "ProgramArguments".into(),
                plist::Value::Array(vec![program.into(), "link".into(), "serve".into()]),
            );
            plist::Value::Dictionary(d).to_file_xml(&plist).unwrap();
        };
        write(&ours.to_string_lossy());
        assert!(plist_runs(&plist, ours));
        write("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
        assert!(!plist_runs(&plist, ours), "a later install re-pointed it");
        assert!(!plist_runs(&dir.join("missing.plist"), ours));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn only_launchd_for_this_label_runs_the_watch() {
        // The test process is no launchd job of these labels.
        assert!(!run_by_launchd("com.cmuxterm.link-test-absent"));
        assert!(for_agent("com.cmuxterm.link-test-absent", PathBuf::from("/x.plist")).is_none());
    }
}
