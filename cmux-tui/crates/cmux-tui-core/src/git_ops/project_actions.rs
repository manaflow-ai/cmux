//! `project.actions.list`: the actions of the project a path or a terminal's
//! working directory is in (`<project>/.cmux/actions.json`), merged with the
//! global `actions` of `cmux-next.json` (`cmux_config::project_actions`).
//! It reads files only, on the git lane like the other folder reads; it never
//! runs an action (the app runs one when the user picks it).

use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "project.actions.list";

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let directory = super::target::directory(mux, request, OPERATION)?;
    let include_global =
        request.fields.get("include_global").and_then(Value::as_bool).unwrap_or(true);
    let global = include_global.then(|| mux.with_settings(|state| state.file_root().clone()));
    let home = crate::platform::home_dir();
    let resolved =
        cmux_config::project_actions::resolve(&directory, home.as_deref(), global.as_ref());
    serde_json::to_value(resolved)
        .map_err(|error| ResourceError::operation_failed(OPERATION, error.to_string(), json!({})))
}
