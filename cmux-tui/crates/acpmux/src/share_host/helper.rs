//! The Screen Sharing helper a share runs (cmux#44069: `<app> Screen Sharing.app`, bundle id
//! `<app id>.screen-sharing`, executable `Contents/MacOS/cmux-screen-sharing serve`), and the
//! join's facts the registration carries.
//!
//! The join (lane share-join-zero-touch, `acpmux::screen_share`) installs a verified copy of the
//! helper beside the daemon's state and keeps the machine's screen-share status; until that
//! module is in this tree, [`installed`], [`share_by_join_here`] and [`status`] read the files
//! it writes, each marked `TODO(share-join-zero-touch)`, so the swap to its API is one line each.
//!
//! In order, a share runs: `CMUX_SCREEN_HELPER_APP`, the join's install, then a helper of the
//! cmux app holding this binary, cmux NIGHTLY or cmux in /Applications. The join's install runs
//! where it is, checked against cmux's Developer ID requirement (the floor). A helper inside an
//! app bundle is never run from there: it is copied to this daemon's own slot,
//! `~/Library/Application Support/cmux-next/screen-sharing/<scope>/daemon/<digest>/` (the app
//! stages its own beside it, never here), and the copy is checked against the source bundle's
//! own designated requirement (so a DEV build's helper runs too).

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The helper's executable inside its bundle.
pub(crate) const EXECUTABLE: &str = "cmux-screen-sharing";
/// Every channel's helper bundle ends with this (`cmux NIGHTLY Screen Sharing.app`).
pub(crate) const BUNDLE_SUFFIX: &str = " Screen Sharing.app";
/// cmux's signing team, the floor the join's install must carry.
const TEAM: &str = "7WLXT3NR37";
/// The apps whose helper a share runs, after the app holding this binary.
const APPS: [&str; 2] = ["/Applications/cmux NIGHTLY.app", "/Applications/cmux.app"];
/// The join's folder under the acpmux home (`screen_share::DIR`) and its files.
const JOIN_DIR: &str = "screen-sharing";
const JOIN_HELPER_RECORD: &str = "helper.json";
const JOIN_STATUS_RECORD: &str = "status.json";
const JOIN_MARK: &str = "joined-from-another-device";
const STATUS_SCHEMA: &str = "cmux.screen-share.status/1";
/// What the last share resolved, for `share-host status`.
const RESOLVED_RECORD: &str = "helper.json";

/// The join's installed helper executable, when there is one.
///
/// TODO(share-join-zero-touch): `crate::screen_share::installed(home).map(|i| i.executable())`.
pub(crate) fn installed(home: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(home.join(JOIN_DIR).join(JOIN_HELPER_RECORD)).ok()?;
    let record: Value = serde_json::from_str(&text).ok()?;
    let app = PathBuf::from(record.get("app")?.as_str()?);
    let executable = app.join("Contents/MacOS").join(EXECUTABLE);
    executable.is_file().then_some(executable)
}

/// Whether this machine's device asks the hub to turn its sharing on at registration: joined
/// from another device (any join but signing in here, or `cmux device setup`'s mark).
///
/// TODO(share-join-zero-touch): `crate::screen_share::share_by_join_here(home)`.
pub(crate) fn share_by_join_here(home: &Path) -> bool {
    let Ok(Some(credential)) = crate::machine_record::load_at(home) else { return false };
    let marked = home.join(JOIN_DIR).join(JOIN_MARK).is_file();
    marked || credential.joined_by.as_deref() != Some(crate::machine_record::JOINED_BY_SIGN_IN)
}

/// The machine's screen-share status (`cmux.screen-share.status/1`) the hub record carries, or
/// None when there is none to send (`PUT /v1/devices/:id/screen-share` is then skipped).
///
/// TODO(share-join-zero-touch): `serde_json::to_value(crate::screen_share::current(home)).ok()`;
/// until then the status the join last kept, never a probe.
pub(crate) fn status(home: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(home.join(JOIN_DIR).join(JOIN_STATUS_RECORD)).ok()?;
    let status: Value = serde_json::from_str(&text).ok()?;
    (status.get("schema").and_then(Value::as_str) == Some(STATUS_SCHEMA)).then_some(status)
}

/// Whether `id` is a cmux Screen Sharing helper's bundle id.
pub(crate) fn is_helper_bundle_id(id: &str) -> bool {
    id.strip_suffix(".screen-sharing")
        .is_some_and(|app| app == "com.cmuxterm.app" || app.starts_with("com.cmuxterm.app."))
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// Where a helper comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Source {
    /// `CMUX_SCREEN_HELPER_APP`: a helper bundle, staged.
    Env(PathBuf),
    /// The join's verified install: its executable, run in place.
    Join(PathBuf),
    /// A helper bundle inside an app, staged.
    App(PathBuf),
}

impl Source {
    fn name(&self) -> &'static str {
        match self {
            Self::Env(_) => "env",
            Self::Join(_) => "join",
            Self::App(_) => "app",
        }
    }
}

