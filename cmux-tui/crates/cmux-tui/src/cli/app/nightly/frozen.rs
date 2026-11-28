//! `cmux nightly install previous|<build>` (`cmux app use ...`) when the app cannot answer: the CLI
//! puts the kept build in place itself, with no app.
//!
//! The app's own rollback (CmuxNext `UpdateDropBack`) runs on its main actor, and `updates.builds`
//! and `updates.switch_build` are main-actor control methods: with the main thread hung (the
//! cmux#59531 beach ball, when Lawrence needed to go back a nightly) the CLI got no answer and had no
//! other way back. Leo (2026-11-28): "in addition can u guys take this thread". Here the CLI reads the
//! kept-build store (`~/Library/Application Support/cmux-next/<bundle id>/versions/<build>/<App>.app`,
//! Swift `KeptVersionStore`), makes the same checks as `RollbackDecision.decide` (the team, then every
//! store the daemons hold must be one the kept build reads), swaps the bundles as `RollbackSwap.perform`
//! does (the running build is kept, so `use next` comes forward again), records the skip and the pick
//! the app records, ends the hung app and opens the kept build. The agent daemon is not touched: the
//! kept build reconnects to it with every session, as after the app's own rollback.
//!
//! It runs with `--direct`, or by itself when the app's socket does not connect or `updates.builds`
//! gets no answer. Only kept builds: a download needs the app's Sparkle check, so a build that is not
//! kept is refused with the reason.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Target;
use crate::cli::OutputMode;
use crate::localization::NightlyMessages;

/// Store name to the newest schema version (`__store-schemas`' answer).
pub(super) type Schemas = BTreeMap<String, i64>;

/// A kept CLI's `__store-schemas` and the stored read (StoreSchemaProbe's 10 s).
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
/// How long the hung app has to exit after SIGTERM before SIGKILL.
const TERM_GRACE: Duration = Duration::from_secs(5);
/// `codesign --verify --deep --strict` of a whole bundle.
const CODESIGN_TIMEOUT: Duration = Duration::from_secs(120);
/// `RollbackSwap.stagedPrefix`: the app's launch puts back a bundle a crash left beside it.
const STAGED_PREFIX: &str = ".cmux-rollback-";
/// `UpdaterService.skipsBuildsThroughKey` and `pickedBuildKey`.
const SKIPS_KEY: &str = "cmux.next.updates.skipsBuildsThrough";
const PICKED_KEY: &str = "cmux.next.updates.pickedBuild";

/// Why the CLI rolls back without the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Reason {
    /// `--direct`.
    Asked,
    /// The socket did not connect (the error's message).
    Unreachable(String),
    /// The app connected but gave `updates.builds` no answer (the transport's message).
    NoAnswer(String),
}

/// A build in the kept store (Swift `KeptVersion`, without the team: that is checked at the pick).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Kept {
    pub build: String,
    pub short_version: String,
    pub bundle: PathBuf,
    /// Its Info.plist `CmuxStoreSchemas`; nil: its CLI is asked once its team checks out.
    pub schemas: Option<Schemas>,
    /// `kept.json`'s `keptAt` (ISO 8601, UTC: it sorts as text).
    pub kept_at: Option<String>,
}

/// Why no rollback ran (Swift `RollbackRefusal`, plus the CLI's own).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Refusal {
    NoApp,
    NothingKept,
    NothingOlder { running: String },
    NotKept { build: String },
    Installed { build: String },
    Signature { kept: String },
    Predates { kept: String },
    StoreTooNew { kept: String, store: String },
    UnknownStore { kept: String, store: String },
    StoresUnknown,
    SparkleWaits,
    Swap { error: String },
}

