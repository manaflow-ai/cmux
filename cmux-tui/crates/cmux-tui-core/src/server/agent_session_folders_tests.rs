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

#[test]
fn list_dir_starts_at_the_work_folder_and_lists_repositories_first() {
    let home = temp("listdir");
    let work = home.join("work");
    for dir in ["zeta", "Alpha", ".hidden", "repo/.git", "beta"] {
        std::fs::create_dir_all(work.join(dir)).unwrap();
    }
    std::fs::write(work.join("notes.txt"), "x").unwrap();
    let got = browse(Some(&home), None, false, false).unwrap();
    assert_eq!(got["path"], json!(work.to_string_lossy()));
    assert_eq!(got["parent"], json!(home.to_string_lossy()));
    assert_eq!(got["home"], json!(home.to_string_lossy()));
    assert_eq!(got["work"], json!(work.to_string_lossy()));
    let names: Vec<&str> =
        got["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["repo", "Alpha", "beta", "zeta"]);
    assert_eq!(got["entries"][0]["repo"], true);
    assert_eq!(got["entries"][1]["repo"], false);
    assert_eq!(got["entries"][0]["path"], json!(work.join("repo").to_string_lossy()));
    assert_eq!(got["truncated"], false);
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn list_dir_without_a_work_folder_starts_at_home_and_can_show_files_and_hidden() {
    let home = temp("listhome");
    std::fs::create_dir_all(home.join(".config")).unwrap();
    std::fs::create_dir_all(home.join("src")).unwrap();
    std::fs::write(home.join("a.txt"), "x").unwrap();
    let got = browse(Some(&home), Some(""), true, true).unwrap();
    assert_eq!(got["path"], json!(home.to_string_lossy()));
    assert_eq!(got["work"], Value::Null);
    let kinds: Vec<(String, String)> = got["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| (e["name"].as_str().unwrap().into(), e["kind"].as_str().unwrap().into()))
        .collect();
    assert_eq!(
        kinds,
        [
            (".config".into(), "dir".into()),
            ("src".into(), "dir".into()),
            ("a.txt".into(), "file".into())
        ]
    );
    let plain = browse(Some(&home), Some(&home.to_string_lossy()), false, false).unwrap();
    assert_eq!(plain["entries"].as_array().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn list_dir_names_why_a_folder_cannot_be_listed() {
    let home = temp("listerr");
    std::fs::write(home.join("file"), "x").unwrap();
    let err = |path: &str| browse(Some(&home), Some(path), false, false).unwrap_err();
    assert_eq!(err("work/api"), BrowseError::NotAbsolute);
    assert_eq!(err("~/work"), BrowseError::NotAbsolute);
    assert_eq!(err(&home.join("missing").to_string_lossy()), BrowseError::NotFound);
    assert_eq!(err(&home.join("file").to_string_lossy()), BrowseError::NotAFolder);
    assert_eq!(browse(None, None, false, false).unwrap_err(), BrowseError::NoStart);
    assert_eq!(BrowseError::NotFound.code(), "list_dir.not_found");
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn list_dir_parent_is_none_at_the_root_and_a_huge_folder_is_capped() {
    let root = browse(None, Some("/"), false, false).unwrap();
    assert_eq!(root["parent"], Value::Null);
    let home = temp("listcap");
    for i in 0..(MAX_LIST_DIR + 5) {
        std::fs::create_dir(home.join(format!("d{i:04}"))).unwrap();
    }
    let got = browse(Some(&home), Some(&home.to_string_lossy()), false, false).unwrap();
    assert_eq!(got["entries"].as_array().unwrap().len(), MAX_LIST_DIR);
    assert_eq!(got["truncated"], true);
    let _ = std::fs::remove_dir_all(home);
}

#[cfg(unix)]
#[test]
fn list_dir_lists_a_symlinked_folder_as_a_folder_with_its_own_path() {
    let home = temp("listlink");
    let elsewhere = temp("listlink-target");
    std::os::unix::fs::symlink(&elsewhere, home.join("shortcut")).unwrap();
    let got = browse(Some(&home), Some(&home.to_string_lossy()), false, false).unwrap();
    assert_eq!(got["entries"][0]["kind"], "dir");
    assert_eq!(got["entries"][0]["path"], json!(home.join("shortcut").to_string_lossy()));
    let _ = std::fs::remove_dir_all(home);
    let _ = std::fs::remove_dir_all(elsewhere);
}
