use super::*;
use crate::github_cli::refused;

const TOKEN: &str = "gho_carried0000000000000000000000000000";
const PUSH: &str = "protocol=https\nhost=github.com\npath=octo/repo.git\n\n";

fn app_never(_: &TokenAsk) -> Result<Minted, Refused> {
    panic!("the App was asked although the carried login covers it")
}

#[test]
fn the_carried_login_answers_first_when_it_can_push() {
    let mut probed = Vec::new();
    let mut probe = |repo: &str| {
        probed.push(repo.to_owned());
        Reach::Write
    };
    let (out, note) = credential_get_own_first(
        PUSH,
        GitOp::Push,
        false,
        Some((TOKEN, &mut probe)),
        &mut app_never,
    );
    assert_eq!(out, format!("username=x-access-token\npassword={TOKEN}\n"));
    assert_eq!(note, None);
    assert_eq!(probed, ["octo/repo"]);
}

#[test]
fn a_read_only_login_reads_but_a_push_goes_to_the_app() {
    let mut probe = |_: &str| Reach::Read;
    let (out, _) = credential_get_own_first(
        PUSH,
        GitOp::Read,
        false,
        Some((TOKEN, &mut probe)),
        &mut app_never,
    );
    assert!(out.contains(TOKEN));
    let mut probe = |_: &str| Reach::Read;
    let mut minted = |_: &TokenAsk| Ok(Minted { token: "ghs_app".to_owned() });
    let (out, note) =
        credential_get_own_first(PUSH, GitOp::Push, false, Some((TOKEN, &mut probe)), &mut minted);
    assert!(out.contains("ghs_app") && !out.contains(TOKEN));
    let note = note.unwrap();
    assert!(note.contains("can read octo/repo but not push"), "{note}");
    assert!(!note.contains(TOKEN));
}

#[test]
fn when_neither_reaches_the_note_names_both() {
    let mut probe = |_: &str| Reach::None;
    let mut refuse = |_: &TokenAsk| Err(refused("integration.not_found", "no GitHub connection"));
    let (out, note) =
        credential_get_own_first(PUSH, GitOp::Push, false, Some((TOKEN, &mut probe)), &mut refuse);
    assert_eq!(out, "");
    let note = note.unwrap();
    assert!(note.starts_with("your GitHub login can't reach octo/repo."), "{note}");
    assert!(note.contains("The cmux GitHub App:"), "{note}");
    assert!(!note.contains(TOKEN));
}

#[test]
fn without_a_carried_login_or_off_github_nothing_changes() {
    let mut minted = |_: &TokenAsk| Ok(Minted { token: "ghs_app".to_owned() });
    let (out, _) = credential_get_own_first(PUSH, GitOp::Push, false, None, &mut minted);
    assert!(out.contains("ghs_app"));
    let mut probe = |_: &str| -> Reach { panic!("probed another host") };
    let gitlab = "protocol=https\nhost=gitlab.com\npath=octo/repo.git\n\n";
    let (out, _) = credential_get_own_first(
        gitlab,
        GitOp::Push,
        false,
        Some((TOKEN, &mut probe)),
        &mut app_never,
    );
    assert_eq!(out, "");
}

#[test]
fn the_probe_output_reads_as_a_reach() {
    assert_eq!(reach_of(true, "true\n"), Reach::Write);
    assert_eq!(reach_of(true, "false\n"), Reach::Read);
    assert_eq!(reach_of(false, ""), Reach::None);
    assert!(Reach::Write.covers(GitOp::Push));
    assert!(!Reach::Read.covers(GitOp::Push));
    assert!(Reach::Read.covers(GitOp::Unknown));
    assert!(!Reach::None.covers(GitOp::Read));
}

#[test]
fn the_token_file_is_read_with_the_gitlab_checks() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    assert_eq!(token(home.path()).unwrap(), None);
    let dir = home.path().join(crate::gitlab_cli::TOKENS_DIR);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join(HOST);
    std::fs::write(&file, format!("{TOKEN}\n")).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(token(home.path()).unwrap().as_deref().map(String::as_str), Some(TOKEN));
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    let note = token(home.path()).unwrap_err();
    assert!(!note.contains(TOKEN));
    assert!(forget(home.path()).unwrap());
    assert!(!file.exists());
    assert!(!forget(home.path()).unwrap());
}
