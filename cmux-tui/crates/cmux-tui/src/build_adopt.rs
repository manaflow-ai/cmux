//! cmux NEXT's one-time adoption of the homes it used before per-build
//! isolation (P0 2026-10-15, after NEXT 1.0.0-nightly.3865928435701).
//!
//! Before S2 (677f1e1a0248) cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`)
//! kept its acpmux home at `<acpmux root>/tags/cmux-next`; S2 moved it to
//! its build key's home (`BuildIdentity::acpmux_home`). Before S0
//! (2a0ef940a7b8) NEXT shared NIGHTLY's Chief home `<chief root>/<account>`;
//! S0 gave it `<chief root>/<bundle id>[.<account>]`. A NEXT that updated
//! opened two empty homes. This module adopts the old ones once:
//!
//! - acpmux ([`acpmux::adopt`]): the old home is renamed to the new one (one
//!   directory, never two copies) and the old path becomes a link to it, so
//!   an agent host or older binary that still names the old path reaches the
//!   same home. Sessions the new home got after the update are merged in.
//! - Chief ([`chief::adopt`]): an APFS clone of the shared home into NEXT's
//!   own home. NIGHTLY keeps its home unchanged; after the clone both go on
//!   separately (the isolation design).
//!
//! Each adopted home gets `adopted.json` {from, at, by, ...}: present = done,
//! so a later launch does nothing. Only cmux NEXT adopts; NIGHTLY, DEV,
//! release, RC and staging never do. The app runs `cmux __adopt-build-homes`
//! (this module's private mode) before it starts any acpmux daemon or Chief
//! owner; the CLI adopts the same way where it resolves those homes
//! (`cmux acp`, `cmux chief`), so both adopt alike whichever runs first.
//! One line per step goes to stderr, with the reason; no secret value is
//! ever read or printed.

pub(crate) mod acpmux;
pub(crate) mod chief;
mod copy;

use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_agent_pane_policy::build_identity::BuildIdentity;

/// The one build that adopts.
pub(crate) const NEXT_BUNDLE_ID: &str = "com.cmuxterm.app.nightly.cmux-next";
/// The tag NEXT's acpmux home had before S2 (`tags/<tag>`).
pub(crate) const LEGACY_TAG: &str = "cmux-next";
/// The record in an adopted home.
pub(crate) const RECORD: &str = "adopted.json";
/// Set on the processes an adoption starts (a daemon stop), so they never
/// adopt themselves while the parent holds the adoption lock.
pub(crate) const CHILD_ENV: &str = "CMUX_ADOPT_BUILD_HOMES_CHILD";
/// How long an adoption waits for another one of the same home.
const LOCK_WAIT: Duration = Duration::from_secs(30);

/// What one adoption did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// `adopted.json` was there: adopted before.
    Done,
    /// No old home to adopt (or this is no NEXT home).
    Nothing,
    /// Adopted now; `mode` says how.
    Adopted(&'static str),
    /// Not now (a daemon or owner could not be stopped, another adoption
    /// runs, an error); the next launch tries again. The reason is logged.
    Deferred(String),
}

impl Outcome {
    pub(crate) fn label(&self) -> String {
        match self {
            Self::Done => "done".into(),
            Self::Nothing => "nothing".into(),
            Self::Adopted(mode) => format!("adopted:{mode}"),
            Self::Deferred(why) => format!("deferred: {why}"),
        }
    }
}

/// Whether `build` is cmux NEXT, the one build that adopts.
pub(crate) fn applies(build: &BuildIdentity) -> bool {
    build.bundle_id() == Some(NEXT_BUNDLE_ID)
}

/// The steps of one adoption: each one printed on stderr at once and kept
/// for the record.
pub(crate) struct Steps {
    area: &'static str,
    pub(crate) lines: Vec<String>,
}

impl Steps {
    pub(crate) fn new(area: &'static str) -> Self {
        Self { area, lines: Vec::new() }
    }

    pub(crate) fn step(&mut self, line: impl Into<String>) {
        let line = line.into();
        eprintln!("cmux adopt {}: {line}", self.area);
        self.lines.push(line);
    }
}

/// An exclusive lock on `path` (created), or None while another process
/// holds it.
pub(crate) fn try_lock(path: &Path) -> std::io::Result<Option<File>> {
    if let Some(parent) = path.parent() {
        cmux_blocking::fs::create_dir_all(parent)?;
    }
    let file = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new().create(true).truncate(false).write(true),
        path,
    )?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(std::fs::TryLockError::WouldBlock) => Ok(None),
        Err(std::fs::TryLockError::Error(error)) => Err(error),
    }
}

/// [`try_lock`], waiting up to [`LOCK_WAIT`] for another holder.
pub(crate) fn wait_lock(path: &Path) -> std::io::Result<Option<File>> {
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        if let Some(file) = try_lock(path)? {
            return Ok(Some(file));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        cmux_blocking::thread::sleep(Duration::from_millis(50));
    }
}

/// Whether a process holds the lock file `path` (an existing file only;
/// never created).
pub(crate) fn held(path: &Path) -> bool {
    let Ok(file) = crate::blocking::fs::open_with(std::fs::OpenOptions::new().read(true), path)
    else {
        return false;
    };
    matches!(file.try_lock(), Err(std::fs::TryLockError::WouldBlock))
}

/// Waits up to `limit` until no process holds `path`; true when free.
pub(crate) fn wait_free(path: &Path, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while held(path) {
        if Instant::now() >= deadline {
            return false;
        }
        cmux_blocking::thread::sleep(Duration::from_millis(100));
    }
    true
}

