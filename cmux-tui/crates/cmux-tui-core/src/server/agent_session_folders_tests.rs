use super::*;

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-folders-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

#[test]
fn no_home_or_no_work_folder_has_no_default() {
    assert_eq!(answer(None, true), json!({"default": null, "folders": []}));
    let home = temp("nowork");
    assert_eq!(answer(Some(&home), false), json!({"default": null, "folders": []}));
    assert!(!home.join("work").exists(), "nothing is made off a Cloud VM");
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn a_cloud_vm_makes_its_missing_work_folder() {
    let home = temp("make");
    let got = answer(Some(&home), true);
    let work = home.join("work");
    assert!(work.is_dir());
    assert_eq!(
        got,
        json!({"default": work.to_string_lossy(), "folders": [work.to_string_lossy()]})
    );
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn folders_list_repositories_first_and_skip_files_hidden_and_links() {
    let home = temp("list");
    let work = home.join("work");
    for dir in ["zeta", "Alpha", ".hidden", "repo/.git", "beta"] {
        std::fs::create_dir_all(work.join(dir)).unwrap();
    }
    std::fs::write(work.join("notes.txt"), "x").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&home, work.join("link")).unwrap();
    let got = answer(Some(&home), false);
    let path = |name: &str| work.join(name).to_string_lossy().into_owned();
    assert_eq!(got["default"], json!(work.to_string_lossy()));
    assert_eq!(
        got["folders"],
        json!([work.to_string_lossy(), path("repo"), path("Alpha"), path("beta"), path("zeta")])
    );
    let _ = std::fs::remove_dir_all(home);
}

#[cfg(unix)]
#[test]
fn a_work_symlink_is_never_the_default() {
    let home = temp("worklink");
    let elsewhere = temp("elsewhere");
    std::os::unix::fs::symlink(&elsewhere, home.join("work")).unwrap();
    assert_eq!(answer(Some(&home), true), json!({"default": null, "folders": []}));
    let _ = std::fs::remove_dir_all(home);
    let _ = std::fs::remove_dir_all(elsewhere);
}

#[test]
fn a_cloud_chat_folder_is_private_and_stable() {
    let home = temp("chat");
    let first = chat_folder(&home, 42, true).expect("chat folder");
    assert_eq!(first, std::fs::canonicalize(home.join("chats/42")).unwrap());
    assert!(home.join("chats").metadata().unwrap().is_dir());
    assert!(private_owned_dir(&home.join("chats")));
    assert!(private_owned_dir(&first));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(home.join("chats")).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(std::fs::metadata(&first).unwrap().permissions().mode() & 0o777, 0o700);
    }
    assert_eq!(chat_folder(&home, 42, false), Some(first));
    assert!(chat_folder(&home, 43, false).is_none());
    let _ = std::fs::remove_dir_all(home);
}

/// A machine's acpmux reserves `~/chats/<name>` and writes its ticket.
fn reserve(home: &Path, name: &str) -> PathBuf {
    let chats = home.join("chats");
    let dir = chats.join(name);
    std::fs::create_dir_all(&dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for d in [&chats, &dir] {
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    std::fs::write(chats.join(RESERVED_TICKET), name).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

const RESERVED: &str = "r0123456789abcdef0123456789abcdef";

#[test]
fn the_first_home_chat_takes_the_reserved_folder_and_the_second_gets_its_own() {
    let home = temp("reserved");
    let reserved = reserve(&home, RESERVED);
    assert_eq!(reserved_chat_folder(&home, 7), Some(reserved.clone()));
    // A retry or a reopen of the same chat finds the same folder.
    assert_eq!(reserved_chat_folder(&home, 7), Some(reserved));
    // No one else can take it, and nothing makes the folder for them here.
    assert_eq!(reserved_chat_folder(&home, 8), None);
    let second = chat_folder(&home, 8, true).expect("its own folder");
    assert_eq!(second, std::fs::canonicalize(home.join("chats/8")).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn a_chat_that_already_has_its_own_folder_keeps_it() {
    let home = temp("reserved-own");
    let own = chat_folder(&home, 9, true).unwrap();
    reserve(&home, RESERVED);
    assert_eq!(reserved_chat_folder(&home, 9), None);
    assert_eq!(chat_folder(&home, 9, true), Some(own));
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn a_ticket_naming_anything_but_a_reserved_folder_is_ignored() {
    let home = temp("reserved-bad");
    let chats = home.join("chats");
    std::fs::create_dir_all(chats.join("5")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for d in [chats.clone(), chats.join("5")] {
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    for name in ["5", "../work", "r123", "rGGGG456789abcdef0123456789abcdef"] {
        std::fs::write(chats.join(RESERVED_TICKET), name).unwrap();
        assert_eq!(reserved_chat_folder(&home, 3), None, "{name}");
    }
    // A ticket that is a link is no ticket.
    #[cfg(unix)]
    {
        let _ = std::fs::remove_file(chats.join(RESERVED_TICKET));
        std::os::unix::fs::symlink(chats.join("5"), chats.join(RESERVED_TICKET)).unwrap();
        assert_eq!(reserved_chat_folder(&home, 3), None);
    }
    // A named folder that is missing is not taken, and the caller falls back.
    let _ = std::fs::remove_file(chats.join(RESERVED_TICKET));
    std::fs::write(chats.join(RESERVED_TICKET), RESERVED).unwrap();
    assert_eq!(reserved_chat_folder(&home, 3), None);
    let _ = std::fs::remove_dir_all(home);
}
