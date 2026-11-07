//! The creator tree as rows (`sidebar_edits` op `tree`): each workspace
//! row's depth under its creator, its indent, its guide lines and its
//! collapsed count. Depth counts within the row's container (a section's
//! top level or a group's members): a child draws under its creator only
//! while it lists inside the creator's subtree there. Rows past
//! [`MAX_DEPTH`] draw at it; the stored links never change for the cap.

use super::creator::{Link, Row, parents};
use super::{Node, Section, SectionId};
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
        let nodes: Vec<&Node> = section.nodes.iter().collect();
        let top = container(&nodes, &section.id, None, indent);
        for (node, row) in section.nodes.iter().zip(top) {
            if let Some(row) = row {
                out.push(row);
            }
            if let Node::Group { group } = node {
                let members: Vec<_> = group.members.iter().collect();
                out.extend(
                    container(&members, &section.id, Some(&group.id), indent).into_iter().flatten(),
                );
            }
        }
    }
    out
}

/// One container's rows: None for a group or an item.
fn container<R: Row>(
    rows: &[&R],
    section: &SectionId,
    group: Option<&String>,
    indent: u32,
) -> Vec<Option<TreeRow>> {
    let links: Vec<Link<'_>> = rows.iter().map(|row| row.link()).collect();
    let parents = parents(&links);
    let count = links.len();
    // The true depth of each workspace row: under its creator only while the
    // creator's subtree is still open above it. `end` is where a subtree stops.
    let mut depth: Vec<Option<usize>> = vec![None; count];
    let mut end: Vec<usize> = vec![count; count];
    let mut open: Vec<usize> = Vec::new();
    for (at, (link, parent)) in links.iter().zip(&parents).enumerate() {
        // Rows stay open while the next one lists under them; a group or an item closes all.
        let keep = match (link, parent) {
            (Some(_), Some(parent)) => {
                open.iter().position(|row| row == parent).map_or(0, |p| p + 1)
            }
            _ => 0,
        };
        for closed in open.drain(keep..) {
            end[closed] = at;
        }
        if link.is_some() {
            depth[at] = Some(open.len());
            open.push(at);
        }
    }
    let shown: Vec<Option<usize>> = depth.iter().map(|d| d.map(|d| d.min(MAX_DEPTH))).collect();
    // A row under a collapsed shown row is hidden.
    let collapsed = |at: usize| {
        rows.get(at).and_then(|row| row.workspace()).is_some_and(|ws| ws.collapsed_children)
    };
    let mut hidden = vec![false; count];
    let mut hide_until = 0;
    for (at, flag) in hidden.iter_mut().enumerate() {
        *flag = at < hide_until;
        if !*flag && collapsed(at) {
            hide_until = hide_until.max(end[at]);
        }
    }
    // Guides, from the bottom up: `follows[c]` says whether the first shown
    // row below with depth at most `c` sits at exactly `c` (a later sibling).
    let mut follows = [false; MAX_DEPTH + 1];
    let mut guides: Vec<Vec<Guide>> = vec![Vec::new(); count];
    for at in (0..count).rev() {
        if hidden[at] {
            continue;
        }
        let d = shown[at].unwrap_or(0);
        if shown[at].is_some() {
            guides[at] = (1..=d)
                .map(|column| match (column == d, follows[column]) {
                    (true, true) => Guide::Branch,
                    (true, false) => Guide::End,
                    (false, true) => Guide::Line,
                    (false, false) => Guide::None,
                })
                .collect();
        }
        for (column, flag) in follows.iter_mut().enumerate().skip(d) {
            *flag = shown[at].is_some() && column == d;
        }
    }
    (0..count)
        .map(|at| {
            let (id, _) = links.get(at).copied().flatten()?;
            let d = shown.get(at).copied().flatten()?;
            let descendants = end[at].saturating_sub(at + 1);
            Some(TreeRow {
                id: id.to_owned(),
                section: section.clone(),
                group: group.cloned(),
                depth: u8::try_from(d).unwrap_or(u8::MAX),
                indent: indent.saturating_mul(u32::try_from(d).unwrap_or(u32::MAX)),
                guides: std::mem::take(&mut guides[at]),
                has_children: descendants > 0,
                collapsed_count: if collapsed(at) { descendants } else { 0 },
                hidden: hidden[at],
            })
        })
        .collect()
}