impl Refusal {
    pub(super) fn code(&self) -> &'static str {
        match self {
            Self::NoApp => "nightly.direct_no_app",
            Self::NothingKept => "nightly.nothing_kept",
            Self::NothingOlder { .. } => "nightly.no_previous",
            Self::NotKept { .. } => "nightly.not_kept",
            Self::Installed { .. } => "nightly.installed",
            Self::Signature { .. } => "nightly.signature",
            Self::Predates { .. } => "nightly.predates_rollback",
            Self::StoreTooNew { .. } => "nightly.store_too_new",
            Self::UnknownStore { .. } => "nightly.unknown_store",
            Self::StoresUnknown => "nightly.stores_unknown",
            Self::SparkleWaits => "nightly.staged_update_waits",
            Self::Swap { .. } => "nightly.swap_failed",
        }
    }

    pub(super) fn message(&self, messages: &NightlyMessages) -> String {
        match self {
            Self::NoApp => messages.direct_no_app.to_owned(),
            Self::NothingKept => messages.direct_nothing_kept.to_owned(),
            Self::NothingOlder { running } => messages.no_previous.replace("{build}", running),
            Self::NotKept { build } => messages.direct_not_kept.replace("{build}", build),
            Self::Installed { build } => messages.installed_already.replace("{build}", build),
            Self::Signature { kept } => messages.direct_signature.replace("{kept}", kept),
            Self::Predates { kept } => messages.direct_predates.replace("{kept}", kept),
            Self::StoreTooNew { kept, store } => {
                messages.direct_store_too_new.replace("{kept}", kept).replace("{store}", store)
            }
            Self::UnknownStore { kept, store } => {
                messages.direct_unknown_store.replace("{kept}", kept).replace("{store}", store)
            }
            Self::StoresUnknown => messages.direct_stores_unknown.to_owned(),
            Self::SparkleWaits => messages.direct_sparkle_waits.to_owned(),
            Self::Swap { error } => messages.direct_swap_failed.replace("{error}", error),
        }
    }
}

/// The running app on disk: its bundle, build and bundle id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Running {
    pub bundle: PathBuf,
    pub build: String,
    pub bundle_id: String,
    /// `CFBundleExecutable`: the process to end is `<bundle>/Contents/MacOS/<this>`.
    pub executable: String,
}

impl Running {
    pub(super) fn read(bundle: &Path) -> Option<Self> {
        let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
        let dictionary = info.as_dictionary()?;
        let text = |key: &str| {
            dictionary.get(key).and_then(plist::Value::as_string).map(str::trim).map(str::to_owned)
        };
        let bundle_id = text("CFBundleIdentifier")
            .filter(|id| id.starts_with(cmux_cloud_config::config::RELEASE_BUNDLE_ID))?;
        Some(Self {
            bundle: bundle.to_path_buf(),
            build: text("CFBundleVersion").filter(|build| !build.is_empty())?,
            executable: text("CFBundleExecutable").unwrap_or_else(|| "cmux".to_owned()),
            bundle_id,
        })
    }

    /// The kept-build store (`UpdaterService.keptVersions`).
    pub(super) fn store(&self, home: &Path) -> PathBuf {
        home.join("Library/Application Support/cmux-next").join(&self.bundle_id).join("versions")
    }
}

/// Every kept build under `root` (`KeptVersionStore.list`): a folder per build holding one `.app`
/// that is not mid-swap (no leading `.`), newest number first.
pub(super) fn list_kept(root: &Path) -> Vec<Kept> {
    let Ok(folders) = std::fs::read_dir(root) else { return Vec::new() };
    let mut kept: Vec<Kept> = folders
        .flatten()
        .filter_map(|folder| {
            let folder = folder.path();
            let app = std::fs::read_dir(&folder).ok()?.flatten().map(|entry| entry.path()).find(
                |path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.ends_with(".app") && !name.starts_with('.'))
                },
            )?;
            let info = plist::Value::from_file(app.join("Contents/Info.plist")).ok();
            let dictionary = info.as_ref().and_then(plist::Value::as_dictionary);
            let text = |key: &str| {
                dictionary?.get(key).and_then(plist::Value::as_string).map(str::to_owned)
            };
            let folder_name = folder.file_name()?.to_str()?.to_owned();
            let build = text("CFBundleVersion").unwrap_or_else(|| folder_name.clone());
            let schemas = dictionary
                .and_then(|d| d.get("CmuxStoreSchemas"))
                .and_then(plist::Value::as_dictionary)
                .map(|stores| {
                    stores
                        .iter()
                        .filter_map(|(store, version)| {
                            let version = version
                                .as_signed_integer()
                                .or_else(|| version.as_unsigned_integer().map(|v| v as i64))?;
                            Some((store.clone(), version))
                        })
                        .collect()
                });
            let kept_at = std::fs::read(folder.join("kept.json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .and_then(|record| record.get("keptAt")?.as_str().map(str::to_owned));
            Some(Kept {
                short_version: text("CFBundleShortVersionString").unwrap_or_else(|| build.clone()),
                build,
                bundle: app,
                schemas,
                kept_at,
            })
        })
        .collect();
    kept.sort_by(|a, b| super::order(&b.build, &a.build));
    kept
}

