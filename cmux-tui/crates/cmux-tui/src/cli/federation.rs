//! Several sessions from one CLI (plans/cmux-next/cli.md, Remaining 12).
//!
//! - Every command acts on one session: the one `--socket`/`--session`, the
//!   environment, or the bundling app names. Lists and bulk commands never
//!   reach another session unless asked, so a script that lists and closes
//!   cannot touch a session it did not name.
//! - `--all-sessions` runs a list on every local session this user runs and
//!   joins the records, each tagged with its `session`.
//! - `<session>:<id>` (`build-box:ws_…`) names an object on that session:
//!   the command routes there as with `--session build-box`. Local named
//!   sessions only; sessions the app reaches over SSH or Cloud have no CLI
//!   transport yet.

use std::io::BufReader;
use std::path::{Path, PathBuf};

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::{Map, Value, json};

use super::command::{RequestPlan, WireOperation};
use super::{GlobalArgs, UsageError};

/// Public id prefixes a session qualifier may stand in front of.
const ID_PREFIXES: &[&str] = &[
    "ws",
    "screen",
    "pane",
    "tab",
    "term",
    "browser",
    "split",
    "notification",
    "agent",
    "tgrp",
    "grp",
];

/// Options whose values are object ids, so a qualified id there routes.
const ID_OPTIONS: &[&str] = &[
    "--workspace",
    "--screen",
    "--pane",
    "--tab",
    "--tabs",
    "--screens",
    "--terminal",
    "--browser",
    "--split",
    "--target",
    "--other-workspace",
    "--other-screen",
    "--other-pane",
];

/// `Some((session, id))` when `value` is `<session>:<typed public id>`. A
/// kind (`workspace:ws_…`, an action target) and the `name:` escape are not
/// sessions. `cmux mcp` shares it.
pub(super) fn qualified(value: &str) -> Option<(&str, &str)> {
    let (session, id) = value.split_once(':')?;
    // A kind (`workspace:ws_…`, an action target) and the `name:` escape are
    // not sessions.
    if session == "name" || cmux_tui_core::resource::is_reserved_selector_token(session) {
        return None;
    }
    let (prefix, rest) = id.split_once('_')?;
    let typed = ID_PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.chars().all(|character| character.is_ascii_alphanumeric());
    (typed && cmux_tui_core::server::validate_session_name(session).is_ok())
        .then_some((session, id))
}

/// Replaces each qualified id in a comma-separated `value` by its bare id and
/// records the session; ids of two sessions are refused.
fn take(value: &mut String, found: &mut Option<String>) -> Result<(), UsageError> {
    let mut parts = Vec::new();
    let mut changed = false;
    for part in value.split(',') {
        match qualified(part) {
            Some((session, id)) => {
                if let Some(other) = found.as_deref()
                    && other != session
                {
                    return Err(UsageError::new(format!(
                        "ids from two sessions ({other} and {session}) in one command; run one command per session"
                    )));
                }
                *found = Some(session.to_owned());
                parts.push(id.to_owned());
                changed = true;
            }
            None => parts.push(part.to_owned()),
        }
    }
    if changed {
        *value = parts.join(",");
    }
    Ok(())
}

/// Strips the session qualifier from the selector word (after the scope) and
/// from id options, and routes the command to that session. Payloads (text,
/// names, URLs) and anything after `--` are never read.
pub(super) fn apply_qualifiers(
    global: &mut GlobalArgs,
    args: &mut [String],
) -> Result<(), UsageError> {
    let mut found: Option<String> = None;
    let mut index = 0;
    while index < args.len() {
        let (before, rest) = args.split_at_mut(index);
        let arg = &mut rest[0];
        if arg == "--" {
            break;
        }
        if index == 1 && !arg.starts_with('-') {
            take(arg, &mut found)?;
        } else if let Some((flag, value)) = arg.split_once('=')
            && ID_OPTIONS.contains(&flag)
        {
            let mut value = value.to_owned();
            take(&mut value, &mut found)?;
            *arg = format!("{flag}={value}");
        } else if index > 0 && ID_OPTIONS.contains(&before[index - 1].as_str()) {
            take(arg, &mut found)?;
        }
        index += 1;
    }
    let Some(session) = found else { return Ok(()) };
    if global.socket.is_some() {
        return Err(UsageError::new(format!(
            "{session}: a qualified id names its session; drop --socket"
        )));
    }
    match &global.session {
        Some(named) if named != &session => Err(UsageError::new(format!(
            "--session {named} and an id qualified with {session}: name one session"
        ))),
        _ => {
            global.session = Some(session);
            Ok(())
        }
    }
}

