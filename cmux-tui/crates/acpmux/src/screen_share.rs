//! Screen sharing on this machine as a join leaves it (cmuxterm-hq
//! docs/design/remote-screen-share-zero-touch.md, Z3): the Screen Sharing helper of cmux#44069
//! (`<app> Screen Sharing.app`, bundle id `<app id>.screen-sharing`) installed at a stable path
//! beside this daemon's state, outside any app bundle, and the one status every surface reads
//! (`cmux.screen-share.status/1`): `granted`, `needs_grant` (with `missing`), `not_installed`,
//! `unsupported`.
//!
//! The helper is the one holder of Screen Recording and Accessibility for screen sharing. Its
//! grants are read from a fresh helper process (`permissions`), started with responsibility
//! disclaimed so macOS checks the helper and never the process that asked: a long-running
//! process can keep an old answer after the grant changes. The status is read again at daemon
//! start, whenever the OS version differs from the one it was read on, and on every
//! `cmux share prepare`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const SCHEMA: &str = "cmux.screen-share.status/1";

/// The folder under the daemon's home that holds the installed helper and the last status.
pub const DIR: &str = "screen-sharing";
const HELPER_RECORD: &str = "helper.json";
const STATUS_RECORD: &str = "status.json";

/// The helper's executable inside its bundle (cmux#44069 `MacScreenHelper.executableName`).
pub const EXECUTABLE: &str = "cmux-screen-sharing";
/// Every channel's helper bundle ends with this (`cmux NIGHTLY Screen Sharing.app`).
pub const BUNDLE_SUFFIX: &str = " Screen Sharing.app";

/// The apps whose helper is installed, in order, after the app holding this binary and
/// `CMUX_SCREEN_HELPER_APP` (a helper bundle itself).
const APPS: [&str; 2] = ["/Applications/cmux NIGHTLY.app", "/Applications/cmux.app"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Granted,
    NeedsGrant,
    NotInstalled,
    Unsupported,
}

/// A macOS grant the helper holds, as the helper's `permissions` line names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Grant {
    ScreenRecording,
    Accessibility,
}

impl Grant {
    /// The name System Settings shows under Privacy & Security.
    pub fn title(self) -> &'static str {
        match self {
            Self::ScreenRecording => "Screen Recording",
            Self::Accessibility => "Accessibility",
        }
    }

    /// The System Settings pane that lists this grant.
    pub fn settings_url(self) -> &'static str {
        match self {
            Self::ScreenRecording => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            }
            Self::Accessibility => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
        }
    }
}

/// Who has the screen: capture needs a logged-in GUI session of this user.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Session {
    /// This user is logged in at the screen.
    ThisUser,
    /// Another user is at the screen (fast user switching).
    OtherUser,
    /// Nobody is logged in: the login window.
    Nobody,
    /// Not a Mac, or the console could not be read.
    Unknown,
}

/// `cmux.screen-share.status/1`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub schema: String,
    pub state: State,
    /// The grants the helper lacks; empty unless `needs_grant`.
    #[serde(default)]
    pub missing: Vec<Grant>,
    /// The name System Settings lists for the holder (`cmux NIGHTLY Screen Sharing`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder: Option<String>,
    /// The installed helper bundle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub helper: Option<PathBuf>,
    pub session: Session,
    /// `sw_vers` product version and build the grants were read on (`26.1 (25B78)`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    /// When it was read, ms since the epoch.
    pub checked_at_ms: u64,
    /// One line for a person, naming the holder and what is missing.
    pub detail: String,
}

/// The helper's `permissions` line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
pub struct Permissions {
    pub screen_recording: bool,
    pub accessibility: bool,
}

/// The installed helper (`helper.json`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Installed {
    /// The bundle: `<home>/screen-sharing/<bundle id>/<name>.app`.
    pub app: PathBuf,
    pub bundle_id: String,
    /// What System Settings lists (the bundle name without `.app`).
    pub name: String,
    /// Content digest of the signed bundle (executable, seal, Info.plist).
    pub digest: String,
    /// The app bundle it was copied from.
    pub source: PathBuf,
}

impl Installed {
    pub fn executable(&self) -> PathBuf {
        self.app.join("Contents/MacOS").join(EXECUTABLE)
    }
}

