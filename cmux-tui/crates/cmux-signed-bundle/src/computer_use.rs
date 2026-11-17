//! The Computer Use helper, cmux's one permission app: `<app>/Contents/Library/cmux Computer
//! Use.app` (`com.cmuxterm.cua`, Developer ID) in Release, NIGHTLY and RC, `cmux Computer Use
//! (dev).app` (`com.cmuxterm.cua.dev`, the pinned Apple Development signature) in DEV. Its
//! `Contents/MacOS` holds its main executable, the supervisor (`cmux-remote`, which the daemon
//! starts and which runs the Computer Use and Screen Sharing workers) and the Screen Sharing
//! executable (`cmux-screen-sharing`, which the acpmux share host runs), each signed with the
//! helper's identifier, so macOS asks for and names one app's Accessibility and Screen
//! Recording grants.
//!
//! Both runners stage the SAME copy through [`stage`]: one root per bundle id, one digest over
//! the same parts, one lock. Whichever runs first copies and checks the bundle; the other
//! finds that copy and reuses it.

use std::path::{Path, PathBuf};

/// The Release, NIGHTLY and RC helper's bundle name in `Contents/Library`.
pub const APP: &str = "cmux Computer Use.app";
/// The DEV helper's bundle name in `Contents/Library`.
pub const DEV_APP: &str = "cmux Computer Use (dev).app";
/// The Release, NIGHTLY and RC helper's bundle id and signing identifier.
pub const BUNDLE_ID: &str = "com.cmuxterm.cua";
/// The DEV helper's bundle id and signing identifier.
pub const DEV_BUNDLE_ID: &str = "com.cmuxterm.cua.dev";
/// The Release helper's main executable (`CFBundleExecutable`).
pub const MAIN_EXECUTABLE: &str = "cmux-cua";
/// The DEV helper's main executable (`CFBundleExecutable`).
pub const DEV_MAIN_EXECUTABLE: &str = "cmux-cua-helper";
/// The supervisor the daemon starts (`cmux-remote host ...`).
pub const SUPERVISOR: &str = "cmux-remote";
/// The Screen Sharing executable the acpmux share host runs (`cmux-screen-sharing serve`).
pub const SCREEN_SHARING: &str = "cmux-screen-sharing";
/// cmux's signing team.
pub const TEAM: &str = "7WLXT3NR37";
/// The Release helper's pinned Developer ID requirement. Keep equal to
/// CuaHelperIdentity.requirement in CmuxNextAgentActivity.
pub const REQUIREMENT: &str = concat!(
    "identifier \"com.cmuxterm.cua\" and anchor apple generic",
    " and certificate 1[field.1.2.840.113635.100.6.2.6]",
    " and certificate leaf[field.1.2.840.113635.100.6.1.13]",
    " and certificate leaf[subject.OU] = \"7WLXT3NR37\"",
);

/// Whether `id` is a Computer Use helper's bundle id.
pub fn is_bundle_id(id: &str) -> bool {
    id == BUNDLE_ID || id == DEV_BUNDLE_ID
}

/// What a copy of the helper `id` must satisfy: the Release helper's pinned Developer ID
/// requirement, or for the DEV helper its identifier signed by cmux's team. None for any other
/// bundle.
pub fn requirement(id: &str) -> Option<String> {
    match id {
        BUNDLE_ID => Some(REQUIREMENT.to_owned()),
        DEV_BUNDLE_ID => Some(super::team_requirement(DEV_BUNDLE_ID, TEAM)),
        _ => None,
    }
}

/// The helpers `app` carries in `Contents/Library` that hold `Contents/MacOS/<executable>`:
/// the Release helper, then the DEV one.
pub fn bundles_in(app: &Path, executable: &str) -> Vec<PathBuf> {
    [APP, DEV_APP]
        .iter()
        .map(|name| app.join("Contents/Library").join(name))
        .filter(|bundle| bundle.join("Contents/MacOS").join(executable).is_file())
        .collect()
}

/// The one staging root of the helper `id`'s copies:
/// `~/Library/Application Support/cmux-next/screen-sharing/<id>/daemon` (the acpmux share host's
/// root since the Screen Sharing executable moved into the helper; the app stages its own
/// copies beside it, never here).
pub fn staging_root(user_home: &Path, id: &str) -> PathBuf {
    user_home.join("Library/Application Support/cmux-next/screen-sharing").join(id).join("daemon")
}

/// The parts of `app` whose bytes make its digest: every file in `Contents/MacOS` by name (the
/// main executable, the supervisor and the Screen Sharing executable, whichever it carries),
/// then the seal and the Info.plist. Both runners read them from the same bundle, so they land
/// on the same slot.
pub fn digest_parts(app: &Path) -> Result<Vec<String>, String> {
    let macos = app.join("Contents/MacOS");
    let entries = std::fs::read_dir(&macos).map_err(|e| format!("{}: {e}", macos.display()))?;
    let mut executables: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    executables.sort();
    let mut parts: Vec<String> =
        executables.into_iter().map(|name| format!("Contents/MacOS/{name}")).collect();
    parts.push("Contents/_CodeSignature/CodeResources".to_owned());
    parts.push("Contents/Info.plist".to_owned());
    Ok(parts)
}

/// The verified copy of the helper bundle `source` that both runners run: its id must be a
/// Computer Use helper's, its copy under [`staging_root`] must carry its [`digest_parts`] and
/// satisfy its [`requirement`].
pub fn stage(source: &Path, user_home: &Path) -> Result<super::Staged, String> {
    let id = super::bundle_id(source).ok_or("the bundle has no identifier")?;
    stage_checked(source, user_home, &id, |copy, requirement| super::verify(copy, requirement))
}