/// `RollbackDecision.previous`: of the kept builds older than `running`, the one kept most recently
/// (the build this Mac updated from); builds with no keep date after those with one, the newest
/// number first.
pub(super) fn previous<'a>(kept: &'a [Kept], running: &str) -> Option<&'a Kept> {
    kept.iter().filter(|kept| super::older(&kept.build, running)).min_by(|a, b| {
        match (&a.kept_at, &b.kept_at) {
            (Some(x), Some(y)) if x != y => y.cmp(x),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            _ => super::order(&b.build, &a.build),
        }
    })
}

/// What [`decide`] reads from the system, so the rules run in tests with no Mac.
pub(super) trait Checks {
    /// The Developer ID team of `bundle` after a full check of every file, else nil.
    fn team(&self, bundle: &Path) -> Option<String>;
    /// The running bundle's team (no full check: it is the code that is running).
    fn running_team(&self, bundle: &Path) -> Option<String>;
    /// The store schemas a kept build reads, from its own CLI.
    fn readable(&self, bundle: &Path) -> Option<Schemas>;
    /// The newest schema of each store the daemons hold; nil when any root cannot be read.
    fn stored(&self) -> Option<Schemas>;
}

/// `RollbackDecision.decide` with the inputs `UpdaterService.rollbackInputs` reads: the target
/// (`build`, else [`previous`]), its team equal to the running one, then every stored store one
/// it reads at that version or newer. The kept CLI runs only after its team checks out.
pub(super) fn decide(
    kept: &[Kept],
    target: &Target,
    running: &Running,
    checks: &dyn Checks,
) -> Result<Kept, Refusal> {
    let picked = match target {
        Target::Build(build) if *build == running.build => {
            return Err(Refusal::Installed { build: build.clone() });
        }
        Target::Build(build) => kept
            .iter()
            .find(|kept| kept.build == *build)
            .ok_or_else(|| Refusal::NotKept { build: build.clone() })?,
        _ if kept.is_empty() => return Err(Refusal::NothingKept),
        _ => previous(kept, &running.build)
            .ok_or_else(|| Refusal::NothingOlder { running: running.build.clone() })?,
    };
    let label = picked.short_version.clone();
    let team = checks.running_team(&running.bundle).filter(|team| !team.is_empty());
    if team.is_none() || checks.team(&picked.bundle) != team {
        return Err(Refusal::Signature { kept: label });
    }
    let readable = picked
        .schemas
        .clone()
        .or_else(|| checks.readable(&picked.bundle))
        .ok_or_else(|| Refusal::Predates { kept: label.clone() })?;
    let stored = checks.stored().ok_or(Refusal::StoresUnknown)?;
    for (store, version) in &stored {
        match readable.get(store) {
            None => {
                return Err(Refusal::UnknownStore { kept: label, store: store.clone() });
            }
            Some(reads) if version > reads => {
                return Err(Refusal::StoreTooNew { kept: label, store: store.clone() });
            }
            Some(_) => {}
        }
    }
    Ok(picked.clone())
}

