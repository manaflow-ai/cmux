use super::*;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-project-new-{tag}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn project_new_refuses_the_phone_web_and_peers() {
    let plain = json!({"name": "app"});
    let phone = json!({"name": "app", "_meta": {"acpmux": {"via": "cloud-mobile"}}});
    assert!(allowed(Origin::LocalApp, &plain));
    assert!(allowed(Origin::Local, &plain));
    assert!(!allowed(Origin::Local, &phone), "the mobile relay's phone prompt makes no folder");
    assert!(!allowed(Origin::Web, &plain));
    assert!(!allowed(Origin::Peer, &plain));
}

#[test]
fn project_new_names_stay_one_plain_folder() {
    for good in ["habit-tracker", "a", "Notes_2.0", &"x".repeat(NAME_MAX)] {
        assert!(valid_name(good), "{good}");
    }
    let long = "x".repeat(NAME_MAX + 1);
    for bad in ["", ".", "..", ".git", "-rf", "a/b", "../up", "a b", "émoji", "a\0b", long.as_str()]
    {
        assert!(!valid_name(bad), "{bad:?}");
    }
}

#[test]
fn project_new_makes_a_git_repo_and_never_takes_an_existing_folder() {
    let root = scratch("make");
    std::fs::create_dir(root.join("habit-tracker")).unwrap();
    std::fs::write(root.join("habit-tracker").join("keep.txt"), "mine").unwrap();
    let cwd = make(&root, "habit-tracker").unwrap();
    assert_eq!(cwd.file_name().unwrap(), "habit-tracker-2");
    assert!(cwd.join(".git").is_dir());
    // The taken folder is untouched.
    assert_eq!(
        std::fs::read_to_string(root.join("habit-tracker").join("keep.txt")).unwrap(),
        "mine"
    );
    let third = make(&root, "habit-tracker").unwrap();
    assert_eq!(third.file_name().unwrap(), "habit-tracker-3");
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn project_new_git_init_drops_the_daemons_git_variables() {
    let inherited = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "HOME", "PATH"]
        .map(std::ffi::OsString::from);
    let init = git_init(Path::new("/tmp/x"), inherited);
    let removed: Vec<_> = init
        .get_envs()
        .filter(|(_, value)| value.is_none())
        .map(|(key, _)| key.to_owned())
        .collect();
    assert_eq!(
        removed,
        ["GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"].map(std::ffi::OsString::from)
    );
    assert_eq!(init.get_current_dir(), Some(Path::new("/tmp/x")));
}

#[test]
fn project_new_root_is_the_first_projects_folder_there() {
    let home = scratch("root");
    assert_eq!(projects_root(&home), home.join("Projects"));
    std::fs::create_dir(home.join("code")).unwrap();
    assert_eq!(projects_root(&home), home.join("code"));
    std::fs::create_dir(home.join("Developer")).unwrap();
    assert_eq!(projects_root(&home), home.join("Developer"));
    std::fs::remove_dir_all(&home).unwrap();
}
