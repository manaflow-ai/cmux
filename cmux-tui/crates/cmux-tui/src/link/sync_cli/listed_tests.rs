use std::os::unix::fs::PermissionsExt as _;

use super::super::local::{Rules, collect};

/// A file this user cannot read is listed by its entry, not opened, so a
/// sharing rule can leave it out before anything reads it.
#[test]
fn an_unreadable_file_is_listed_without_being_read() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    std::fs::write(top.join("a.txt"), "a\n").unwrap();
    std::fs::write(top.join(".env"), "TOKEN=x\n").unwrap();
    std::fs::set_permissions(top.join(".env"), std::fs::Permissions::from_mode(0o000)).unwrap();
    let set = collect(&top, Rules::Share, None).unwrap();
    let env = set.files.get(".env").expect("listed");
    assert_eq!(env.permissions, 0o600);
    assert!(env.id.is_some() && set.files.contains_key("a.txt"));
}

/// A git file's symlink is followed from the folder listed, through its
/// descriptor: with that folder swapped since for a symlink to another
/// (`~/.ssh`), a relative text never reaches a file there. A symlinked
/// reflog is left out, and so is a config whose file is in a credential
/// folder.
#[test]
fn a_git_file_symlink_is_read_from_the_folder_listed_never_its_path() {
    use super::super::place;
    use super::git_text;
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let (git, ssh) = (root.join("repo/.git"), root.join("home/.ssh"));
    std::fs::create_dir_all(&git).unwrap();
    std::fs::create_dir_all(&ssh).unwrap();
    std::fs::write(git.join("config.real"), "[core]\n\tmine = 1\n").unwrap();
    std::fs::write(ssh.join("config.real"), "PRIVATE KEY\n").unwrap();
    for name in ["config", "id_rsa"] {
        std::os::unix::fs::symlink("config.real", git.join(name)).unwrap();
    }
    let held = place::Dir::open(&git).unwrap();
    std::fs::rename(&git, root.join("repo/.git-old")).unwrap();
    std::os::unix::fs::symlink(&ssh, &git).unwrap();
    let read = |name: &str| git_text(&held, name, &place::Entry::Link, &git.join(name)).unwrap();
    assert_eq!(read("config").as_deref(), Some(&b"[core]\n\tmine = 1\n"[..]));
    assert_eq!(read("id_rsa"), None, "a symlinked reflog or other git file is left out");
    let secret = place::Dir::open(&root.join("repo/.git-old")).unwrap();
    std::fs::remove_file(root.join("repo/.git-old/config")).unwrap();
    std::os::unix::fs::symlink(ssh.join("config.real"), root.join("repo/.git-old/config")).unwrap();
    assert_eq!(git_text(&secret, "config", &place::Entry::Link, &git).unwrap(), None);
}

/// A share of files reads no git state: an unreadable reflog never fails it.
#[test]
fn a_share_of_a_working_copy_reads_no_git_state() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let git = |args: &[&str]| {
        assert!(
            cmux_process::Command::new("git")
                .arg("-C")
                .arg(&top)
                .args(args)
                .status()
                .unwrap()
                .success()
        );
    };
    git(&["init", "-q"]);
    std::fs::write(top.join("a.txt"), "a\n").unwrap();
    git(&["add", "a.txt"]);
    git(&["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "a"]);
    let head = top.join(".git/logs/HEAD");
    std::fs::set_permissions(&head, std::fs::Permissions::from_mode(0o000)).unwrap();
    let set = collect(&top, Rules::Share, None).unwrap();
    std::fs::set_permissions(&head, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(
        set.files.contains_key("a.txt") && set.files.keys().all(|key| !key.starts_with(".git/"))
    );
}
