use super::*;
use std::path::PathBuf;

struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    tmp: PathBuf,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let home = root.join("home/agent");
    let tmp = root.join("tmp");
    std::fs::create_dir_all(home.join("Projects/checkouts/app/src")).unwrap();
    std::fs::create_dir_all(home.join("Projects/checkouts/app/.git")).unwrap();
    std::fs::create_dir_all(home.join("Projects/linked")).unwrap();
    std::fs::write(home.join("Projects/linked/.git"), "gitdir: /x/.git/worktrees/linked\n")
        .unwrap();
    std::fs::create_dir_all(home.join(".cache/lane-tmp")).unwrap();
    std::fs::create_dir_all(tmp.join("lane-tmp")).unwrap();
    std::fs::create_dir_all(tmp.join("acpmux-remote-abc")).unwrap();
    Fixture { _dir: dir, home, tmp }
}

#[test]
fn a_folder_above_the_checkouts_is_refused_with_the_cause() {
    let f = fixture();
    let projects = f.home.join("Projects");
    let err = check(&projects, &f.tmp).unwrap_err();
    assert_eq!(err.code, -32602);
    assert!(err.message.contains(
        "Claude creates empty placeholder files (package.json, lockfiles, .env*) in its working folder"
    ));
    assert!(err.message.contains(&format!("{} isn't a checkout", projects.display())));
    assert!(err.message.contains(&f.tmp.join("<lane>-tmp").display().to_string()));
    assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");
    assert!(check(&f.home, &f.tmp).is_err());
}

#[test]
fn a_checkout_and_a_folder_inside_one_are_fine() {
    let f = fixture();
    let app = f.home.join("Projects/checkouts/app");
    assert!(check(&app, &f.tmp).is_ok());
    assert!(check(&app.join("src"), &f.tmp).is_ok());
    assert!(check(&f.home.join("Projects/linked"), &f.tmp).is_ok());
}

#[test]
fn a_scratch_folder_in_the_temporary_folder_is_fine_and_nothing_the_sandbox_refuses() {
    let f = fixture();
    assert!(check(&f.tmp.join("lane-tmp"), &f.tmp).is_ok());
    assert!(check(&f.tmp, &f.tmp).is_err(), "the temporary folder itself");
    assert!(
        check(&f.tmp.join("acpmux-remote-abc"), &f.tmp).is_err(),
        "a remote chain's own folder"
    );
    // The sandbox refuses top-level dot folders in the home directory.
    assert!(check(&f.home.join(".cache/lane-tmp"), &f.tmp).is_err());
}

#[test]
fn only_a_new_remote_claude_session_is_checked() {
    use crate::config::HarnessKind;
    let f = fixture();
    let projects = f.home.join("Projects");
    let gate =
        |remote, trigger, kind| admit_new(NewSession { remote, trigger, kind }, &projects, &f.tmp, None);
    let err = gate(true, false, HarnessKind::ClaudeStdio).unwrap_err();
    assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");
    assert!(gate(false, false, HarnessKind::ClaudeStdio).is_ok(), "a local session is unchanged");
    assert!(gate(true, true, HarnessKind::ClaudeStdio).is_ok(), "a trigger chat is unchanged");
    for kind in [HarnessKind::Acp, HarnessKind::Terminal] {
        assert!(gate(true, false, kind).is_ok(), "another harness is unchanged");
    }
    let app = f.home.join("Projects/checkouts/app");
    assert!(
        admit_new(
            NewSession { remote: true, trigger: false, kind: HarnessKind::ClaudeStdio },
            &app,
            &f.tmp,
            None
        )
        .is_ok()
    );
}

#[cfg(unix)]
#[test]
fn a_symlink_into_a_checkout_is_judged_by_where_it_leads() {
    let f = fixture();
    let link = f.home.join("app-link");
    std::os::unix::fs::symlink(f.home.join("Projects/checkouts/app"), &link).unwrap();
    assert!(check(&link, &f.tmp).is_ok());
    let up = f.tmp.join("projects-link");
    std::os::unix::fs::symlink(f.home.join("Projects"), &up).unwrap();
    assert!(
        check(&up, &f.tmp).is_err(),
        "a link in the temporary folder to a non-checkout is not scratch"
    );
}

#[test]
fn a_chat_folder_under_home_chats_is_fine_and_nothing_else_there() {
    use crate::config::HarnessKind;
    let f = fixture();
    let chats = f.home.join("chats");
    std::fs::create_dir_all(chats.join("fix-login/deeper")).unwrap();
    let gate = |cwd: &Path, chats: Option<&Path>| {
        admit_new(
            NewSession { remote: true, trigger: false, kind: HarnessKind::ClaudeStdio },
            cwd,
            &f.tmp,
            chats,
        )
    };
    // The folder a vmBoundary peer's folderless chat gets (`remote_guard.rs`).
    assert!(gate(&chats.join("fix-login"), Some(&chats)).is_ok());
    assert!(gate(&chats, Some(&chats)).is_err(), "the chats folder itself");
    assert!(gate(&chats.join("fix-login/deeper"), Some(&chats)).is_err(), "deeper down");
    assert!(gate(&chats.join("missing"), Some(&chats)).is_err(), "a folder that is not there");
    assert!(gate(&f.home.join("Projects"), Some(&chats)).is_err(), "anything else still");
    assert!(gate(&chats.join("fix-login"), None).is_err(), "no chats folder known");
    #[cfg(unix)]
    {
        // A `chats` that is a link to the home directory names no chat folder.
        let link = f.home.join("chats-link");
        std::os::unix::fs::symlink(&f.home, &link).unwrap();
        assert!(gate(&link.join("Projects"), Some(&link)).is_err());
    }
}
