//! Which cmux may write the person's global agent configs (`~/.claude.json`,
//! the Codex config): only a shipped build, the release or nightly channel,
//! on the shared settings file. A tagged DEV build, a build from Xcode's
//! DerivedData, an RC or staging build, or any cmux on its own settings file
//! (`CMUX_NEXT_CONFIG_FILE` naming another file than
//! `~/.config/cmux/cmux-next.json`) gives its agents cmux's server only
//! through its own terminals: the `claude` and `codex` shims pass it to each
//! agent they start (`agent_mcp_choice`), with the terminal's settings file.
//! Such a build never touches an existing install's entry.
//!
//! A shipped build's setup also cleans up after DEV builds: a global `cmux`
//! entry whose command runs from a DEV build ([`dev_build`]) is replaced.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

use cmux_agent_pane_policy::build_identity::BuildKind;
use cmux_tui_core::user_settings::{CONFIG_OVERRIDE, path_from};

use crate::app_identity::{AppIdentity, containing_app_bundle};

/// cmux NEXT's shipped nightly: its bundle id's suffix is its tag, and it is
/// no DEV build.
const CMUX_NEXT_NIGHTLY: &str = "com.cmuxterm.app.nightly.cmux-next";

/// The app's shared settings file under the home.
const SHARED_FILE: &str = ".config/cmux/cmux-next.json";

/// Who writes the person's global agent configs.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Writer {
    /// This cmux writes them (`claude mcp add`, `codex mcp add`).
    Global,
    /// This cmux writes nothing outside its own terminals; why.
    Terminals(String),
}

/// [`Writer`] of the cmux at `exe` with the environment `getenv`.
pub(super) fn writer(exe: &Path, getenv: impl Fn(&str) -> Option<OsString>) -> Writer {
    if let Some(file) = own_settings_file(&getenv) {
        return Writer::Terminals(format!(
            "this cmux runs on its own settings file ({}), not the shared ~/{SHARED_FILE}, so it \
             leaves your agents' own settings alone",
            file.display()
        ));
    }
    let exe = resolved(exe);
    if let Some(why) = dev_build(&exe) {
        return Writer::Terminals(format!(
            "this cmux is a development build ({why}), so it leaves your agents' own settings alone"
        ));
    }
    if containing_app_bundle(&exe).is_some() {
        let kind = AppIdentity::from_bundle(Some(&exe)).map(|identity| identity.build().kind());
        if !matches!(kind, Some(BuildKind::Release | BuildKind::Nightly)) {
            return Writer::Terminals(
                "only the release and nightly cmux add cmux to your agents' own settings; this \
                 build leaves them alone"
                    .to_owned(),
            );
        }
    }
    Writer::Global
}

/// The settings file `CMUX_NEXT_CONFIG_FILE` names when it is another file
/// than the shared one; `None` when it is unset, empty or the shared file.
fn own_settings_file(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    getenv(CONFIG_OVERRIDE).filter(|value| !value.is_empty())?;
    let named = path_from(|key| getenv(key));
    let shared = PathBuf::from(getenv("HOME").unwrap_or_default()).join(SHARED_FILE);
    if same_file(&named, &shared) { None } else { Some(named) }
}

/// Whether two paths name one file: equal once absolute, or the same file
/// on disk.
fn same_file(left: &Path, right: &Path) -> bool {
    let absolute = |path: &Path| std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    if absolute(left) == absolute(right) {
        return true;
    }
    matches!((left.canonicalize(), right.canonicalize()), (Ok(a), Ok(b)) if a == b)
}

