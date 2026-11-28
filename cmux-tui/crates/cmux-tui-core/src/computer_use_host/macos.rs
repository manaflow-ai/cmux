//! Starting the worker on macOS when the cmux build embeds no cmux Remote (Release and
//! NIGHTLY): the build's helper `<app> Helper.app` (`<app> Screen Sharing.app` before it;
//! executable `cmux-screen-sharing`, cmux-tui/crates/cmux-rd-host) runs it in its hidden
//! `__computer-use-worker` mode. The helper is the one app of the build that holds macOS's
//! Accessibility and Screen Recording grants, so Computer Use asks for and uses those grants
//! under the helper's identity (`<app id>.screen-sharing`), never cmux's, the daemon's or an
//! agent's.
//!
//! As the acpmux share host's helper (`acpmux/src/share_host/helper.rs`) and the app's
//! `SignedHelperStaging`, the helper never runs from inside the app bundle (macOS would check
//! the outermost app's grants): one verified copy per bundle id lives at the fixed path
//! `~/Library/Application Support/cmux-next/helper/<bundle id>/<bundle name>.app`
//! (`cmux_signed_bundle::helper_folder`), shared by every stager under the folder's lock,
//! replaced in place when a build's helper differs, checked against the source bundle's
//! designated requirement, and started with macOS responsibility disclaimed. One path for
//! every build is what keeps macOS from asking again after an update: it keeps a
//! screen-capture approval per executable path.

use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};

use super::{Launcher, WORKER_MODE, WorkerProcess};

/// The helper's executable inside its bundle.
pub(crate) const EXECUTABLE: &str = "cmux-screen-sharing";
/// A helper bundle in development (the app's `MacScreenHelper.bundled()` reads the same).
pub(crate) const HELPER_ENV: &str = "CMUX_NEXT_SCREEN_HELPER_APP";
/// This daemon's folder of the per-digest layout before the fixed path
/// (`.../cmux-next/screen-sharing/<bundle id>/computer-use/<16 hex>/`), removed once.
const LEGACY_SLOT: &str = "computer-use";

/// The reason the endpoint and status show when the build carries no helper.
pub(crate) const NO_HELPER: &str =
    "This cmux build can't run Computer Use. Install the latest cmux.";
/// The reason when the helper could not be copied out of the app or failed its signature check.
pub(crate) const NOT_STAGED: &str = "cmux couldn't start Computer Use. Restart cmux.";

pub(crate) struct NativeLauncher {
    /// This daemon's own executable (the app's `Contents/Resources/bin/cmux-tui`).
    exe: PathBuf,
}

impl NativeLauncher {
    pub(crate) fn new(exe: PathBuf) -> Self {
        Self { exe }
    }
}

/// The helper bundles `app` carries in `Contents/Library`, sorted (as the app's
/// `MacScreenHelper.bundled()` picks the first).
pub(crate) fn helpers_in(app: &Path) -> Vec<PathBuf> {
    cmux_signed_bundle::helpers_in(app, EXECUTABLE)
}

/// The helper bundle to run: `env` (the development override) when set, else the first helper
/// of the app bundle holding `exe`, else of the installed apps (`installed`, in order), as the
/// acpmux share host searches (`cmux_signed_bundle::search_apps`). A daemon outside any app
/// (acpmux, a standalone cmux-tui) so runs in the one stably signed helper, never as its own
/// bare binary, a separate macOS permission entry that loses its grant on every update.
pub(crate) fn find_helper(env: Option<PathBuf>, exe: &Path, installed: &[&str]) -> Option<PathBuf> {
    if let Some(app) = env.filter(|path| !path.as_os_str().is_empty()) {
        return app.join("Contents/MacOS").join(EXECUTABLE).is_file().then_some(app);
    }
    cmux_signed_bundle::first_helper(&cmux_signed_bundle::search_apps(exe, installed), EXECUTABLE)
}

