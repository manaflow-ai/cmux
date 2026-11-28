use super::*;
use crate::store::care_tests::scratch;

#[test]
fn globs_match_within_parts_and_across_them() {
    assert!(glob_match("/h/*/cache", "/h/a/cache"));
    assert!(!glob_match("/h/*/cache", "/h/a/b/cache"));
    assert!(glob_match("/h/**/cache", "/h/a/b/cache"));
    assert!(glob_match("/h/a?", "/h/ab"));
    assert!(!glob_match("/h/a?", "/h/a/"));
}

#[test]
fn the_fleet_list_and_a_users_file_both_keep_things_with_a_reason() {
    let home = scratch("never");
    std::fs::create_dir_all(user_file(&home).parent().unwrap()).unwrap();
    std::fs::write(user_file(&home), "# mine\n~/keep/me  # trailing\nprecious-*\n/srv/**/golden\n")
        .unwrap();
    let (never, problems) = NeverDelete::load(&home);
    assert!(problems.is_empty(), "{problems:?}");
    // Fleet entries.
    assert!(never.holds(&home, &home.join("cmux-browser-fleet/x")).is_some());
    assert!(never.holds(&home, &home.join("Library/Caches/siso")).is_some());
    assert!(never.holds(&home, &home.join("work/depot_tools/out")).is_some());
    // The user's: a folder and everything in it, a by-name glob, an absolute deep glob.
    let held = never.holds(&home, &home.join("keep/me/deep/file")).expect("held");
    assert!(held.contains("keep/me"), "{held}");
    assert!(never.holds(&home, &home.join("x/precious-data/a")).is_some());
    assert!(never.holds(&home, Path::new("/srv/a/b/golden/x")).is_some());
    // Others go on as before.
    assert!(never.holds(&home, &home.join(".npm/_cacache")).is_none());
    assert!(never.holds(&home, &home.join("keep/other")).is_none());
}

#[test]
fn recursive_protection_is_bounded_and_fails_closed() {
    use std::time::{Duration, Instant};
    let home = scratch("never-tree");
    let tree = home.join("tree");
    std::fs::create_dir_all(tree.join("nested")).unwrap();
    std::fs::write(tree.join("nested/keep.txt"), "precious").unwrap();
    for glob in ["~/tree/nested/keep.txt", "keep.*", "~/tree/**/keep.txt"] {
        let never = NeverDelete::from_globs([glob.into()]);
        assert!(never.holds_tree(&home, &tree).is_some(), "{glob}");
    }
    assert!(NONE.holds_tree(&home, &tree).is_none());
    assert!(NONE.inspect_tree(&home, &tree, 0, Instant::now() + Duration::from_secs(1)).is_some());
    assert!(NONE.inspect_tree(&home, &tree, 100, Instant::now()).is_some());
    assert!(NONE.holds_tree(&home, &home.join("missing")).is_some());
    std::fs::create_dir(tree.join("nested/depot_tools")).unwrap();
    assert!(NONE.holds_tree(&home, &tree).is_some());
}

#[cfg(unix)]
#[test]
fn recursive_protection_does_not_follow_links_outside_the_tree() {
    let home = scratch("never-tree-link");
    let tree = home.join("tree");
    std::fs::create_dir(&tree).unwrap();
    std::fs::create_dir(home.join("outside")).unwrap();
    std::fs::write(home.join("outside/keep.txt"), "precious").unwrap();
    std::os::unix::fs::symlink(home.join("outside"), tree.join("link")).unwrap();
    let never = NeverDelete::from_globs(["keep.txt".into()]);
    assert!(never.holds_tree(&home, &tree).is_none());
}

#[test]
fn an_unreadable_file_is_reported_not_fatal() {
    let home = scratch("never-bad");
    std::fs::create_dir_all(home.join(".cmux/care-never-delete")).unwrap();
    let (never, problems) = NeverDelete::load(&home);
    assert_eq!(problems.len(), 1);
    assert!(!never.is_empty());
    assert!(never.holds(&home, &home.join("anything")).is_some());
}
