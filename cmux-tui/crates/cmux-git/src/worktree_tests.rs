use super::*;

/// A scratch folder removed on drop.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch(tag: &str) -> Scratch {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let path =
        std::env::temp_dir().join(format!("cmux-git-w7f-{tag}-{}-{nanos:x}", std::process::id()));
    std::fs::create_dir_all(&path).unwrap();
    Scratch(path)
}

/// `home` with the macOS layout: `.cmux/worktrees` a link to `.cmux/worktrees.noindex`.
fn linked_home(top: &Path) -> PathBuf {
    let home = top.join("home");
    std::fs::create_dir_all(home.join(".cmux/worktrees.noindex")).unwrap();
    std::os::unix::fs::symlink("worktrees.noindex", home.join(".cmux/worktrees")).unwrap();
    home
}

#[test]
fn w7f_a_named_branch_is_kept_as_given_and_a_bad_one_is_refused() {
    assert_eq!(branch_for("fix-login", None).unwrap(), "cmux/fix-login");
    assert_eq!(branch_for("fix-login", Some("feat/login")).unwrap(), "feat/login");
    for bad in [
        "", "-x", "a b", "a..b", "a/", "/a", "a//b", "a.lock", ".a", "a/.b", "a~1", "a^", "a:b",
        "@", "HEAD", "a@{1}", "a.",
    ] {
        assert!(check_branch_name(bad).is_err(), "{bad:?} was accepted");
    }
    for good in ["main", "feat/login", "r6a", "user/fix-2", "v1.2"] {
        assert!(check_branch_name(good).is_ok(), "{good:?} was refused");
    }
}

#[test]
fn w7f_a_worktree_folder_is_shown_under_the_link_and_matches_either_spelling() {
    let top = scratch("shown");
    let home = linked_home(&top.0);
    let real = home.join(".cmux/worktrees.noindex/proj/a");
    std::fs::create_dir_all(&real).unwrap();
    let link = home.join(".cmux/worktrees/proj/a");
    // Both spellings show as the link, and name the same folder.
    assert_eq!(shown(&home, &real), link);
    assert_eq!(shown(&home, &link), link);
    assert!(same_folder(&real, &link));
    // A folder outside the worktree root is shown as it is.
    let other = top.0.join("elsewhere");
    assert_eq!(shown(&home, &other), other);
    // The filter spellings hold both forms.
    let spellings = folder_spellings(&link, Some(&home));
    assert!(spellings.contains(&link), "{spellings:?}");
    assert!(spellings.contains(&std::fs::canonicalize(&real).unwrap()), "{spellings:?}");
}

#[test]
fn w7f_the_project_folder_goes_with_its_last_worktree_only() {
    let top = scratch("project");
    let home = linked_home(&top.0);
    let project = home.join(".cmux/worktrees.noindex/proj");
    std::fs::create_dir_all(project.join("b")).unwrap();
    // Still holds b: stays.
    assert!(!remove_empty_project_folder(&home, &home.join(".cmux/worktrees/proj/a")));
    assert!(project.is_dir());
    std::fs::remove_dir(project.join("b")).unwrap();
    assert!(remove_empty_project_folder(&home, &home.join(".cmux/worktrees/proj/b")));
    assert!(!project.exists());
    // Never the root itself, nor a folder outside it.
    assert!(home.join(".cmux/worktrees.noindex").is_dir());
    let outside = top.0.join("repo/sub");
    std::fs::create_dir_all(&outside).unwrap();
    assert!(!remove_empty_project_folder(&home, &outside.join("x")));
    assert!(outside.is_dir());
}
