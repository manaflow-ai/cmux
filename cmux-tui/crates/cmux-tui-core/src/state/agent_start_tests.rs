//! `workspace.agent_start.get` (cx-nn3e, cx-9aps): one owner for where a new
//! agent chat starts. The chip said `~`, the line under it said the chat
//! starts in a private folder, and the start was refused, because the app,
//! the page and the relay each decided the folder. The store answers once.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::agent_start::{Inputs, resolve};
use super::tests::{empty_workspace, mutate, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// A fake home with a project, a folder above home, and an agent-home base.
struct Tree {
    root: PathBuf,
    home: PathBuf,
    project: String,
    base: PathBuf,
}

fn tree(name: &str) -> Tree {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-start-{name}-{}", WorkspacePublicId::random().unwrap()));
    let home = root.join("users").join("me");
    std::fs::create_dir_all(home.join("src").join("project")).unwrap();
    let base = home.join("data").join("cmux").join("agent-home");
    std::fs::create_dir_all(base.join("ws-1")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let home = std::fs::canonicalize(home).unwrap();
    let project = home.join("src").join("project").to_str().unwrap().to_string();
    let base = std::fs::canonicalize(base).unwrap();
    Tree { root, home, project, base }
}

fn answer(tree: &Tree, seed: Option<&str>, chosen: Option<&str>, tabs: &[String]) -> Value {
    resolve(&Inputs {
        seed,
        chosen,
        tab_folders: tabs,
        home: Some(&tree.home),
        agent_home_base: Some(&tree.base),
        workspace_id: "ws-1",
    })
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_string()
}

#[test]
fn a_folderless_workspace_starts_in_its_agent_home_never_the_home_folder() {
    let tree = tree("folderless");
    let home = text(&tree.home);
    // A fresh workspace's terminal sits at `~` (and one at `/`): neither is a start folder.
    let value = answer(&tree, None, None, &[home, "/".into()]);
    let agent_home = text(&tree.base.join("ws-1"));
    assert_eq!(value["kind"], "agent_home");
    assert_eq!(value["cwd"], agent_home);
    assert_eq!(value["agent_home"], agent_home);
    assert!(value.get("skipped").is_none());
    let _ = std::fs::remove_dir_all(&tree.root);
}

#[test]
fn the_rules_take_the_seed_then_the_chosen_folder_then_a_tab_folder() {
    let tree = tree("order");
    let other = text(&tree.home.join("src"));
    let tabs = [text(&tree.home), other.clone()];
    assert_eq!(answer(&tree, None, None, &tabs)["kind"], "workspace");
    assert_eq!(answer(&tree, None, None, &tabs)["cwd"], other);
    let chosen = answer(&tree, None, Some(&tree.project), &tabs);
    assert_eq!(
        (chosen["kind"].as_str(), chosen["cwd"].as_str()),
        (Some("chosen"), Some(tree.project.as_str()))
    );
    let seeded =
        answer(&tree, Some(&format!("{}/src/./project/", text(&tree.home))), Some(&other), &tabs);
    // The seed is made canonical.
    assert_eq!(
        (seeded["kind"].as_str(), seeded["cwd"].as_str()),
        (Some("seed"), Some(tree.project.as_str()))
    );
    let _ = std::fs::remove_dir_all(&tree.root);
}

#[test]
fn a_seed_at_home_above_it_in_agent_home_or_missing_is_skipped_with_its_reason() {
    let tree = tree("skipped");
    let cases = [
        (text(&tree.home), "home"),
        (text(tree.home.parent().unwrap()), "above_home"),
        ("/".to_string(), "above_home"),
        (text(&tree.base.join("ws-1")), "agent_home"),
        (format!("{}/missing", tree.project), "missing"),
        ("relative".to_string(), "missing"),
    ];
    for (seed, reason) in cases {
        let value = answer(&tree, Some(&seed), Some(&tree.project), &[]);
        assert_eq!(value["skipped"], json!({"cwd": seed, "reason": reason}), "{seed}");
        // The chat still starts somewhere real: the next rule.
        assert_eq!(value["kind"], "chosen", "{seed}");
    }
    let _ = std::fs::remove_dir_all(&tree.root);
}

#[test]
fn a_chosen_folder_that_went_away_falls_through() {
    let tree = tree("gone");
    let gone = format!("{}/gone", tree.project);
    assert_eq!(answer(&tree, None, Some(&gone), &[])["kind"], "agent_home");
    let _ = std::fs::remove_dir_all(&tree.root);
}

#[test]
fn an_unsafe_workspace_id_has_no_agent_home() {
    let tree = tree("unsafe");
    let value = resolve(&Inputs {
        seed: None,
        chosen: None,
        tab_folders: &[],
        home: Some(&tree.home),
        agent_home_base: Some(&tree.base),
        workspace_id: "../etc",
    });
    assert_eq!(value["kind"], "agent_home");
    assert!(value["cwd"].is_null());
    let _ = std::fs::remove_dir_all(&tree.root);
}

#[test]
fn the_operation_answers_for_a_workspace() {
    let tree = tree("operation");
    let mux = Mux::new_for_test("agent-start-op", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "w");
    let fresh =
        send(&mux, "workspace.agent_start.get", json!({"workspace": workspace}), None).unwrap();
    assert_eq!(fresh["kind"], "agent_home");
    assert!(fresh["cwd"].as_str().unwrap().ends_with(&format!("/cmux/agent-home/{workspace}")));
    let seeded = send(
        &mux,
        "workspace.agent_start.get",
        json!({"workspace": workspace, "cwd": tree.project}),
        None,
    )
    .unwrap();
    assert_eq!(
        (seeded["kind"].as_str(), seeded["cwd"].as_str()),
        (Some("seed"), Some(tree.project.as_str()))
    );
    if let Some(home) =
        crate::platform::home_dir().and_then(|home| std::fs::canonicalize(home).ok())
    {
        let at_home = send(
            &mux,
            "workspace.agent_start.get",
            json!({"workspace": workspace, "cwd": text(&home)}),
            None,
        )
        .unwrap();
        assert_eq!(at_home["skipped"]["reason"], "home");
        assert_eq!(at_home["kind"], "agent_home");
    }
    mutate(
        &mux,
        "workspace.agent_folder.set",
        json!({"workspace": workspace, "path": tree.project}),
        "f-1",
    );
    let chosen =
        send(&mux, "workspace.agent_start.get", json!({"workspace": workspace}), None).unwrap();
    assert_eq!(
        (chosen["kind"].as_str(), chosen["cwd"].as_str()),
        (Some("chosen"), Some(tree.project.as_str()))
    );
    let _ = std::fs::remove_dir_all(&tree.root);
}

/// The store owns the home rule for the chosen folder too: Choose Folder…
/// refused home only in Swift, so another client could save it.
#[test]
fn the_agent_folder_is_never_the_home_folder_or_above() {
    let Some(home) = crate::platform::home_dir().and_then(|home| std::fs::canonicalize(home).ok())
    else {
        return;
    };
    let mux = Mux::new_for_test("agent-folder-home", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "w");
    let mut refused = vec![text(&home)];
    let mut above = home.parent();
    while let Some(folder) = above {
        refused.push(text(folder));
        above = folder.parent();
    }
    for (index, path) in refused.into_iter().enumerate() {
        let result = send(
            &mux,
            "workspace.agent_folder.set",
            json!({"workspace": workspace, "path": path}),
            Some(&format!("home-{index}")),
        );
        assert_eq!(super::tests::error_code(result), "validation.invalid", "{path}");
    }
}
