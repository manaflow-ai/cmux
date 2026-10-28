//! Which cmux app this CLI belongs to, and where that app listens.
//!
//! The same binary ships inside each cmux app bundle as `cmux`. Inside one of
//! the app's terminals the app says who it is through `CMUX_SOCKET_PATH`,
//! `CMUX_BUNDLE_ID` and `CMUX_TAG`; elsewhere the bundle that contains the
//! executable decides. The paths mirror the app's `ControlSocketPath` and
//! `DaemonLauncher.sessionName`; the tests pin both tables.

use std::path::{Path, PathBuf};

use cmux_agent_pane_policy::build_identity::BuildIdentity;

const DEBUG_BUNDLE_ID: &str = "com.cmuxterm.app.debug";
/// `sockaddr_un.sun_path` on macOS (104 bytes) less its terminating NUL.
const MAX_SOCKET_PATH_BYTES: usize = 103;
/// `action.list`'s per-action surface plan key (where the app offers the
/// action: palette, CLI, right-click, MCP). App control vocabulary for UI
/// surfaces, not a daemon resource word; `cmux mcp` reads its `mcp` entry.
pub(crate) const ACTION_SURFACE_PLAN: &str = "surfaces";
const CHANNELS: [(&str, &str); 3] = [
    ("com.cmuxterm.app.nightly", "nightly"),
    ("com.cmuxterm.app.rc", "rc"),
    ("com.cmuxterm.app.staging", "staging"),
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AppIdentity {
    pub bundle_id: Option<String>,
    /// Sanitized tag (`[a-z0-9-]`), for tagged dev builds.
    pub tag: Option<String>,
    /// Set by the app in its terminals; wins over the derived path.
    pub socket_override: Option<PathBuf>,
    /// The tag as given (`CMUX_TAG` of an app terminal, else the bundle's
    /// `LSEnvironment` `CMUX_TAG`), unsanitized: the build identity's input.
    pub shipped_tag: Option<String>,
}

impl AppIdentity {
    /// The app this process belongs to: the environment an app terminal
    /// sets, else the app bundle around `exe`. `None` outside any cmux app.
    ///
    /// A `cmux` bundled in one app but run in another app's terminal (the
    /// environment names another bundle id or tag) acts for its own bundle
    /// and says so once on stderr (per-build isolation S4, cx-is1kf.5): the
    /// other app's socket, session and Chief are never this build's.
    pub(crate) fn detect(env: impl Fn(&str) -> Option<String>, exe: Option<&Path>) -> Option<Self> {
        let non_empty = |key: &str| env(key).filter(|value| !value.trim().is_empty());
        let socket_override = non_empty("CMUX_SOCKET_PATH").map(PathBuf::from);
        let env_bundle = non_empty("CMUX_BUNDLE_ID");
        let env_tag = non_empty("CMUX_TAG");
        if socket_override.is_none() && env_bundle.is_none() && env_tag.is_none() {
            return Self::from_bundle(exe);
        }
        let from_env = Self::new(env_bundle, env_tag.as_deref(), socket_override);
        match Self::from_bundle(exe) {
            Some(own) if own.names_other_build(&from_env) => {
                warn_other_app_once(&own, &from_env);
                Some(own)
            }
            _ => Some(from_env),
        }
    }

    /// Whether the app-terminal identity `env` names another build than
    /// this bundle: another build key (`BuildIdentity`). An environment with
    /// only `CMUX_SOCKET_PATH` (a Chief brain's turn) names no build; a DEV
    /// tag under another spelling of its bundle id (`debug.a-b` for
    /// reload.sh's `debug.a.b`) is the same build.
    fn names_other_build(&self, env: &Self) -> bool {
        if env.bundle_id.is_none() && env.tag.is_none() {
            return false;
        }
        if env.build().key() == self.build().key() {
            return false;
        }
        let dev = |identity: &Self| identity.bundle_id.as_deref().is_none_or(is_debug_bundle);
        !(dev(env) && dev(self) && env.tag.is_some() && env.tag == self.tag)
    }

    /// The app bundle around `exe`, if it is a cmux app.
    fn from_bundle(exe: Option<&Path>) -> Option<Self> {
        let bundle = exe.and_then(containing_app_bundle)?;
        let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
        let dictionary = info.as_dictionary()?;
        let bundle_id = dictionary.get("CFBundleIdentifier")?.as_string()?.to_owned();
        if !bundle_id.starts_with("com.cmuxterm.app") {
            return None;
        }
        // The tag the bundle ships; a copy named `cmux DEV <tag>.app` that
        // lost `LSEnvironment` ships its name's tag (CmuxNext
        // `LaunchIdentity.taggedAppName`), so the CLI and the app agree.
        let bundled_tag = dictionary
            .get("LSEnvironment")
            .and_then(plist::Value::as_dictionary)
            .and_then(|environment| environment.get("CMUX_TAG"))
            .and_then(plist::Value::as_string)
            .and_then(sanitize)
            .or_else(|| {
                let name = bundle.file_stem()?.to_str()?;
                sanitize(name.strip_prefix("cmux DEV ")?)
            });
        Some(Self::new(Some(bundle_id), bundled_tag.as_deref(), None))
    }

    fn new(bundle_id: Option<String>, tag: Option<&str>, socket_override: Option<PathBuf>) -> Self {
        let shipped_tag = tag.map(str::to_owned);
        let tag = bundle_id.as_deref().and_then(bundle_tag).or_else(|| tag.and_then(sanitize));
        Self { bundle_id, tag, socket_override, shipped_tag }
    }

    /// The build whose state roots this process uses (per-build isolation,
    /// cx-is1kf): the bundle id and the tag it ships. A tag with no bundle id
    /// (an app terminal of a build that sets only `CMUX_TAG`) names the DEV
    /// build of that tag, as the control socket does, so it never resolves
    /// NIGHTLY's shared roots.
    pub(crate) fn build(&self) -> BuildIdentity {
        match (self.bundle_id.as_deref(), self.tag.as_deref()) {
            // `scripts/reload.sh` names a tagged build `com.cmuxterm.app.debug.<segment>`:
            // runs outside `[a-z0-9]` become one `.` (tag `foo-bar` is `…debug.foo.bar`).
            (None, Some(tag)) => {
                let segment: Vec<&str> = tag
                    .split(|c: char| !c.is_ascii_alphanumeric())
                    .filter(|s| !s.is_empty())
                    .collect();
                BuildIdentity::new(Some(&format!("{DEBUG_BUNDLE_ID}.{}", segment.join("."))), None)
            }
            (bundle_id, _) => BuildIdentity::new(bundle_id, self.shipped_tag.as_deref()),
        }
    }

    /// The app control socket (`ControlSocketPath.resolve` of the build:
    /// [`BuildIdentity::control_socket`], per-build isolation S3) in the
    /// user's `~/.local/state/cmux`, since a host's /tmp cleaner deleted a
    /// running app's `/tmp` socket (hq#1870). A path too long for `sun_path`
    /// keeps its old `/tmp` name, and so does an app from before the move:
    /// when only the old name exists, that is where it listens.
    pub(crate) fn control_socket(&self, home: &Path) -> PathBuf {
        if let Some(path) = &self.socket_override {
            return path.clone();
        }
        let old = self
            .build()
            .control_socket(home)
            .unwrap_or_else(|| home.join(".local/state/cmux/cmux.sock"));
        let Ok(name) = old.strip_prefix("/tmp") else { return old };
        let moved = home.join(".local/state/cmux").join(name);
        if moved.as_os_str().len() > MAX_SOCKET_PATH_BYTES || (!moved.exists() && old.exists()) {
            return old;
        }
        moved
    }

    /// The app's cmux-tui session (`DaemonLauncher.sessionName` of the build,
    /// [`BuildIdentity::app_session`]): `cmux-app-<tag>` for a
    /// `scripts/reload.sh` DEV build, `cmux-app-<channel>` for an untagged
    /// nightly, rc or staging build, `cmux-app` for release, and
    /// `cmux-app--<key hash>` for every other build (the untagged DEV build
    /// among them), so each build reaches its own daemon.
    ///
    /// An untagged NIGHTLY, RC or staging app that adopted the old shared
    /// session (`DaemonLauncher.appNames`, `LegacyChannelSession`, cx-r650e)
    /// runs `cmux-app` instead: the app records that once beside its daemon
    /// state ([`BuildIdentity::legacy_session_marker`]), and this answer
    /// follows the record, so `cmux tab list`, `cmux browser open` and
    /// `cmux pane split` from that app's terminals reach its daemon.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn daemon_session(&self) -> Option<String> {
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        self.daemon_session_in(&home)
    }

    /// [`Self::daemon_session`] for the user home `home` (tests).
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn daemon_session_in(&self, home: &Path) -> Option<String> {
        let build = self.build();
        let session = build.app_session()?;
        if build.legacy_session_marker(home).is_some_and(|marker| marker.is_file()) {
            // `LegacyChannelSession.session`: the old shared daemon session.
            return Some("cmux-app".to_owned());
        }
        Some(session)
    }
}

