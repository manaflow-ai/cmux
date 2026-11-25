use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir()
            .join(format!("cmux-project-actions-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path.canonicalize().unwrap())
    }

    fn write(&self, relative: &str, text: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, text).unwrap();
        path
    }

    fn dir(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(&path).unwrap();
        path
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn discovers_the_file_from_a_subfolder_and_stops_at_the_repository_root() {
    let tmp = Folder::new("discover");
    tmp.dir("repo/.git");
    let file = tmp.write("repo/.cmux/actions.json", "{}");
    let deep = tmp.dir("repo/src/app");
    let found = discover(&deep, None);
    assert_eq!(found.root.as_deref(), Some(tmp.0.join("repo").as_path()));
    assert_eq!(found.file, Some(file));

    // Above the repository root, an outer file is not this project's.
    tmp.write(".cmux/actions.json", "{}");
    let inner = tmp.dir("other/.git");
    let found = discover(&tmp.0.join("other"), None);
    assert_eq!(found.root.as_deref(), inner.parent());
    assert_eq!(found.file, None);
}

#[test]
fn a_nested_package_file_wins_over_the_repository_root() {
    let tmp = Folder::new("nested");
    tmp.dir("mono/.git");
    tmp.write("mono/.cmux/actions.json", "{}");
    let inner = tmp.write("mono/packages/web/.cmux/actions.json", "{}");
    let found = discover(&tmp.dir("mono/packages/web/src"), None);
    assert_eq!(found.file, Some(inner));
}

#[test]
fn the_home_folder_is_never_a_project() {
    let tmp = Folder::new("home");
    tmp.write(".cmux/actions.json", "{}");
    let found = discover(&tmp.dir("scratch"), Some(&tmp.0));
    assert_eq!(found, Found::default());
}

#[test]
fn parses_the_global_shape_and_reports_bad_entries() {
    let tmp = Folder::new("parse");
    tmp.dir("repo/.git");
    tmp.write(
        "repo/.cmux/actions.json",
        r#"{
          // the repository's own buttons
          "actions": {
            "setup": { "title": "Setup", "command": "npm install", "icon": "shippingbox" },
            "test": { "command": "npm test", "target": "currentTerminal", "tooltip": "Run tests" },
            "review": { "type": "agent", "agent": "claude-code", "args": "-p review" },
            "logo": { "command": "open .", "icon": { "type": "image", "path": "logo.png" } },
            "empty": { "command": "  " },
            "flags": { "agent": "claude --yolo" },
            "ws": { "type": "workspace", "command": "x" },
            "where": { "command": "ls", "target": "elsewhere" },
            "text": "make deploy"
          }
        }"#,
    );
    let resolved = resolve(&tmp.0.join("repo"), None, None);
    let root = tmp.0.join("repo").to_string_lossy().into_owned();
    assert_eq!(resolved.project_root.as_deref(), Some(root.as_str()));
    let names: Vec<&str> = resolved.actions.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, ["logo", "review", "setup", "test", "where"]);
    let by = |name: &str| resolved.actions.iter().find(|a| a.name == name).unwrap();
    assert_eq!(by("setup").title, "Setup");
    assert_eq!(by("setup").icon, Some(json!({"type": "symbol", "name": "shippingbox"})));
    assert_eq!(by("setup").cwd.as_deref(), Some(root.as_str()));
    assert_eq!(by("setup").target, "newTabInCurrentPane");
    assert_eq!(by("test").title, "Run tests");
    assert_eq!(by("test").target, "currentTerminal");
    assert_eq!(by("review").command, "claude -p review");
    assert_eq!(by("review").title, "review");
    let logo = tmp.0.join("repo/.cmux/logo.png").to_string_lossy().into_owned();
    assert_eq!(by("logo").icon, Some(json!({"type": "image", "path": logo})));
    assert_eq!(by("where").target, "newTabInCurrentPane");
    let paths: Vec<&str> = resolved.problems.iter().map(|p| p.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "actions.empty.command",
            "actions.flags.agent",
            "actions.text",
            "actions.where.target",
            "actions.ws.type"
        ]
    );
    assert!(resolved.problems.iter().all(|p| p.source == Source::Project));
}

