//! The settings file a `cmux theme`, `cmux settings` or `cmux customize`
//! write is for. With no app socket named it is this process's
//! (`CMUX_NEXT_CONFIG_FILE`, else the home default). `--app-socket` names
//! another app, which may run on another file (a side instance has its own
//! `CMUX_NEXT_CONFIG_FILE`): the file is the one that app says it reads and
//! writes (its `settings.get` `file`). An app that does not answer refuses
//! the verb, never the home default, and so does an app whose file is not
//! the one `CMUX_NEXT_CONFIG_FILE` names: the two must agree.
//!
//! A daemon write (`settings set|reset|unset|edit`) for a named file (either
//! way) is pinned to it: it goes as `settings.edit` with `file`, which a
//! daemon serving another file refuses (`settings.file_mismatch`), so a write
//! meant for another app never lands in the settings of the app this
//! terminal belongs to. On 2026-11-19 a write with both set went to Leo's
//! own NIGHTLY settings, because neither was carried to the daemon.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::command::{RequestPlan, WireOperation};

fn process_env(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|value| !value.is_empty())
}

/// The settings file for this run: the file the `--app-socket` app
/// reports (which must be `CMUX_NEXT_CONFIG_FILE` when that is set), else
/// `CMUX_NEXT_CONFIG_FILE`, else the default.
pub(super) fn path(global: &GlobalArgs) -> Result<PathBuf, Value> {
    path_with(global, process_env, ask_app)
}

/// `CMUX_NEXT_CONFIG_FILE` as an absolute path, when set.
fn named(env: &impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    env(cmux_config::CONFIG_OVERRIDE).filter(|value| !value.is_empty())?;
    let file = cmux_config::location::config_path_from(env);
    Some(std::path::absolute(&file).unwrap_or(file))
}

/// [`path`] with an injected environment and app (tests).
pub(super) fn path_with(
    global: &GlobalArgs,
    env: impl Fn(&str) -> Option<OsString>,
    ask: impl FnOnce(&Path) -> Result<PathBuf, String>,
) -> Result<PathBuf, Value> {
    let named = named(&env);
    let Some(socket) = &global.app_socket else {
        return Ok(named.unwrap_or_else(|| cmux_config::location::config_path_from(&env)));
    };
    // The named app is asked even when the variable names a file: a socket
    // that answers nothing refuses, so a typo never writes anywhere.
    let reported = ask(socket).map_err(|why| {
        json!({
            "code": "settings.app_unanswered",
            "message": format!(
                "the app at --app-socket {} did not say which settings file it uses ({why}), so \
                 nothing was read or written; open that app, or leave out --app-socket",
                socket.display()
            ),
            "details": { "socket": socket.display().to_string() },
            "retryable": true,
        })
    })?;
    match named {
        Some(named) if named != reported => Err(json!({
            "code": "settings.file_conflict",
            "message": format!(
                "CMUX_NEXT_CONFIG_FILE is {} but the app at --app-socket {} reads and writes {}, \
                 so nothing was read or written; drop one, or make them the same file",
                named.display(),
                socket.display(),
                reported.display()
            ),
            "details": {
                "socket": socket.display().to_string(),
                "named": named.display().to_string(),
                "reported": reported.display().to_string(),
            },
            "retryable": false,
        })),
        _ => Ok(reported),
    }
}

/// The app's settings file: the `file` of its `settings.get` answer.
fn ask_app(socket: &Path) -> Result<PathBuf, String> {
    let mut stream = super::app::connect(socket)?;
    let params = json!({ "path": cmux_config::theme_file::SETTING_KEY });
    let answer =
        super::app::request(&mut stream, "settings.get", params, super::app::READ_TIMEOUT)?
            .map_err(|refusal| {
                refusal.get("message").and_then(Value::as_str).unwrap_or("refused").to_owned()
            })?;
    reported_file(&answer)
}

/// The absolute `file` an app's `settings.get` answer names.
fn reported_file(answer: &Value) -> Result<PathBuf, String> {
    answer
        .get("file")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .filter(|file| file.is_absolute())
        .ok_or_else(|| "its settings.get answer names no settings file".to_owned())
}

/// Whether `plan` is a daemon settings write for a named file
/// (`--app-socket` or `CMUX_NEXT_CONFIG_FILE`), which is pinned to it.
pub(super) fn pins(global: &GlobalArgs, plan: &RequestPlan) -> bool {
    pins_with(global, plan, process_env)
}

/// [`pins`] with an injected environment (tests).
pub(super) fn pins_with(
    global: &GlobalArgs,
    plan: &RequestPlan,
    env: impl Fn(&str) -> Option<OsString>,
) -> bool {
    (global.app_socket.is_some() || named(&env).is_some())
        && matches!(
            plan.operation,
            WireOperation::Typed(
                ResourceOperation::SettingsSet
                    | ResourceOperation::SettingsReset
                    | ResourceOperation::SettingsEdit
            )
        )
}

/// Makes the settings write `plan` a `settings.edit` for `file` only: a set
/// or reset is its one edit, and the other params (the route) are kept.
pub(super) fn pin(plan: &mut RequestPlan, file: &Path) {
    let mut params: Map<String, Value> = plan.params.as_object().cloned().unwrap_or_default();
    let edit = |op: &str, params: &mut Map<String, Value>| {
        let mut edit = Map::from_iter([("op".to_owned(), Value::String(op.to_owned()))]);
        for name in ["key", "value"] {
            if let Some(value) = params.remove(name) {
                edit.insert(name.to_owned(), value);
            }
        }
        params.insert("edits".to_owned(), json!([edit]));
    };
    match plan.operation {
        WireOperation::Typed(ResourceOperation::SettingsSet) => edit("set", &mut params),
        WireOperation::Typed(ResourceOperation::SettingsReset) => edit("reset", &mut params),
        _ => {}
    }
    params.insert("file".to_owned(), Value::String(file.to_string_lossy().into_owned()));
    plan.operation = WireOperation::Typed(ResourceOperation::SettingsEdit);
    plan.params = Value::Object(params);
}

#[cfg(test)]
mod tests;
