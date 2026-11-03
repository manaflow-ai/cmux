use super::*;
use std::cell::Cell;

/// A set, non-empty `$HOME` wins, and the passwd entry is not read.
#[test]
fn a_set_home_wins_without_reading_passwd() {
    let asked = Cell::new(false);
    let home = home_from(Some("/Users/someone".into()), || {
        asked.set(true);
        Some("/from/passwd".into())
    });
    assert_eq!(home, Some(PathBuf::from("/Users/someone")));
    assert!(!asked.get());
}

/// An unset or empty `$HOME` falls back to the passwd entry, as `dirs::home_dir` does.
#[test]
fn an_unset_or_empty_home_reads_the_passwd_entry() {
    for home in [None, Some(OsString::new())] {
        let asked = Cell::new(false);
        let found = home_from(home.clone(), || {
            asked.set(true);
            Some("/from/passwd".into())
        });
        assert_eq!(found, Some(PathBuf::from("/from/passwd")), "{home:?}");
        assert!(asked.get(), "{home:?}");
        assert_eq!(home_from(home, || None), None);
    }
}

/// The real passwd read: the test user's entry, when it has one, names an absolute directory.
#[test]
fn the_passwd_entry_is_an_absolute_directory() {
    if let Some(dir) = passwd_home() {
        assert!(dir.is_absolute(), "{dir:?}");
    }
}

/// With `$HOME` set, `home_dir` is `$HOME`, as `dirs::home_dir` returns it.
#[test]
fn home_dir_is_home_when_it_is_set() {
    match std::env::var_os("HOME").filter(|h| !h.is_empty()) {
        Some(home) => assert_eq!(home_dir(), Some(PathBuf::from(home))),
        None => assert_eq!(home_dir(), passwd_home()),
    }
}