/// [`stage`] with the bundle id read and the signature check given (tests run it on any Unix).
pub fn stage_checked(
    source: &Path,
    user_home: &Path,
    id: &str,
    verify: impl Fn(&Path, &str) -> Result<(), String>,
) -> Result<super::Staged, String> {
    let requirement =
        requirement(id).ok_or_else(|| format!("{id} is not the cmux Computer Use helper"))?;
    let parts = digest_parts(source)?;
    let root = staging_root(user_home, id);
    super::stage(source, &root, &parts, |copy| verify(copy, &requirement))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake helper `<app>/Contents/Library/<name>` holding `executables`.
    fn helper(app: &Path, name: &str, executables: &[&str]) -> PathBuf {
        let bundle = app.join("Contents/Library").join(name);
        std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
        std::fs::create_dir_all(bundle.join("Contents/_CodeSignature")).unwrap();
        for executable in executables {
            std::fs::write(bundle.join("Contents/MacOS").join(executable), executable).unwrap();
        }
        std::fs::write(bundle.join("Contents/_CodeSignature/CodeResources"), "seal").unwrap();
        std::fs::write(bundle.join("Contents/Info.plist"), "plist").unwrap();
        bundle
    }

    #[test]
    fn the_supervisor_is_found_in_the_release_helper_then_the_dev_one() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("cmux.app");
        let release = helper(&app, APP, &[MAIN_EXECUTABLE, SUPERVISOR, SCREEN_SHARING]);
        let dev = helper(&app, DEV_APP, &[DEV_MAIN_EXECUTABLE, SUPERVISOR]);
        assert_eq!(bundles_in(&app, SUPERVISOR), [release.clone(), dev]);
        assert_eq!(bundles_in(&app, SCREEN_SHARING), [release]);
        // A DEV helper published before it carried the supervisor: no supervisor at all.
        let older = dir.path().join("older.app");
        helper(&older, DEV_APP, &[DEV_MAIN_EXECUTABLE]);
        assert!(bundles_in(&older, SUPERVISOR).is_empty());
        // A retired `cmux Remote.app` is never looked at.
        let retired = dir.path().join("retired.app");
        helper(&retired, "cmux Remote.app", &[SUPERVISOR]);
        assert!(bundles_in(&retired, SUPERVISOR).is_empty());
    }

    #[test]
    fn the_release_helper_is_pinned_and_the_dev_one_is_checked_by_team() {
        assert_eq!(requirement(BUNDLE_ID).as_deref(), Some(REQUIREMENT));
        assert_eq!(
            requirement(DEV_BUNDLE_ID).as_deref(),
            Some(
                "identifier \"com.cmuxterm.cua.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\""
            )
        );
        for retired in ["com.cmuxterm.remote", "com.cmuxterm.remote.dev", "com.cmuxterm.app"] {
            assert_eq!(requirement(retired), None);
            assert!(!is_bundle_id(retired));
        }
        assert!(REQUIREMENT.starts_with("identifier \"com.cmuxterm.cua\" "));
    }

    #[test]
    fn the_digest_covers_every_executable_the_seal_and_the_plist() {
        let dir = tempfile::tempdir().unwrap();
        let release = helper(dir.path(), APP, &[SUPERVISOR, MAIN_EXECUTABLE, SCREEN_SHARING]);
        assert_eq!(
            digest_parts(&release).unwrap(),
            [
                "Contents/MacOS/cmux-cua",
                "Contents/MacOS/cmux-remote",
                "Contents/MacOS/cmux-screen-sharing",
                "Contents/_CodeSignature/CodeResources",
                "Contents/Info.plist",
            ]
        );
        assert!(digest_parts(&dir.path().join("missing.app")).is_err());
    }

    #[test]
    fn both_runners_stage_one_copy() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let app = dir.path().join("cmux.app");
        let source = helper(&app, APP, &[MAIN_EXECUTABLE, SUPERVISOR, SCREEN_SHARING]);
        fn copy(from: &Path, to: &Path) -> Result<(), String> {
            std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
            for entry in std::fs::read_dir(from).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let target = to.join(entry.file_name());
                if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
                    copy(&entry.path(), &target)?;
                } else {
                    std::fs::copy(entry.path(), target).map_err(|e| e.to_string())?;
                }
            }
            Ok(())
        }
        let checked: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
        // The supervisor's stage, then the share host's: the second reuses the first's copy.
        let stage_once = || {
            let requirement = requirement(BUNDLE_ID).unwrap();
            let parts = digest_parts(&source).unwrap();
            super::super::stage_with(&source, &staging_root(&home, BUNDLE_ID), &parts, copy, |_| {
                checked.lock().unwrap().push(requirement.clone());
                Ok(())
            })
        };
        let supervisor = stage_once().unwrap();
        let share_host = stage_once().unwrap();
        assert_eq!(supervisor, share_host);
        assert_eq!(checked.lock().unwrap().len(), 1, "one copy, checked once");
        assert_eq!(checked.lock().unwrap()[0], REQUIREMENT);
        assert!(supervisor.app.starts_with(
            home.join(
                "Library/Application Support/cmux-next/screen-sharing/com.cmuxterm.cua/daemon"
            )
        ));
        assert!(supervisor.executable(SUPERVISOR).is_file());
        assert!(supervisor.executable(SCREEN_SHARING).is_file());
        // `stage_checked` (what `stage` runs) lands on that same copy.
        let again = stage_checked(&source, &home, BUNDLE_ID, |_, _| Ok(())).unwrap();
        assert_eq!(again, supervisor);
        // Another bundle id is refused before anything is copied.
        let refused = stage_checked(&source, &home, "com.cmuxterm.remote", |_, _| Ok(()));
        assert_eq!(refused, Err("com.cmuxterm.remote is not the cmux Computer Use helper".into()));
    }
}
