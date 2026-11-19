use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::super::command::CommandPlan;
use super::*;

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
    let pairs: Vec<(String, OsString)> =
        pairs.iter().map(|(key, value)| (key.to_string(), OsString::from(value))).collect();
    move |name| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
}

fn app_socket(path: &str) -> GlobalArgs {
    GlobalArgs { app_socket: Some(path.into()), ..GlobalArgs::default() }
}

fn never_asked(_: &Path) -> Result<PathBuf, String> {
    panic!("no app is asked")
}

#[test]
fn an_app_socket_reads_the_file_that_app_reports() {
    let mut asked = None;
    let file = path_with(&app_socket("/side/control.sock"), env(&[("HOME", "/home/me")]), |at| {
        asked = Some(at.to_path_buf());
        Ok("/side/config/cmux-next.json".into())
    });
    assert_eq!(file, Ok(PathBuf::from("/side/config/cmux-next.json")));
    assert_eq!(asked, Some(PathBuf::from("/side/control.sock")));
}

#[test]
fn an_app_that_does_not_answer_refuses_instead_of_the_home_default() {
    let error = path_with(&app_socket("/side/control.sock"), env(&[("HOME", "/home/me")]), |_| {
        Err("no cmux app is running there".into())
    })
    .expect_err("refused");
    assert_eq!(error["code"], "settings.app_unanswered");
    let message = error["message"].as_str().unwrap_or_default();
    assert!(message.contains("/side/control.sock") && message.contains("no cmux app"), "{message}");
    assert!(!message.contains("/home/me"), "{message}");
}

#[test]
fn an_explicit_config_file_wins_over_the_app_socket() {
    let environment = env(&[("HOME", "/home/me"), ("CMUX_NEXT_CONFIG_FILE", "/tmp/mine.json")]);
    let file = path_with(&app_socket("/side/control.sock"), environment, never_asked);
    assert_eq!(file, Ok(PathBuf::from("/tmp/mine.json")));
}

#[test]
fn no_app_socket_is_the_default_file_and_asks_no_app() {
    let file = path_with(&GlobalArgs::default(), env(&[("HOME", "/home/me")]), never_asked);
    assert_eq!(file, Ok(PathBuf::from("/home/me/.config/cmux/cmux-next.json")));
    // A daemon route names no app: its owner writes its own file, as before.
    let socket = GlobalArgs { socket: Some("/tmp/d.sock".into()), ..GlobalArgs::default() };
    let file = path_with(&socket, env(&[("HOME", "/home/me")]), never_asked);
    assert_eq!(file, Ok(PathBuf::from("/home/me/.config/cmux/cmux-next.json")));
}

#[test]
fn the_reported_file_is_an_absolute_path() {
    let answer = json!({ "path": ["appearance", "themeFile"], "file": "/side/cmux-next.json" });
    assert_eq!(reported_file(&answer), Ok(PathBuf::from("/side/cmux-next.json")));
    for answer in [json!({}), json!({ "file": "" }), json!({ "file": "cmux-next.json" })] {
        assert!(reported_file(&answer).is_err(), "{answer}");
    }
}

fn plan(words: &[&str]) -> RequestPlan {
    let words: Vec<String> = words.iter().map(|word| word.to_string()).collect();
    match super::super::command::parse(&words, super::super::Surface::Cmux) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        _ => panic!("{words:?} is not a request"),
    }
}

#[test]
fn a_settings_write_for_the_app_socket_is_pinned_to_its_file() {
    let global = app_socket("/side/control.sock");
    let file = Path::new("/side/cmux-next.json");

    let mut set = plan(&["settings", "set", "appearance.themeFile", "tokyo"]);
    assert!(pins(&global, &set));
    pin(&mut set, file);
    assert!(matches!(set.operation, WireOperation::Typed(ResourceOperation::SettingsEdit)));
    assert_eq!(set.params["file"], "/side/cmux-next.json");
    assert_eq!(
        set.params["edits"],
        json!([{ "op": "set", "key": "appearance.themeFile", "value": "tokyo" }])
    );
    assert!(set.params.get("key").is_none() && set.params.get("value").is_none());
    assert_eq!(set.params["session"], "current");

    let mut reset = plan(&["settings", "reset", "appearance.themeFile"]);
    pin(&mut reset, file);
    assert_eq!(reset.params["edits"], json!([{ "op": "reset", "key": "appearance.themeFile" }]));
    assert_eq!(reset.params["file"], "/side/cmux-next.json");

    let edits = r#"[{"op":"reset","key":"appearance.theme"}]"#;
    let mut edit = plan(&["settings", "edit", edits]);
    pin(&mut edit, file);
    assert_eq!(edit.params["edits"], json!([{ "op": "reset", "key": "appearance.theme" }]));
    assert_eq!(edit.params["file"], "/side/cmux-next.json");
}

#[test]
fn only_settings_writes_with_an_app_socket_are_pinned() {
    let set = plan(&["settings", "set", "appearance.themeFile", "tokyo"]);
    assert!(!pins(&GlobalArgs::default(), &set));
    let socket = GlobalArgs { socket: Some("/tmp/d.sock".into()), ..GlobalArgs::default() };
    assert!(!pins(&socket, &set));
    assert!(!pins(&app_socket("/side/control.sock"), &plan(&["settings", "get", "a.b"])));
}
