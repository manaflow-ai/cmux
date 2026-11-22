use super::*;

fn look(unlinked: bool, path_exists: bool, bundle_exists: bool) -> Look {
    Look { unlinked, path_exists, bundle_exists }
}

#[test]
fn a_linked_program_is_never_changed() {
    assert_eq!(judge(look(false, true, true)), None);
    assert_eq!(judge(look(false, false, false)), None, "unreadable: never gone");
}

#[test]
fn a_new_file_at_the_path_is_a_restart() {
    assert_eq!(judge(look(true, true, true)), Some(Outcome::Replaced));
    assert_eq!(judge(look(true, true, false)), Some(Outcome::Replaced), "~/.local/bin");
}

#[test]
fn a_gone_program_and_bundle_is_a_removal_mid_update_is_not() {
    assert_eq!(judge(look(true, false, false)), Some(Outcome::Removed));
    assert_eq!(judge(look(true, false, true)), None, "the bundle is still there");
}

#[test]
fn an_outcome_counts_after_two_looks_in_a_row() {
    let mut debounce = Debounce::default();
    assert_eq!(debounce.push(Some(Outcome::Removed)), None);
    assert_eq!(debounce.push(Some(Outcome::Replaced)), None, "it changed");
    assert_eq!(debounce.push(Some(Outcome::Replaced)), Some(Outcome::Replaced));
    assert_eq!(debounce.push(None), None);
    assert_eq!(debounce.push(Some(Outcome::Removed)), None);
    assert_eq!(debounce.push(Some(Outcome::Removed)), Some(Outcome::Removed));
}

#[test]
fn the_bundle_is_the_app_around_the_program() {
    let exe = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
    assert_eq!(app_bundle(exe), Some(PathBuf::from("/Applications/cmux NIGHTLY.app")));
    assert_eq!(app_bundle(Path::new("/Users/a/.local/bin/cmux")), None);
}

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-lr-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn looks_follow_an_update_a_deletion_and_a_move() {
    let dir = scratch("look");
    let bundle = dir.join("cmux.app");
    let bin = bundle.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let exe = bin.join("cmux");
    std::fs::write(&exe, b"one").unwrap();
    let program = Program::open(exe.clone());
    assert_eq!(judge(program.look()), None);
    // Touched or re-signed in place: the same file.
    std::fs::write(&exe, b"one, signed").unwrap();
    assert_eq!(judge(program.look()), None);
    // An update writes a new file over the name.
    let next = bin.join("cmux.next");
    std::fs::write(&next, b"two").unwrap();
    std::fs::rename(&next, &exe).unwrap();
    assert_eq!(judge(program.look()), Some(Outcome::Replaced));
    // The app is deleted.
    let second = Program::open(exe.clone());
    std::fs::remove_dir_all(&bundle).unwrap();
    assert_eq!(judge(second.look()), Some(Outcome::Removed));
    // Moved: the file keeps a name elsewhere.
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(&exe, b"three").unwrap();
    let third = Program::open(exe);
    std::fs::rename(&bundle, dir.join("moved.app")).unwrap();
    assert_eq!(judge(third.look()), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn only_a_plist_that_runs_this_program_is_removed() {
    let dir = scratch("plist");
    let plist = dir.join("agent.plist");
    let write = |program: &str| {
        let mut d = plist::Dictionary::new();
        d.insert(
            "ProgramArguments".into(),
            plist::Value::Array(vec![program.into(), "link".into(), "serve".into()]),
        );
        plist::Value::Dictionary(d).to_file_xml(&plist).unwrap();
    };
    // The program as launched through a symlink, and its resolved target.
    let bundle = dir.join("cmux.app/Contents/Resources/bin");
    std::fs::create_dir_all(&bundle).unwrap();
    let target = bundle.join("cmux");
    std::fs::write(&target, b"one").unwrap();
    let link = dir.join("cmux-link");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let program = Program::open(link.clone());
    write(&link.to_string_lossy());
    assert!(plist_program(&plist).is_some_and(|p| program.is(&p)), "the launched spelling");
    let resolved = std::fs::canonicalize(&target).unwrap();
    write(&resolved.to_string_lossy());
    assert!(plist_program(&plist).is_some_and(|p| program.is(&p)), "the resolved spelling");
    write("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
    assert!(!plist_program(&plist).is_some_and(|p| program.is(&p)), "a later install");
    assert_eq!(plist_program(&dir.join("missing.plist")), None);
    // Launched through a symlink: the bundle is the one around its target.
    assert!(program.look().bundle_exists);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn only_launchd_for_this_label_runs_the_watch() {
    // The test process is no launchd job of these labels.
    assert!(!run_by_launchd("com.cmuxterm.link-test-absent"));
    assert!(for_agent("com.cmuxterm.link-test-absent", PathBuf::from("/x.plist")).is_none());
}