/// Variables of an app terminal or agent that name that app's daemon, Chief
/// or acpmux, beside `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID` and `CMUX_TAG`:
/// ignored by a `cmux` bundled in another app (per-build isolation S4).
pub(crate) const OTHER_APP_STATE_KEYS: [&str; 15] = [
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_APP_DAEMON_SOCKET",
    "CMUX_CHIEF_OWNER_SOCKET",
    "CMUX_CHIEF_HOME",
    "CMUX_NEXT_CHIEF_HOME",
    "CMUX_NEXT_CHIEF_ROOT",
    "CMUX_NEXT_CHIEF_BUILD_ID",
    "CMUX_NEXT_CHIEF_ACCOUNT",
    "CMUX_NEXT_MUX_HOME",
    "CMUX_NEXT_ACPMUX_ROOT",
    "CMUX_NEXT_SOCKET_PATH",
    "CMUX_NEXT_CONFIG_FILE",
    "ACPMUX_HOME",
    "ACPMUX_SOCKET",
];

/// Whether this process is a `cmux` bundled in one app, run in a terminal
/// of another app (`env` names another build): then [`OTHER_APP_STATE_KEYS`]
/// are that app's and [`AppIdentity::detect`] acts for the own bundle.
pub(crate) fn in_other_apps_terminal(
    env: impl Fn(&str) -> Option<String>,
    exe: Option<&Path>,
) -> bool {
    let non_empty = |key: &str| env(key).filter(|value| !value.trim().is_empty());
    let socket_override = non_empty("CMUX_SOCKET_PATH").map(PathBuf::from);
    let env_bundle = non_empty("CMUX_BUNDLE_ID");
    let env_tag = non_empty("CMUX_TAG");
    if socket_override.is_none() && env_bundle.is_none() && env_tag.is_none() {
        return false;
    }
    let from_env = AppIdentity::new(env_bundle, env_tag.as_deref(), socket_override);
    AppIdentity::from_bundle(exe).is_some_and(|own| own.names_other_build(&from_env))
}

