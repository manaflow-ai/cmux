use super::{mode_of, parse, size_of, stays_inside};

#[test]
fn a_symlink_is_kept_only_inside_the_folder() {
    assert!(stays_inside("a/link", "b"));
    assert!(stays_inside("a/link", "../top.txt"));
    assert!(!stays_inside("link", "../out"));
    assert!(!stays_inside("a/link", "/etc/passwd"));
    assert!(!stays_inside("a/link", "../../x"));
}

#[test]
fn modes_and_sizes_read_from_the_listing() {
    assert_eq!(mode_of("rwxr-xr-x"), Some(0o755));
    assert_eq!(mode_of("r--r--r--"), Some(0o644));
    assert_eq!(mode_of("bad"), None);
    // Each letter sets its own bit (owner write is always added).
    assert_eq!(mode_of("r--------"), Some(0o600));
    assert_eq!(mode_of("--x------"), Some(0o700));
    assert_eq!(mode_of("---r-----"), Some(0o640));
    assert_eq!(mode_of("----w----"), Some(0o620));
    assert_eq!(mode_of("-----x---"), Some(0o610));
    assert_eq!(mode_of("------r--"), Some(0o604));
    assert_eq!(mode_of("-------w-"), Some(0o602));
    assert_eq!(mode_of("--------x"), Some(0o601));
    assert_eq!(mode_of("rwxrwxrwx"), Some(0o777));
    assert_eq!(size_of("s1234-m99"), Some(1234));
    assert_eq!(size_of("nonsense"), None);
}

#[test]
fn both_folders_are_absolute() {
    let args = |list: &[&str]| list.iter().map(|arg| (*arg).to_string()).collect::<Vec<_>>();
    assert!(
        parse(&args(&[
            "--from-socket",
            "/a",
            "--socket",
            "/b",
            "/home/cmux/work/app",
            "/home/cmux/work/app/"
        ]))
        .is_some()
    );
    assert!(parse(&args(&["--from-socket", "/a", "--socket", "/b", "rel", "/x"])).is_none());
    assert!(parse(&args(&["--socket", "/b", "/x", "/y"])).is_none());
}
