//! The carrier key's store: a Team-signed build keeps the Keychain; a build
//! with no Team ID keeps one 0600 file per build, the same across rebuilds.
//! Generated keys only.

use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

use super::*;

/// A fake app bundle `<root>/<name>.app` with `bundle_id` (and `tag` in
/// `LSEnvironment`), holding a `cmux` binary whose bytes are `build`: two
/// builds of one tag differ in their code, as two ad-hoc rebuilds do.
fn bundle(root: &Path, name: &str, bundle_id: &str, tag: Option<&str>, build: &[u8]) -> PathBuf {
    let app = root.join(format!("{name}.app"));
    let bin = app.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let environment = tag.map_or_else(String::new, |tag| {
        format!("<key>LSEnvironment</key><dict><key>CMUX_TAG</key><string>{tag}</string></dict>")
    });
    std::fs::write(
        app.join("Contents/Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleIdentifier</key><string>{bundle_id}</string>{environment}</dict></plist>\n"
        ),
    )
    .unwrap();
    let exe = bin.join("cmux");
    std::fs::write(&exe, build).unwrap();
    exe
}

fn file_of(store: Store) -> PathBuf {
    match store {
        Store::File(path) => path,
        Store::Keychain => panic!("a build with no Team ID must not use the Keychain"),
    }
}

#[test]
fn a_team_signed_build_keeps_the_keychain() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let exe = bundle(root.path(), "cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", None, b"r");
    // Whatever bundle, tag or home: a Team-signed build (or one whose
    // signature could not be read, which counts as signed) never gets a file.
    assert_eq!(store_for(true, Some(&exe), Some(&home)), Ok(Store::Keychain));
    assert_eq!(store_for(true, None, None), Ok(Store::Keychain));
    let dev = bundle(root.path(), "cmux DEV a", "com.cmuxterm.app.debug.a", None, b"d");
    assert_eq!(store_for(true, Some(&dev), Some(&home)), Ok(Store::Keychain));
    assert!(!home.exists(), "choosing the Keychain writes nothing");
}

#[test]
fn a_link_to_the_bundled_cmux_from_outside_the_bundle_is_that_build() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let exe = bundle(root.path(), "cmux DEV fix", "com.cmuxterm.app.debug.fix", None, b"1");
    let shim = root.path().join("cmux");
    std::os::unix::fs::symlink(&exe, &shim).unwrap();
    assert_eq!(store_for(false, Some(&shim), Some(&home)), store_for(false, Some(&exe), Some(&home)));
}

#[test]
fn an_ad_hoc_build_without_a_home_has_no_store_and_no_keychain_fallback() {
    let root = tempfile::tempdir().unwrap();
    let exe = bundle(root.path(), "cmux DEV a", "com.cmuxterm.app.debug.a", None, b"d");
    assert!(store_for(false, Some(&exe), None).is_err());
}

#[test]
fn two_rebuilds_of_one_tag_share_one_key_file_and_other_tags_do_not() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let first = bundle(root.path(), "one/cmux DEV fix", "com.cmuxterm.app.debug.fix", None, b"1");
    let second = bundle(root.path(), "two/cmux DEV fix", "com.cmuxterm.app.debug.fix", None, b"2");
    let other = bundle(root.path(), "cmux DEV other", "com.cmuxterm.app.debug.other", None, b"3");
    let first_path = file_of(store_for(false, Some(&first), Some(&home)).unwrap());
    let second_path = file_of(store_for(false, Some(&second), Some(&home)).unwrap());
    let other_path = file_of(store_for(false, Some(&other), Some(&home)).unwrap());
    assert_eq!(first_path, second_path, "a rebuild of the tag finds the same file");
    assert_ne!(first_path, other_path, "another tag never shares the file");
    assert!(first_path.starts_with(home.join("Library/Application Support/cmux-next/builds")));

    // The first build makes the key; the rebuild reads the same one.
    let made = file_key::load_or_create(&first_path).unwrap();
    let again = file_key::load_or_create(&second_path).unwrap();
    assert_eq!(made, again);
    assert_ne!(made, file_key::load_or_create(&other_path).unwrap());

    let meta = std::fs::symlink_metadata(&first_path).unwrap();
    assert!(meta.is_file());
    assert_eq!(meta.mode() & 0o777, 0o600);
    assert_eq!(meta.len(), 32);
    assert_eq!(meta.nlink(), 1, "the temporary name is gone");
    let folder = std::fs::symlink_metadata(first_path.parent().unwrap()).unwrap();
    assert_eq!(folder.mode() & 0o777, 0o700);
    let leftovers: Vec<_> = std::fs::read_dir(first_path.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(leftovers, vec![std::ffi::OsString::from(file_key::FILE)]);
}

#[test]
fn a_symlink_at_the_key_path_is_refused_and_left_alone() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("carrier");
    std::fs::create_dir(&folder).unwrap();
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700)).unwrap();
    let elsewhere = root.path().join("elsewhere");
    std::fs::write(&elsewhere, [7_u8; 32]).unwrap();
    std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o600)).unwrap();
    let path = folder.join(file_key::FILE);
    std::os::unix::fs::symlink(&elsewhere, &path).unwrap();
    let refused = file_key::load_or_create(&path).unwrap_err();
    assert!(refused.contains("symbolic link"), "{refused}");
    // Never replaced through or over the link.
    assert!(std::fs::symlink_metadata(&path).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read(&elsewhere).unwrap(), [7_u8; 32]);
    // A dangling link is refused too: it is never followed to create a file.
    std::fs::remove_file(&path).unwrap();
    let target = root.path().join("made-through-link");
    std::os::unix::fs::symlink(&target, &path).unwrap();
    assert!(file_key::load_or_create(&path).is_err());
    assert!(!target.exists());
}

#[test]
fn a_symlinked_key_folder_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let real = root.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let link = root.path().join("carrier");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert!(file_key::load_or_create(&link.join(file_key::FILE)).is_err());
    assert_eq!(std::fs::read_dir(&real).unwrap().count(), 0);
}

#[test]
fn a_key_file_others_can_read_or_of_the_wrong_size_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("carrier").join(file_key::FILE);
    let key = file_key::load_or_create(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let refused = file_key::load_or_create(&path).unwrap_err();
    assert!(refused.contains("open to other users"), "{refused}");
    assert!(refused.contains(&path.display().to_string()), "the refusal names the file: {refused}");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(file_key::load_or_create(&path).unwrap(), key);
    std::fs::write(&path, [1_u8; 31]).unwrap();
    assert!(file_key::load_or_create(&path).is_err(), "a short file is never replaced");
    assert_eq!(std::fs::read(&path).unwrap(), [1_u8; 31]);
}

#[test]
fn a_wide_key_folder_is_narrowed_to_the_owner() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("carrier");
    std::fs::create_dir(&folder).unwrap();
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();
    file_key::load_or_create(&folder.join(file_key::FILE)).unwrap();
    assert_eq!(std::fs::metadata(&folder).unwrap().mode() & 0o777, 0o700);
}
