//! The verb handlers' small rules (remote ports and Switch Host, Open as
//! Pane's folder, a workspace's PR links, Duplicate Tab's plan, a tab move
//! that becomes a split, a group's walk and edge), served to the app over
//! the app FFI's JSON channel (ops `handlers_verbs_*`). Pure: no I/O. The
//! app reads its models, asks here, and acts on the answer.

use crate::tabs::{self, Duplicate, DuplicateFacts};
use crate::targets::{self, TargetRef};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `--port N` for Forward Port… and Stop Forwarding Port…: an integer, or
/// a string holding one (spaces and tabs trimmed), 1 to 65535. None: the app
/// refuses with its "needs a port" text.
pub fn port_argument(value: &Value) -> Option<u16> {
    let port = match value {
        Value::Number(number) => number.as_i64()?,
        Value::String(text) => targets::trim_spaces(text).parse::<i64>().ok()?,
        _ => return None,
    };
    u16::try_from(port).ok().filter(|&port| port >= 1)
}

/// One forwarded port of an SSH machine's link (`LinkForward`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Forward {
    pub port: i64,
    pub url: String,
}

/// List Forwarded Ports' text: one `port → url` line per forward. None for
/// no forward (the app shows its own "no forwarded ports" text).
pub fn port_list_text(forwards: &[Forward]) -> Option<String> {
    (!forwards.is_empty()).then(|| {
        forwards
            .iter()
            .map(|forward| format!("{} → {}", forward.port, forward.url))
            .collect::<Vec<_>>()
            .join("\n")
    })
}

/// One row of the Hosts section (`MachineSectionRow`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HostRow {
    pub id: String,
    pub name: String,
}

/// What Switch Host… names: the invocation's target when it is a machine,
/// else the `machine` argument as a target, else as text.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SwitchHostFacts {
    pub target: Option<TargetRef>,
    pub machine_target: Option<String>,
    pub machine_text: Option<String>,
    pub rows: Vec<HostRow>,
}

/// Switch Host…'s pick: the host it names and its row (by id, else by name).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchHost {
    /// The host the run named; None: no host was chosen.
    pub wanted: Option<String>,
    /// The row of `wanted`; None: the host is unknown (or none was chosen).
    pub row: Option<usize>,
}

pub fn switch_host(facts: &SwitchHostFacts) -> SwitchHost {
    let wanted = facts
        .target
        .as_ref()
        .filter(|target| target.kind == "machine")
        .map(|target| target.id.clone())
        .or_else(|| facts.machine_target.clone())
        .or_else(|| facts.machine_text.clone());
    let row = wanted.as_ref().and_then(|wanted| {
        facts
            .rows
            .iter()
            .position(|row| &row.id == wanted)
            .or_else(|| facts.rows.iter().position(|row| &row.name == wanted))
    });
    SwitchHost { wanted, row }
}

/// The folder Open Files as Pane and Open Find as Pane open on.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PaneFolderFacts {
    /// The run's `path` argument.
    pub path: Option<String>,
    /// The folder of the named (or focused) pane's local terminal.
    pub pane_folder: Option<String>,
    /// The person's home folder.
    pub home: String,
}

/// The run's `path` wins (trimmed; `~` and `~/` expanded; a relative one
/// under the pane's folder, else home; `.` and `..` resolved); else the
/// pane's folder. None means home.
pub fn pane_folder(facts: &PaneFolderFacts) -> Option<String> {
    let path = facts.path.as_deref().map(str::trim).filter(|path| !path.is_empty());
    let Some(path) = path else { return facts.pane_folder.clone() };
    let expanded = if path == "~" {
        facts.home.clone()
    } else if let Some(rest) = path.strip_prefix("~/") {
        format!("{}/{rest}", facts.home.trim_end_matches('/'))
    } else {
        path.to_owned()
    };
    if expanded.starts_with('/') {
        return Some(standardized(&expanded));
    }
    let base = facts.pane_folder.as_deref().unwrap_or(&facts.home);
    Some(standardized(&format!("{}/{expanded}", base.trim_end_matches('/'))))
}

/// An absolute path with empty and `.` components dropped and each `..`
/// taking off the one before it (Foundation's `standardizedFileURL` path).
fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}

/// One status entry of a workspace and the links the app found in its text.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StatusLinks {
    pub key: String,
    pub links: Vec<String>,
}

/// Open All Workspace PR Links: the `pr_key` entry's links first, then the
/// other entries', in order, each link once; only http and https.
pub fn pr_links(entries: &[StatusLinks], pr_key: &str) -> Vec<String> {
    let ordered = entries
        .iter()
        .filter(|entry| entry.key == pr_key)
        .chain(entries.iter().filter(|entry| entry.key != pr_key));
    let mut links: Vec<String> = Vec::new();
    for link in ordered.flat_map(|entry| &entry.links) {
        let scheme = link.split_once(':').map(|(scheme, _)| scheme.to_ascii_lowercase());
        if matches!(scheme.as_deref(), Some("http" | "https")) && !links.contains(link) {
            links.push(link.clone());
        }
    }
    links
}

