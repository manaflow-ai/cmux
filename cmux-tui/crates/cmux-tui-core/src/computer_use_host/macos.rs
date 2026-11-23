//! Starting the worker on macOS when the cmux build embeds no cmux Remote (Release and
//! NIGHTLY): the Screen Sharing helper `<app> Screen Sharing.app` (executable
//! `cmux-screen-sharing`, cmux-tui/crates/cmux-rd-host) runs it in its hidden
//! `__computer-use-worker` mode. The helper is the one app of the build that holds macOS's
//! Accessibility and Screen Recording grants, so Computer Use asks for and uses those grants
//! under the helper's identity (`<app id>.screen-sharing`), never cmux's, the daemon's or an
//! agent's.
//!
//! As cmux Remote (`remote_host/macos.rs`) and the acpmux share host's helper
//! (`acpmux/src/share_host/helper.rs`), the helper never runs from inside the app bundle
//! (macOS would check the outermost app's grants): a verified copy is staged under
//! `~/Library/Application Support/cmux-next/screen-sharing/<bundle id>/computer-use/`, a slot of
//! its own beside acpmux's `daemon/` (each prunes only its own root, so neither deletes a copy
//! the other runs), checked against the source bundle's designated requirement, and started
//! with macOS responsibility disclaimed.

use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};

use super::{Launcher, WORKER_MODE, WorkerProcess};

/// The helper's executable inside its bundle.
pub(crate) const EXECUTABLE: &str = "cmux-screen-sharing";
/// Every channel's helper bundle ends with this (`cmux NIGHTLY Screen Sharing.app`).
pub(crate) const BUNDLE_SUFFIX: &str = " Screen Sharing.app";
/// A helper bundle in development (the app's `MacScreenHelper.bundled()` reads the same).
pub(crate) const HELPER_ENV: &str = "CMUX_NEXT_SCREEN_HELPER_APP";
/// This daemon's staging folder under the helper's own folder.
const SLOT: &str = "computer-use";

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
    let Ok(entries) = std::fs::read_dir(app.join("Contents/Library")) else { return Vec::new() };
    let mut found: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name().is_some_and(|name| name.to_string_lossy().ends_with(BUNDLE_SUFFIX))
                && path.join("Contents/MacOS").join(EXECUTABLE).is_file()
        })
        .collect();
    found.sort();
    found
}

/// The helper bundle to run: `env` (the development override) when set, else the first helper
/// of the app bundle holding `exe`.
pub(crate) fn find_helper(env: Option<PathBuf>, exe: &Path) -> Option<PathBuf> {
    if let Some(app) = env.filter(|path| !path.as_os_str().is_empty()) {
        return app.join("Contents/MacOS").join(EXECUTABLE).is_file().then_some(app);
    }
    let app = exe.ancestors().find(|path| path.extension().is_some_and(|ext| ext == "app"))?;
    helpers_in(app).into_iter().next()
}

