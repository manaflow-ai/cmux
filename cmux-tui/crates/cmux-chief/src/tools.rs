//! The Chief's tools come from the operation catalog, never from a list in
//! code (plans/cmux-next/chief-mac.md section 5). An operation is a Chief
//! tool when its descriptor has `"agents": {"chief": true}` and it is a read
//! or a mutation. `cmux mcp serve --profile chief` and the generated tool
//! section of the Chief's CLAUDE.md both read this selection.

use serde_json::Value;

/// The catalog field that puts an operation in an agent profile.
pub const PROFILE_FIELD: &str = "agents";
/// The Chief's profile name.
pub const CHIEF_PROFILE: &str = "chief";

/// One generated tool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileTool {
    /// MCP tool name: the operation with `_` for `.`.
    pub name: String,
    /// The catalog operation (`chief.agent.spawn`).
    pub operation: String,
    pub mutation: bool,
    /// The operation's group: its first segment (`chief`, `workspace`).
    pub group: String,
}

/// The tools of `profile`, in catalog order, from a catalog in the
/// `resource-operations-v2.json` shape (`operations` maps names to
/// descriptors).
pub fn profile_tools(catalog: &Value, profile: &str) -> Vec<ProfileTool> {
    let Some(operations) = catalog.get("operations").and_then(Value::as_object) else {
        return Vec::new();
    };
    operations
        .iter()
        .filter(|(_, descriptor)| {
            descriptor.get(PROFILE_FIELD).and_then(|agents| agents.get(profile))
                == Some(&Value::Bool(true))
        })
        .filter_map(|(operation, descriptor)| {
            let mutation = match descriptor.get("class").and_then(Value::as_str) {
                Some("read") => false,
                Some("mutation") => true,
                _ => return None,
            };
            Some(ProfileTool {
                name: operation.replace('.', "_"),
                operation: operation.clone(),
                mutation,
                group: operation.split('.').next().unwrap_or_default().to_owned(),
            })
        })
        .collect()
}

/// The tool section of the Chief's prompt: one line per group with its
/// tools, so the prompt and the served tools cannot disagree.
pub fn prompt_section(tools: &[ProfileTool]) -> String {
    let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
    for tool in tools {
        match groups.iter_mut().find(|(group, _)| *group == tool.group) {
            Some((_, names)) => names.push(&tool.name),
            None => groups.push((&tool.group, vec![&tool.name])),
        }
    }
    groups
        .iter()
        .map(|(group, names)| format!("- {group}: {}", names.join(", ")))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_profile_is_selected_by_the_catalog_field() {
        let catalog = json!({"operations": {
            "chief.agent.spawn": {"class": "mutation", "agents": {"chief": true}},
            "chief.memory.recall": {"class": "read", "agents": {"chief": true}},
            "workspace.list": {"class": "read", "agents": {"chief": true}},
            "workspace.close": {"class": "mutation"},
            "events.open": {"class": "stream_open", "agents": {"chief": true}},
            "other.read": {"class": "read", "agents": {"chief": false}}
        }});
        let tools = profile_tools(&catalog, CHIEF_PROFILE);
        let names: Vec<_> = tools.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["chief_agent_spawn", "chief_memory_recall", "workspace_list"]);
        assert!(tools[0].mutation && !tools[1].mutation);
        assert_eq!(
            prompt_section(&tools),
            "- chief: chief_agent_spawn, chief_memory_recall\n- workspace: workspace_list"
        );
    }
}