/// [`in_other_apps_terminal`] of this process (its environment and executable).
pub(crate) fn this_process_in_other_apps_terminal() -> bool {
    let exe = std::env::current_exe().ok();
    in_other_apps_terminal(|key| std::env::var(key).ok(), exe.as_deref())
}

/// One stderr line per process: this `cmux` belongs to `own` but runs in a
/// terminal of `other`, and acts for its own app.
fn warn_other_app_once(own: &AppIdentity, other: &AppIdentity) {
    static WARNED: std::sync::Once = std::sync::Once::new();
    let name = |identity: &AppIdentity| {
        let bundle = identity.bundle_id.as_deref().unwrap_or("an unknown bundle");
        match identity.tag.as_deref() {
            Some(tag) => format!("{bundle} (tag {tag})"),
            None => bundle.to_owned(),
        }
    };
    WARNED.call_once(|| {
        eprintln!(
            "cmux: warning: this cmux belongs to {}, but this terminal is of {}; it acts for its own app. \
             To act for {}, run that app's own cmux; to use this one without the warning, unset \
             CMUX_BUNDLE_ID CMUX_TAG CMUX_SOCKET_PATH CMUX_TUI_SOCKET CMUX_CHIEF_HOME.",
            name(own),
            name(other),
            name(other)
        );
    });
}

