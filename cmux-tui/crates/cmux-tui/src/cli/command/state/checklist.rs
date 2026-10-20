//! `workspace [<selector>] checklist …` (`workspace-checklist-v1`): the
//! workspace's checklist. Without a selector the target is the caller's
//! workspace inside a cmux terminal, else `current`, as for `status`.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::Value;

use super::super::{CommandPlan, Flags, Selectors, UsageError, insert_u32, usage, validate_one_of};
use super::{Params, caller_terminal, status_target, text_argument};

const ITEM_STATES: &[&str] = &["todo", "in_progress", "done"];
const ITEM_ORIGINS: &[&str] = &["user", "agent"];

fn optional_state(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(state) = flags.take("state") {
        validate_one_of("--state", &state, ITEM_STATES)?;
        params.insert("state", Value::String(state));
    }
    Ok(())
}

fn optional_index(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(index) = flags.take("index") {
        insert_u32(&mut params.fields, "index", "--index", index)?;
    }
    Ok(())
}

/// `--attachments-json '[{"path": "/abs.png", "name": "…", "id": "att_…"}]'`
/// replaces the item's attachments; `[]` clears them.
fn optional_attachments(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(json) = flags.take("attachments-json") {
        let value: Value = serde_json::from_str(&json)
            .map_err(|_| UsageError::new("--attachments-json must be a JSON array"))?;
        if !value.is_array() {
            return Err(UsageError::new("--attachments-json must be a JSON array"));
        }
        params.insert("attachments", value);
    }
    Ok(())
}

fn item(params: &mut Params, item: &str) -> Result<(), UsageError> {
    if item.is_empty() || item.len() > 64 {
        return Err(UsageError::new("a checklist item id has 1 to 64 bytes"));
    }
    params.insert("item", Value::String(item.into()));
    Ok(())
}

/// Parses `workspace [<selector>] checklist list|add|update|remove …`.
pub(in crate::cli::command) fn parse_workspace_checklist(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<&[String]>,
) -> Result<Option<CommandPlan>, UsageError> {
    let (target, rest) = match words {
        [selector, "checklist", rest @ ..] if !rest.is_empty() => (Some(*selector), rest),
        ["checklist", rest @ ..] => (None, rest),
        _ => return Ok(None),
    };
    let resolve = status_target(target, false, caller_terminal(), selectors)?;
    let mut params = Params::default();
    params.resolve.extend(resolve);
    let operation = match rest {
        ["list"] => Op::WorkspaceChecklistList,
        ["add", text @ ..] if text.len() <= 1 => {
            params.insert("text", Value::String(text_argument(text.first().copied(), argv)?));
            optional_state(&mut params, flags)?;
            if let Some(origin) = flags.take("origin") {
                validate_one_of("--origin", &origin, ITEM_ORIGINS)?;
                params.insert("origin", Value::String(origin));
            }
            optional_index(&mut params, flags)?;
            Op::WorkspaceChecklistAdd
        }
        ["update", id] => {
            item(&mut params, id)?;
            if let Some(text) = flags.take("text") {
                params.insert("text", Value::String(text));
            }
            optional_state(&mut params, flags)?;
            optional_index(&mut params, flags)?;
            optional_attachments(&mut params, flags)?;
            if params.fields.len() == 1 {
                return Err(UsageError::new(
                    "checklist update needs --text, --state, --index or --attachments-json",
                ));
            }
            Op::WorkspaceChecklistUpdate
        }
        ["remove", id] => {
            item(&mut params, id)?;
            Op::WorkspaceChecklistRemove
        }
        _ => return usage("workspace checklist action"),
    };
    if argv.is_some() && operation != Op::WorkspaceChecklistAdd {
        return Err(UsageError::new("workspace checklist takes -- arguments only for add"));
    }
    params.send(operation, selectors, flags).map(Some)
}
