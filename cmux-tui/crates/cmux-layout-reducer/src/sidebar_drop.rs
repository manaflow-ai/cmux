//! Pure sidebar hit testing and drop-target resolution.
//!
//! The macOS sidebar sends a flattened layout plus the section tree over the
//! small C ABI in `cmux-layout-reducer-ffi`.  Keeping the input and output
//! types here makes the same rules available to the TUI and iOS without
//! teaching either caller about the other's view models.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const GROUP_EDGE_FRACTION: f64 = 0.25;
const GROUP_EXIT_FRACTION: f64 = 0.25;
const SECTION_TOP_FRACTION: f64 = 0.35;
const TAB_INTO_START: f64 = 0.25;
const TAB_INTO_END: f64 = 0.75;

fn default_group_edge_fraction() -> f64 {
    GROUP_EDGE_FRACTION
}
fn default_group_exit_fraction() -> f64 {
    GROUP_EXIT_FRACTION
}
fn default_section_top_fraction() -> f64 {
    SECTION_TOP_FRACTION
}
fn default_tab_into_start() -> f64 {
    TAB_INTO_START
}
fn default_tab_into_end() -> f64 {
    TAB_INTO_END
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SectionId {
    Pinned,
    Machine { id: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RowKey {
    Section { id: SectionId },
    Group { id: String },
    Workspace { id: String },
    Tab { workspace: String, id: String },
    EmptySection { id: SectionId },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub key: RowKey,
    pub y: f64,
    pub height: f64,
    pub section: SectionId,
    pub group: Option<String>,
    pub workspace: Option<String>,
    pub sibling_index: i32,
    pub parent_index: Option<i32>,
    pub is_last_in_group: bool,
    pub is_collapsed: bool,
    pub child_count: i32,
}

impl Row {
    fn max_y(&self) -> f64 {
        self.y + self.height
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: String,
    pub machine: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Node {
    Workspace { workspace: Workspace },
    Group { id: String, machine: Option<String>, workspaces: Vec<Workspace> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub id: SectionId,
    pub machine: Option<String>,
    pub nodes: Vec<Node>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Payload {
    Workspaces { ids: Vec<String> },
    Group { id: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub y: f64,
    pub payload: Payload,
    pub rows: Vec<Row>,
    pub sections: Vec<Section>,
    #[serde(default)]
    pub ungrouped_first: bool,
    #[serde(default = "default_group_edge_fraction")]
    pub group_edge_fraction: f64,
    #[serde(default = "default_group_exit_fraction")]
    pub group_exit_fraction: f64,
    #[serde(default = "default_section_top_fraction")]
    pub section_top_fraction: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Target {
    Position { section: SectionId, group: Option<String>, index: i32 },
    IntoGroup { group: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TabDrop {
    IntoWorkspace { workspace: String },
    NewWorkspace { section: SectionId, group: Option<String>, index: i32 },
    IntoGroup { group: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Refusal {
    OtherMachine,
    PinnedArea,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabRequest {
    pub y: f64,
    pub rows: Vec<Row>,
    pub sections: Vec<Section>,
    pub source_machine: Option<String>,
    #[serde(default = "default_group_edge_fraction")]
    pub group_edge_fraction: f64,
    #[serde(default = "default_group_exit_fraction")]
    pub group_exit_fraction: f64,
    #[serde(default = "default_section_top_fraction")]
    pub section_top_fraction: f64,
    #[serde(default = "default_tab_into_start")]
    pub tab_into_start: f64,
    #[serde(default = "default_tab_into_end")]
    pub tab_into_end: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabRefusal {
    pub row: RowKey,
    pub reason: Refusal,
}

fn section_eq(a: &SectionId, b: &SectionId) -> bool {
    a == b
}

fn locate_group<'a>(id: &str, sections: &'a [Section]) -> Option<(usize, &'a Node)> {
    sections.iter().enumerate().find_map(|(index, section)| {
        section.nodes.iter().find_map(|node| match node {
            Node::Group { id: group_id, .. } if group_id == id => Some((index, node)),
            _ => None,
        })
    })
}

fn workspace<'a>(id: &str, sections: &'a [Section]) -> Option<&'a Workspace> {
    sections.iter().flat_map(|section| section.nodes.iter()).find_map(|node| match node {
        Node::Workspace { workspace } if workspace.id == id => Some(workspace),
        Node::Group { workspaces, .. } => workspaces.iter().find(|workspace| workspace.id == id),
        _ => None,
    })
}

fn hit(y: f64, rows: &[Row]) -> Option<(&Row, f64)> {
    let row = rows.iter().rev().find(|row| row.y <= y).or_else(|| rows.first())?;
    let fraction = if row.height > 0.0 { ((y - row.y) / row.height).clamp(0.0, 1.0) } else { 0.0 };
    Some((row, fraction))
}

fn previous_expanded_section<'a>(row: &Row, rows: &'a [Row]) -> Option<&'a Row> {
    let index = rows.iter().position(|candidate| candidate == row)?;
    rows[..index].iter().rev().find(|candidate| {
        matches!(candidate.key, RowKey::Section { .. }) && !candidate.is_collapsed
    })
}

fn workspace_target(
    row: &Row,
    fraction: f64,
    rows: &[Row],
    _sections: &[Section],
    group_edge_fraction: f64,
    group_exit_fraction: f64,
    section_top_fraction: f64,
) -> Option<Target> {
    match &row.key {
        RowKey::Workspace { .. } => {
            if let Some(group) = row.group.as_ref() {
                if row.is_last_in_group && fraction > 1.0 - group_exit_fraction {
                    return Some(Target::Position {
                        section: row.section.clone(),
                        group: None,
                        index: row.parent_index? + 1,
                    });
                }
                Some(Target::Position {
                    section: row.section.clone(),
                    group: Some(group.clone()),
                    index: row.sibling_index + i32::from(fraction >= 0.5),
                })
            } else {
                Some(Target::Position {
                    section: row.section.clone(),
                    group: None,
                    index: row.sibling_index + i32::from(fraction >= 0.5),
                })
            }
        }
        RowKey::Tab { workspace, .. } => {
            let parent = rows.iter().find(
                |candidate| matches!(&candidate.key, RowKey::Workspace { id } if id == workspace),
            )?;
            Some(Target::Position {
                section: parent.section.clone(),
                group: parent.group.clone(),
                index: parent.sibling_index + 1,
            })
        }
        RowKey::Group { id } => {
            if row.is_collapsed {
                if fraction < group_edge_fraction {
                    Some(Target::Position {
                        section: row.section.clone(),
                        group: None,
                        index: row.sibling_index,
                    })
                } else if fraction > 1.0 - group_edge_fraction {
                    Some(Target::Position {
                        section: row.section.clone(),
                        group: None,
                        index: row.sibling_index + 1,
                    })
                } else {
                    Some(Target::IntoGroup { group: id.clone() })
                }
            } else if fraction < 0.4 {
                Some(Target::Position {
                    section: row.section.clone(),
                    group: None,
                    index: row.sibling_index,
                })
            } else {
                Some(Target::Position {
                    section: row.section.clone(),
                    group: Some(id.clone()),
                    index: 0,
                })
            }
        }
        RowKey::Section { .. } => {
            if fraction < section_top_fraction {
                if let Some(previous) = previous_expanded_section(row, rows) {
                    return Some(Target::Position {
                        section: previous.section.clone(),
                        group: None,
                        index: previous.child_count,
                    });
                }
            }
            Some(Target::Position {
                section: row.section.clone(),
                group: None,
                index: if row.is_collapsed { row.child_count } else { 0 },
            })
        }
        RowKey::EmptySection { .. } => {
            Some(Target::Position { section: row.section.clone(), group: None, index: 0 })
        }
    }
}

fn group_target(
    group: &str,
    row: &Row,
    fraction: f64,
    y: f64,
    rows: &[Row],
    sections: &[Section],
    section_top_fraction: f64,
) -> Option<Target> {
    let (section_index, _) = locate_group(group, sections)?;
    let home = sections[section_index].id.clone();
    let index = match &row.key {
        RowKey::Workspace { .. } if row.group.is_some() => {
            let block_group = row.group.as_ref()?;
            if row.section != home {
                return None;
            }
            let block_rows: Vec<&Row> = rows
                .iter()
                .filter(|candidate| candidate.group.as_deref() == Some(block_group))
                .collect();
            let top =
                block_rows.iter().map(|candidate| candidate.y).reduce(f64::min).unwrap_or(row.y);
            let bottom = block_rows
                .iter()
                .map(|candidate| candidate.max_y())
                .reduce(f64::max)
                .unwrap_or(row.max_y());
            let group_index = row.parent_index.unwrap_or(row.sibling_index);
            if y < (top + bottom) / 2.0 { group_index } else { group_index + 1 }
        }
        RowKey::Group { .. } => {
            if row.section != home {
                return None;
            }
            let block_group = row.group.as_ref()?;
            let block_rows: Vec<&Row> = rows
                .iter()
                .filter(|candidate| candidate.group.as_deref() == Some(block_group))
                .collect();
            let top =
                block_rows.iter().map(|candidate| candidate.y).reduce(f64::min).unwrap_or(row.y);
            let bottom = block_rows
                .iter()
                .map(|candidate| candidate.max_y())
                .reduce(f64::max)
                .unwrap_or(row.max_y());
            let group_index = row.parent_index.unwrap_or(row.sibling_index);
            if y < (top + bottom) / 2.0 { group_index } else { group_index + 1 }
        }
        RowKey::Workspace { .. } => {
            if row.section != home {
                return None;
            }
            row.sibling_index + i32::from(fraction >= 0.5)
        }
        RowKey::Tab { .. } => {
            if row.section != home {
                return None;
            }
            let parent = row.workspace.as_ref().and_then(|id| rows.iter().find(|candidate| matches!(&candidate.key, RowKey::Workspace { id: candidate_id } if candidate_id == id)))?;
            parent.sibling_index + 1
        }
        RowKey::Section { .. } => {
            if row.section == home {
                if row.is_collapsed { row.child_count } else { 0 }
            } else if fraction < section_top_fraction {
                let previous = previous_expanded_section(row, rows)?;
                if previous.section == home {
                    previous.child_count
                } else {
                    return None;
                }
            } else {
                return None;
            }
        }
        RowKey::EmptySection { .. } => {
            if row.section != home {
                return None;
            }
            0
        }
    };
    Some(Target::Position { section: home, group: None, index })
}

fn leading_ungrouped(target: Target, moving: &[String], sections: &[Section]) -> Target {
    let Target::Position { section, group: None, index } = &target else { return target };
    let Some(section_data) = sections.iter().find(|candidate| section_eq(&candidate.id, section))
    else {
        return target;
    };
    if section_data.machine.is_none() {
        return target;
    }
    let moving: HashSet<&str> = moving.iter().map(String::as_str).collect();
    let nodes: Vec<&Node> = section_data
        .nodes
        .iter()
        .filter(|node| match node {
            Node::Workspace { workspace } => !moving.contains(workspace.id.as_str()),
            Node::Group { .. } => true,
        })
        .collect();
    let Some(first_group) = nodes.iter().position(|node| matches!(node, Node::Group { .. })) else {
        return target;
    };
    if *index > first_group as i32 {
        Target::Position { section: section.clone(), group: None, index: first_group as i32 }
    } else {
        target
    }
}

fn is_valid(target: &Target, ids: &[String], sections: &[Section]) -> bool {
    let section = match target {
        Target::Position { section, group, .. } => {
            let Some(section) =
                sections.iter().find(|candidate| section_eq(&candidate.id, section))
            else {
                return false;
            };
            if group.is_some() && section.machine.is_none() {
                return false;
            }
            section
        }
        Target::IntoGroup { group } => {
            let Some((section_index, _)) = locate_group(group, sections) else { return false };
            &sections[section_index]
        }
    };
    ids.iter().all(|id| {
        workspace(id, sections).is_some_and(|workspace| {
            section.machine.as_deref().is_none_or(|machine| machine == workspace.machine)
        })
    })
}

/// Converts a displayed coordinate to base-layout coordinates.
pub fn base_y(display_y: f64, gap_y: Option<f64>, gap_height: f64) -> Option<f64> {
    let Some(gap_y) = gap_y else { return Some(display_y) };
    if display_y < gap_y {
        Some(display_y)
    } else if display_y >= gap_y + gap_height {
        Some(display_y - gap_height)
    } else {
        None
    }
}

/// Resolves a workspace or group drag.
pub fn resolve(request: &Request) -> Option<Target> {
    let (row, fraction) = hit(request.y, &request.rows)?;
    let target = match &request.payload {
        Payload::Workspaces { ids } => {
            let target = workspace_target(
                row,
                fraction,
                &request.rows,
                &request.sections,
                request.group_edge_fraction,
                request.group_exit_fraction,
                request.section_top_fraction,
            )?;
            let target = if request.ungrouped_first {
                leading_ungrouped(target, ids, &request.sections)
            } else {
                target
            };
            return is_valid(&target, ids, &request.sections).then_some(target);
        }
        Payload::Group { id } => group_target(
            id,
            row,
            fraction,
            request.y,
            &request.rows,
            &request.sections,
            request.section_top_fraction,
        ),
    }?;
    Some(target)
}

/// Resolves a tab dragged in from a pane.
pub fn resolve_tab_drop(request: &TabRequest) -> Option<TabDrop> {
    let (row, fraction) = hit(request.y, &request.rows)?;
    let machine_ok = |machine: Option<&str>| match request.source_machine.as_deref() {
        Some(source) => machine == Some(source),
        None => machine.is_some(),
    };
    let target_workspace = match &row.key {
        RowKey::Workspace { id } => Some(id.as_str()),
        RowKey::Tab { workspace, .. } => Some(workspace.as_str()),
        _ => None,
    };
    if let Some(id) = target_workspace
        .filter(|_| (request.tab_into_start..=request.tab_into_end).contains(&fraction))
    {
        let ws = workspace(id, &request.sections)?;
        if machine_ok(Some(ws.machine.as_str())) {
            return Some(TabDrop::IntoWorkspace { workspace: id.to_string() });
        }
        return None;
    }
    let target = workspace_target(
        row,
        fraction,
        &request.rows,
        &request.sections,
        request.group_edge_fraction,
        request.group_exit_fraction,
        request.section_top_fraction,
    )?;
    match target {
        Target::Position { section: SectionId::Machine { id: machine }, group, index }
            if machine_ok(Some(machine.as_str())) =>
        {
            Some(TabDrop::NewWorkspace {
                section: SectionId::Machine { id: machine },
                group,
                index,
            })
        }
        Target::IntoGroup { group } => {
            let (section_index, _) = locate_group(&group, &request.sections)?;
            let machine = request.sections[section_index].machine.as_deref();
            machine_ok(machine).then_some(TabDrop::IntoGroup { group })
        }
        _ => None,
    }
}

/// Explains why a tab drop is refused at a given row.
pub fn tab_drop_refusal(request: &TabRequest) -> Option<TabRefusal> {
    if request.rows.is_empty() || resolve_tab_drop(request).is_some() {
        return None;
    }
    let (row, _) = hit(request.y, &request.rows)?;
    let workspace_id = match &row.key {
        RowKey::Workspace { id } => Some(id.as_str()),
        RowKey::Tab { workspace, .. } => Some(workspace.as_str()),
        _ => None,
    };
    let workspace_machine = workspace_id
        .and_then(|id| workspace(id, &request.sections))
        .map(|workspace| workspace.machine.as_str());
    let section_machine = match &row.section {
        SectionId::Machine { id } => Some(id.as_str()),
        SectionId::Pinned => None,
    };
    let reason = if let (Some(source), Some(machine)) =
        (request.source_machine.as_deref(), workspace_machine.or(section_machine))
    {
        if source != machine {
            Refusal::OtherMachine
        } else if matches!(row.section, SectionId::Pinned) {
            Refusal::PinnedArea
        } else {
            Refusal::OtherMachine
        }
    } else if matches!(row.section, SectionId::Pinned) {
        Refusal::PinnedArea
    } else {
        Refusal::OtherMachine
    };
    Some(TabRefusal { row: row.key.clone(), reason })
}

#[cfg(test)]
#[path = "sidebar_drop_tests.rs"]
mod tests;