/// What a status was made from: everything [`classify`] needs, none of it read here.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    pub mac: bool,
    pub installed: Option<Installed>,
    /// Why no helper is installed, when one is not.
    pub install_error: Option<String>,
    /// The helper's answer, or why there is none.
    pub probe: Option<Result<Permissions, String>>,
    pub session: Option<Session>,
    pub os_version: Option<String>,
    pub now_ms: u64,
}

/// The status of `facts`. Pure: every read happens in [`read`].
pub fn classify(facts: Facts) -> Status {
    let session = facts.session.unwrap_or(Session::Unknown);
    let mut status = Status {
        schema: SCHEMA.to_owned(),
        state: State::Unsupported,
        missing: Vec::new(),
        holder: facts.installed.as_ref().map(|i| i.name.clone()),
        helper: facts.installed.as_ref().map(|i| i.app.clone()),
        session,
        os_version: facts.os_version,
        checked_at_ms: facts.now_ms,
        detail: String::new(),
    };
    if !facts.mac {
        status.detail =
            "screen sharing grants are a macOS matter; this machine is not a Mac".into();
        return status;
    }
    let (state, detail) = match (&facts.installed, &facts.probe) {
        (None, _) => (
            State::NotInstalled,
            format!(
                "the Screen Sharing helper is not installed: {}",
                facts.install_error.as_deref().unwrap_or("no cmux app here carries it")
            ),
        ),
        (Some(installed), None | Some(Err(_))) => {
            let why = match &facts.probe {
                Some(Err(why)) => why.as_str(),
                _ => "it was not asked",
            };
            (State::NotInstalled, format!("{} did not answer: {why}", installed.name))
        }
        (Some(installed), Some(Ok(permissions))) => {
            let missing: Vec<Grant> = [
                (Grant::ScreenRecording, permissions.screen_recording),
                (Grant::Accessibility, permissions.accessibility),
            ]
            .into_iter()
            .filter(|(_, held)| !held)
            .map(|(grant, _)| grant)
            .collect();
            if missing.is_empty() {
                (
                    State::Granted,
                    format!("{} has Screen Recording and Accessibility", installed.name),
                )
            } else {
                let titles = missing.iter().map(|g| g.title()).collect::<Vec<_>>().join(" and ");
                status.missing = missing;
                (
                    State::NeedsGrant,
                    format!("allow {} under Privacy & Security > {titles}", installed.name),
                )
            }
        }
    };
    status.state = state;
    status.detail = match session {
        Session::Nobody => {
            format!("{detail}; nobody is logged in (sharing needs a logged-in session)")
        }
        Session::OtherUser => format!("{detail}; another user is at the screen"),
        _ => detail,
    };
    status
}

/// The folder holding the helper and the last status.
pub fn dir(home: &Path) -> PathBuf {
    home.join(DIR)
}

/// The installed helper, when there is one.
pub fn installed(home: &Path) -> Option<Installed> {
    let text = std::fs::read_to_string(dir(home).join(HELPER_RECORD)).ok()?;
    let installed: Installed = serde_json::from_str(&text).ok()?;
    installed.executable().is_file().then_some(installed)
}

/// The last status read on this machine, when there is one.
pub fn cached(home: &Path) -> Option<Status> {
    let text = std::fs::read_to_string(dir(home).join(STATUS_RECORD)).ok()?;
    serde_json::from_str::<Status>(&text).ok().filter(|s| s.schema == SCHEMA)
}

/// Whether a cached status still holds: it was read on this OS version (a macOS update can
/// reset grants, 26.5 did on 2026-09-25).
pub fn still_holds(cached: &Status, os_version: Option<&str>) -> bool {
    cached.os_version.as_deref() == os_version
}

/// How [`read`] reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// Install (or update) the helper from a cmux app here first.
    pub install: bool,
}

/// Reads the status now (a fresh helper process), installs first when asked, and keeps it as
/// the machine's last status. Blocking: a probe may take up to 10 s.
pub fn read(home: &Path, options: Options) -> Status {
    let status = classify(gather(home, options));
    let _ = keep(home, &status);
    status
}

/// The status the machine record carries: the kept one while it holds (same OS version),
/// else a fresh [`read`] with install.
pub fn current(home: &Path) -> Status {
    let os = platform::os_version();
    match cached(home) {
        Some(status) if still_holds(&status, os.as_deref()) => status,
        _ => read(home, Options { install: true }),
    }
}

