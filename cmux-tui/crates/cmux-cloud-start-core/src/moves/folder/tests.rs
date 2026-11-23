//! The move's folder and the New Workspace plan (moved from the app's `CloudNewWorkspaceTests`,
//! `CloudNewWorkspaceMachineTests` and the Swift `CloudMoveFolder`).

use super::*;

fn git_at(tops: &'static [&'static str]) -> impl Fn(&str) -> bool {
    move |folder| tops.contains(&folder)
}

#[test]
fn a_path_resolves_its_dots_and_never_climbs_above_the_root() {
    assert_eq!(normalized("/a/./b/../c/").as_deref(), Some("/a/c"));
    assert_eq!(normalized("/private/tmp").as_deref(), Some("/private/tmp"));
    assert_eq!(normalized("/").as_deref(), Some("/"));
    assert_eq!(normalized("/.."), None);
    assert_eq!(normalized("relative/x"), None);
}

#[test]
fn a_chat_moves_with_its_working_copy_else_its_own_folder() {
    let inside = move_folder("/w/app/src/ui", git_at(&["/w/app"])).unwrap();
    assert_eq!(
        (inside.root.as_str(), inside.subpath.as_str(), inside.git),
        ("/w/app", "src/ui", true)
    );
    let top = move_folder("/w/app/", git_at(&["/w/app"])).unwrap();
    assert_eq!((top.root.as_str(), top.subpath.as_str()), ("/w/app", ""));
    let plain = move_folder("/Users/me/Downloads/big", git_at(&[])).unwrap();
    assert_eq!(
        (plain.root.as_str(), plain.subpath.as_str(), plain.git),
        ("/Users/me/Downloads/big", "", false)
    );
    let disk = move_folder("/x/y", git_at(&["/"])).unwrap();
    assert_eq!((disk.root.as_str(), disk.subpath.as_str()), ("/", "x/y"));
    assert_eq!(move_folder("x", git_at(&[])), None);
    assert_eq!(move_folder("/../x", git_at(&[])), None);
}

#[test]
fn a_folders_machine_name_is_its_name_and_a_hash_of_where_it_is() {
    let one = remote_name("/Users/a/app");
    let two = remote_name("/Users/b/app");
    assert!(one.starts_with("app-") && one.len() == "app-".len() + 6);
    assert_ne!(one, two, "two folders with one name never share a synced folder");
    assert!(remote_name("/").starts_with("folder-"));
    assert_eq!(remote_name(""), "folder-1c9dc5", "the hash of nothing is FNV-1a's basis");
    let remote = remote("/Users/a/app", "src/ui", "/root/work/");
    assert_eq!(remote.folder, format!("/root/work/{one}"));
    assert_eq!(remote.chat, format!("/root/work/{one}/src/ui"));
    assert_eq!(super::remote("/Users/a/app", "", "/root/work").chat, format!("/root/work/{one}"));
}

fn toggle(in_cloud: bool, inherits: bool, by_person: bool, names: bool) -> Toggle {
    Toggle {
        in_cloud,
        inherits_folder: inherits,
        cwd: Some("/w/app/src".into()),
        by_person,
        names_machine_or_command: names,
    }
}

#[test]
fn only_a_persons_new_workspace_with_the_toggle_on_goes_to_cloud() {
    assert_eq!(
        plan(&toggle(false, true, true, false)),
        None,
        "off by default keeps it on this Mac"
    );
    assert_eq!(plan(&toggle(true, true, true, false)), Some(Some("/w/app/src".into())));
    assert_eq!(
        plan(&toggle(true, false, true, false)),
        Some(None),
        "an empty folder, or an app that cannot copy"
    );
    assert_eq!(
        plan(&toggle(true, true, false, false)),
        None,
        "`cmux workspace new` stays where it was asked"
    );
    assert_eq!(plan(&toggle(true, true, true, true)), None);
    assert_eq!(plan(&Toggle { cwd: None, ..toggle(true, true, true, false) }), Some(None));
}

/// A machine is asked for only where Cloud can make it and a window shows its progress.
#[test]
fn the_route_needs_cloud_a_sign_in_and_a_window() {
    assert_eq!(route(None, true, true), Route::Cloud);
    assert_eq!(route(None, true, false), Route::ThisMac { refusal: Refusal::NoWindow });
    assert_eq!(route(None, false, true), Route::ThisMac { refusal: Refusal::SignedOut });
    assert_eq!(
        route(Some("off"), true, true),
        Route::ThisMac { refusal: Refusal::Unavailable { reason: "off".into() } }
    );
}

fn answer(ok: bool, code: Option<&str>, error: Option<&str>) -> CopyAnswer {
    CopyAnswer { ok, error_code: code.map(str::to_owned), error: error.map(str::to_owned) }
}

/// The copy goes under the first work root the machine lets it write, and stops at the first real refusal.
#[test]
fn the_folder_is_copied_under_the_first_work_root_the_machine_allows() {
    assert_eq!(
        copy_step(&answer(false, Some("fs.permission_denied"), None), false),
        CopyStep::Next
    );
    assert_eq!(copy_step(&answer(true, None, None), false), CopyStep::Done);
    assert_eq!(
        copy_step(&answer(false, Some("io"), Some("disk full")), false),
        CopyStep::Failed { message: "disk full".into() }
    );
    assert_eq!(
        copy_step(&answer(false, Some("fs.permission_denied"), None), true),
        CopyStep::Failed { message: "fs.permission_denied".into() }
    );
    assert_eq!(copy_step(&answer(false, Some("machine_outdated"), None), true), CopyStep::Outdated);
    assert_eq!(
        copy_step(&answer(false, None, None), true),
        CopyStep::Failed { message: String::new() },
        "no work root at all"
    );
}

/// Every new Cloud workspace makes a machine of its own: a person's gesture in a
/// window that shows a Cloud machine gets a new one too. Only an explicit
/// `--target machine:<id>` names an existing machine.
#[test]
fn a_new_workspace_opens_on_the_named_machine_else_a_new_one() {
    assert_eq!(
        new_workspace_machine(Some("vm-1"), false, Some("vm-2")),
        NewWorkspaceMachine::Named("vm-1".into())
    );
    assert_eq!(
        new_workspace_machine(Some("vm-1"), true, Some("vm-2")),
        NewWorkspaceMachine::Named("vm-1".into())
    );
    assert_eq!(new_workspace_machine(None, false, Some("vm-fleet")), NewWorkspaceMachine::New);
    assert_eq!(new_workspace_machine(Some(""), false, None), NewWorkspaceMachine::New);
    assert_eq!(new_workspace_machine(None, true, Some("vm-2")), NewWorkspaceMachine::New);
    assert_eq!(new_workspace_machine(Some(""), true, Some("vm-2")), NewWorkspaceMachine::New);
    assert_eq!(new_workspace_machine(None, true, None), NewWorkspaceMachine::New);
    assert_eq!(new_workspace_machine(None, true, Some("")), NewWorkspaceMachine::New);
}
