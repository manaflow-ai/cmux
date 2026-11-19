//! The settings file a `cmux theme` or `cmux settings` write is for. With
//! no app socket named it is this process's (`cmux_config::config_path`).
//! `--app-socket` names another app, which may run on another file (a side
//! instance has its own `CMUX_NEXT_CONFIG_FILE`): the file is the one that
//! app says it reads and writes (its `settings.get` `file`), and an app that
//! does not say refuses the verb, never the home default. An explicit
//! `CMUX_NEXT_CONFIG_FILE` wins over both.
//!
//! A daemon write (`settings set|reset|unset|edit`) is pinned to that file:
//! it goes as `settings.edit` with `file`, which a daemon serving another
//! file refuses (`settings.file_mismatch`), so a write meant for the named
//! app never lands in the settings of the app this terminal belongs to.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::command::{RequestPlan, WireOperation};

/// The settings file for this run: `CMUX_NEXT_CONFIG_FILE`, else the file
/// the `--app-socket` app reports, else the default.
pub(super) fn path(global: &GlobalArgs) -> Result<PathBuf, Value> {
    path_with(global, |name| std::env::var_os(name).filter(|value| !value.is_empty()), ask_app)
}

/// [`path`] with an injected environment and app (tests).
pub(super) fn path_with(
    global: &GlobalArgs,
    env: impl Fn(&str) -> Option<OsString>,
    ask: impl FnOnce(&Path) -> Result<PathBuf, String>,
) -> Result<PathBuf, Value> {
    if env(cmux_config::CONFIG_OVERRIDE).is_some_and(|value| !value.is_empty()) {
        let file = cmux_config::location::config_path_from(&env);
        return Ok(std::path::absolute(&file).unwrap_or(file));
    }
    let Some(socket) = &global.app_socket else {
        return Ok(cmux_config::location::config_path_from(&env));
    };
    ask(socket).map_err(|why| {
        json!({
            "code": "settings.app_unanswered",
            "message": format!(
                "the app at --app-socket {} did not say which settings file it uses ({why}), so \
                 nothing was read or written; open that app, or name the file with \
                 CMUX_NEXT_CONFIG_FILE",
                socket.display()
            ),
            "details": { "socket": socket.display().to_string() },
            "retryable": true,
        })
    })
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

/// Whether `plan` is a daemon settings write that `--app-socket` pins.
pub(super) fn pins(global: &GlobalArgs, plan: &RequestPlan) -> bool {
    global.app_socket.is_some()
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
