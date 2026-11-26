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
    let err = check(&projects, &f.tmp, Some(&f.home)).unwrap_err();
    assert_eq!(err.code, -32602);
    assert!(err.message.contains(
        "Claude creates empty placeholder files (package.json, lockfiles, .env*) in its working folder"
    ));
    assert!(err.message.contains(&format!("{} isn't a checkout", projects.display())));
    assert!(err.message.contains(&f.tmp.join("<lane>-tmp").display().to_string()));
    assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");
    assert!(check(&f.home, &f.tmp, Some(&f.home)).is_err());
}

#[test]
fn a_checkout_and_a_folder_inside_one_are_fine() {
    let f = fixture();
    let app = f.home.join("Projects/checkouts/app");
    assert!(check(&app, &f.tmp, Some(&f.home)).is_ok());
    assert!(check(&app.join("src"), &f.tmp, Some(&f.home)).is_ok());
    assert!(check(&f.home.join("Projects/linked"), &f.tmp, Some(&f.home)).is_ok());
}

#[test]
fn a_scratch_folder_in_the_temporary_folder_is_fine_and_nothing_the_sandbox_refuses() {
    let f = fixture();
    assert!(check(&f.tmp.join("lane-tmp"), &f.tmp, Some(&f.home)).is_ok());
    assert!(check(&f.tmp, &f.tmp, Some(&f.home)).is_err(), "the temporary folder itself");
    assert!(
        check(&f.tmp.join("acpmux-remote-abc"), &f.tmp, Some(&f.home)).is_err(),
        "a remote chain's own folder"
    );
    // The sandbox refuses top-level dot folders in the home directory.
    assert!(check(&f.home.join(".cache/lane-tmp"), &f.tmp, Some(&f.home)).is_err());
}

#[test]
fn only_a_new_remote_claude_session_is_checked() {
    use crate::config::HarnessKind;
    let f = fixture();
    let projects = f.home.join("Projects");
    let gate = |remote, trigger, kind| {
        admit_new(NewSession { remote, trigger, kind }, &projects, &f.tmp, Some(&f.home))
    };
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
            Some(&f.home)
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
    assert!(check(&link, &f.tmp, Some(&f.home)).is_ok());
    let up = f.tmp.join("projects-link");
    std::os::unix::fs::symlink(f.home.join("Projects"), &up).unwrap();
    assert!(
        check(&up, &f.tmp, Some(&f.home)).is_err(),
        "a link in the temporary folder to a non-checkout is not scratch"
    );
}

/// A folder in `<home>/chats` as acpmux makes it for a chat with no folder: marked.
fn chat(f: &Fixture, name: &str) -> PathBuf {
    let dir = f.home.join("chats").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(crate::trust::AGENT_HOME_MARKER), "").unwrap();
    dir
}

#[test]
fn acpmux_own_chat_folder_is_scratch() {
    let f = fixture();
    let dir = chat(&f, "lane-router");
    assert!(check(&dir, &f.tmp, Some(&f.home)).is_ok());
    // Claude's own stubs and a plain folder inside change nothing.
    std::fs::write(dir.join("package.json"), "").unwrap();
    std::fs::create_dir_all(dir.join("notes/deep")).unwrap();
    assert!(check(&dir, &f.tmp, Some(&f.home)).is_ok());
    // Without the home directory there is no chat folder to know.
    assert!(check(&dir, &f.tmp, None).is_err());
}

#[test]
fn a_chat_folder_holding_a_checkout_or_without_the_marker_is_refused() {
    let f = fixture();
    let unmarked = f.home.join("chats/unmarked");
    std::fs::create_dir_all(&unmarked).unwrap();
    let err = check(&unmarked, &f.tmp, Some(&f.home)).unwrap_err();
    assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");

    let holds = chat(&f, "holds-a-clone");
    std::fs::create_dir_all(holds.join("work/repo/.git")).unwrap();
    assert!(check(&holds, &f.tmp, Some(&f.home)).is_err(), "stubs would sit above a checkout");
    let linked = chat(&f, "holds-a-worktree");
    std::fs::create_dir_all(linked.join("wt")).unwrap();
    std::fs::write(linked.join("wt/.git"), "gitdir: /x\n").unwrap();
    assert!(check(&linked, &f.tmp, Some(&f.home)).is_err());

    // Only a direct child of `<home>/chats`: not `chats` itself, not deeper, not elsewhere.
    assert!(check(&f.home.join("chats"), &f.tmp, Some(&f.home)).is_err());
    let deeper = chat(&f, "outer").join("inner");
    std::fs::create_dir_all(&deeper).unwrap();
    std::fs::write(deeper.join(crate::trust::AGENT_HOME_MARKER), "").unwrap();
    assert!(check(&deeper, &f.tmp, Some(&f.home)).is_err());
    let elsewhere = f.home.join("Projects/marked");
    std::fs::create_dir_all(&elsewhere).unwrap();
    std::fs::write(elsewhere.join(crate::trust::AGENT_HOME_MARKER), "").unwrap();
    assert!(check(&elsewhere, &f.tmp, Some(&f.home)).is_err());
}

#[cfg(unix)]
#[test]
fn a_chat_folder_is_walked_without_following_links_and_within_a_budget() {
    let f = fixture();
    let dir = chat(&f, "linked");
    // A link to a checkout is not looked through: the stubs land in this folder, not there.
    std::os::unix::fs::symlink(f.home.join("Projects"), dir.join("projects")).unwrap();
    assert!(check(&dir, &f.tmp, Some(&f.home)).is_ok());
    let big = chat(&f, "big");
    for i in 0..5 {
        std::fs::write(big.join(format!("f{i}")), "").unwrap();
    }
    assert!(holds_no_checkout(&big, 100));
    assert!(!holds_no_checkout(&big, 3), "over budget is refused, never guessed");
}

#[test]
fn a_brief_only_remote_new_passes_in_the_folder_the_peer_made() {
    use crate::config::HarnessKind;
    let f = fixture();
    // What `session/new` with no `cwd` gets on a Cloud peer (`peer_scratch`).
    let dir = crate::server::remote_guard::cloud_chat_folder_under(&f.home, "lane-router").unwrap();
    let new = NewSession { remote: true, trigger: false, kind: HarnessKind::ClaudeStdio };
    assert!(admit_new(new, &dir, &f.tmp, Some(&f.home)).is_ok());
    // A folder from before the marker is marked when it is handed out again.
    let old = f.home.join("chats/older");
    std::fs::create_dir_all(&old).unwrap();
    assert!(admit_new(new, &old, &f.tmp, Some(&f.home)).is_err());
    let again = crate::server::remote_guard::cloud_chat_folder_under(&f.home, "older").unwrap();
    assert!(admit_new(new, &again, &f.tmp, Some(&f.home)).is_ok());
}
