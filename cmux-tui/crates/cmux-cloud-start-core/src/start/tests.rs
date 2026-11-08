//! The start's own checks (moved from the app's `CloudStartChatAppLinkTests` and
//! `CloudStartChatMachineTests`).

use super::*;

fn account(user: Option<&str>, team: Option<&str>) -> Vec<Option<String>> {
    vec![user.map(str::to_owned), team.map(str::to_owned)]
}

/// Not behind Labs: only Cloud off by policy and a signed-out account refuse, whatever the link.
#[test]
fn a_cloud_start_is_refused_only_when_cloud_is_off_or_nobody_is_signed_in() {
    assert_eq!(refusal(false, true), None);
    assert_eq!(refusal(false, false), Some(Refusal::NotSignedIn));
    assert_eq!(refusal(true, true), Some(Refusal::CloudDisabled));
    assert_eq!(refusal(true, false), Some(Refusal::CloudDisabled));
    assert_eq!(serde_json::to_value(Refusal::NotSignedIn).unwrap(), "not_signed_in");
    assert_eq!(serde_json::to_value(Refusal::CloudDisabled).unwrap(), "cloud_disabled");
}

/// A team switch keeps the user signed in and the previous team's machines in the store until the
/// new list lands. A send is kept under the account it was sent in, and copies nothing while the
/// account changed or its list is not current.
#[test]
fn a_send_is_kept_under_the_account_it_began_in_and_checks_it_at_every_step() {
    let team_a = account(Some("user-leo"), Some("team-a"));
    let team_b = account(Some("user-leo"), Some("team-b"));
    assert_eq!(account_text(&team_a), "user-leo/team-a");
    assert_ne!(account_text(&team_a), account_text(&team_b));
    assert_eq!(account_text(&account(Some("user-leo"), None)), "user-leo/");
    assert_eq!(account_text(&account(None, None)), "/");
    assert_eq!(check_account(&team_a, &team_a, true), None);
    assert_eq!(check_account(&team_a, &team_b, true), Some(AccountCheck::AccountChanged));
    assert_eq!(check_account(&team_a, &team_a, false), Some(AccountCheck::ListUnread));
    assert_eq!(
        check_account(&team_a, &account(None, None), true),
        Some(AccountCheck::AccountChanged)
    );
    // A changed account is named before an unread list.
    assert_eq!(check_account(&team_a, &team_b, false), Some(AccountCheck::AccountChanged));
}

#[test]
fn the_home_folder_and_the_disks_root_are_too_broad() {
    assert!(too_broad("/", "/Users/me"));
    assert!(too_broad("/Users/me", "/Users/me"));
    assert!(!too_broad("/Users/me/src/paint", "/Users/me"));
    assert!(!too_broad("/Users", "/Users/me"));
}

fn named(root: &str, upload_root: Option<&str>) -> Folder {
    Folder {
        cwd_given: true,
        upload_root: upload_root.map(str::to_owned),
        root: root.into(),
        paths: vec![root.into()],
        homes: vec!["/Users/me".into()],
        ..Folder::default()
    }
}

fn own(root: &str, subpath: &str, homes: &[&str]) -> Folder {
    Folder {
        root: root.into(),
        subpath: subpath.into(),
        paths: vec![root.into()],
        homes: homes.iter().map(|home| (*home).to_owned()).collect(),
        ..Folder::default()
    }
}

/// A folder the page named is copied only as the pane checked it.
#[test]
fn a_page_named_folder_is_copied_only_as_its_checked_upload_root() {
    assert_eq!(uploads(&named("/Users/me/src/paint", None)), Uploads::No);
    assert_eq!(uploads(&named("/Users/me/src/paint", Some("/Users/me/src/paint"))), Uploads::Yes);
    assert_eq!(
        uploads(&named("/Users/me/src/paint", Some("/Users/me/src/paint/sub"))),
        Uploads::No
    );
    // A named folder is the pane's checked root even at home: the pane's roots decided.
    assert_eq!(uploads(&named("/Users/me", Some("/Users/me"))), Uploads::Yes);
}

/// The tab's own folder (no `cwd`): only that folder itself, never a working copy above it, never
/// the home folder or a folder above it, and only once its git folders are inside it.
#[test]
fn a_tabs_own_folder_is_copied_only_as_itself_below_home() {
    let home = ["/Users/me"];
    assert_eq!(uploads(&own("/Users/me/src/paint", "", &home)), Uploads::IfGitFoldersInside);
    assert_eq!(uploads(&own("/Users/me/src/repo", "project", &home)), Uploads::No);
    assert_eq!(uploads(&own("/Users", "", &home)), Uploads::No);
    assert_eq!(uploads(&own("/Users/me", "", &home)), Uploads::No);
    assert_eq!(uploads(&own("/", "", &home)), Uploads::No);
    // Components, not prefixes: /Users/meet is not above /Users/me.
    assert_eq!(uploads(&own("/Users/meet", "", &home)), Uploads::IfGitFoldersInside);
    // With no home known, only the disk's root refuses.
    assert_eq!(uploads(&own("/Users", "", &[])), Uploads::IfGitFoldersInside);
    assert_eq!(uploads(&own("/", "", &[])), Uploads::No);
}

/// By its canonical path too: a folder whose canonical path is the home folder (a symlink to it), or
/// a home whose canonical spelling differs (/private/var vs /var), refuses.
#[test]
fn the_home_check_reads_every_spelling() {
    let linked = Folder {
        paths: vec!["/tmp/link".into(), "/Users/me".into()],
        ..own("/tmp/link", "", &["/Users/me"])
    };
    assert_eq!(uploads(&linked), Uploads::No);
    let var = own("/private/var/home", "", &["/private/var/home/me", "/var/home/me"]);
    assert_eq!(uploads(&var), Uploads::No);
    let var = own("/var/home", "", &["/private/var/home/me", "/var/home/me"]);
    assert_eq!(uploads(&var), Uploads::No);
}

#[test]
fn the_wire_is_the_apps_shape() {
    let folder: Folder = serde_json::from_str(
        r#"{"cwdGiven":false,"root":"/Users/me/src/paint","subpath":"","paths":["/Users/me/src/paint"],"homes":["/Users/me"]}"#,
    )
    .unwrap();
    assert_eq!(serde_json::to_value(uploads(&folder)).unwrap(), "if-git-folders-inside");
    assert_eq!(serde_json::to_value(AccountCheck::ListUnread).unwrap(), "list-unread");
    assert_eq!(serde_json::to_value(AccountCheck::AccountChanged).unwrap(), "account-changed");
}