/// Whether `--all-sessions` may run `plan`: a read that lists records.
pub(super) fn validate_all_sessions(
    global: &GlobalArgs,
    plan: &RequestPlan,
) -> Result<(), UsageError> {
    let lists = plan.operation.class() == OperationClass::Read
        && !plan.stream
        && plan.operation.name().is_ok_and(|name| name.ends_with(".list"));
    if !lists {
        return Err(UsageError::new("--all-sessions applies only to list commands"));
    }
    if global.socket.is_some() || global.session.is_some() {
        return Err(UsageError::new(
            "--all-sessions cannot be combined with --socket or --session",
        ));
    }
    Ok(())
}

/// Every local session socket this user runs: `<name>.sock` in the runtime
/// directories, plus the bundling app's session. Sorted by name, one per path.
pub(super) fn local_sessions(
    directories: &[PathBuf],
    extra: Option<(String, PathBuf)>,
) -> Vec<(String, PathBuf)> {
    let mut sessions: Vec<(String, PathBuf)> = Vec::new();
    for directory in directories {
        let Ok(entries) = std::fs::read_dir(directory) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|extension| extension != "sock") {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|stem| stem.to_str()) else { continue };
            if cmux_tui_core::server::validate_session_name(name).is_ok() {
                sessions.push((name.to_owned(), path));
            }
        }
    }
    sessions.extend(extra);
    sessions.sort();
    sessions.dedup_by(|a, b| a.1 == b.1);
    sessions
}

/// Joins each session's list: records gain `session`; a non-list result is
/// `{session, result}`.
pub(super) fn join(results: Vec<(String, Value)>) -> Value {
    let mut joined = Vec::new();
    for (session, result) in results {
        match result {
            Value::Array(records) => {
                for record in records {
                    joined.push(match record {
                        Value::Object(mut object) => {
                            object.insert("session".into(), json!(session));
                            Value::Object(object)
                        }
                        other => json!({ "session": session, "result": other }),
                    });
                }
            }
            other => joined.push(json!({ "session": session, "result": other })),
        }
    }
    Value::Array(joined)
}

#[cfg(unix)]
fn session_sockets() -> Vec<(String, PathBuf)> {
    let directories =
        [cmux_tui_core::platform::runtime_dir(), cmux_tui_core::platform::fallback_runtime_dir()];
    #[cfg(target_os = "macos")]
    let app = crate::app_identity::AppIdentity::detect(
        |name| std::env::var(name).ok(),
        std::env::current_exe().ok().as_deref(),
    )
    .and_then(|identity| {
        let session = identity.daemon_session()?;
        Some((session, crate::app_identity::app_daemon_socket(&identity)?))
    });
    #[cfg(not(target_os = "macos"))]
    let app = None;
    local_sessions(&directories, app)
}

#[cfg(not(unix))]
fn session_sockets() -> Vec<(String, PathBuf)> {
    local_sessions(&[cmux_tui_core::platform::runtime_dir()], None)
}

/// Runs a list on every local session. A socket nobody listens on (a session
/// that exited) is skipped; any other failure is reported and makes the exit
/// code 1 after the joined list is printed.
pub(super) fn run_all_sessions(global: &GlobalArgs, plan: RequestPlan) -> i32 {
    let WireOperation::Typed(operation) = plan.operation else {
        eprintln!("cmux: --all-sessions applies only to list commands");
        return 2;
    };
    let mut results = Vec::new();
    let mut failed = false;
    for (session, socket) in session_sockets() {
        match list_on(&socket, &session, operation, &plan.params) {
            Ok(Some(result)) => results.push((session, result)),
            Ok(None) => {}
            Err(message) => {
                eprintln!("cmux: session {session}: {message}");
                failed = true;
            }
        }
    }
    let code = super::wire::print_local_success(&join(results), global.output);
    if failed && code == 0 { 1 } else { code }
}

