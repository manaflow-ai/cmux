use super::*;

#[test]
fn the_search_goes_from_the_enclosing_app_to_the_installed_ones() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let make = |app: &Path, name: &str| {
        let h = app.join("Contents/Library").join(name);
        std::fs::create_dir_all(h.join("Contents/MacOS")).unwrap();
        std::fs::write(h.join("Contents/MacOS/helper"), "x").unwrap();
        h
    };
    let own = dir.join("own.app");
    let nightly = dir.join("nightly.app");
    let stable = dir.join("stable.app");
    let (n, s) = (nightly.to_str().unwrap(), stable.to_str().unwrap());
    let exe = own.join("Contents/Resources/bin/cmux-tui");
    assert_eq!(search_apps(&exe, &[n, s]), vec![own.clone(), nightly.clone(), stable.clone()]);
    assert_eq!(
        search_apps(&dir.join("bin/cmux-tui"), &[n, s]),
        vec![nightly.clone(), stable.clone()]
    );
    assert_eq!(search_apps(&nightly.join("Contents/MacOS/x"), &[n]), vec![nightly.clone()]);
    // Nothing installed anywhere: none.
    assert_eq!(first_helper(&search_apps(&exe, &[n, s]), "helper"), None);
    // Only the stable app has one (an older build's name): a daemon outside any app runs it.
    let in_stable = make(&stable, "cmux Screen Sharing.app");
    assert_eq!(first_helper(&search_apps(&dir.join("bin/x"), &[n, s]), "helper"), Some(in_stable));
    // NIGHTLY beats stable; the enclosing app beats both.
    let in_nightly = make(&nightly, "cmux NIGHTLY Helper.app");
    assert_eq!(
        first_helper(&search_apps(&dir.join("bin/x"), &[n, s]), "helper"),
        Some(in_nightly.clone())
    );
    let in_own = make(&own, "cmux DEV Helper.app");
    assert_eq!(first_helper(&search_apps(&exe, &[n, s]), "helper"), Some(in_own));
    // A bundle without the executable, or not named as a helper, is none.
    std::fs::remove_file(in_nightly.join("Contents/MacOS/helper")).unwrap();
    make(&nightly, "Other.app");
    assert_eq!(helpers_in(&nightly, "helper"), Vec::<PathBuf>::new());
}

#[test]
fn the_current_helper_name_comes_before_the_old_one() {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().join("cmux.app");
    for name in ["cmux A Screen Sharing.app", "cmux Z Helper.app", "cmux B Helper.app"] {
        let h = app.join("Contents/Library").join(name);
        std::fs::create_dir_all(h.join("Contents/MacOS")).unwrap();
        std::fs::write(h.join("Contents/MacOS/helper"), "x").unwrap();
    }
    let names: Vec<String> = helpers_in(&app, "helper")
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["cmux B Helper.app", "cmux Z Helper.app", "cmux A Screen Sharing.app"]);
}

/// A fake bundle `<dir>/<name>` whose executable holds `body`.
fn bundle(dir: &Path, name: &str, body: &str) -> PathBuf {
    let app = dir.join(name);
    std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
    std::fs::create_dir_all(app.join("Contents/_CodeSignature")).unwrap();
    std::fs::write(app.join("Contents/MacOS/helper"), body).unwrap();
    std::fs::write(app.join("Contents/_CodeSignature/CodeResources"), "seal").unwrap();
    std::fs::write(app.join("Contents/Info.plist"), "plist").unwrap();
    app
}

fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
    std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
    for entry in std::fs::read_dir(from).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let target = to.join(entry.file_name());
        if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// The names in `dir`, sorted.
fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn the_digest_covers_the_executable_seal_and_plist() {
    let dir = tempfile::tempdir().unwrap();
    let parts = digest_parts("helper");
    let one = digest_of(&bundle(dir.path(), "A.app", "one"), &parts).unwrap();
    let two = digest_of(&bundle(dir.path(), "B.app", "two"), &parts).unwrap();
    assert_eq!(one.len(), 64);
    assert_ne!(one, two);
    assert!(digest_of(&dir.path().join("missing.app"), &parts).is_err());
}

#[test]
fn every_helper_has_one_fixed_folder_per_bundle_id() {
    assert_eq!(
        helper_folder(Path::new("/Users/me"), "com.cmuxterm.app.nightly.screen-sharing"),
        Path::new(
            "/Users/me/Library/Application Support/cmux-next/helper/com.cmuxterm.app.nightly.screen-sharing"
        )
    );
}

