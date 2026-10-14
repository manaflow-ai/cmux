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

fn indexes(fields: &Map<String, Value>, name: &str) -> Option<Vec<usize>> {
    fields.get(name).and_then(Value::as_array).map(|values| {
        values
            .iter()
            .filter_map(|value| value.as_u64().and_then(|v| usize::try_from(v).ok()))
            .collect()
    })
}

fn import_groups(fields: &Map<String, Value>) -> Vec<ImportGroup> {
    fields
        .get("groups")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|group| ImportGroup {
            name: group["name"].as_str().map(str::to_string),
            // A decimal string (catalog `decimal`).
            created_ms: group["created_ms"].as_str().and_then(|value| value.parse().ok()),
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
        .collect()
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
            let source = match string(fields, "workspace") {
                Some(workspace) if !fields.contains_key("tabs") => {
                    StashSource::Workspace(workspace)
                }
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
            mux.state_stash_create(&mutation, &source)
        }
        Op::StashRestore => mux.state_stash_restore(
            &mutation,
            &stash,
            indexes(fields, "members").as_deref(),
            RestoreTarget::parse(fields.get("target").and_then(Value::as_str)),
        ),
        Op::StashDelete => {
            mux.state_stash_delete(&mutation, &stash, indexes(fields, "members").as_deref())
        }
        Op::StashImport => mux.state_stash_import(
            &mutation,
            &string(fields, "source").unwrap_or_default(),
            fields.get("engine").and_then(Value::as_str),
            &import_groups(fields),
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
