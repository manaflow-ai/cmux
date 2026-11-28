//! `_meta.acpmux.disallowedTools` on a new chat.

use super::*;

/// `_meta.acpmux.disallowedTools`: Claude Code built-in tools the new chat
/// never gets (`acpmux new --worktree` sends `["AskUserQuestion"]`). Each is
/// a tool's name, letters, digits and `_`, so none is a permission rule
/// (`Bash(rm *)`) or a flag; it only takes tools away, from any origin.
pub(super) fn disallowed_tools(meta: Option<&Value>) -> Result<Vec<String>, RpcError> {
    let refused = || RpcError::invalid_params("disallowedTools must be a list of tool names");
    match meta.and_then(|m| m.get("disallowedTools")) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(names)) => names
            .iter()
            .map(|n| {
                n.as_str()
                    .filter(|n| {
                        !n.is_empty() && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                    })
                    .map(str::to_owned)
                    .ok_or_else(refused)
            })
            .collect(),
        Some(_) => Err(refused()),
    }
}