/// The app's session socket: `DaemonLauncher` starts the owner with
/// `TMPDIR` set to the per-user Darwin temp directory, whatever this
/// process's `TMPDIR` is.
#[cfg(target_os = "macos")]
pub(crate) fn app_daemon_socket(identity: &AppIdentity) -> Option<PathBuf> {
    let session = identity.daemon_session()?;
    let base = darwin_user_temp_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    cmux_tui_core::server::try_default_socket_path_in_base(&session, &base).ok()
}

/// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, as the app's `userTemporaryDirectory`.
#[cfg(target_os = "macos")]
pub(crate) fn darwin_user_temp_dir() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    // SAFETY: a null buffer of length 0 asks for the required length.
    let length = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, std::ptr::null_mut(), 0) };
    if length == 0 {
        return None;
    }
    let mut buffer = vec![0u8; length];
    // SAFETY: buffer holds `length` bytes, the size confstr reported.
    let written = unsafe {
        libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buffer.as_mut_ptr().cast(), length)
    };
    if written == 0 {
        return None;
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    buffer.truncate(end);
    (!buffer.is_empty()).then(|| PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

/// `…/Foo.app` for an executable at `…/Foo.app/Contents/Resources/bin/cmux`
/// or `…/Foo.app/Contents/MacOS/cmux`.
pub(crate) fn containing_app_bundle(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))
        .map(Path::to_path_buf)
}

/// The tag a tagged bundle id carries (`com.cmuxterm.app.debug.<tag>` or
/// `com.cmuxterm.app.<channel>.<tag>`), sanitized.
/// A DEV or tagged debug build (`com.cmuxterm.app.debug[.<tag>]`), the only
/// app whose control socket `cmux app call` may use.
pub(crate) fn is_debug_bundle(bundle_id: &str) -> bool {
    bundle_id
        .strip_prefix(DEBUG_BUNDLE_ID)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
}

fn bundle_tag(bundle_id: &str) -> Option<String> {
    let bundle_id = bundle_id.trim();
    std::iter::once(DEBUG_BUNDLE_ID)
        .chain(CHANNELS.iter().map(|(id, _)| *id))
        .find_map(|prefix| bundle_id.strip_prefix(prefix)?.strip_prefix('.'))
        .and_then(sanitize)
}