/// `Ok(None)` when the session is not running.
fn list_on(
    socket: &Path,
    session: &str,
    operation: ResourceOperation,
    params: &Value,
) -> Result<Option<Value>, String> {
    let stream = match cmux_tui_core::server::connect_session_socket(socket, true) {
        Ok(stream) => stream,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
            ) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error.to_string()),
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut reader = BufReader::new(stream);
    let mut params: Map<String, Value> = params.as_object().cloned().unwrap_or_default();
    params.insert("session".into(), json!(session));
    match super::resolve::read(&mut reader, operation, params) {
        Ok(value) => Ok(Some(value)),
        Err(super::resolve::Failure::Resource(error)) => {
            Err(error.get("message").and_then(Value::as_str).unwrap_or("failed").to_owned())
        }
        Err(super::resolve::Failure::Transport(message)) => Err(message),
        Err(super::resolve::Failure::AppAction { .. }) => Err("unexpected app action".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn a_kind_or_the_name_escape_is_not_a_session() {
        assert_eq!(qualified("build-box:ws_1a2b"), Some(("build-box", "ws_1a2b")));
        assert_eq!(qualified("workspace:ws_1a2b"), None);
        assert_eq!(qualified("name:ws_1a2b"), None);
    }

    #[test]
    fn a_qualified_selector_routes_to_its_session_and_loses_the_qualifier() {
        let mut global = GlobalArgs::default();
        let mut command = args(&["workspace", "build-box:ws_1a2b", "update", "--title", "x:ws_9"]);
        apply_qualifiers(&mut global, &mut command).unwrap();
        assert_eq!(global.session.as_deref(), Some("build-box"));
        // The payload of --title is text, never a selector.
        assert_eq!(command, args(&["workspace", "ws_1a2b", "update", "--title", "x:ws_9"]));
    }

    #[test]
    fn id_options_and_lists_take_qualifiers_from_one_session_only() {
        let mut global = GlobalArgs::default();
        let mut command =
            args(&["tab", "group", "create", "--tabs", "box:tab_1,box:tab_2", "--pane=box:pane_3"]);
        apply_qualifiers(&mut global, &mut command).unwrap();
        assert_eq!(command[4], "tab_1,tab_2");
        assert_eq!(command[5], "--pane=pane_3");
        assert_eq!(global.session.as_deref(), Some("box"));

        let mut command = args(&["tab", "group", "create", "--tabs", "a:tab_1,b:tab_2"]);
        assert!(apply_qualifiers(&mut GlobalArgs::default(), &mut command).is_err());
        let mut named = GlobalArgs { session: Some("a".into()), ..GlobalArgs::default() };
        assert!(apply_qualifiers(&mut named, &mut args(&["workspace", "b:ws_1", "show"])).is_err());
        let mut socket =
            GlobalArgs { socket: Some(PathBuf::from("/tmp/s.sock")), ..GlobalArgs::default() };
        assert!(
            apply_qualifiers(&mut socket, &mut args(&["workspace", "b:ws_1", "show"])).is_err()
        );
    }

    #[test]
    fn unqualified_urls_and_words_after_the_separator_are_untouched() {
        let mut global = GlobalArgs::default();
        let mut command =
            args(&["tab", "create", "browser", "--url", "https:ws_1", "--", "box:ws_2"]);
        let before = command.clone();
        apply_qualifiers(&mut global, &mut command).unwrap();
        assert_eq!(command, before);
        assert_eq!(global.session, None);
        assert_eq!(qualified("box:ws_"), None);
        assert_eq!(qualified("box:room_1"), None);
        assert_eq!(qualified("a/b:ws_1"), None);
        assert_eq!(qualified("box:term_9f"), Some(("box", "term_9f")));
    }

    #[test]
    fn local_sessions_are_the_socket_files_by_name_plus_the_app_session() {
        let directory = tempfile::tempdir().unwrap();
        for name in ["main.sock", "build.sock", "notes.txt"] {
            std::fs::write(directory.path().join(name), b"").unwrap();
        }
        let app = ("cmux-app".to_owned(), PathBuf::from("/elsewhere/cmux-app.sock"));
        let sessions = local_sessions(
            &[directory.path().to_path_buf(), directory.path().join("missing")],
            Some(app.clone()),
        );
        let names: Vec<&str> = sessions.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, vec!["build", "cmux-app", "main"]);
        assert_eq!(sessions[1], app);
    }

    #[test]
    fn joined_lists_tag_every_record_with_its_session() {
        let joined = join(vec![
            ("main".into(), json!([{"id": "ws_1"}, {"id": "ws_2"}])),
            ("build".into(), json!([{"id": "ws_3"}])),
            ("odd".into(), json!({"count": 0})),
        ]);
        assert_eq!(
            joined,
            json!([
                {"id": "ws_1", "session": "main"},
                {"id": "ws_2", "session": "main"},
                {"id": "ws_3", "session": "build"},
                {"session": "odd", "result": {"count": 0}},
            ])
        );
    }
}
