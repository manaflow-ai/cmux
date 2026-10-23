//! The `stash.*` operations of `cmux.protocol/2` (`stash-v1`, bead
//! cx-rws36); the behavior lives in [`super::stash`].

use std::sync::Arc;

use serde_json::{Map, Value};

use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, mutation_result, resource_operation_error};
use crate::state::stash::{ImportGroup, RestoreTarget, StashSource};
use crate::state::stash_store;
use crate::state::store::StateCommit;
use crate::{Mux, ResourceTarget};

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    use ResourceOperation as Op;
    matches!(
        operation,
        Op::StashCreate | Op::StashList | Op::StashRestore | Op::StashDelete | Op::StashImport
    )
}

/// `bad request: ...` failures are the caller's input (`validation.invalid`).
fn stash_error(error: anyhow::Error) -> ResourceError {
    if error.downcast_ref::<ResourceError>().is_none()
        && let Some(reason) = error.to_string().strip_prefix("bad request: ")
    {
        return ResourceError::validation_invalid(None, reason);
    }
    resource_operation_error(error)
}

fn string(fields: &Map<String, Value>, name: &str) -> Option<String> {
    fields.get(name).and_then(Value::as_str).map(str::to_string)
}

/// Member ids (`members`): strings, each a member id from `stash.list`.
fn member_ids(fields: &Map<String, Value>) -> Result<Option<Vec<String>>, ResourceError> {
    let Some(values) = fields.get("members") else { return Ok(None) };
    values
        .as_array()
        .and_then(|values| {
            values
                .iter()
                .map(|value| value.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()
        })
        .map(Some)
        .ok_or_else(|| {
            ResourceError::validation_invalid(Some("members"), "members must be member ids")
        })
}

/// A group's `created_ms`: decimal digits (more than fit is the far
/// future, which the import clamps to now); anything else is refused.
fn created_ms(group: &Value) -> Result<Option<u64>, ResourceError> {
    match group.get("created_ms") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text))
            if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) =>
        {
            Ok(Some(text.parse().unwrap_or(u64::MAX)))
        }
        Some(_) => Err(ResourceError::validation_invalid(
            Some("groups"),
            "created_ms must be a decimal number of milliseconds",
        )),
    }
}

fn import_groups(fields: &Map<String, Value>) -> Result<Vec<ImportGroup>, ResourceError> {
    fields
        .get("groups")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|group| {
            Ok(ImportGroup {
                name: group["name"].as_str().map(str::to_string),
                created_ms: created_ms(group)?,
                tabs: group["tabs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|tab| {
                        Some((
                            tab["url"].as_str()?.to_string(),
                            tab["title"].as_str().map(str::to_string),
                        ))
                    })
                    .collect(),
            })
        })
        .collect()
}

/// `stash.create {tabs}` or `{workspace}` (`stash-v1`).
fn create_source(fields: &Map<String, Value>) -> Result<StashSource, ResourceError> {
    let source = match string(fields, "workspace") {
        Some(workspace) if !fields.contains_key("tabs") => StashSource::Workspace(workspace),
        Some(_) => {
            return Err(ResourceError::validation_invalid(
                Some("workspace"),
                "name either tabs or a workspace",
            ));
        }
        None => {
            let tabs = fields
                .get("tabs")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|tab| tab.as_str().map(str::to_string))
                .collect::<Vec<_>>();
            if tabs.is_empty() {
                return Err(ResourceError::validation_invalid(
                    Some("tabs"),
                    "name the tabs or a workspace to stash",
                ));
            }
            StashSource::Tabs(tabs)
        }
    };
    Ok(source)
}

/// `stash.create {workspaces, name?}` (`stash-workspaces-v1`), or None
/// when the request names no `workspaces`. It names neither `tabs` nor
/// `workspace`, and at least one workspace.
fn create_workspaces(fields: &Map<String, Value>) -> Result<Option<StashSource>, ResourceError> {
    let Some(values) = fields.get("workspaces") else {
        if fields.contains_key("name") {
            return Err(ResourceError::validation_invalid(
                Some("name"),
                "name goes with workspaces",
            ));
        }
        return Ok(None);
    };
    if fields.contains_key("tabs") || fields.contains_key("workspace") {
        return Err(ResourceError::validation_invalid(
            Some("workspaces"),
            "name exactly one of tabs, workspace or workspaces",
        ));
    }
    let workspaces = values
        .as_array()
        .and_then(|values| {
            values
                .iter()
                .map(|value| value.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()
        })
        .filter(|workspaces| !workspaces.is_empty())
        .ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("workspaces"),
                "workspaces must be one or more workspace ids",
            )
        })?;
    let name = match fields.get("name") {
        None | Some(Value::Null) => None,
        Some(Value::String(name)) => {
            Some(crate::state::stash_workspaces::clean_name(name).map_err(|error| {
                let reason = error.to_string();
                ResourceError::validation_invalid(
                    Some("name"),
                    reason.strip_prefix("bad request: ").unwrap_or(&reason),
                )
            })?)
        }
        Some(_) => {
            return Err(ResourceError::validation_invalid(Some("name"), "name must be a string"));
        }
    };
    Ok(Some(StashSource::Workspaces { workspaces, name }))
}

fn result(mux: &Mux, commit: StateCommit) -> Result<Value, ResourceError> {
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    use ResourceOperation as Op;
    debug_assert!(handles(request.envelope.operation));
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let fields = &request.fields;
    if request.envelope.operation == Op::StashList {
        return mux.personal_state_read(stash_store::stash_list).map(Value::Array);
    }
    let mutation = request.mutation().map_err(resource_operation_error)?;
    let stash = string(fields, "stash").unwrap_or_default();
    let commit = match request.envelope.operation {
        Op::StashCreate => {
            let source = match create_workspaces(fields)? {
                Some(source) => source,
                None => create_source(fields)?,
            };
            mux.state_stash_create(&mutation, &source)
        }
        Op::StashRestore => mux.state_stash_restore(
            &mutation,
            &stash,
            member_ids(fields)?.as_deref(),
            RestoreTarget::parse(fields.get("target").and_then(Value::as_str)),
            fields.get("pane").and_then(Value::as_str),
        ),
        Op::StashDelete => {
            mux.state_stash_delete(&mutation, &stash, member_ids(fields)?.as_deref())
        }
        Op::StashImport => mux.state_stash_import(
            &mutation,
            &string(fields, "source").unwrap_or_default(),
            fields.get("engine").and_then(Value::as_str),
            &import_groups(fields)?,
        ),
        other => {
            return Err(ResourceError::validation_invalid(
                None,
                format!("{} is not a stash operation", other.wire_name()),
            ));
        }
    };
    result(mux, commit.map_err(stash_error)?)
}