/// One tab Duplicate Tab acts on: its facts, and whether it is an agent
/// chat of another Mac.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DuplicateTab {
    #[serde(flatten)]
    pub facts: DuplicateFacts,
    pub other_host: bool,
}

/// What Duplicate Tab does with one tab, another Mac's chat included.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DuplicateAction {
    Browser,
    LocalBrowser,
    Agent,
    Skip,
    Terminal,
    /// Another Mac's chat stays there.
    Elsewhere,
}

/// Why Duplicate Tab has nothing to duplicate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DuplicateRefusal {
    /// Another Mac's chat (alone, or with only page tabs).
    AgentTabOtherHost,
    /// Only page tabs, or no tab.
    PageTabOpensOnce,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicatePlan {
    /// One action per tab, in order; empty with a refusal.
    pub actions: Vec<DuplicateAction>,
    pub refusal: Option<DuplicateRefusal>,
}

pub fn duplicate_plan(tabs_in: &[DuplicateTab]) -> DuplicatePlan {
    let facts: Vec<DuplicateFacts> = tabs_in.iter().map(|tab| tab.facts).collect();
    let actions: Vec<DuplicateAction> = tabs::duplicate(&facts)
        .unwrap_or_default()
        .into_iter()
        .zip(tabs_in)
        .map(|(action, tab)| match action {
            Duplicate::Agent if tab.other_host => DuplicateAction::Elsewhere,
            Duplicate::Agent => DuplicateAction::Agent,
            Duplicate::Browser => DuplicateAction::Browser,
            Duplicate::LocalBrowser => DuplicateAction::LocalBrowser,
            Duplicate::Skip => DuplicateAction::Skip,
            Duplicate::Terminal => DuplicateAction::Terminal,
        })
        .collect();
    if actions
        .iter()
        .any(|action| !matches!(action, DuplicateAction::Skip | DuplicateAction::Elsewhere))
    {
        return DuplicatePlan { actions, refusal: None };
    }
    let refusal = if actions.contains(&DuplicateAction::Elsewhere) {
        DuplicateRefusal::AgentTabOtherHost
    } else {
        DuplicateRefusal::PageTabOpensOnce
    };
    DuplicatePlan { actions: Vec::new(), refusal: Some(refusal) }
}

/// The split Move Tab to Pane Left/Right/Up/Down makes at the screen's
/// edge (Move Tab to New Split), for a tab that is not alone in its pane.
/// None: that move has no split (left/right within the strip, previous/next
/// pane), or the tab is alone.
pub fn move_split(action: &str, tabs_in_pane: usize) -> Option<&'static str> {
    let direction = match action {
        "moveSurfaceToPaneLeft" => "left",
        "moveSurfaceToPaneRight" => "right",
        "moveSurfaceToPaneUp" => "up",
        "moveSurfaceToPaneDown" => "down",
        _ => return None,
    };
    (tabs_in_pane > 1).then_some(direction)
}

/// The order Next/Previous Workspace Group tries the groups in: from the
/// active group (else from before the first, or after the last), each group
/// once, wrapping, the active one last.
pub fn group_walk(count: usize, active: Option<usize>, offset: i64) -> Vec<usize> {
    let Ok(signed) = i64::try_from(count) else { return Vec::new() };
    if signed == 0 {
        return Vec::new();
    }
    let start = active
        .filter(|&active| active < count)
        .and_then(|active| i64::try_from(active).ok())
        .unwrap_or(if offset > 0 { -1 } else { signed });
    (1..=signed)
        .filter_map(|step| {
            let index = start.checked_add(offset.checked_mul(step)?)?.rem_euclid(signed);
            usize::try_from(index).ok()
        })
        .collect()
}

/// Which end a group move that cannot go on stops at (its refusal).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupEdge {
    AlreadyAtTop,
    AlreadyAtBottom,
}

/// `top` and `up` stop at the top; `down` and `bottom` at the bottom.
pub fn group_edge(direction: &str) -> Option<GroupEdge> {
    match direction {
        "top" | "up" => Some(GroupEdge::AlreadyAtTop),
        "down" | "bottom" => Some(GroupEdge::AlreadyAtBottom),
        _ => None,
    }
}

/// Where Remove from Group puts a section's ungrouped workspaces: before
/// the first unpinned group (else at the end) when ungrouped rows lead the
/// section, else right after the group the first of them left.
pub fn ungroup_index(
    ungrouped_first: bool,
    first_unpinned_group: Option<usize>,
    node_count: usize,
    group_node: usize,
) -> usize {
    if ungrouped_first {
        first_unpinned_group.unwrap_or(node_count)
    } else {
        group_node.saturating_add(1)
    }
}