/// `(compact stamp for names, RFC 3339 UTC)` of now.
pub(crate) fn now_stamps() -> (String, String) {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    let (h, m, s) = (rem / 3_600, rem / 60 % 60, rem % 60);
    (
        format!("{year:04}{month:02}{day:02}T{h:02}{m:02}{s:02}Z"),
        format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z"),
    )
}

/// Random lowercase hex of `bytes` bytes (a new session id, a partial name).
pub(crate) fn random_hex(bytes: usize) -> String {
    use std::io::Read;
    let mut buf = vec![0u8; bytes];
    let filled =
        cmux_blocking::fs::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut buf)).is_ok();
    if !filled {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
        for (i, byte) in buf.iter_mut().enumerate() {
            *byte = (nanos >> ((i % 16) * 8)) as u8 ^ (std::process::id() as u8);
        }
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// Writes `value` to `path` whole (a temp file renamed over it).
pub(crate) fn write_record(path: &Path, value: &serde_json::Value) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("json.tmp-{}", random_hex(4)));
    cmux_blocking::fs::write(&tmp, serde_json::to_vec_pretty(value).unwrap_or_default())?;
    // A file it replaces keeps its mode (an acpmux config.json is 0600); a new one is 0600.
    let mode = cmux_blocking::fs::metadata(path).map_or(0o600, |m| {
        use std::os::unix::fs::PermissionsExt;
        m.permissions().mode()
    });
    {
        use std::os::unix::fs::PermissionsExt;
        crate::blocking::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode & 0o7777))?;
    }
    cmux_blocking::fs::rename(&tmp, path)
}

/// This binary, for the stops an adoption runs.
fn this_exe() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

/// A test build that stands for another one (`CMUX_NEXT_CHIEF_BUILD_ID`, a
/// DEBUG override) adopts only under test roots (`CMUX_NEXT_CHIEF_ROOT` and
/// `CMUX_NEXT_ACPMUX_ROOT`), never the person's real homes.
fn overrides_complete() -> bool {
    let set = |key: &str| std::env::var_os(key).is_some_and(|v| !v.is_empty());
    !set("CMUX_NEXT_CHIEF_BUILD_ID")
        || (set("CMUX_NEXT_CHIEF_ROOT") && set("CMUX_NEXT_ACPMUX_ROOT"))
}

/// The CLI's acpmux adoption (`cmux acp …` in NEXT, `acp::build_home`):
/// only for NEXT, only when the CLI uses the build's home (no explicit
/// `ACPMUX_HOME`), never in a process an adoption started.
pub(crate) fn acpmux_for_cli(build: &BuildIdentity, home: &Path) {
    if !applies(build)
        || std::env::var_os(CHILD_ENV).is_some()
        || std::env::var_os("ACPMUX_HOME").is_some_and(|h| !h.is_empty())
    {
        return;
    }
    // The CLI never stops a daemon the app may use now: it defers instead.
    let _ = acpmux::adopt(home, None, "cmux acp");
}

/// The CLI's Chief adoption (`cmux chief …` in NEXT): `root` is the
/// resolved home of a non-isolated launch.
pub(crate) fn chief_for_cli(root: &Path) {
    if std::env::var_os(CHILD_ENV).is_some() || !overrides_complete() {
        return;
    }
    // The CLI never stops a Chief the app may use now: it defers instead.
    let _ = chief::adopt(root, None, "cmux chief");
}

/// `cmux __adopt-build-homes`: the app's adoption at launch, before it
/// starts an acpmux daemon or the Chief owner. The build is this bundle's
/// (`CMUX_BUNDLE_ID` / the bundle around the binary); a DEV bundle may name
/// another build in `CMUX_NEXT_CHIEF_BUILD_ID` and an acpmux root in
/// `CMUX_NEXT_ACPMUX_ROOT` (tests only, as the app does). Prints one JSON
/// line with both outcomes; exit 0 also when an adoption is deferred.
pub(crate) fn run(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("usage: cmux __adopt-build-homes");
        return 2;
    }
    let env = |key: &str| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    let exe = this_exe();
    let Some(user_home) = env("HOME").map(PathBuf::from) else {
        println!(
            "{}",
            serde_json::json!({"acpmux": "nothing", "chief": "nothing", "why": "no HOME"})
        );
        return 0;
    };
    let identity = crate::app_identity::AppIdentity::detect(env, exe.as_deref());
    let own = identity.as_ref().and_then(|i| i.bundle_id.clone());
    let debug = own.as_deref().is_some_and(crate::app_identity::is_debug_bundle);
    if debug && !overrides_complete() {
        println!("{}", serde_json::json!({"acpmux": "not-next", "chief": "not-next"}));
        return 0;
    }
    let build = match env("CMUX_NEXT_CHIEF_BUILD_ID").filter(|_| debug) {
        Some(id) => BuildIdentity::new(Some(&id), None),
        None => identity.map(|i| i.build()).unwrap_or_else(|| BuildIdentity::new(None, None)),
    };
    if !applies(&build) {
        println!("{}", serde_json::json!({"acpmux": "not-next", "chief": "not-next"}));
        return 0;
    }
    let acpmux_home = match env("CMUX_NEXT_ACPMUX_ROOT").filter(|_| debug) {
        Some(root) => PathBuf::from(root).join("builds").join(build.key()),
        None => build.acpmux_home(&user_home),
    };
    let acpmux = acpmux::adopt(&acpmux_home, exe.as_deref(), "app launch");
    let chief = match crate::cli::chief_home_for_adopt() {
        Some(root) => chief::adopt(&root, exe.as_deref(), "app launch"),
        None => Outcome::Nothing,
    };
    println!("{}", serde_json::json!({"acpmux": acpmux.label(), "chief": chief.label()}));
    0
}
