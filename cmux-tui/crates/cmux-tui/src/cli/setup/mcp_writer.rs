//! Which cmux may write the person's global agent configs (`~/.claude.json`,
//! the Codex config): only a shipped build ([`SHIPPED_BUNDLE_IDS`], with no
//! tag) on the shared settings file. A tagged DEV build, a build from Xcode's
//! DerivedData or a cargo target folder, any other bundle, or any cmux on its
//! own settings file (`CMUX_NEXT_CONFIG_FILE` naming another file than
//! `~/.config/cmux/cmux-next.json`) gives its agents cmux's server only
//! through its own terminals: the `claude` and `codex` shims pass it to each
//! agent they start (`agent_mcp_choice`), with the terminal's settings file.
//! Such a build never touches an entry a shipped build wrote.
//!
//! A shipped build's setup also cleans up after DEV builds: a global `cmux`
//! entry whose command runs from a DEV build ([`dev_build`]) is replaced.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

use cmux_tui_core::user_settings::{CONFIG_OVERRIDE, path_from};

use crate::app_identity::{AppIdentity, containing_app_bundle};

/// The bundle ids cmux ships, one per release channel, as
/// scripts/verify-app-bundle-channel-metadata.sh checks them: classic release
/// (`stable`), classic NIGHTLY (`nightly`), cmux NEXT (`next`), cmux NEXT
/// Stable (`next-stable`, scripts/ci/stable-next-identity.sh) and RC (`rc`).
/// An explicit list, not a parse of the id: NEXT's ids end in a suffix that
/// reads as a tag. A test keeps it equal to the script's table.
pub(super) const SHIPPED_BUNDLE_IDS: [&str; 5] = [
    "com.cmuxterm.app",
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.nightly.cmux-next",
    "com.cmuxterm.app.nightly.cmux-next-stable",
    "com.cmuxterm.app.rc",
];

/// The app names of those channels (`EXPECTED_NAME` in the same script), to
/// know a bundle that is gone and whose Info.plist can no longer be read.
pub(super) const SHIPPED_BUNDLE_NAMES: [&str; 5] =
    ["cmux", "cmux NIGHTLY", "cmux NEXT", "cmux NEXT Stable", "cmux RC"];

/// The `env` keys of a `cmux` entry whose values setup may print and put
/// back: cmux's own routing and settings-file keys, none of them a secret.
/// Any other key (a token, a proxy, `CMUX_SOCKET_PASSWORD`) is never printed,
/// and an entry with one is never replaced or removed (cmux could not put it
/// back).
pub(super) const RESTORABLE_ENV: [&str; 4] =
    ["CMUX_NEXT_CONFIG_FILE", "CMUX_TAG", "CMUX_BUNDLE_ID", "CMUX_TUI_SOCKET"];

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
    if temporary_cache(&exe) {
        return Writer::Terminals(
            "this cmux runs from a temporary cache (npx, uvx, pipx run, bunx or pnpm dlx), which \
             can be gone after this run, so it leaves your agents' own settings alone"
                .to_owned(),
        );
    }
    if let Some(why) = dev_build(&exe) {
        return Writer::Terminals(format!(
            "this cmux is a development build ({why}), so it leaves your agents' own settings alone"
        ));
    }
    if containing_app_bundle(&exe).is_some() && !shipped_bundle(&exe) {
        return Writer::Terminals(
            "only a shipped cmux adds cmux to your agents' own settings; this build leaves them \
             alone"
                .to_owned(),
        );
    }
    Writer::Global
}

/// The settings file `CMUX_NEXT_CONFIG_FILE` names when it is another file
/// than the shared one; `None` when it is unset, empty or the shared file.
fn own_settings_file(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    getenv(CONFIG_OVERRIDE).filter(|value| !value.is_empty())?;
    let named = path_from(|key| getenv(key));
    if names_shared_settings(&named, getenv) { None } else { Some(named) }
}