/// At daemon start: install or update the helper and read the status again (a new app may have
/// brought a new helper, and a restart is when an OS update shows). Blocking.
pub fn at_daemon_start(home: &Path) -> Status {
    read(home, Options { install: true })
}

/// Written when the person set this machine up from another of their devices
/// (`cmux device setup`): that is a join too, though its credential came from a sign-in.
const JOINED_MARK: &str = "joined-from-another-device";

/// Records that this machine was set up from another of the person's devices.
pub fn mark_joined(home: &Path) -> std::io::Result<()> {
    let folder = dir(home);
    std::fs::create_dir_all(&folder)?;
    std::fs::write(folder.join(JOINED_MARK), b"")
}

/// Whether this machine's device asks the hub to turn its sharing on (`POST /v1/devices
/// {shareByJoin: true}` from its machine sign-in; design Z4, joining is the consent): it was
/// joined from another device (a join line, a pair code, `cmux device add`, or `cmux device
/// setup`'s mark). A machine joined only by signing in to cmux here (`joined_by: sign-in`)
/// never asks, so its switch stays off. The hub keeps a person's explicit off over this.
pub fn share_by_join(joined_by: Option<&str>, marked: bool) -> bool {
    marked || joined_by != Some("sign-in")
}

/// [`share_by_join`] for this machine: its join record and the mark. False with no join record.
pub fn share_by_join_here(home: &Path) -> bool {
    let Ok(Some(credential)) = crate::machine_record::load_at(home) else {
        return false;
    };
    share_by_join(credential.joined_by.as_deref(), dir(home).join(JOINED_MARK).is_file())
}

fn keep(home: &Path, status: &Status) -> std::io::Result<()> {
    let folder = dir(home);
    std::fs::create_dir_all(&folder)?;
    let text = serde_json::to_vec_pretty(status).map_err(std::io::Error::other)?;
    let temporary = folder.join(format!(".{STATUS_RECORD}.{}", std::process::id()));
    std::fs::write(&temporary, text)?;
    std::fs::rename(temporary, folder.join(STATUS_RECORD))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

fn gather(home: &Path, options: Options) -> Facts {
    let mut facts = Facts { mac: cfg!(target_os = "macos"), now_ms: now_ms(), ..Facts::default() };
    if !facts.mac {
        return facts;
    }
    facts.os_version = platform::os_version();
    facts.session = Some(platform::session());
    let installed = if options.install {
        match platform::install(home) {
            Ok(installed) => Some(installed),
            Err(why) => {
                // A failed update keeps the helper already installed.
                facts.install_error = Some(why);
                installed(home)
            }
        }
    } else {
        installed(home)
    };
    if let Some(installed) = &installed {
        facts.probe = Some(platform::probe(&installed.executable()));
    }
    facts.installed = installed;
    facts
}

/// Parses the helper's one `permissions` line.
pub fn parse_permissions(stdout: &[u8]) -> Result<Permissions, String> {
    let line = stdout.split(|b| *b == b'\n').find(|l| !l.is_empty()).unwrap_or_default();
    serde_json::from_slice(line).map_err(|e| format!("no permissions line ({e})"))
}

/// Whether `id` is a cmux Screen Sharing helper's bundle id (`com.cmuxterm.app.nightly.screen-sharing`).
pub fn is_helper_bundle_id(id: &str) -> bool {
    id.strip_suffix(".screen-sharing")
        .is_some_and(|app| app == "com.cmuxterm.app" || app.starts_with("com.cmuxterm.app."))
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// The helper bundles `app` carries in `Contents/Library`, sorted.
pub fn helpers_in(app: &Path) -> Vec<PathBuf> {
    let library = app.join("Contents/Library");
    let Ok(entries) = std::fs::read_dir(&library) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name().is_some_and(|n| n.to_string_lossy().ends_with(BUNDLE_SUFFIX))
                && p.join("Contents/MacOS").join(EXECUTABLE).is_file()
        })
        .collect();
    found.sort();
    found
}

/// The app bundle holding `executable` (`X.app/Contents/Resources/bin/acpmux` → `X.app`).
pub fn app_of(executable: &Path) -> Option<PathBuf> {
    executable
        .ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(Path::to_path_buf)
}