/// `RollbackSwap.perform` without the app: the kept bundle goes beside the running one under a
/// staged name, the two swap in one rename (`renamex_np(RENAME_SWAP)`, or two renames where there is
/// none), and the build that ran is kept in the store with a `kept.json` carrying `build` and `keptAt`
/// (no MAC: the app gives it a full signature check before trusting it). On a failure the kept
/// bundle goes back where it was.
pub(super) fn swap(
    current: &Path,
    running_build: &str,
    target: &Kept,
    store: &Path,
    now: &str,
) -> Result<(), String> {
    let name = current.file_name().ok_or("the app has no file name")?.to_owned();
    let folder = current.parent().ok_or("the app has no folder")?;
    let staged = folder.join(format!(
        "{STAGED_PREFIX}{}-{}-{}",
        target.build,
        std::process::id(),
        name.to_string_lossy()
    ));
    std::fs::rename(&target.bundle, &staged)
        .map_err(|error| move_error(&target.bundle, &staged, &error))?;
    let home = store.join(running_build);
    let kept_running = home.join(&name);
    let put_back = |error: String| {
        let _ = std::fs::rename(&staged, &target.bundle);
        error
    };
    if let Err(error) = std::fs::create_dir_all(&home) {
        return Err(put_back(error.to_string()));
    }
    // An earlier copy of this same build in the store gives way to the one that ran.
    if kept_running.exists() {
        if let Err(error) = std::fs::remove_dir_all(&kept_running) {
            return Err(put_back(error.to_string()));
        }
    }
    swap_in(current, &staged, &kept_running).map_err(put_back)?;
    let record = json!({ "build": running_build, "keptAt": now });
    let _ = std::fs::write(home.join("kept.json"), record.to_string());
    // The kept build's folder is empty now (its record went with it).
    if let Some(left) = target.bundle.parent() {
        let _ = std::fs::remove_file(left.join("kept.json"));
        let _ = std::fs::remove_dir(left);
    }
    Ok(())
}

/// `staged` takes `current`'s place and the bundle that was there goes to `kept`.
fn swap_in(current: &Path, staged: &Path, kept: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt as _;
        let c = |path: &Path| {
            std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())
        };
        let (from, to) = (c(staged)?, c(current)?);
        let mut attempts = 0;
        loop {
            // SAFETY: two NUL-terminated paths that live past the call.
            let status = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_SWAP) };
            if status == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            attempts += 1;
            if error.kind() == std::io::ErrorKind::Interrupted && attempts < 4 {
                continue;
            }
            return Err(move_error(staged, current, &error));
        }
        // `staged` now names the build that ran.
        std::fs::rename(staged, kept).map_err(|error| {
            // Swap back, so the app that ran is the one in place and the kept build is staged again.
            // SAFETY: as above.
            let _ = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_SWAP) };
            move_error(staged, kept, &error)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::rename(current, kept).map_err(|error| move_error(current, kept, &error))?;
        std::fs::rename(staged, current).map_err(|error| {
            let _ = std::fs::rename(kept, current);
            move_error(staged, current, &error)
        })
    }
}

fn move_error(from: &Path, to: &Path, error: &std::io::Error) -> String {
    format!("{} -> {}: {error}", from.display(), to.display())
}

/// The real checks: `codesign`, the kept build's CLI, the running CLI's `--stored`.
struct System {
    running_cli: PathBuf,
    state_dirs: Vec<Option<PathBuf>>,
}

impl Checks for System {
    fn team(&self, bundle: &Path) -> Option<String> {
        let verified = output(
            cmux_process::Command::new("/usr/bin/codesign")
                .args(["--verify", "--deep", "--strict"])
                .arg(bundle),
            CODESIGN_TIMEOUT,
        )?;
        verified.status.success().then(|| self.running_team(bundle)).flatten()
    }

    fn running_team(&self, bundle: &Path) -> Option<String> {
        let shown = output(
            cmux_process::Command::new("/usr/bin/codesign").args(["-d", "--verbose=2"]).arg(bundle),
            PROBE_TIMEOUT,
        )?;
        team_identifier(&String::from_utf8_lossy(&shown.stderr))
    }

    fn readable(&self, bundle: &Path) -> Option<Schemas> {
        let mut command = cmux_process::Command::new(bundle.join("Contents/Resources/bin/cmux"));
        command.arg("__store-schemas");
        schemas(&String::from_utf8_lossy(&ok_output(&mut command)?))
    }

    fn stored(&self) -> Option<Schemas> {
        let mut newest = Schemas::new();
        for directory in &self.state_dirs {
            let mut command = cmux_process::Command::new(&self.running_cli);
            command.args(["__store-schemas", "--stored"]);
            match directory {
                Some(directory) => command.env("CMUX_TUI_STATE_DIR", directory),
                None => command.env_remove("CMUX_TUI_STATE_DIR"),
            };
            for (store, version) in schemas(&String::from_utf8_lossy(&ok_output(&mut command)?))? {
                let entry = newest.entry(store).or_insert(version);
                *entry = (*entry).max(version);
            }
        }
        Some(newest)
    }
}