/// `path` with its links followed, else as given.
fn resolved(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// Why the cmux at `command` is a development build, or `None`: it runs from
/// Xcode's DerivedData, or from a DEV bundle (`com.cmuxterm.app.debug…`), or
/// from a bundle that ships a tag (cmux NEXT's nightly excepted, whose bundle
/// id ends in its name). A bare command name (found on PATH) is the person's.
pub(super) fn dev_build(command: &Path) -> Option<String> {
    if command.components().count() < 2 {
        return None;
    }
    let command = resolved(command);
    if command.components().any(|part| part == Component::Normal("DerivedData".as_ref())) {
        return Some("it runs from Xcode's DerivedData".to_owned());
    }
    let build = AppIdentity::from_bundle(Some(&command))?.build();
    if build.kind() == BuildKind::Dev {
        return Some(match build.tag() {
            Some(tag) => format!("tag {tag}"),
            None => "a DEV bundle".to_owned(),
        });
    }
    match build.tag() {
        Some(_) if build.bundle_id() == Some(CMUX_NEXT_NIGHTLY) => None,
        Some(tag) => Some(format!("tag {tag}")),
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake app bundle at `dir/<name>.app` with `bundle_id` (and `tag` in
    /// its `LSEnvironment`), and the path of its bundled CLI.
    fn bundle(dir: &Path, name: &str, bundle_id: &str, tag: Option<&str>) -> PathBuf {
        let app = dir.join(format!("{name}.app"));
        let bin = app.join("Contents/Resources/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let environment = tag
            .map(|tag| {
                format!(
                    "<key>LSEnvironment</key><dict><key>CMUX_TAG</key><string>{tag}</string></dict>"
                )
            })
            .unwrap_or_default();
        std::fs::write(
            app.join("Contents/Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{bundle_id}</string>{environment}</dict></plist>"#
            ),
        )
        .unwrap();
        let cli = bin.join("cmux");
        std::fs::write(&cli, "").unwrap();
        cli
    }

    fn env(pairs: Vec<(&'static str, String)>) -> impl Fn(&str) -> Option<OsString> {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| OsString::from(v))
    }

    /// Only the release and nightly channels on the shared settings file
    /// write the person's global agent configs.
    #[test]
    fn only_shipped_builds_on_the_shared_file_write_global_agent_configs() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let base = || vec![("HOME", home.display().to_string())];
        let release = bundle(dir.path(), "cmux", "com.cmuxterm.app", None);
        let nightly = bundle(dir.path(), "cmux NIGHTLY", "com.cmuxterm.app.nightly", None);
        let next = bundle(dir.path(), "cmux NEXT", CMUX_NEXT_NIGHTLY, None);
        let unbundled = dir.path().join("bin/cmux");
        for exe in [&release, &nightly, &next, &unbundled] {
            assert_eq!(writer(exe, env(base())), Writer::Global, "{exe:?}");
            // The override naming the shared file is the shared file.
            let mut shared = base();
            shared.push((CONFIG_OVERRIDE, "~/.config/cmux/cmux-next.json".into()));
            assert_eq!(writer(exe, env(shared)), Writer::Global, "{exe:?}");
        }

        let tagged =
            bundle(dir.path(), "cmux DEV cu-fresh", "com.cmuxterm.app.debug.cu.fresh", None);
        let plain_dev = bundle(dir.path(), "cmux DEV", "com.cmuxterm.app.debug", Some("cu-x"));
        let tagged_nightly =
            bundle(dir.path(), "cmux NIGHTLY t", "com.cmuxterm.app.nightly", Some("t1"));
        let rc = bundle(dir.path(), "cmux RC", "com.cmuxterm.app.rc", None);
        let derived = dir.path().join("Library/Developer/Xcode/DerivedData/cmux-x/Build/cmux");
        for exe in [&tagged, &plain_dev, &tagged_nightly, &rc, &derived] {
            assert!(matches!(writer(exe, env(base())), Writer::Terminals(_)), "{exe:?}");
        }
        // The release build on its own settings file writes nothing either.
        let mut own = base();
        own.push((CONFIG_OVERRIDE, "~/.config/cmux/cmux-next-cu-fresh.json".into()));
        let Writer::Terminals(why) = writer(&release, env(own)) else { panic!("global") };
        assert!(why.contains("cmux-next-cu-fresh.json"), "{why}");
    }

    /// A shipped build replaces an entry whose command runs from a DEV build
    /// (DerivedData or a tagged bundle), never one of a shipped build or a
    /// bare command on PATH.
    #[test]
    fn dev_build_names_derived_data_and_tagged_bundles() {
        let dir = tempfile::tempdir().unwrap();
        let tagged = bundle(dir.path(), "cmux DEV a", "com.cmuxterm.app.debug.a", None);
        assert_eq!(dev_build(&tagged).as_deref(), Some("tag a"));
        let derived = Path::new(
            "/Users/u/Library/Developer/Xcode/DerivedData/x/cmux DEV.app/Contents/Resources/bin/cmux",
        );
        assert!(dev_build(derived).is_some());
        for shipped in [
            bundle(dir.path(), "cmux", "com.cmuxterm.app", None),
            bundle(dir.path(), "cmux NIGHTLY", "com.cmuxterm.app.nightly", None),
            bundle(dir.path(), "cmux NEXT", CMUX_NEXT_NIGHTLY, None),
        ] {
            assert_eq!(dev_build(&shipped), None, "{shipped:?}");
        }
        assert_eq!(dev_build(Path::new("cmux")), None);
        assert_eq!(dev_build(Path::new("/usr/local/bin/cmux")), None);
    }
}