/// Where to install from, in order: `CMUX_SCREEN_HELPER_APP` (a helper bundle), the app this
/// binary runs from, then NIGHTLY and Release in /Applications.
fn sources() -> Vec<(PathBuf, PathBuf)> {
    let mut out = Vec::new();
    if let Some(path) = std::env::var_os("CMUX_SCREEN_HELPER_APP").map(PathBuf::from) {
        out.push((path.clone(), path));
    }
    let mut apps: Vec<PathBuf> = Vec::new();
    if let Some(app) = cmux_link::app_caller::own_executable().ok().as_deref().and_then(app_of) {
        apps.push(app);
    }
    apps.extend(APPS.iter().map(PathBuf::from));
    for app in apps {
        for helper in helpers_in(&app) {
            if !out.iter().any(|(h, _)| *h == helper) {
                out.push((helper, app.clone()));
            }
        }
    }
    out
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use cmux_process::{Command, Stdio};
    use std::io::Read;
    use std::time::Duration;

    /// cmux's signing team: an installed helper must carry it, so its grants hold across updates.
    const TEAM: &str = "7WLXT3NR37";
    /// How long a `permissions` probe may take before it is ended and reads as no answer.
    const PROBE_LIMIT: Duration = Duration::from_secs(10);

    pub(super) fn os_version() -> Option<String> {
        let read = |flag: &str| {
            let out =
                Command::new("/usr/bin/sw_vers").arg(flag).stdin(Stdio::null()).output().ok()?;
            let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
            (out.status.success() && !text.is_empty()).then_some(text)
        };
        let version = read("-productVersion")?;
        Some(match read("-buildVersion") {
            Some(build) => format!("{version} ({build})"),
            None => version,
        })
    }

    pub(super) fn session() -> Session {
        use std::os::unix::fs::MetadataExt;
        let Ok(console) = std::fs::metadata("/dev/console") else {
            return Session::Unknown;
        };
        // SAFETY: getuid has no preconditions.
        let me = unsafe { libc::getuid() };
        match console.uid() {
            0 => Session::Nobody,
            uid if uid == me => Session::ThisUser,
            _ => Session::OtherUser,
        }
    }

    fn plist_value(app: &Path, key: &str) -> Option<String> {
        let out = Command::new("/usr/bin/plutil")
            .args(["-extract", key, "raw", "-o", "-"])
            .arg(app.join("Contents/Info.plist"))
            .stdin(Stdio::null())
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        (out.status.success() && !text.is_empty()).then_some(text)
    }

    fn digest_of(app: &Path) -> Result<String, String> {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        let executable = format!("Contents/MacOS/{EXECUTABLE}");
        for part in
            [executable.as_str(), "Contents/_CodeSignature/CodeResources", "Contents/Info.plist"]
        {
            let mut file =
                std::fs::File::open(app.join(part)).map_err(|e| format!("{part}: {e}"))?;
            std::io::copy(&mut file, &mut hasher).map_err(|e| format!("{part}: {e}"))?;
        }
        Ok(format!("{:x}", hasher.finalize()))
    }

    /// Whether `app` is a sealed cmux Screen Sharing helper signed by cmux's team.
    fn verify(app: &Path) -> Result<String, String> {
        let id = plist_value(app, "CFBundleIdentifier").ok_or("the bundle has no identifier")?;
        if !is_helper_bundle_id(&id) {
            return Err(format!("{id} is not a cmux Screen Sharing helper"));
        }
        let requirement = format!(
            "=identifier \"{id}\" and anchor apple generic and certificate leaf[subject.OU] = \"{TEAM}\""
        );
        let out = Command::new("/usr/bin/codesign")
            .args(["--verify", "--strict", "--deep", "-R"])
            .arg(&requirement)
            .arg(app)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("codesign: {e}"))?;
        if out.status.success() {
            Ok(id)
        } else {
            Err(format!("its signature: {}", String::from_utf8_lossy(&out.stderr).trim()))
        }
    }

    /// Copies the first valid helper a cmux app here carries to
    /// `<home>/screen-sharing/<bundle id>/<name>.app` when it differs from the one there, checks
    /// the copy, and records it. Never runs anything from inside an app bundle.
    pub(super) fn install(home: &Path) -> Result<Installed, String> {
        let candidates = sources();
        if candidates.is_empty() {
            return Err("no cmux app here carries it (install cmux NIGHTLY)".into());
        }
        let mut refused = Vec::new();
        for (helper, app) in candidates {
            match install_one(home, &helper, &app) {
                Ok(installed) => return Ok(installed),
                Err(why) => refused.push(format!("{}: {why}", helper.display())),
            }
        }
        Err(refused.join("; "))
    }

    fn install_one(home: &Path, helper: &Path, app: &Path) -> Result<Installed, String> {
        use std::os::unix::fs::PermissionsExt;
        let id = verify(helper)?;
        let digest = digest_of(helper)?;
        let file_name = helper.file_name().ok_or("bad bundle name")?.to_owned();
        let name = file_name.to_string_lossy().trim_end_matches(".app").to_owned();
        let root = dir(home);
        std::fs::create_dir_all(&root).map_err(|e| format!("{}: {e}", root.display()))?;
        let _ = std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700));
        let slot = root.join(&id);
        let target = slot.join(&file_name);
        let installed =
            Installed { app: target.clone(), bundle_id: id, name, digest, source: app.into() };
        let current = super::installed(home);
        if current.as_ref().is_some_and(|c| c.app == target && c.digest == installed.digest)
            && digest_of(&target).is_ok_and(|d| d == installed.digest)
        {
            return Ok(installed);
        }
        let temporary = root.join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).map_err(|e| e.to_string())?;
        let copy = temporary.join(&file_name);
        let copied = Command::new("/usr/bin/ditto")
            .args(["--norsrc", "--noqtn"])
            .arg(helper)
            .arg(&copy)
            .stdin(Stdio::null())
            .status()
            .map_err(|e| format!("ditto: {e}"))?;
        let checked = if copied.success() {
            verify(&copy).and_then(|_| {
                (digest_of(&copy)? == installed.digest)
                    .then_some(())
                    .ok_or_else(|| "the copy differs from the app's helper".to_owned())
            })
        } else {
            Err("cannot copy the helper out of the app".into())
        };
        if let Err(why) = checked {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err(why);
        }
        // A share running from the old copy keeps its open files; the next starts the new one.
        let old = root.join(format!(".old-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&old);
        if slot.exists() {
            std::fs::rename(&slot, &old).map_err(|e| e.to_string())?;
        }
        if let Err(e) = std::fs::rename(&temporary, &slot) {
            let _ = std::fs::rename(&old, &slot);
            return Err(e.to_string());
        }
        let _ = std::fs::remove_dir_all(&old);
        let record = serde_json::to_vec_pretty(&installed).map_err(|e| e.to_string())?;
        let path = root.join(HELPER_RECORD);
        let temporary = root.join(format!(".{HELPER_RECORD}.{}", std::process::id()));
        std::fs::write(&temporary, record).map_err(|e| e.to_string())?;
        std::fs::rename(temporary, path).map_err(|e| e.to_string())?;
        Ok(installed)
    }

    /// A fresh `permissions` from the helper, its own responsible process (macOS checks the
    /// helper's grants, never this daemon's or the ssh session's). Bounded by [`PROBE_LIMIT`].
    pub(super) fn probe(executable: &Path) -> Result<Permissions, String> {
        let mut command = Command::new(executable);
        command
            .arg("permissions")
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .disclaim_responsibility();
        for name in ["HOME", "USER", "TMPDIR", "LANG"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let mut child = command.spawn().map_err(|e| format!("it did not start: {e}"))?;
        let mut stdout = child.stdout.take().ok_or("it has no stdout")?;
        // Its answer is one short line, far below a pipe's buffer: it exits without waiting
        // for a reader, and the line is read after.
        match child.wait_timeout(PROBE_LIMIT) {
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("it gave no answer within 10 s".into());
            }
        }
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).map_err(|e| format!("its answer: {e}"))?;
        parse_permissions(&bytes)
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;

    pub(super) fn os_version() -> Option<String> {
        None
    }

    pub(super) fn session() -> Session {
        Session::Unknown
    }

    pub(super) fn install(_home: &Path) -> Result<Installed, String> {
        let _ = sources;
        Err("the Screen Sharing helper is macOS only".into())
    }

    pub(super) fn probe(_executable: &Path) -> Result<Permissions, String> {
        Err("the Screen Sharing helper is macOS only".into())
    }
}

#[cfg(test)]
#[path = "screen_share_tests.rs"]
mod tests;