/// The helper bundles `app` carries in `Contents/Library`, sorted.
pub(crate) fn helpers_in(app: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(app.join("Contents/Library")) else { return Vec::new() };
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

/// The app bundle holding `executable` (`X.app/Contents/Resources/bin/acpmux` -> `X.app`).
pub(crate) fn app_of(executable: &Path) -> Option<PathBuf> {
    executable
        .ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(Path::to_path_buf)
}

/// Every helper a share may run, in order: `env`, `join`, then the helpers of `apps`.
pub(crate) fn sources(
    env: Option<PathBuf>,
    join: Option<PathBuf>,
    apps: &[PathBuf],
) -> Vec<Source> {
    let mut out: Vec<Source> = env.into_iter().map(Source::Env).collect();
    out.extend(join.map(Source::Join));
    for app in apps {
        for helper in helpers_in(app) {
            if !out.contains(&Source::App(helper.clone())) {
                out.push(Source::App(helper));
            }
        }
    }
    out
}

/// This daemon's staging root for a helper of bundle id `bundle_id`: its own sibling slot of
/// the app's (`.../screen-sharing/<scope>/<helper>.app`), under `daemon/`.
///
/// TODO(ss-helper-land): `<scope>` is the helper's bundle id until SignedHelperLaunch (#44069)
/// names its scope folder; use the same name then.
pub(crate) fn staging_root(user_home: &Path, bundle_id: &str) -> PathBuf {
    user_home
        .join("Library/Application Support/cmux-next/screen-sharing")
        .join(bundle_id)
        .join("daemon")
}

/// The helper a share runs, how it was found, and the digest of its staged copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Resolved {
    pub executable: PathBuf,
    pub source: &'static str,
    pub digest: Option<String>,
}

/// Finds, checks and (from an app bundle) stages the helper a share runs now. Blocking: a
/// first staging copies and checks a bundle.
pub(crate) fn resolve(home: &Path) -> Result<Resolved, String> {
    let mut apps = Vec::new();
    if let Some(app) = cmux_link::app_caller::own_executable().ok().as_deref().and_then(app_of) {
        apps.push(app);
    }
    apps.extend(APPS.iter().map(PathBuf::from));
    let env = std::env::var_os("CMUX_SCREEN_HELPER_APP").map(PathBuf::from);
    let candidates = sources(env, installed(home), &apps);
    if candidates.is_empty() {
        return Err("no Screen Sharing helper is installed (install cmux NIGHTLY)".into());
    }
    let user_home = dirs::home_dir().ok_or("no home folder")?;
    let mut refused = Vec::new();
    for source in candidates {
        match resolve_one(&source, &user_home) {
            Ok(resolved) => {
                keep(home, &resolved);
                return Ok(resolved);
            }
            Err(why) => refused.push(format!("{} ({}): {why}", source.name(), path_of(&source))),
        }
    }
    Err(refused.join("; "))
}

fn path_of(source: &Source) -> String {
    match source {
        Source::Env(p) | Source::Join(p) | Source::App(p) => p.display().to_string(),
    }
}

fn resolve_one(source: &Source, user_home: &Path) -> Result<Resolved, String> {
    match source {
        Source::Join(executable) => {
            let app = app_of(executable).ok_or("the install is not a bundle")?;
            let id = cmux_signed_bundle::bundle_id(&app).ok_or("the bundle has no identifier")?;
            if !is_helper_bundle_id(&id) {
                return Err(format!("{id} is not a cmux Screen Sharing helper"));
            }
            cmux_signed_bundle::verify(&app, &cmux_signed_bundle::team_requirement(&id, TEAM))?;
            Ok(Resolved { executable: executable.clone(), source: "join", digest: None })
        }
        Source::Env(bundle) | Source::App(bundle) => {
            let id = cmux_signed_bundle::bundle_id(bundle).ok_or("the bundle has no identifier")?;
            if !is_helper_bundle_id(&id) {
                return Err(format!("{id} is not a cmux Screen Sharing helper"));
            }
            // The copy must be the source's own code, signed as the source is.
            let requirement = cmux_signed_bundle::designated_requirement(bundle)?;
            let parts = cmux_signed_bundle::digest_parts(EXECUTABLE);
            let root = staging_root(user_home, &id);
            let staged = cmux_signed_bundle::stage(bundle, &root, &parts, |copy| {
                cmux_signed_bundle::verify(copy, &requirement)
            })?;
            Ok(Resolved {
                executable: staged.executable(EXECUTABLE),
                source: source.name(),
                digest: Some(staged.digest),
            })
        }
    }
}

/// Records what a share resolved, for `share-host status`.
fn keep(home: &Path, resolved: &Resolved) {
    let record = json!({
        "path": resolved.executable,
        "source": resolved.source,
        "digest": resolved.digest,
        "at": crate::store::now_ms(),
    });
    let file = super::dir(home).join(RESOLVED_RECORD);
    let _ = cmux_hub_host::identity::write_private(&file, record.to_string().as_bytes());
}

/// What the last share resolved, as `share-host status` shows it, with the join's install.
pub(crate) fn status_json(home: &Path) -> Value {
    let last = cmux_hub_host::identity::read_private(&super::dir(home).join(RESOLVED_RECORD))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
    json!({"joinInstall": installed(home), "lastResolved": last})
}