#[test]
fn a_project_action_takes_the_place_of_a_global_one_with_its_name() {
    let tmp = Folder::new("merge");
    tmp.dir("repo/.git");
    tmp.write("repo/.cmux/actions.json", r#"{"actions": {"test": {"command": "cargo test"}}}"#);
    let global = json!({"actions": {
        "test": {"command": "npm test"},
        "deploy": {"title": "Deploy", "command": "make deploy"},
    }});
    let resolved = resolve(&tmp.0.join("repo"), None, Some(&global));
    let summary: Vec<(&str, Source, &str, bool)> = resolved
        .actions
        .iter()
        .map(|a| (a.name.as_str(), a.source, a.command.as_str(), a.shadows))
        .collect();
    assert_eq!(
        summary,
        [
            ("test", Source::Project, "cargo test", true),
            ("deploy", Source::Global, "make deploy", false),
        ]
    );
    assert_eq!(resolved.actions[1].cwd, None);
}

#[test]
fn a_folder_in_no_project_lists_only_the_global_actions() {
    let tmp = Folder::new("none");
    let global = json!({"actions": {"deploy": {"command": "make deploy"}}});
    let resolved = resolve(&tmp.dir("loose"), Some(&tmp.0), Some(&global));
    assert_eq!(resolved.project_root, None);
    assert_eq!(resolved.file, None);
    assert_eq!(resolved.actions.len(), 1);
    assert_eq!(resolved.actions[0].source, Source::Global);
}

#[test]
fn a_broken_or_oversized_file_is_reported_not_read() {
    let tmp = Folder::new("broken");
    tmp.dir("repo/.git");
    tmp.write("repo/.cmux/actions.json", "{ \"actions\": ");
    let resolved = resolve(&tmp.0.join("repo"), None, None);
    assert!(resolved.actions.is_empty());
    assert_eq!(resolved.problems.len(), 1);
    assert!(resolved.problems[0].path.ends_with(PROJECT_FILE));

    let big =
        format!("{{\"actions\": {{}}, \"pad\": \"{}\"}}", "x".repeat(MAX_FILE_BYTES as usize));
    tmp.write("repo/.cmux/actions.json", &big);
    let resolved = resolve(&tmp.0.join("repo"), None, None);
    assert!(resolved.problems[0].message.starts_with("larger than"));
}

#[cfg(unix)]
#[test]
fn a_linked_file_or_folder_is_not_read() {
    let tmp = Folder::new("link");
    tmp.dir("repo/.git");
    let outside = tmp.write("outside/actions.json", r#"{"actions": {"x": {"command": "x"}}}"#);
    std::os::unix::fs::symlink(&outside, tmp.dir("repo/.cmux").join("actions.json")).unwrap();
    let resolved = resolve(&tmp.0.join("repo"), None, None);
    assert!(resolved.actions.is_empty());
    assert_eq!(resolved.problems[0].message, LINK_PROBLEM);

    tmp.dir("repo2/.git");
    std::os::unix::fs::symlink(tmp.0.join("outside"), tmp.0.join("repo2/.cmux")).unwrap();
    let resolved = resolve(&tmp.0.join("repo2"), None, None);
    assert!(resolved.actions.is_empty());
    assert_eq!(resolved.problems[0].message, LINK_PROBLEM);
}

#[test]
fn global_actions_never_carry_a_cwd_and_the_section_must_be_an_object() {
    let mut problems = Vec::new();
    let actions =
        parse(&json!({"actions": []}), Source::Global, Path::new("/"), None, &mut problems);
    assert!(actions.is_empty());
    assert_eq!(problems[0].path, "actions");
}