/// Whether `file` is the shared settings file (`~/.config/cmux/cmux-next.json`
/// under `HOME` from `getenv`), by its path or a link to it.
pub(super) fn names_shared_settings(
    file: &Path,
    getenv: &impl Fn(&str) -> Option<OsString>,
) -> bool {
    let shared = PathBuf::from(getenv("HOME").unwrap_or_default()).join(SHARED_FILE);
    same_file(file, &shared)
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

/// Whether the app bundle around `exe` is a shipped channel's: a bundle id in
/// [`SHIPPED_BUNDLE_IDS`] and no tag of its own (`LSEnvironment` `CMUX_TAG`, a
/// `cmux DEV <tag>.app` name).
fn shipped_bundle(exe: &Path) -> bool {
    AppIdentity::from_bundle(Some(exe)).is_some_and(|identity| {
        identity.shipped_tag.is_none()
            && identity.bundle_id.as_deref().is_some_and(|id| SHIPPED_BUNDLE_IDS.contains(&id))
    })
}

/// The normal components of `path`, as strings.
fn parts(path: &Path) -> Vec<&str> {
    path.components()
        .filter_map(|part| match part {
            Component::Normal(name) => name.to_str(),
            _ => None,
        })
        .collect()
}

/// Whether `path` is in a package runner's disposable cache, gone after the
/// run or the next cleanup: npx (`_npx`), uvx (`archive-v0`), `pipx run`
/// (`pipx/.cache`), bunx (`bunx-…`) or `pnpm dlx` (`pnpm/dlx`).
pub(super) fn temporary_cache(path: &Path) -> bool {
    let parts = parts(path);
    parts.iter().any(|part| *part == "_npx" || *part == "archive-v0" || part.starts_with("bunx-"))
        || parts.windows(2).any(|pair| pair == ["pipx", ".cache"] || pair == ["pnpm", "dlx"])
}

/// Whether `path`, outside any app bundle, is where a shipped release
/// installs cmux's CLI for good: npm's platform package
/// (`node_modules/cmux-tui-<platform>/bin/cmux-tui`,
/// cmux-tui/dist/npm/cmux/bin/cmux.js) or the PyPI wheel
/// (`site-packages/cmux_tui/bin/cmux-tui`, or Debian's and Ubuntu's
/// `dist-packages`; cmux-tui/dist/scripts/package_pypi.py), never a package
/// runner's [`temporary_cache`]. Any other unbundled binary (a cargo target,
/// `cargo install`, a custom target folder) is a development build. The
/// app's own `cmux` link (`/usr/local/bin/cmux`) resolves into its bundle and
/// is judged there.
fn known_install(path: &Path) -> bool {
    if temporary_cache(path) {
        return false;
    }
    let parts = parts(path);
    let [.., package_parent, package, bin, _file] = parts.as_slice() else {
        return false;
    };
    *bin == "bin"
        && ((*package_parent == "node_modules" && package.starts_with("cmux-tui-"))
            || (matches!(*package_parent, "site-packages" | "dist-packages")
                && *package == "cmux_tui"))
}

/// Why the cmux at `command` is a development build, or `None`. A cmux app
/// bundle is shipped only as a [`SHIPPED_BUNDLE_IDS`] bundle with no tag; a
/// bundle that is gone (its Info.plist cannot be read) by its name
/// ([`SHIPPED_BUNDLE_NAMES`]; a `cmux DEV <tag>.app` is DEV). Xcode's
/// DerivedData is DEV. A binary outside any bundle is shipped only at a
/// [`known_install`] path. A bare command name (found on PATH) is the
/// person's, and not judged.
pub(super) fn dev_build(command: &Path) -> Option<String> {
    if command.components().count() < 2 {
        return None;
    }
    let command = resolved(command);
    if parts(&command).contains(&"DerivedData") {
        return Some("it runs from Xcode's DerivedData".to_owned());
    }
    let Some(bundle) = containing_app_bundle(&command) else {
        if temporary_cache(&command) {
            return Some("it runs from a temporary cache".to_owned());
        }
        return (!known_install(&command))
            .then(|| "it runs from outside any installed cmux".to_owned());
    };
    let Some(identity) = AppIdentity::from_bundle(Some(&command)) else {
        let name = bundle.file_stem().and_then(|name| name.to_str()).unwrap_or_default();
        return (!SHIPPED_BUNDLE_NAMES.contains(&name))
            .then(|| format!("it ran from {name}.app, which is no shipped cmux"));
    };
    if shipped_bundle(&command) {
        return None;
    }
    Some(match identity.build().tag() {
        Some(tag) => format!("tag {tag}"),
        None => format!(
            "{}, which is no shipped channel",
            identity.bundle_id.as_deref().unwrap_or("an unknown bundle")
        ),
    })
}

/// `value` of an entry's `CMUX_NEXT_CONFIG_FILE` as a path, a leading `~`
/// expanded to `HOME` from `getenv` (as `path_from` does).
pub(super) fn settings_path(value: &str, getenv: &impl Fn(&str) -> Option<OsString>) -> PathBuf {
    path_from(|key| if key == CONFIG_OVERRIDE { Some(OsString::from(value)) } else { getenv(key) })
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

    /// Only a shipped channel (the bundle ids of
    /// scripts/verify-app-bundle-channel-metadata.sh, no tag) on the shared
    /// settings file writes the person's global agent configs. NEXT Stable's id
    /// ends in `cmux-next-stable`, which reads as a tag: it is shipped anyway.
    #[test]
    fn only_shipped_builds_on_the_shared_file_write_global_agent_configs() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let base = || vec![("HOME", home.display().to_string())];
        let shipped = [
            bundle(dir.path(), "cmux", "com.cmuxterm.app", None),
            bundle(dir.path(), "cmux NIGHTLY", "com.cmuxterm.app.nightly", None),
            bundle(dir.path(), "cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", None),
            bundle(
                dir.path(),
                "cmux NEXT Stable",
                "com.cmuxterm.app.nightly.cmux-next-stable",
                None,
            ),
            bundle(dir.path(), "cmux RC", "com.cmuxterm.app.rc", None),
            // npm's platform package and the PyPI wheel, installed for good.
            dir.path().join("lib/node_modules/cmux-tui-darwin-arm64/bin/cmux-tui"),
            dir.path().join("venv/lib/python3.12/site-packages/cmux_tui/bin/cmux-tui"),
            dir.path().join("usr/lib/python3/dist-packages/cmux_tui/bin/cmux-tui"),
        ];
        for exe in &shipped {
            assert_eq!(writer(exe, env(base())), Writer::Global, "{exe:?}");
            assert_eq!(dev_build(exe), None, "{exe:?}");
            // The override naming the shared file is the shared file.
            let mut shared = base();
            shared.push((CONFIG_OVERRIDE, "~/.config/cmux/cmux-next.json".into()));
            assert_eq!(writer(exe, env(shared)), Writer::Global, "{exe:?}");
        }

        let dev = [
            bundle(dir.path(), "cmux DEV cu-fresh", "com.cmuxterm.app.debug.cu.fresh", None),
            bundle(dir.path(), "cmux DEV", "com.cmuxterm.app.debug", Some("cu-x")),
            bundle(dir.path(), "cmux NIGHTLY t", "com.cmuxterm.app.nightly", Some("t1")),
            bundle(dir.path(), "cmux STAGING", "com.cmuxterm.app.staging", None),
            bundle(dir.path(), "cmux NEXT other", "com.cmuxterm.app.nightly.cmux-next-x", None),
            dir.path().join("Library/Developer/Xcode/DerivedData/cmux-x/Build/cmux"),
            // `cargo run` and `cargo build` outputs, under any target folder name.
            dir.path().join("cmux/cmux-tui/target/debug/cmux-tui"),
            dir.path().join("w/target/release/cmux"),
            dir.path().join("w/target/aarch64-apple-darwin/debug/cmux-tui"),
            dir.path().join("cmux/.build/cmux-tui-rust-target/debug/cmux-tui"),
            dir.path().join("cmux/target-tui/release/cmux-tui"),
            dir.path().join("scratch/out/cmux"),
            // `cargo install`, and npx's and uv's disposable caches.
            dir.path().join("home/.cargo/bin/cmux-tui"),
            dir.path().join("home/.npm/_npx/1a2b/node_modules/cmux-tui-darwin-arm64/bin/cmux-tui"),
            dir.path().join(
                "home/.cache/uv/archive-v0/x/lib/python3.12/site-packages/cmux_tui/bin/cmux-tui",
            ),
        ];
        for exe in &dev {
            assert!(matches!(writer(exe, env(base())), Writer::Terminals(_)), "{exe:?}");
            assert!(dev_build(exe).is_some(), "{exe:?}");
        }
        // A package runner's disposable cache says so, not "development build".
        let temporary = [
            dir.path().join("home/.npm/_npx/1a2b/node_modules/cmux-tui-darwin-arm64/bin/cmux-tui"),
            dir.path().join(
                "home/.cache/uv/archive-v0/x/lib/python3.12/site-packages/cmux_tui/bin/cmux-tui",
            ),
            dir.path().join(
                "home/.local/pipx/.cache/abc/lib/python3.12/site-packages/cmux_tui/bin/cmux-tui",
            ),
            dir.path()
                .join("tmp/bunx-501-cmux@latest/node_modules/cmux-tui-darwin-arm64/bin/cmux-tui"),
            dir.path().join(
                "home/Library/Caches/pnpm/dlx/x/node_modules/cmux-tui-darwin-arm64/bin/cmux-tui",
            ),
        ];
        for exe in &temporary {
            let Writer::Terminals(why) = writer(exe, env(base())) else { panic!("{exe:?}") };
            assert!(why.contains("temporary cache"), "{exe:?}: {why}");
            assert!(!why.contains("development build"), "{exe:?}: {why}");
            assert!(dev_build(exe).is_some_and(|why| why.contains("temporary cache")), "{exe:?}");
        }
        // The release build on its own settings file writes nothing either.
        let mut own = base();
        own.push((CONFIG_OVERRIDE, "~/.config/cmux/cmux-next-cu-fresh.json".into()));
        let Writer::Terminals(why) = writer(&shipped[0], env(own)) else { panic!("global") };
        assert!(why.contains("cmux-next-cu-fresh.json"), "{why}");
    }

    /// Every bundle id the release scripts check for a channel is a shipped
    /// one here: a channel added there and not here would leave its people
    /// without the global entry (NEXT Stable did).
    #[test]
    fn every_channel_of_the_release_scripts_is_shipped() {
        let script = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../scripts/verify-app-bundle-channel-metadata.sh");
        let text = std::fs::read_to_string(&script).expect("the channel metadata script");
        let values = |key: &str| -> Vec<String> {
            text.lines()
                .filter_map(|line| line.trim().strip_prefix(&format!("{key}=\"")))
                .filter_map(|rest| rest.strip_suffix('"'))
                .map(str::to_owned)
                .collect()
        };
        let ids = values("EXPECTED_BUNDLE_ID");
        assert!(ids.len() >= 5, "{ids:?}");
        // A deleted app of every channel is known by its name.
        for name in values("EXPECTED_NAME") {
            let gone = Path::new("/Applications/gone")
                .join(format!("{name}.app/Contents/Resources/bin/cmux"));
            assert_eq!(dev_build(&gone), None, "{name}");
        }
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        for (at, id) in ids.iter().map(String::as_str).enumerate() {
            let exe = bundle(dir.path(), &format!("channel {at}"), id, None);
            assert_eq!(
                writer(&exe, env(vec![("HOME", home.display().to_string())])),
                Writer::Global,
                "{id}"
            );
            assert_eq!(dev_build(&exe), None, "{id}");
        }
    }

    /// The settings file an entry names is the shared one by its path or a
    /// link to it.
    #[test]
    fn the_shared_settings_file_is_known_by_path_or_link() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let shared = home.join(SHARED_FILE);
        std::fs::create_dir_all(shared.parent().unwrap()).unwrap();
        std::fs::write(&shared, "{}").unwrap();
        let link = dir.path().join("link.json");
        std::os::unix::fs::symlink(&shared, &link).unwrap();
        let getenv = env(vec![("HOME", home.display().to_string())]);
        assert!(names_shared_settings(&shared, &getenv));
        assert!(names_shared_settings(&link, &getenv));
        assert!(!names_shared_settings(&home.join(".config/cmux/other.json"), &getenv));
    }

    /// A shipped build replaces an entry whose command runs from a DEV build
    /// (DerivedData, a cargo target, a tagged bundle), never one of a shipped
    /// build or a bare command on PATH.
    #[test]
    fn dev_build_names_derived_data_cargo_targets_and_tagged_bundles() {
        let dir = tempfile::tempdir().unwrap();
        let tagged = bundle(dir.path(), "cmux DEV a", "com.cmuxterm.app.debug.a", None);
        assert_eq!(dev_build(&tagged).as_deref(), Some("tag a"));
        let derived = Path::new(
            "/Users/u/Library/Developer/Xcode/DerivedData/x/cmux DEV.app/Contents/Resources/bin/cmux",
        );
        assert!(dev_build(derived).is_some());
        assert!(dev_build(Path::new("/Users/u/cmux/cmux-tui/target/debug/cmux-tui")).is_some());
        assert_eq!(dev_build(Path::new("cmux")), None, "a bare name on PATH is the person's");
        // An unbundled binary outside a known install is a development build.
        assert!(dev_build(Path::new("/Users/u/target/cmux")).is_some());
        // A deleted DEV app is still a DEV app; a deleted shipped app is not.
        let gone =
            |name: &str| format!("/Applications/gone/{name}.app/Contents/Resources/bin/cmux");
        assert!(dev_build(Path::new(&gone("cmux DEV cu-fresh"))).is_some());
        assert!(dev_build(Path::new(&gone("cmux DEV"))).is_some());
        assert_eq!(dev_build(Path::new(&gone("cmux NEXT Stable"))), None);
        assert_eq!(dev_build(Path::new(&gone("cmux"))), None);
    }

    /// An entry's settings file with a leading `~` is the home's.
    #[test]
    fn an_entrys_settings_file_expands_the_home() {
        let getenv = env(vec![("HOME", "/Users/u".to_owned())]);
        assert_eq!(
            settings_path("~/.config/cmux/cmux-next.json", &getenv),
            PathBuf::from("/Users/u/.config/cmux/cmux-next.json")
        );
        assert_eq!(settings_path("/a/b.json", &getenv), PathBuf::from("/a/b.json"));
    }
}
