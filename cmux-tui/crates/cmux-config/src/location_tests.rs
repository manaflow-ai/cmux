use super::*;

fn temp_home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("cmux-config-location-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

#[test]
fn default_path_is_in_this_platforms_next_dir() {
    let path = config_path_from(|name| (name == "HOME").then(|| OsString::from("/h")));
    assert_eq!(path, PathBuf::from("/h/.config").join(NEXT_DIR).join("cmux-next.json"));
    #[cfg(target_os = "macos")]
    assert_eq!(path, PathBuf::from("/h/.config/cmux-next/cmux-next.json"));
    #[cfg(not(target_os = "macos"))]
    assert_eq!(path, PathBuf::from("/h/.config/cmux/cmux-next.json"));
}

#[test]
fn override_wins() {
    let path = config_path_from(|name| match name {
        CONFIG_OVERRIDE => Some(OsString::from("~/x.json")),
        "HOME" => Some(OsString::from("/h")),
        _ => None,
    });
    assert_eq!(path, PathBuf::from("/h/x.json"));
}

#[test]
fn legacy_file_moves_once_to_the_next_dir() {
    let home = temp_home("move");
    let old_dir = home.join(".config/cmux");
    std::fs::create_dir_all(&old_dir).unwrap();
    std::fs::write(old_dir.join("cmux-next.json"), "{\"a\": 1}").unwrap();
    assert!(migrate_legacy_file(&home, "cmux-next").unwrap());
    let new = home.join(".config/cmux-next/cmux-next.json");
    assert_eq!(std::fs::read_to_string(&new).unwrap(), "{\"a\": 1}");
    assert!(!old_dir.join("cmux-next.json").exists());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(new.parent().unwrap()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    assert!(!migrate_legacy_file(&home, "cmux-next").unwrap());
    std::fs::remove_dir_all(&home).unwrap();
}

#[test]
fn legacy_file_never_overwrites_the_new_one() {
    let home = temp_home("keep");
    std::fs::create_dir_all(home.join(".config/cmux")).unwrap();
    std::fs::create_dir_all(home.join(".config/cmux-next")).unwrap();
    std::fs::write(home.join(".config/cmux/cmux-next.json"), "old").unwrap();
    std::fs::write(home.join(".config/cmux-next/cmux-next.json"), "new").unwrap();
    assert!(!migrate_legacy_file(&home, "cmux-next").unwrap());
    assert_eq!(
        std::fs::read_to_string(home.join(".config/cmux-next/cmux-next.json")).unwrap(),
        "new"
    );
    assert!(home.join(".config/cmux/cmux-next.json").exists());
    std::fs::remove_dir_all(&home).unwrap();
}

#[test]
fn nothing_moves_without_a_regular_legacy_file_or_on_the_legacy_dir() {
    let home = temp_home("none");
    assert!(!migrate_legacy_file(&home, "cmux-next").unwrap());
    assert!(!home.join(".config/cmux-next").exists());
    std::fs::create_dir_all(home.join(".config/cmux/cmux-next.json")).unwrap();
    assert!(!migrate_legacy_file(&home, "cmux-next").unwrap());
    assert!(!migrate_legacy_file(&home, "cmux").unwrap());
    std::fs::remove_dir_all(&home).unwrap();
}

#[test]
fn state_items_move_once_and_never_over_the_new_ones() {
    let state = temp_home("state");
    let old = state.join(LEGACY_DIR);
    std::fs::create_dir_all(old.join("customize")).unwrap();
    std::fs::write(old.join("customize/drafts.json"), "old").unwrap();
    std::fs::write(old.join("last-chat.json"), "old-chat").unwrap();
    std::fs::write(old.join("cmux.sock.lock"), "classic").unwrap();
    assert_eq!(migrate_legacy_state(&state, LEGACY_DIR).unwrap(), Vec::<&str>::new());
    assert_eq!(migrate_legacy_state(&state, "next").unwrap(), vec!["customize", "last-chat.json"]);
    let new = state.join("next");
    assert_eq!(std::fs::read_to_string(new.join("customize/drafts.json")).unwrap(), "old");
    assert_eq!(std::fs::read_to_string(new.join("last-chat.json")).unwrap(), "old-chat");
    assert!(old.join("cmux.sock.lock").exists(), "only NEXT's items move");
    assert!(!old.join("customize").exists() && !old.join("last-chat.json").exists());
    assert_eq!(migrate_legacy_state(&state, "next").unwrap(), Vec::<&str>::new());

    // Something already at the new name is never replaced; the old one stays.
    std::fs::create_dir_all(old.join("customize")).unwrap();
    std::fs::write(old.join("last-chat.json"), "stale").unwrap();
    assert_eq!(migrate_legacy_state(&state, "next").unwrap(), Vec::<&str>::new());
    assert_eq!(std::fs::read_to_string(new.join("last-chat.json")).unwrap(), "old-chat");
    assert!(old.join("last-chat.json").exists() && old.join("customize").exists());
    std::fs::remove_dir_all(&state).unwrap();
}

#[cfg(unix)]
#[test]
fn a_linked_state_item_never_moves() {
    let state = temp_home("state-link");
    let old = state.join(LEGACY_DIR);
    std::fs::create_dir_all(&old).unwrap();
    std::os::unix::fs::symlink("/nowhere", old.join("last-chat.json")).unwrap();
    assert_eq!(migrate_legacy_state(&state, "next").unwrap(), Vec::<&str>::new());
    assert!(!state.join("next").exists());
    std::fs::remove_dir_all(&state).unwrap();
}
