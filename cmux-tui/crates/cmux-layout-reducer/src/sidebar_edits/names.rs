//! The sidebar group `agent.openSessionWorkspace` (`acpmux new --group`,
//! `cmux agent open --group`) names by its label: which group a workspace
//! joins and which row a re-homed lane reuses.

use serde::{Deserialize, Serialize};

use super::{Node, Section, Workspace, can_move, can_place, workspace};

/// The machine id of this Mac.
const LOCAL_MACHINE: &str = "local";

/// Whether `name` may name a sidebar group. Group arguments are labels:
/// object ids (and UUIDs) are refused so an automation retry cannot turn an
/// id into a persistent visible title.
pub fn valid_group_name(name: &str) -> bool {
    let label = name.trim();
    if label.is_empty() {
        return false;
    }
    let lower = label.to_lowercase();
    if ["grp_", "ws_", "tab_", "pane_", "win_", "workspace_group:"]
        .iter()
        .any(|prefix| lower.starts_with(prefix))
    {
        return false;
    }
    !is_uuid(label)
}

/// Foundation's `UUID(uuidString:)`: 8-4-4-4-12 hex digits, either case.
fn is_uuid(text: &str) -> bool {
    let parts: Vec<&str> = text.split('-').collect();
    parts.len() == 5
        && parts.iter().zip([8, 4, 4, 4, 12]).all(|(part, len)| {
            part.len() == len && part.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
}

/// Whether two group names are one label: equal once outer whitespace is
/// trimmed, ignoring case.
pub fn same_group_name(listed: &str, asked: &str) -> bool {
    let (listed, asked) = (listed.trim(), asked.trim());
    listed == asked || listed.to_lowercase() == asked.to_lowercase()
}

/// The first listed group named `name` that may hold workspace `id` (the
/// drag's rule, `can_move`), in any section; None when none may. A group of
/// exactly that name wins; only when none is listed, one whose name is the
/// same label (`same_group_name`). `machine`: the workspace's machine, for
/// a workspace `sections` leaves out (a new one held until it lists in its
/// group): a group whose section may hold that machine's workspaces takes it.
pub fn group_named(
    name: &str,
    id: &str,
    sections: &[Section],
    machine: Option<&str>,
) -> Option<String> {
    let unlisted = machine.filter(|_| workspace(id, sections).is_none()).map(|machine| Workspace {
        id: id.to_owned(),
        machine: machine.to_owned(),
        ..Workspace::default()
    });
    let ids = [id.to_owned()];
    let find = |exact: bool| {
        sections.iter().find_map(|section| {
            section.nodes.iter().find_map(|node| match node {
                Node::Group { group }
                    if (if exact {
                        group.name == name
                    } else {
                        same_group_name(&group.name, name)
                    }) =>
                {
                    let accepts = match &unlisted {
                        Some(ws) => can_place(ws, section),
                        None => can_move(&ids, &group.id, sections),
                    };
                    accepts.then(|| group.id.clone())
                }
                _ => None,
            })
        })
    };
    // A listed exact group that cannot hold the workspace still gets a new group of that name.
    if let Some(exact) = find(true) {
        return Some(exact);
    }
    let listed = sections.iter().flat_map(|section| &section.nodes).any(|node| match node {
        Node::Group { group } => group.name == name,
        Node::Workspace { .. } | Node::Item { .. } => false,
    });
    if listed { None } else { find(false) }
}

/// A group as the lane launcher reads it: its name and its workspace rows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NamedGroup {
    pub name: String,
    pub rows: Vec<NamedRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NamedRow {
    pub id: String,
    pub title: String,
    pub machine: String,
}

/// The row of this Mac titled `name` in a group named `group`, across
/// several sidebars (each window lists only its own workspaces): the
/// workspace a lane of that name already has there. A group of exactly that
/// name in any sidebar wins over the same label typed another way.
pub fn predecessor(name: &str, group: &str, sidebars: &[Vec<NamedGroup>]) -> Option<String> {
    let rows = |exact: bool| {
        sidebars.iter().flatten().find_map(|listed| {
            let matches =
                if exact { listed.name == group } else { same_group_name(&listed.name, group) };
            if !matches {
                return None;
            }
            listed
                .rows
                .iter()
                .find(|row| row.title == name && row.machine == LOCAL_MACHINE)
                .map(|row| row.id.clone())
        })
    };
    if let Some(exact) = rows(true) {
        return Some(exact);
    }
    // A listed group of exactly that name without the row gets a new row in it.
    let listed = sidebars.iter().flatten().any(|listed| listed.name == group);
    if listed { None } else { rows(false) }
}