/// `TeamIdentifier=ABCDE12345` of `codesign -d --verbose=2`; nil for "not set" (ad hoc).
pub(super) fn team_identifier(text: &str) -> Option<String> {
    text.lines()
        .find_map(|line| line.strip_prefix("TeamIdentifier="))
        .map(str::trim)
        .filter(|team| !team.is_empty() && *team != "not set")
        .map(str::to_owned)
}

/// One JSON object of integers (`__store-schemas`' answer), else nil (a `not_ready` answer too).
pub(super) fn schemas(text: &str) -> Option<Schemas> {
    let object = serde_json::from_str::<Value>(text.trim()).ok()?;
    object
        .as_object()?
        .iter()
        .map(|(store, version)| Some((store.clone(), version.as_i64()?)))
        .collect()
}

fn ok_output(command: &mut cmux_process::Command) -> Option<Vec<u8>> {
    let done = output(command, PROBE_TIMEOUT)?;
    done.status.success().then_some(done.stdout)
}

/// Runs `command` to its end or `timeout` (then it is killed: nil). Its output goes to two
/// unnamed temporary files, read back once it ended, so no reader thread runs beside it.
fn output(command: &mut cmux_process::Command, timeout: Duration) -> Option<cmux_process::Output> {
    use std::io::{Read, Seek};
    let mut stdout = tempfile::tempfile().ok()?;
    let mut stderr = tempfile::tempfile().ok()?;
    let mut child = command
        .stdin(cmux_process::Stdio::null())
        .stdout(stdout.try_clone().ok()?)
        .stderr(stderr.try_clone().ok()?)
        .spawn()
        .ok()?;
    let Ok(Some(status)) = child.wait_timeout(timeout) else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let read = |file: &mut std::fs::File| {
        file.rewind().ok()?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).ok()?;
        Some(bytes)
    };
    Some(cmux_process::Output { status, stdout: read(&mut stdout)?, stderr: read(&mut stderr)? })
}

/// Whether Sparkle staged an update for this app: its installer would put that build over the
/// swap once the app quits (cmux#41013 review F2; the app cancels it first, the CLI cannot). Read
/// from the staged folder on disk, never from a process list (cmux-next scans no processes).
pub(super) fn sparkle_waits(running: &Running, home: &Path) -> bool {
    let installation = home
        .join("Library/Caches")
        .join(&running.bundle_id)
        .join("org.sparkle-project.Sparkle/Installation");
    std::fs::read_dir(installation).is_ok_and(|mut entries| entries.next().is_some())
}

/// Ends `pids` (SIGTERM, then SIGKILL after [`TERM_GRACE`]); true when none is left.
fn end(pids: &[i32]) -> bool {
    let alive = |pid: i32| unsafe { libc::kill(pid, 0) } == 0;
    let wait = |deadline: Instant| {
        while pids.iter().any(|pid| alive(*pid)) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
    };
    for pid in pids {
        // SAFETY: a signal to the pid behind the app's socket, read a moment ago.
        unsafe { libc::kill(*pid, libc::SIGTERM) };
    }
    wait(Instant::now() + TERM_GRACE);
    for pid in pids.iter().filter(|pid| alive(**pid)) {
        // SAFETY: as above; the main thread is hung, so SIGTERM may never be handled.
        unsafe { libc::kill(*pid, libc::SIGKILL) };
    }
    wait(Instant::now() + Duration::from_secs(3));
    !pids.iter().any(|pid| alive(*pid))
}

fn now_iso8601() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    iso8601(seconds)
}

/// `YYYY-MM-DDTHH:MM:SSZ` of `seconds` since 1970 (the app's `JSONEncoder` `.iso8601`).
pub(super) fn iso8601(seconds: u64) -> String {
    let (days, rest) = ((seconds / 86_400) as i64, seconds % 86_400);
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// Whether this CLI runs from inside a cmux app bundle (else there is nothing to swap, and the
/// app's own error is the answer).
pub(super) fn in_app() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|exe| crate::app_identity::containing_app_bundle(&exe))
        .and_then(|bundle| Running::read(&bundle))
        .is_some()
}