/// `ControlSocketPath.sanitize`: lowercase, runs outside `[a-z0-9]` become
/// one `-`, no leading or trailing `-`.
pub(crate) fn sanitize(raw: &str) -> Option<String> {
    let mut slug = String::with_capacity(raw.len());
    for character in raw.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    (!slug.is_empty()).then(|| slug.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(bundle: Option<&str>, tag: Option<&str>) -> AppIdentity {
        AppIdentity::new(bundle.map(str::to_owned), tag, None)
    }

    #[test]
    fn control_socket_matches_the_app_table() {
        let home = Path::new("/Users/a");
        let cases = [
            // Not the reload.sh form, the untagged DEV build and a tagged RC
            // build: names of their build key (S3).
            (
                Some("com.cmuxterm.app.debug.Feat_X"),
                None,
                "/Users/a/.local/state/cmux/cmux-debug--ec0e7410.sock",
            ),
            (
                Some("com.cmuxterm.app.debug"),
                Some("clic"),
                "/Users/a/.local/state/cmux/cmux-debug-clic.sock",
            ),
            (
                Some("com.cmuxterm.app.debug"),
                None,
                "/Users/a/.local/state/cmux/cmux-debug--650e93e3.sock",
            ),
            (None, Some("nx9"), "/Users/a/.local/state/cmux/cmux-debug-nx9.sock"),
            (
                Some("com.cmuxterm.app.nightly"),
                None,
                "/Users/a/.local/state/cmux/cmux-nightly.sock",
            ),
            (
                Some("com.cmuxterm.app.rc.try2"),
                None,
                "/Users/a/.local/state/cmux/cmux-rc--36529c0e.sock",
            ),
            (Some("com.cmuxterm.app"), None, "/Users/a/.local/state/cmux/cmux.sock"),
        ];
        for (bundle, tag, expected) in cases {
            assert_eq!(
                identity(bundle, tag).control_socket(home),
                PathBuf::from(expected),
                "{bundle:?} {tag:?}"
            );
        }
    }

    #[test]
    fn daemon_session_matches_the_app_launcher() {
        assert_eq!(
            identity(Some("com.cmuxterm.app"), None).daemon_session().as_deref(),
            Some("cmux-app")
        );
        assert_eq!(
            identity(Some("com.cmuxterm.app.debug.nx9"), None).daemon_session().as_deref(),
            Some("cmux-app-nx9")
        );
    }

    #[test]
    fn an_adopted_legacy_session_is_the_channel_apps_daemon() {
        let root =
            std::env::temp_dir().join(format!("cmux-adopted-session-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let nightly = identity(Some("com.cmuxterm.app.nightly"), None);
        assert_eq!(nightly.daemon_session_in(&root).as_deref(), Some("cmux-app-nightly"));
        let marker = nightly.build().legacy_session_marker(&root).unwrap();
        std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
        std::fs::write(&marker, br#"{"session":"cmux-app","state_root":"/x"}"#).unwrap();
        assert_eq!(
            nightly.daemon_session_in(&root).as_deref(),
            Some("cmux-app"),
            "the NIGHTLY app runs the adopted cmux-app session"
        );
        assert_eq!(
            identity(Some("com.cmuxterm.app.rc"), None).daemon_session_in(&root).as_deref(),
            Some("cmux-app-rc"),
            "another channel's record is not this one's"
        );
        assert_eq!(
            identity(Some("com.cmuxterm.app.debug.nx9"), None).daemon_session_in(&root).as_deref(),
            Some("cmux-app-nx9")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn terminal_environment_wins_over_the_bundle() {
        let env = |key: &str| match key {
            "CMUX_SOCKET_PATH" => Some("/tmp/cmux-debug-own.sock".to_owned()),
            "CMUX_TAG" => Some("own".to_owned()),
            _ => None,
        };
        let found = AppIdentity::detect(env, None).unwrap();
        assert_eq!(
            found.control_socket(Path::new("/h")),
            PathBuf::from("/tmp/cmux-debug-own.sock")
        );
        assert_eq!(found.daemon_session().as_deref(), Some("cmux-app-own"));
        assert_eq!(AppIdentity::detect(|_| None, None), None);
    }

    #[test]
    fn app_bundle_is_found_from_the_bundled_cli() {
        assert_eq!(
            containing_app_bundle(Path::new("/A/cmux DEV x.app/Contents/Resources/bin/cmux")),
            Some(PathBuf::from("/A/cmux DEV x.app"))
        );
        assert_eq!(containing_app_bundle(Path::new("/usr/local/bin/cmux")), None);
    }
}
