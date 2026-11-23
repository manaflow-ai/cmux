//! The app's first launch (`prepare_launch_file`, the app's
//! `file.prepare_launch` op).

use std::fs;
use std::path::PathBuf;

use cmux_config::prepare_launch_file;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-config-launch-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_fresh_install_gets_an_empty_object() {
    let dir = scratch("fresh");
    let next = dir.join("cmux/cmux-next.json");
    assert!(prepare_launch_file(&next, Some(&dir.join("cmux/cmux.json"))).unwrap());
    assert_eq!(fs::read_to_string(&next).unwrap(), "{}\n");
    // The next launch finds it and is not a fresh install.
    assert!(!prepare_launch_file(&next, Some(&dir.join("cmux/cmux.json"))).unwrap());
}

#[test]
fn classic_settings_seed_the_file_once() {
    let dir = scratch("classic");
    let classic = dir.join("cmux.json");
    fs::write(&classic, "{ // mine\n \"a\": 1 }\n").unwrap();
    let next = dir.join("cmux-next.json");
    assert!(!prepare_launch_file(&next, Some(&classic)).unwrap());
    assert_eq!(fs::read_to_string(&next).unwrap(), "{ // mine\n \"a\": 1 }\n");
    fs::write(&classic, "{}").unwrap();
    assert!(!prepare_launch_file(&next, Some(&classic)).unwrap());
    assert_eq!(fs::read_to_string(&next).unwrap(), "{ // mine\n \"a\": 1 }\n");
}

#[cfg(unix)]
#[test]
fn a_symlinked_classic_file_is_copied_not_linked() {
    let dir = scratch("symlink");
    let dotfiles = dir.join("dotfiles.json");
    fs::write(&dotfiles, "{\"b\": 2}").unwrap();
    let classic = dir.join("cmux.json");
    std::os::unix::fs::symlink(&dotfiles, &classic).unwrap();
    let next = dir.join("cmux-next.json");
    prepare_launch_file(&next, Some(&classic)).unwrap();
    assert!(!fs::symlink_metadata(&next).unwrap().file_type().is_symlink());
    assert_eq!(fs::read_to_string(&next).unwrap(), "{\"b\": 2}");
}

#[test]
fn an_override_file_is_never_made() {
    let dir = scratch("override");
    let next = dir.join("custom.json");
    assert!(!prepare_launch_file(&next, None).unwrap());
    assert!(!next.exists());
}
