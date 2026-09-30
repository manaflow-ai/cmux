//! Which cmux app this CLI belongs to, and where that app listens.
//!
//! The same binary ships inside each cmux app bundle as `cmux`. Inside one of
//! the app's terminals the app says who it is through `CMUX_SOCKET_PATH`,
//! `CMUX_BUNDLE_ID` and `CMUX_TAG`; elsewhere the bundle that contains the
//! executable decides. The paths mirror the app's `ControlSocketPath` and
//! `DaemonLauncher.sessionName`; the tests pin both tables.

use std::path::{Path, PathBuf};

const DEBUG_BUNDLE_ID: &str = "com.cmuxterm.app.debug";
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
}

impl AppIdentity {
    /// The app this process belongs to: the environment an app terminal
    /// sets, else the app bundle around `exe`. `None` outside any cmux app.
    pub(crate) fn detect(env: impl Fn(&str) -> Option<String>, exe: Option<&Path>) -> Option<Self> {
        let non_empty = |key: &str| env(key).filter(|value| !value.trim().is_empty());
        let socket_override = non_empty("CMUX_SOCKET_PATH").map(PathBuf::from);
        let env_bundle = non_empty("CMUX_BUNDLE_ID");
        let env_tag = non_empty("CMUX_TAG");
        if socket_override.is_some() || env_bundle.is_some() || env_tag.is_some() {
            return Some(Self::new(env_bundle, env_tag.as_deref(), socket_override));
        }
        let bundle = exe.and_then(containing_app_bundle)?;
        let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
        let dictionary = info.as_dictionary()?;
        let bundle_id = dictionary.get("CFBundleIdentifier")?.as_string()?.to_owned();
        if !bundle_id.starts_with("com.cmuxterm.app") {
            return None;
        }
        let bundled_tag = dictionary
            .get("LSEnvironment")
            .and_then(plist::Value::as_dictionary)
            .and_then(|environment| environment.get("CMUX_TAG"))
            .and_then(plist::Value::as_string)
            .map(str::to_owned);
        Some(Self::new(Some(bundle_id), bundled_tag.as_deref(), None))
    }

    fn new(bundle_id: Option<String>, tag: Option<&str>, socket_override: Option<PathBuf>) -> Self {
        let tag = bundle_id.as_deref().and_then(bundle_tag).or_else(|| tag.and_then(sanitize));
        Self { bundle_id, tag, socket_override }
    }

    /// The app control socket (`ControlSocketPath.resolve`).
    pub(crate) fn control_socket(&self, home: &Path) -> PathBuf {
        if let Some(path) = &self.socket_override {
            return path.clone();
        }
        let bundle = self.bundle_id.as_deref().unwrap_or("").trim();
        for (channel_id, channel) in CHANNELS {
            if bundle == channel_id {
                return PathBuf::from(format!("/tmp/cmux-{channel}.sock"));
            }
            if let Some(slug) =
                bundle.strip_prefix(channel_id).and_then(|rest| rest.strip_prefix('.')).and_then(sanitize)
            {
                return PathBuf::from(format!("/tmp/cmux-{channel}-{slug}.sock"));
            }
        }
        if let Some(slug) = bundle_tag(bundle) {
            return PathBuf::from(format!("/tmp/cmux-debug-{slug}.sock"));
        }
        let is_debug = bundle == DEBUG_BUNDLE_ID || (bundle.is_empty() && self.tag.is_some());
        if is_debug {
            return match &self.tag {
                Some(tag) => PathBuf::from(format!("/tmp/cmux-debug-{tag}.sock")),
                None => PathBuf::from("/tmp/cmux-debug.sock"),
            };
        }
        home.join(".local/state/cmux/cmux.sock")
    }

    /// The app's cmux-tui session (`DaemonLauncher.sessionName`).
    pub(crate) fn daemon_session(&self) -> Option<String> {
        let Some(tag) = &self.tag else { return Some("cmux-app".into()) };
        let cleaned: String = tag
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
            .collect();
        let cleaned = cleaned.trim_matches(|c| c == '-' || c == '.');
        (!cleaned.is_empty()).then(|| format!("cmux-app-{cleaned}"))
    }
}

/// `…/Foo.app` for an executable at `…/Foo.app/Contents/Resources/bin/cmux`
/// or `…/Foo.app/Contents/MacOS/cmux`.
fn containing_app_bundle(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))
        .map(Path::to_path_buf)
}

/// The tag a tagged bundle id carries (`com.cmuxterm.app.debug.<tag>` or
/// `com.cmuxterm.app.<channel>.<tag>`), sanitized.
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
            (Some("com.cmuxterm.app.debug.Feat_X"), None, "/tmp/cmux-debug-feat-x.sock"),
            (Some("com.cmuxterm.app.debug"), Some("clic"), "/tmp/cmux-debug-clic.sock"),
            (Some("com.cmuxterm.app.debug"), None, "/tmp/cmux-debug.sock"),
            (None, Some("nx9"), "/tmp/cmux-debug-nx9.sock"),
            (Some("com.cmuxterm.app.nightly"), None, "/tmp/cmux-nightly.sock"),
            (Some("com.cmuxterm.app.rc.try2"), None, "/tmp/cmux-rc-try2.sock"),
            (Some("com.cmuxterm.app"), None, "/Users/a/.local/state/cmux/cmux.sock"),
        ];
        for (bundle, tag, expected) in cases {
            assert_eq!(identity(bundle, tag).control_socket(home), PathBuf::from(expected), "{bundle:?} {tag:?}");
        }
    }

    #[test]
    fn daemon_session_matches_the_app_launcher() {
        assert_eq!(identity(Some("com.cmuxterm.app"), None).daemon_session().as_deref(), Some("cmux-app"));
        assert_eq!(
            identity(Some("com.cmuxterm.app.debug.nx9"), None).daemon_session().as_deref(),
            Some("cmux-app-nx9")
        );
    }

    #[test]
    fn terminal_environment_wins_over_the_bundle() {
        let env = |key: &str| match key {
            "CMUX_SOCKET_PATH" => Some("/tmp/cmux-debug-own.sock".to_owned()),
            "CMUX_TAG" => Some("own".to_owned()),
            _ => None,
        };
        let found = AppIdentity::detect(env, None).unwrap();
        assert_eq!(found.control_socket(Path::new("/h")), PathBuf::from("/tmp/cmux-debug-own.sock"));
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
