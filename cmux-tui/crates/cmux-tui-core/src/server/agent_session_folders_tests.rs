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
