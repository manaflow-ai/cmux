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
    assert_eq!(find_helper(None, &exe, &[], None), None);
    // A bundle without the executable is no helper; the current name beats the old one.
    helper(&app.join("Contents/Library/cmux A Screen Sharing.app"), "x", false);
    helper(&app.join("Contents/Library/cmux NIGHTLY Helper.app"), "x", true);
    helper(&app.join("Contents/Library/cmux Z Screen Sharing.app"), "x", true);
    helper(&app.join("Contents/Library/Other.app"), "x", true);
    assert_eq!(
        find_helper(None, &exe, &[], None),
        Some(app.join("Contents/Library/cmux NIGHTLY Helper.app"))
    );
    // A daemon outside any app bundle finds none.
    assert_eq!(find_helper(None, &root.join("bin/cmux-tui"), &[], None), None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_daemon_outside_any_app_runs_the_installed_apps_helper() {
    let root = scratch("installed");
    let nightly = root.join("Applications/cmux NIGHTLY.app");
    let stable = root.join("Applications/cmux.app");
    let installed = [nightly.to_str().unwrap(), stable.to_str().unwrap()];
    let bare = root.join("bin/cmux-tui");
    assert_eq!(find_helper(None, &bare, &installed, None), None);
    let in_stable = stable.join("Contents/Library/cmux Screen Sharing.app");
    helper(&in_stable, "x", true);
    assert_eq!(find_helper(None, &bare, &installed, None), Some(in_stable));
    // NIGHTLY is searched before stable.
    let in_nightly = nightly.join("Contents/Library/cmux NIGHTLY Helper.app");
    helper(&in_nightly, "x", true);
    assert_eq!(find_helper(None, &bare, &installed, None), Some(in_nightly));
    // The app holding the daemon comes first, and the override beats all.
    let own = root.join("own.app");
    let in_own = own.join("Contents/Library/cmux Screen Sharing.app");
    helper(&in_own, "x", true);
    let exe = own.join("Contents/Resources/bin/cmux-tui");
    assert_eq!(find_helper(None, &exe, &installed, None), Some(in_own));
    let dev = root.join("Dev Screen Sharing.app");
    helper(&dev, "x", true);
    assert_eq!(find_helper(Some(dev.clone()), &exe, &installed, None), Some(dev));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_machine_without_a_cmux_app_runs_the_standalone_installed_helper() {
    let root = scratch("standalone");
    let stable = root.join("Applications/cmux.app");
    let installed = [stable.to_str().unwrap()];
    let standalone = root.join("standalone");
    let bare = root.join("bin/cmux-tui");
    // `cmux computer-use install` has not run: nothing to run.
    assert_eq!(find_helper(None, &bare, &installed, Some(&standalone)), None);
    let in_standalone = standalone.join("Contents/Library/cmux NIGHTLY Helper.app");
    helper(&in_standalone, "x", true);
    assert_eq!(
        find_helper(None, &bare, &installed, Some(&standalone)),
        Some(in_standalone.clone())
    );
    // An installed app's own helper comes first: the standalone one is only the fallback.
    let in_stable = stable.join("Contents/Library/cmux Helper.app");
    helper(&in_stable, "x", true);
    assert_eq!(find_helper(None, &bare, &installed, Some(&standalone)), Some(in_stable));
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
    assert_eq!(find_helper(Some(dev.clone()), &exe, &[], None), Some(dev));
    // Set but not a helper: refused, never a silent fall back to the bundled one.
    assert_eq!(find_helper(Some(root.join("missing.app")), &exe, &[], None), None);
    // Empty means unset.
    assert_eq!(
        find_helper(Some(PathBuf::new()), &exe, &[], None),
        Some(app.join("Contents/Library/cmux Screen Sharing.app"))
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn only_cmux_helper_ids_stage_at_their_fixed_path() {
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
            "/Users/me/Library/Application Support/cmux-next/helper/com.cmuxterm.app.nightly.screen-sharing"
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
