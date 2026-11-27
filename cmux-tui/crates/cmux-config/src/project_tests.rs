//! The project settings layer: what a project file sets, where it is found, and that a managed
//! value still wins.

use super::*;
use crate::managed::{ManagedPreferences, TeamPolicyLayer};
use crate::{Domains, FileRead};

const USER: Origin = Origin::User;

fn state(user: &str, managed: ManagedPreferences) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(user.to_string()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        1,
    )
}

fn forced(key: &str, value: Value) -> ManagedPreferences {
    ManagedPreferences { forced: [(key.to_string(), value)].into(), ..Default::default() }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-project-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_project_file_sets_only_per_project_keys() {
    let text = r#"{
        // the project's cache
        "agents": {"promptCache": "5m"},
        "appearance.theme": "Dracula"
    }"#;
    let layer = ProjectLayer::from_text(Path::new("/p"), text, Schema::embedded());
    assert_eq!(layer.value("agents.promptCache"), Some(&json!("5m")));
    assert_eq!(layer.value("appearance.theme"), None);
    assert_eq!(layer.ignored, vec!["appearance.theme".to_string()]);
    assert!(layer.problem.is_none());
    let flat = ProjectLayer::from_text(
        Path::new("/p"),
        r#"{"agents.promptCache":"5m"}"#,
        Schema::embedded(),
    );
    assert_eq!(flat.value("agents.promptCache"), Some(&json!("5m")));
}

#[test]
fn a_broken_project_file_sets_nothing() {
    let layer = ProjectLayer::from_text(Path::new("/p"), "{", Schema::embedded());
    assert!(layer.values.is_empty());
    assert!(layer.problem.is_some());
    let list = ProjectLayer::from_text(Path::new("/p"), "[]", Schema::embedded());
    assert!(list.values.is_empty() && list.problem.is_some());
}

#[test]
fn every_project_key_is_a_catalog_row() {
    for key in PROJECT_KEYS {
        assert!(Schema::embedded().row(key).is_some(), "{key} is no settings row");
    }
}

#[test]
fn find_takes_the_nearest_project_and_stops_below_home() {
    let root = scratch("find");
    let home = root.join("home");
    let project = home.join("code").join("app");
    let deep = project.join("src").join("lib");
    std::fs::create_dir_all(&deep).unwrap();
    assert_eq!(find(&deep, Some(&home)), None);
    std::fs::create_dir_all(project_file(&project).parent().unwrap()).unwrap();
    std::fs::write(project_file(&project), "{}").unwrap();
    assert_eq!(find(&deep, Some(&home)), Some(project.clone()));
    assert_eq!(find(&project, Some(&home)), Some(project.clone()));
    // ~/.cmux/cmux-next.json is cmux's own folder, never a project.
    std::fs::remove_file(project_file(&project)).unwrap();
    std::fs::create_dir_all(project_file(&home).parent().unwrap()).unwrap();
    std::fs::write(project_file(&home), "{}").unwrap();
    assert_eq!(find(&deep, Some(&home)), None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn get_reports_project_over_user_and_managed_over_project() {
    let user = r#"{"agents": {"promptCache": "1h"}}"#;
    let layer = ProjectLayer::from_text(
        Path::new("/p"),
        r#"{"agents": {"promptCache": "5m"}}"#,
        Schema::embedded(),
    );
    let plain = state(user, ManagedPreferences::default());
    let reply = get_json(&plain, "agents.promptCache", Path::new("/p/src"), Some(&layer));
    assert_eq!(reply["value"], "5m");
    assert_eq!(reply["source"], "project");
    assert_eq!(reply["project"]["folder"], "/p");
    let none = get_json(&plain, "agents.promptCache", Path::new("/q"), None);
    assert_eq!((none["value"].clone(), none["source"].clone()), (json!("1h"), json!("user")));
    let managed = state(user, forced("agents.promptCache", json!("1h")));
    let reply = get_json(&managed, "agents.promptCache", Path::new("/p"), Some(&layer));
    assert_eq!(reply["value"], "1h");
    assert_eq!(reply["source"], "managed");
    let empty = state("", ManagedPreferences::default());
    assert_eq!(get_json(&empty, "agents.promptCache", Path::new("/q"), None)["source"], "default");
}

#[test]
fn a_project_write_keeps_comments_and_refuses_what_does_not_apply() {
    let plain = state("", ManagedPreferences::default());
    let source = "{\n  // keep me\n  \"agents.promptCache\": \"1h\"\n}\n";
    let text = set_text(&plain, source, "agents.promptCache", json!("5m"), USER).unwrap();
    assert!(text.contains("// keep me"), "{text}");
    let layer = ProjectLayer::from_text(Path::new("/p"), &text, Schema::embedded());
    assert_eq!(layer.value("agents.promptCache"), Some(&json!("5m")));
    assert!(!text.contains("\"agents.promptCache\""), "the flat key stays: {text}");
    let fresh = set_text(&plain, "", "agents.promptCache", json!("5m"), USER).unwrap();
    assert_eq!(jsonc::parse(&fresh).unwrap(), json!({"agents": {"promptCache": "5m"}}));
    assert!(matches!(
        set_text(&plain, "", "agents.promptCache", json!("2h"), USER),
        Err(Refusal::InvalidValue { .. })
    ));
    assert!(matches!(
        set_text(&plain, "", "appearance.theme", json!("Dracula"), USER),
        Err(Refusal::InvalidParams { .. })
    ));
    let managed = state("", forced("agents.promptCache", json!("1h")));
    assert!(matches!(
        set_text(&managed, "", "agents.promptCache", json!("5m"), USER),
        Err(Refusal::Managed { .. })
    ));
    assert!(matches!(
        set_text(&plain, "", "agents.promptCache", json!("5m"), Origin::Mcp),
        Err(Refusal::AgentRefused { .. })
    ));
    assert!(set_text(&plain, "", "agents.promptCache", json!("5m"), Origin::Cli).is_ok());
    let reset = reset_text(&plain, &text, "agents.promptCache", USER).unwrap();
    assert!(ProjectLayer::from_text(Path::new("/p"), &reset, Schema::embedded()).values.is_empty());
}

#[test]
fn write_creates_the_project_file() {
    let folder = scratch("write");
    let plain = state("", ManagedPreferences::default());
    let path = write(&plain, &folder, "agents.promptCache", Some(json!("5m")), USER).unwrap();
    assert_eq!(path, project_file(&folder));
    let layer = ProjectLayer::read(&folder, Schema::embedded());
    assert_eq!(layer.value("agents.promptCache"), Some(&json!("5m")));
    write(&plain, &folder, "agents.promptCache", None, USER).unwrap();
    assert!(ProjectLayer::read(&folder, Schema::embedded()).values.is_empty());
    let _ = std::fs::remove_dir_all(&folder);
}