#[test]
fn every_build_stages_to_the_same_path_and_replaces_the_copy_in_place() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("helper/com.cmuxterm.app.screen-sharing");
    let parts = digest_parts("helper");
    let first = bundle(&dir.path().join("v1"), "cmux Helper.app", "one");
    let staged = stage_with(&first, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
    assert_eq!(staged.app, folder.join("cmux Helper.app"));
    assert!(staged.executable("helper").is_file());
    // Reused: a copier that fails is never asked.
    let again =
        stage_with(&first, &folder, &parts, |_, _| Err("copied".into()), |_| Ok(())).unwrap();
    assert_eq!(again, staged);
    // A process of the first build holds its executable open across the update.
    let running = std::fs::File::open(staged.executable("helper")).unwrap();
    // The next builds: the same path, the new bytes, nothing else left beside it.
    for body in ["two", "three"] {
        let next = bundle(&dir.path().join(body), "cmux Helper.app", body);
        let replaced = stage_with(&next, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
        assert_eq!(replaced.app, staged.app);
        assert_ne!(replaced.digest, staged.digest);
        let text = std::fs::read_to_string(replaced.executable("helper")).unwrap();
        assert_eq!(text, body);
        assert_eq!(names(&folder), [".lock", ".verified", "cmux Helper.app"]);
        let marker = std::fs::read_to_string(folder.join(".verified")).unwrap();
        assert_eq!(marker, replaced.digest);
    }
    let mut old = String::new();
    (&running).read_to_string(&mut old).unwrap();
    assert_eq!(old, "one");
}

#[test]
fn a_copy_without_its_marker_or_with_other_bytes_is_made_again() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("f");
    let parts = digest_parts("helper");
    let source = bundle(dir.path(), "cmux Helper.app", "one");
    let staged = stage_with(&source, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
    std::fs::remove_file(folder.join(".verified")).unwrap();
    let refused = stage_with(&source, &folder, &parts, |_, _| Err("copied".into()), |_| Ok(()));
    assert_eq!(refused, Err("copied".into()));
    assert!(stage_with(&source, &folder, &parts, copy_tree, |_| Ok(())).is_ok());
    std::fs::write(staged.executable("helper"), "changed").unwrap();
    let refused = stage_with(&source, &folder, &parts, |_, _| Err("copied".into()), |_| Ok(()));
    assert_eq!(refused, Err("copied".into()));
}

#[test]
fn a_copy_that_fails_its_check_never_replaces_the_good_one() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("f");
    let parts = digest_parts("helper");
    let good = bundle(&dir.path().join("v1"), "cmux Helper.app", "one");
    let staged = stage_with(&good, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
    let next = bundle(&dir.path().join("v2"), "cmux Helper.app", "two");
    let refused = stage_with(&next, &folder, &parts, copy_tree, |_| Err("unsigned".into()));
    assert_eq!(refused, Err("unsigned".into()));
    // A copier that changes the bytes is caught by the digest.
    let tamper = |from: &Path, to: &Path| {
        copy_tree(from, to)?;
        std::fs::write(to.join("Contents/MacOS/helper"), "evil").map_err(|e| e.to_string())
    };
    let refused = stage_with(&next, &folder, &parts, tamper, |_| Ok(()));
    assert_eq!(refused, Err("the copy differs from the source bundle".into()));
    assert_eq!(std::fs::read_to_string(staged.executable("helper")).unwrap(), "one");
    assert_eq!(names(&folder), [".lock", ".verified", "cmux Helper.app"]);
}

#[test]
fn concurrent_stagers_take_turns_and_agree() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("f");
    let parts = digest_parts("helper");
    let source = bundle(dir.path(), "cmux Helper.app", "one");
    let inside = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let copies = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let results: Vec<Staged> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let (inside, copies, folder, parts, source) =
                    (inside.clone(), copies.clone(), &folder, &parts, &source);
                scope.spawn(move || {
                    let copy = |from: &Path, to: &Path| {
                        use std::sync::atomic::Ordering::SeqCst;
                        // Never two copiers at once: the folder's lock is held.
                        assert_eq!(inside.fetch_add(1, SeqCst), 0);
                        copies.fetch_add(1, SeqCst);
                        std::thread::sleep(std::time::Duration::from_millis(30));
                        let copied = copy_tree(from, to);
                        inside.fetch_sub(1, SeqCst);
                        copied
                    };
                    stage_with(source, folder, parts, copy, |_| Ok(())).unwrap()
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    assert!(results.windows(2).all(|pair| pair[0] == pair[1]));
    // The first one copied; the rest found its copy ready.
    assert_eq!(copies.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[test]
fn the_old_per_digest_copies_are_removed_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let support = dir.path().join("cmux-next");
    let id = support.join("screen-sharing/com.cmuxterm.app.nightly.screen-sharing");
    let mine = id.join("computer-use");
    bundle(&mine.join("abedd9b827d7038f"), "cmux NIGHTLY Screen Sharing.app", "a");
    bundle(&mine.join("6746ffe600b6f02a"), "cmux NIGHTLY Screen Sharing.app", "b");
    std::fs::create_dir_all(mine.join(".staging-123")).unwrap();
    // Another stager's slot beside it stays, and so do the folders that hold it.
    bundle(&id.join("daemon/0123456789abcdef"), "cmux NIGHTLY Screen Sharing.app", "c");
    let removed = remove_legacy_root(&mine, &support);
    assert_eq!(removed.len(), 3);
    assert!(!mine.exists());
    assert!(id.join("daemon/0123456789abcdef").is_dir());
    // The last one out removes the empty folders up to, never including, `stop`.
    assert_eq!(remove_legacy_root(&id.join("daemon"), &support).len(), 1);
    assert!(!support.join("screen-sharing").exists());
    assert!(support.is_dir());
    // A folder holding anything else is left with it; a missing one is nothing.
    let other = support.join("screen-sharing/x/daemon");
    std::fs::create_dir_all(other.join("not-hex-name")).unwrap();
    std::fs::write(other.join("notes.txt"), "keep").unwrap();
    assert!(remove_legacy_root(&other, &support).is_empty());
    assert!(other.join("notes.txt").is_file() && other.join("not-hex-name").is_dir());
    assert!(remove_legacy_root(&support.join("missing"), &support).is_empty());
}

#[test]
fn staging_in_a_folder_of_the_old_layout_clears_its_slots() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("files-host/app");
    bundle(&folder.join("00112233aabbccdd"), "cmux Files (dev).app", "old");
    std::fs::create_dir_all(folder.join(".staging-99")).unwrap();
    let parts = digest_parts("helper");
    let source = bundle(dir.path(), "cmux Files (dev).app", "new");
    stage_with(&source, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
    assert_eq!(names(&folder), [".lock", ".verified", "cmux Files (dev).app"]);
}

#[cfg(unix)]
#[test]
fn a_symlink_in_the_way_is_replaced_never_followed() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("f");
    let target = dir.path().join("elsewhere");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::create_dir_all(&folder).unwrap();
    std::os::unix::fs::symlink(&target, folder.join("cmux Helper.app")).unwrap();
    let parts = digest_parts("helper");
    let source = bundle(dir.path(), "cmux Helper.app", "one");
    let staged = stage_with(&source, &folder, &parts, copy_tree, |_| Ok(())).unwrap();
    assert!(std::fs::symlink_metadata(&staged.app).unwrap().is_dir());
    assert!(target.is_dir() && names(&target).is_empty());
}

#[cfg(unix)]
#[test]
fn a_symlinked_root_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert!(private_dir(&link).is_err());
    assert!(private_dir(&real).is_ok());
}

#[test]
fn requirements_read_and_write_as_codesign_does() {
    assert_eq!(
        team_requirement("com.cmuxterm.app.screen-sharing", "7WLXT3NR37"),
        "identifier \"com.cmuxterm.app.screen-sharing\" and anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\""
    );
    let printed = "Executable=/x/Helper.app/Contents/MacOS/helper\n# designated => cdhash H\"ab\"\ndesignated => identifier \"a.b\" and anchor apple generic\n";
    assert_eq!(
        parse_designated(printed).as_deref(),
        Some("identifier \"a.b\" and anchor apple generic")
    );
    assert_eq!(parse_designated("Executable=/x\n"), None);
}

#[test]
fn an_ad_hoc_signature_reads_its_implied_cdhash_requirement() {
    let printed =
        "Executable=/x/Helper.app/Contents/MacOS/helper\n# designated => cdhash H\"0123abcd\"\n";
    assert_eq!(parse_designated(printed).as_deref(), Some("cdhash H\"0123abcd\""));
    // Only an implied cdhash counts; any other commented line is not a requirement.
    assert_eq!(parse_designated("# designated => identifier \"a.b\"\n"), None);
    assert_eq!(parse_designated("# designated =>\n"), None);
}