/// Whether `id` is a cmux Screen Sharing helper's bundle id (`com.cmuxterm.app[.<tag>].screen-sharing`).
pub(crate) fn is_helper_bundle_id(id: &str) -> bool {
    id.strip_suffix(".screen-sharing")
        .is_some_and(|app| app == "com.cmuxterm.app" || app.starts_with("com.cmuxterm.app."))
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// This daemon's staging root for the helper with bundle id `bundle_id`.
pub(crate) fn staging_root(user_home: &Path, bundle_id: &str) -> PathBuf {
    user_home
        .join("Library/Application Support/cmux-next/screen-sharing")
        .join(bundle_id)
        .join(SLOT)
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
        let Some(helper) = find_helper(std::env::var_os(HELPER_ENV).map(PathBuf::from), &self.exe)
        else {
            note(log, &format!("no Screen Sharing helper beside {}", self.exe.display()));
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
mod tests {
    use super::*;

    /// A scratch folder for one test.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-cu-mac-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A fake helper bundle at `path`, its Info.plist naming `id`, with or without its executable.
    fn helper(path: &Path, id: &str, executable: bool) {
        let macos = path.join("Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        std::fs::write(
            path.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
                 <key>CFBundleIdentifier</key><string>{id}</string></dict></plist>\n"
            ),
        )
        .unwrap();
        if executable {
            std::fs::write(macos.join(EXECUTABLE), "#!/bin/sh\n").unwrap();
        }
    }

    #[test]
    fn the_app_bundles_first_helper_runs_the_worker() {
        let root = scratch("find");
        let app = root.join("cmux NIGHTLY.app");
        let exe = app.join("Contents/Resources/bin/cmux-tui");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        // No helper yet: nothing to run.
        assert_eq!(find_helper(None, &exe), None);
        // A bundle without the executable is no helper; a sorted first one wins.
        helper(&app.join("Contents/Library/cmux A Screen Sharing.app"), "x", false);
        helper(&app.join("Contents/Library/cmux NIGHTLY Screen Sharing.app"), "x", true);
        helper(&app.join("Contents/Library/cmux Z Screen Sharing.app"), "x", true);
        helper(&app.join("Contents/Library/Other.app"), "x", true);
        assert_eq!(
            find_helper(None, &exe),
            Some(app.join("Contents/Library/cmux NIGHTLY Screen Sharing.app"))
        );
        // A daemon outside any app bundle finds none.
        assert_eq!(find_helper(None, &root.join("bin/cmux-tui")), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_development_override_wins_only_when_it_is_a_helper() {
        let root = scratch("env");
        let app = root.join("cmux.app");
        let exe = app.join("Contents/Resources/bin/cmux-tui");
        helper(&app.join("Contents/Library/cmux Screen Sharing.app"), "x", true);
        let dev = root.join("Dev Screen Sharing.app");
        helper(&dev, "x", true);
        assert_eq!(find_helper(Some(dev.clone()), &exe), Some(dev));
        // Set but not a helper: refused, never a silent fall back to the bundled one.
        assert_eq!(find_helper(Some(root.join("missing.app")), &exe), None);
        // Empty means unset.
        assert_eq!(
            find_helper(Some(PathBuf::new()), &exe),
            Some(app.join("Contents/Library/cmux Screen Sharing.app"))
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn only_cmux_helper_ids_stage_in_their_own_slot() {
        assert!(is_helper_bundle_id("com.cmuxterm.app.screen-sharing"));
        assert!(is_helper_bundle_id("com.cmuxterm.app.nightly.screen-sharing"));
        assert!(is_helper_bundle_id("com.cmuxterm.app.debug.my-tag.screen-sharing"));
        assert!(!is_helper_bundle_id("com.cmuxterm.app"));
        assert!(!is_helper_bundle_id("com.cmuxterm.appx.screen-sharing"));
        assert!(!is_helper_bundle_id("com.example.screen-sharing"));
        assert!(!is_helper_bundle_id("com.cmuxterm.app.../x.screen-sharing"));
        assert_eq!(
            staging_root(Path::new("/Users/me"), "com.cmuxterm.app.nightly.screen-sharing"),
            Path::new(
                "/Users/me/Library/Application Support/cmux-next/screen-sharing/com.cmuxterm.app.nightly.screen-sharing/computer-use"
            )
        );
    }

    #[test]
    fn an_unsigned_or_foreign_helper_is_never_staged() {
        let root = scratch("stage");
        let home = root.join("home");
        let foreign = root.join("Foreign Screen Sharing.app");
        helper(&foreign, "com.example.screen-sharing", true);
        let error = stage(&foreign, &home).unwrap_err();
        assert!(error.contains("not a cmux Screen Sharing helper"), "{error}");
        let unsigned = root.join("cmux Screen Sharing.app");
        helper(&unsigned, "com.cmuxterm.app.screen-sharing", true);
        assert!(stage(&unsigned, &home).is_err());
        assert!(!staging_root(&home, "com.cmuxterm.app.screen-sharing").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_build_without_the_helper_says_so() {
        if std::env::var_os(HELPER_ENV).is_some() {
            return; // A development override is set on this machine.
        }
        let root = scratch("launch");
        let log = root.join("computer-use/worker.log");
        let launcher = NativeLauncher::new(root.join("cmux-tui"));
        let error = launcher.launch(&log).err().unwrap();
        assert_eq!(error, NO_HELPER);
        assert!(std::fs::read_to_string(&log).unwrap().contains("no Screen Sharing helper"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