/// Whether `id` is a cmux Screen Sharing helper's bundle id (`com.cmuxterm.app[.<tag>].screen-sharing`).
pub(crate) fn is_helper_bundle_id(id: &str) -> bool {
    id.strip_suffix(".screen-sharing")
        .is_some_and(|app| app == "com.cmuxterm.app" || app.starts_with("com.cmuxterm.app."))
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// The folder of the helper with bundle id `bundle_id`'s one copy, shared with the acpmux
/// share host and the app.
pub(crate) fn staging_root(user_home: &Path, bundle_id: &str) -> PathBuf {
    cmux_signed_bundle::helper_folder(user_home, bundle_id)
}

/// This daemon's folder of the old per-digest layout, and the folder its cleanup stops at.
fn legacy_root(user_home: &Path, bundle_id: &str) -> (PathBuf, PathBuf) {
    let support = user_home.join("Library/Application Support/cmux-next");
    (support.join("screen-sharing").join(bundle_id).join(LEGACY_SLOT), support)
}

/// A verified copy of `helper` outside the app; its executable.
pub(crate) fn stage(helper: &Path, user_home: &Path) -> Result<PathBuf, String> {
    let id = cmux_signed_bundle::bundle_id(helper).ok_or("the bundle has no identifier")?;
    if !is_helper_bundle_id(&id) {
        return Err(format!("{id} is not a cmux Screen Sharing helper"));
    }
    // The copy must be the source's own code, signed as the source is (a DEV build's too).
    let requirement = cmux_signed_bundle::designated_requirement(helper)?;
    let parts = cmux_signed_bundle::digest_parts(EXECUTABLE);
    let staged =
        cmux_signed_bundle::stage(helper, &staging_root(user_home, &id), &parts, |copy| {
            cmux_signed_bundle::verify(copy, &requirement)
        })?;
    let (legacy, stop) = legacy_root(user_home, &id);
    cmux_signed_bundle::remove_legacy_root(&legacy, &stop);
    Ok(staged.executable(EXECUTABLE))
}

/// Appends one line to the worker's log (why it did not start), best effort.
fn note(log: &Path, line: &str) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log) {
        let _ = writeln!(file, "cmux-tui: {line}");
    }
}

impl Launcher for NativeLauncher {
    fn launch(&self, log: &Path) -> Result<WorkerProcess, String> {
        if let Some(dir) = log.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let Some(helper) = find_helper(
            std::env::var_os(HELPER_ENV).map(PathBuf::from),
            &self.exe,
            &cmux_signed_bundle::INSTALLED_APPS,
        ) else {
            note(
                log,
                &format!(
                    "no Screen Sharing helper beside {} or in the installed apps",
                    self.exe.display()
                ),
            );
            return Err(NO_HELPER.into());
        };
        let user_home = crate::platform::home_dir().ok_or(NOT_STAGED)?;
        let executable = stage(&helper, &user_home).map_err(|why| {
            note(log, &format!("{} was not staged: {why}", helper.display()));
            eprintln!("cmux-tui: Computer Use helper {} was not staged: {why}", helper.display());
            NOT_STAGED.to_string()
        })?;
        let log_file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .map_err(|error| format!("{}: {error}", log.display()))?;
        let mut command = Command::new(&executable);
        command
            .arg(WORKER_MODE)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log_file))
            // Its own session: a terminal's Ctrl-C to the daemon's group does not reach it.
            .new_session()
            // Its own responsible process: macOS checks the helper's grants, never cmux's.
            .disclaim_responsibility();
        command.env("HOME", &user_home);
        for name in ["USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let mut child = command
            .spawn()
            .map_err(|error| format!("the Computer Use worker did not start: {error}"))?;
        let input = child.stdin.take().ok_or("the worker has no stdin")?;
        let output = child.stdout.take().ok_or("the worker has no stdout")?;
        Ok(WorkerProcess {
            input: Box::new(input),
            output: Box::new(output),
            reap: Box::new(move || {
                let _ = child.wait();
            }),
        })
    }
}

#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;