/// Rolls back to `target` with no app. Exit 0 when the kept build was put in place and opened.
/// `app_pid` is the pid behind the app's control socket (`LOCAL_PEERPID`), when it connected: the
/// process to end. Without it the swap still happens and the person is told to quit the app.
pub(super) fn run(
    target: &Target,
    reason: &Reason,
    app_pid: Option<u32>,
    output_mode: OutputMode,
) -> i32 {
    let messages = &crate::localization::catalog().app_control.nightly;
    let human = output_mode == OutputMode::Human;
    let say = |line: String| {
        if human {
            eprintln!("{line}");
        }
    };
    match reason {
        Reason::Asked => {}
        Reason::Unreachable(error) => say(messages.direct_unreachable.replace("{error}", error)),
        Reason::NoAnswer(error) => say(messages.direct_no_answer.replace("{error}", error)),
    }
    let refuse =
        |refusal: Refusal| super::failure(refusal.code(), &refusal.message(messages), output_mode);
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let exe = std::env::current_exe().ok();
    let Some(running) = exe
        .as_deref()
        .and_then(crate::app_identity::containing_app_bundle)
        .and_then(|bundle| Running::read(&bundle))
    else {
        return refuse(Refusal::NoApp);
    };
    let cwd = std::env::current_dir().unwrap_or_default();
    let identity = crate::app_identity::AppIdentity::from_bundle(exe.as_deref());
    let checks = System {
        running_cli: running.bundle.join("Contents/Resources/bin/cmux"),
        state_dirs: vec![
            identity.as_ref().and_then(|identity| identity.daemon_state_dir_in(&home)),
            Some(crate::cli::chief::conversation_state_dir(&home, &cwd)),
        ],
    };
    let store = running.store(&home);
    let kept = list_kept(&store);
    let picked = match decide(&kept, target, &running, &checks) {
        Ok(picked) => picked,
        Err(refusal) => return refuse(refusal),
    };
    if sparkle_waits(&running, &home) {
        return refuse(Refusal::SparkleWaits);
    }
    say(messages
        .direct_swapping
        .replace("{build}", &picked.build)
        .replace("{version}", &picked.short_version)
        .replace("{from}", &running.build));
    if let Err(error) = swap(&running.bundle, &running.build, &picked, &store, &now_iso8601()) {
        return refuse(Refusal::Swap { error });
    }
    // The build left behind is not offered again, and a newer one waits for a click (`swapForRollback`).
    for (key, value) in [(SKIPS_KEY, &running.build), (PICKED_KEY, &picked.build)] {
        let _ = output(
            cmux_process::Command::new("/usr/bin/defaults").args([
                "write",
                &running.bundle_id,
                key,
                "-string",
                value,
            ]),
            PROBE_TIMEOUT,
        );
    }
    let pids: Vec<i32> = app_pid.and_then(|pid| i32::try_from(pid).ok()).into_iter().collect();
    let ended = !pids.is_empty() && end(&pids);
    if !ended {
        say(messages.direct_still_running.to_owned());
    }
    let opened = ended
        && output(cmux_process::Command::new("/usr/bin/open").arg(&running.bundle), PROBE_TIMEOUT)
            .is_some_and(|done| done.status.success());
    let now = Running::read(&running.bundle).map(|now| now.build);
    if now.as_deref() != Some(picked.build.as_str()) {
        let found = now.unwrap_or_default();
        return super::failure(
            "nightly.replaced",
            &messages.direct_replaced.replace("{build}", &picked.build).replace("{found}", &found),
            output_mode,
        );
    }
    if !opened && ended {
        say(messages.direct_open_failed.replace("{app}", &running.bundle.display().to_string()));
    }
    let answer = json!({
        "rolled_back_to": picked.build,
        "version": picked.short_version,
        "from": running.build,
        "direct": true,
        "app_ended": ended,
        "opened": opened,
    });
    if human {
        println!(
            "{}",
            messages
                .direct_done
                .replace("{build}", &picked.build)
                .replace("{from}", &running.build)
        );
        return if opened { 0 } else { 1 };
    }
    let code = crate::cli::wire::print_local_success(&answer, output_mode);
    if opened { code } else { 1 }
}

#[cfg(test)]
#[path = "frozen_tests.rs"]
mod tests;
