//! The creator tree as rows (`sidebar_edits` op `tree`): each workspace
//! row's depth under its creator, its indent, its guide lines and its
//! collapsed count. Depth counts within the row's container (a section's
//! top level or a group's members): a child draws under its creator only
//! while it lists inside the creator's subtree there. Rows past
//! [`MAX_DEPTH`] draw at it; the stored links never change for the cap.

use super::creator::{Link, Nesting, nesting, parents};
use super::{Member, Node, Section, SectionId};
use serde::{Deserialize, Serialize};

/// The deepest a row draws; deeper rows flatten to it.
pub const MAX_DEPTH: usize = 3;

/// The indent step in points when the request names none.
pub(super) fn default_indent() -> u32 {
    12
}

/// One column of a row's guide lines, outermost first: the column of its
/// ancestor at that depth, and the last one its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Guide {
    /// An ancestor column whose ancestor has no later sibling: blank.
    None,
    /// An ancestor column whose ancestor has a later sibling: a vertical line.
    Line,
    /// The row's own column when a sibling follows it: a tee.
    Branch,
    /// The row's own column when it is the last child: a corner.
    End,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TreeRow {
    pub id: String,
    pub section: SectionId,
    pub group: Option<String>,
    /// 0 for a root, at most [`MAX_DEPTH`].
    pub depth: u8,
    /// `depth` times the request's indent step, in points.
    pub indent: u32,
    /// One entry per depth level (empty for a root).
    pub guides: Vec<Guide>,
    /// Rows list under it.
    pub has_children: bool,
    /// The rows its collapse hides (0 when it shows them).
    pub collapsed_count: usize,
    /// Under a collapsed creator.
    pub hidden: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TreeReply {
    pub rows: Vec<TreeRow>,
}

/// Every workspace row in drawn order (a group's members after it).
pub fn rows(sections: &[Section], indent: u32) -> Vec<TreeRow> {
    let mut out = Vec::new();
    for section in sections {
        let nodes: Vec<Link<'_>> = section.nodes.iter().map(workspace_of).collect();
        let top = container(&nodes, &section.id, None, indent);
        for (node, row) in section.nodes.iter().zip(top) {
            if let Some(row) = row {
                out.push(row);
            }
            if let Node::Group { group } = node {
                let members: Vec<Link<'_>> = group
                    .members
                    .iter()
                    .map(|member| match member {
                        Member::Workspace { workspace } => Some(workspace),
                        Member::Item { .. } => None,
                    })
                    .collect();
                out.extend(
                    container(&members, &section.id, Some(&group.id), indent).into_iter().flatten(),
                );
            }
        }
    }
    out
}

fn workspace_of(node: &Node) -> Link<'_> {
    match node {
        Node::Workspace { workspace } => Some(workspace),
        Node::Group { .. } | Node::Item { .. } => None,
    }
}

/// One container's rows: None for a group or an item.
fn container(
    links: &[Link<'_>],
    section: &SectionId,
    group: Option<&String>,
    indent: u32,
) -> Vec<Option<TreeRow>> {
    let count = links.len();
    let Nesting { depth, end } = nesting(links, &parents(links));
    let shown: Vec<Option<usize>> = depth.iter().map(|d| d.map(|d| d.min(MAX_DEPTH))).collect();
    // A row under a collapsed shown row is hidden.
    let collapsed =
        |at: usize| links.get(at).copied().flatten().is_some_and(|ws| ws.collapsed_children);
    let mut hidden = vec![false; count];
    let mut hide_until = 0;
    for (at, flag) in hidden.iter_mut().enumerate() {
        *flag = at < hide_until;
        if !*flag && collapsed(at) {
            hide_until = hide_until.max(end.get(at).copied().unwrap_or(count));
        }
    }
    // Guides, from the bottom up: `follows[c]` says whether the first shown
    // row below with depth at most `c` sits at exactly `c` (a later sibling).
    let mut follows = [false; MAX_DEPTH + 1];
    let mut guides: Vec<Vec<Guide>> = vec![Vec::new(); count];
    for at in (0..count).rev() {
        if hidden.get(at).copied().unwrap_or(true) {
            continue;
        }
        let row_shown = shown.get(at).copied().flatten();
        let d = row_shown.unwrap_or(0);
        if row_shown.is_some()
            && let Some(row_guides) = guides.get_mut(at)
        {
            *row_guides = (1..=d)
                .map(|column| match (column == d, follows.get(column).copied().unwrap_or(false)) {
                    (true, true) => Guide::Branch,
                    (true, false) => Guide::End,
                    (false, true) => Guide::Line,
                    (false, false) => Guide::None,
                })
                .collect();
        }
        for (column, flag) in follows.iter_mut().enumerate().skip(d) {
            *flag = row_shown.is_some() && column == d;
        }
    }
    (0..count)
        .map(|at| {
            let ws = links.get(at).copied().flatten()?;
            let d = shown.get(at).copied().flatten()?;
            let descendants = end.get(at).copied().unwrap_or(at).saturating_sub(at + 1);
            Some(TreeRow {
                id: ws.id.clone(),
                section: section.clone(),
                group: group.cloned(),
                depth: u8::try_from(d).unwrap_or(u8::MAX),
                indent: indent.saturating_mul(u32::try_from(d).unwrap_or(u32::MAX)),
                guides: guides.get_mut(at).map(std::mem::take).unwrap_or_default(),
                has_children: descendants > 0,
                collapsed_count: if collapsed(at) { descendants } else { 0 },
                hidden: hidden.get(at).copied().unwrap_or(false),
            })
        })
        .collect()
}
