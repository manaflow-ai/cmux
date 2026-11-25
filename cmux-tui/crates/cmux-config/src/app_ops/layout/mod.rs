//! Layout settings: workspace groups, pane chrome and the surface tab bar. Swift `WorkspaceGroupConfig`,
//! `PaneChromeConfigParser`, `SurfaceTabBarParser`, `ConfigActionParser`, `BuiltInButtonActions`.
//!
//! - `layout.workspace_groups` `{root}` answers `{config, diagnostics}`: `config` is
//!   `{newWorkspacePlacement, byCwd: {KEY: {color, icon, newWorkspacePlacement, contextMenu: [{action, title}]}}}`;
//!   a color is a palette token, `none` or `#RRGGBB`.
//! - `layout.workspace_group_entry` `{config, directory, home}` answers `{key, entry, configuredPlacement,
//!   placement}` (all absent when no key matches or `directory` is null, the placements still answer).
//! - `layout.workspace_group_key` `{directory, home}` answers `{key}`: the key a new entry takes.
//! - `layout.pane_chrome` `{root}` answers `{overrides, diagnostics}`; `overrides` holds the members set.
//! - `layout.surface_tab_bar` `{root, configDirectory, home}` answers `{tabBar, actions, diagnostics}`.
//!
//! A diagnostic is `{kind, path, message}`, kind `invalid_value`, `unknown_action` or `removed_setting`.

mod actions;
mod chrome;
mod groups;
#[cfg(test)]
mod tests;

use serde_json::{Value, json};

use super::OpError;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    match op {
        "layout.workspace_groups" => Some(groups::parse_op(request)),
        "layout.workspace_group_entry" => Some(groups::entry_op(request)),
        "layout.workspace_group_key" => Some(groups::key_op(request)),
        "layout.pane_chrome" => Some(chrome::parse_op(request)),
        "layout.surface_tab_bar" => Some(actions::surface_tab_bar_op(request)),
        _ => None,
    }
}

/// A problem found while reading the file.
pub(crate) struct Diag {
    kind: &'static str,
    path: String,
    message: String,
}

impl Diag {
    pub(crate) fn invalid(path: impl Into<String>, message: impl Into<String>) -> Diag {
        Diag { kind: "invalid_value", path: path.into(), message: message.into() }
    }

    pub(crate) fn unknown_action(path: impl Into<String>, message: impl Into<String>) -> Diag {
        Diag { kind: "unknown_action", path: path.into(), message: message.into() }
    }

    pub(crate) fn removed(path: impl Into<String>, message: impl Into<String>) -> Diag {
        Diag { kind: "removed_setting", path: path.into(), message: message.into() }
    }
}

pub(crate) fn diags_json(diags: &[Diag]) -> Value {
    Value::Array(
        diags
            .iter()
            .map(|d| json!({"kind": d.kind, "path": d.path, "message": d.message}))
            .collect(),
    )
}

pub(crate) fn root_of(request: &Value) -> Result<&Value, OpError> {
    request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".into()))
}

/// The optional string member `key`; absent or null is `None`.
pub(crate) fn opt_string<'a>(request: &'a Value, key: &str) -> Result<Option<&'a str>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(OpError::Invalid(format!("expected a string `{key}`"))),
    }
}

/// `value` at a key path of objects.
pub(crate) fn at<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(root, |value, key| value.as_object()?.get(*key))
}
