//! Fitting the cached layout to what the daemon says exists now, without moving anything that
//! did not have to move. Every pane, tab and row whose id survives keeps its cached geometry
//! exactly (the same `f64`s, not a recomputation that rounds differently). A pane that vanished
//! gives its space to its siblings and a new pane splits its neighbour evenly (the app's default);
//! both come back as transitions so the app animates the change once, after the first frame drew
//! the cached layout, instead of the layout settling over several frames.
use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::model::{Axis, EPSILON, Leaf, PaneKind, PaneNode, Rect, RowHeight, Split, TabSlot};

/// The split structure the daemon says exists. Leaves carry the kind, for panes the cache lacks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LiveNode {
    Split {
        #[serde(default)]
        axis: Axis,
        #[serde(default)]
        children: Vec<LiveNode>,
    },
    Leaf {
        pane_id: String,
        #[serde(default)]
        kind: PaneKind,
    },
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct LiveTree {
    /// The live pane ids. Used when `root` is absent: the cached structure, pruned to these, with
    /// any id the cache lacks split off its last pane.
    pub panes: Vec<String>,
    pub root: Option<LiveNode>,
    /// The window's content area; absent: the cached tree's bounds.
    pub bounds: Option<Rect>,
    /// The divider between panes, for a split the cache cannot infer it from.
    pub divider: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransitionKind {
    /// These panes are gone; their siblings grew into their space.
    Removed,
    /// These panes are new; they took an even share of a neighbour.
    Added,
    /// The split structure changed beyond removals and additions (reordered, axis flipped):
    /// these panes were laid out anew, evenly.
    Restructured,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Transition {
    pub kind: TransitionKind,
    pub panes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Moved {
    pub pane_id: String,
    pub from: Rect,
    pub to: Rect,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Applied {
    /// The tree to show: cached geometry wherever the identity survived.
    pub node: PaneNode,
    /// Empty when the cache matched exactly: the first frame is the final frame.
    pub transitions: Vec<Transition>,
    /// Surviving panes whose frame changed, with both frames, for the one animation.
    pub moved: Vec<Moved>,
}

/// Fits `cached` to `live`; see the module comment for the rule.
pub fn reconcile(cached: &PaneNode, live: &LiveTree) -> Applied {
    let cached_leaves: HashMap<&str, &Leaf> =
        cached.leaves().into_iter().map(|l| (l.pane_id.as_str(), l)).collect();
    let root = live.root.clone().unwrap_or_else(|| derived_live(cached, &live.panes));
    let slot = live.bounds.or_else(|| cached.bounds()).unwrap_or_default();
    let mut ctx =
        Ctx { cached, leaves: &cached_leaves, divider: live.divider, restructured: Vec::new() };
    let node = ctx.build(&root, slot);

    let live_ids: HashSet<String> = live_leaf_ids(&root).into_iter().collect();
    let removed: Vec<String> = cached
        .leaves()
        .iter()
        .map(|l| l.pane_id.clone())
        .filter(|id| !live_ids.contains(id))
        .collect();
    let added: Vec<String> = live_leaf_ids(&root)
        .into_iter()
        .filter(|id| !cached_leaves.contains_key(id.as_str()))
        .collect();
    let moved: Vec<Moved> = node
        .leaves()
        .iter()
        .filter_map(|l| {
            let c = cached_leaves.get(l.pane_id.as_str())?;
            (c.frame != l.frame).then(|| Moved {
                pane_id: l.pane_id.clone(),
                from: c.frame,
                to: l.frame,
            })
        })
        .collect();
    let mut transitions = Vec::new();
    for (kind, panes) in [
        (TransitionKind::Removed, removed),
        (TransitionKind::Added, added),
        (TransitionKind::Restructured, std::mem::take(&mut ctx.restructured)),
    ] {
        if !panes.is_empty() {
            transitions.push(Transition { kind, panes });
        }
    }
    Applied { node, transitions, moved }
}

fn live_leaf_ids(n: &LiveNode) -> Vec<String> {
    match n {
        LiveNode::Leaf { pane_id, .. } => vec![pane_id.clone()],
        LiveNode::Split { children, .. } => children.iter().flat_map(live_leaf_ids).collect(),
    }
}

/// The cached structure pruned to `panes` (a split left with one child becomes that child), with
/// each id the cache lacks split off the last pane, side by side.
pub fn derived_live(cached: &PaneNode, panes: &[String]) -> LiveNode {
    let keep: HashSet<&str> = panes.iter().map(String::as_str).collect();
    fn prune(n: &PaneNode, keep: &HashSet<&str>) -> Option<LiveNode> {
        match n {
            PaneNode::Leaf(l) => keep
                .contains(l.pane_id.as_str())
                .then(|| LiveNode::Leaf { pane_id: l.pane_id.clone(), kind: l.kind }),
            PaneNode::Split(s) => {
                let mut kids: Vec<LiveNode> =
                    s.children.iter().filter_map(|c| prune(c, keep)).collect();
                match kids.len() {
                    0 => None,
                    1 => kids.pop(),
                    _ => Some(LiveNode::Split { axis: s.axis, children: kids }),
                }
            }
        }
    }
    let cached_ids: HashSet<&str> = cached.leaves().iter().map(|l| l.pane_id.as_str()).collect();
    let new: Vec<LiveNode> = panes
        .iter()
        .filter(|id| !cached_ids.contains(id.as_str()))
        .map(|id| LiveNode::Leaf { pane_id: id.clone(), kind: PaneKind::Other })
        .collect();
    let root = prune(cached, &keep);
    if new.is_empty() {
        return root.unwrap_or(LiveNode::Split { axis: Axis::Horizontal, children: Vec::new() });
    }
    // The new panes split the last pane: replace the last leaf with a split of it and them.
    match root {
        None if new.len() == 1 => new
            .into_iter()
            .next()
            .unwrap_or(LiveNode::Split { axis: Axis::Horizontal, children: Vec::new() }),
        None => LiveNode::Split { axis: Axis::Horizontal, children: new },
        Some(mut r) => {
            fn last_leaf(n: &mut LiveNode) -> &mut LiveNode {
                let has_children =
                    matches!(n, LiveNode::Split { children, .. } if !children.is_empty());
                if !has_children {
                    return n;
                }
                let LiveNode::Split { children, .. } = n else { return n };
                let last = children.len() - 1;
                last_leaf(&mut children[last])
            }
            let target = last_leaf(&mut r);
            let old = std::mem::replace(
                target,
                LiveNode::Split { axis: Axis::Horizontal, children: Vec::new() },
            );
            let mut children = vec![old];
            children.extend(new);
            *target = LiveNode::Split { axis: Axis::Horizontal, children };
            r
        }
    }
}

struct Ctx<'a> {
    cached: &'a PaneNode,
    leaves: &'a HashMap<&'a str, &'a Leaf>,
    divider: f64,
    restructured: Vec<String>,
}

/// A span along one axis: `lo` to `hi`.
#[derive(Clone, Copy)]
struct Span {
    lo: f64,
    hi: f64,
}

fn span(r: &Rect, axis: Axis) -> Span {
    match axis {
        Axis::Horizontal => Span { lo: r.x, hi: r.max_x() },
        Axis::Vertical => Span { lo: r.y, hi: r.max_y() },
    }
}

fn with_span(slot: &Rect, axis: Axis, s: Span) -> Rect {
    match axis {
        Axis::Horizontal => Rect::new(s.lo, slot.y, s.hi - s.lo, slot.height),
        Axis::Vertical => Rect::new(slot.x, s.lo, slot.width, s.hi - s.lo),
    }
}

impl Ctx<'_> {
    fn build(&mut self, live: &LiveNode, slot: Rect) -> PaneNode {
        match live {
            LiveNode::Leaf { pane_id, kind } => match self.leaves.get(pane_id.as_str()) {
                Some(c) => {
                    let mut l = (*c).clone();
                    // Exactly the cached numbers when the place is the same: no rounding drift.
                    if !c.frame.same_place(&slot) {
                        l.frame = slot;
                    }
                    PaneNode::Leaf(l)
                }
                None => PaneNode::Leaf(Leaf {
                    pane_id: pane_id.clone(),
                    kind: *kind,
                    frame: slot,
                    ..Leaf::default()
                }),
            },
            LiveNode::Split { axis, children } if children.is_empty() => {
                PaneNode::Split(Split { axis: *axis, fractions: Vec::new(), children: Vec::new() })
            }
            LiveNode::Split { axis, children } => {
                let (spans, fractions) = match self.matched_spans(*axis, children, slot) {
                    Some(r) => r,
                    None => {
                        let survivors: Vec<String> = children
                            .iter()
                            .flat_map(live_leaf_ids)
                            .filter(|id| self.leaves.contains_key(id.as_str()))
                            .collect();
                        if survivors.len() > 1 {
                            self.restructured.extend(survivors);
                        }
                        let gap = self.divider;
                        let spans = even(span(&slot, *axis), children.len(), gap);
                        (spans, vec![1.0 / children.len() as f64; children.len()])
                    }
                };
                let kids = children
                    .iter()
                    .zip(&spans)
                    .map(|(c, s)| self.build(c, with_span(&slot, *axis, *s)))
                    .collect();
                PaneNode::Split(Split { axis: *axis, fractions, children: kids })
            }
        }
    }

    /// The live children's spans from the cached split they came from, or None when there is
    /// none to follow (no survivors, a different axis, a reordering).
    fn matched_spans(
        &self,
        axis: Axis,
        children: &[LiveNode],
        slot: Rect,
    ) -> Option<(Vec<Span>, Vec<f64>)> {
        let survivors: Vec<Vec<String>> = children
            .iter()
            .map(|c| {
                live_leaf_ids(c)
                    .into_iter()
                    .filter(|id| self.leaves.contains_key(id.as_str()))
                    .collect()
            })
            .collect();
        let all: HashSet<&str> = survivors.iter().flatten().map(String::as_str).collect();
        if survivors.iter().filter(|s| !s.is_empty()).count() < 2 {
            return None;
        }
        let PaneNode::Split(split) = lowest_holding(self.cached, &all)? else { return None };
        if split.axis != axis {
            return None;
        }
        // Each live child with survivors maps into one cached child; increasing, distinct.
        let mut mapped: Vec<Option<usize>> = Vec::with_capacity(children.len());
        let mut last: Option<usize> = None;
        for s in &survivors {
            if s.is_empty() {
                mapped.push(None);
                continue;
            }
            let j =
                split.children.iter().position(|c| c.leaves().iter().any(|l| l.pane_id == s[0]))?;
            let inside = &split.children[j];
            if !s.iter().all(|id| inside.leaves().iter().any(|l| &l.pane_id == id))
                || last.is_some_and(|p| j <= p)
            {
                return None;
            }
            last = Some(j);
            mapped.push(Some(j));
        }
        let slots: Vec<Span> =
            split.children.iter().map(|c| span(&c.bounds().unwrap_or_default(), axis)).collect();
        let gap =
            if slots.len() >= 2 { (slots[1].lo - slots[0].hi).max(0.0) } else { self.divider };
        let whole = span(&slot, axis);
        let anchors: Vec<(usize, usize)> =
            mapped.iter().enumerate().filter_map(|(i, j)| j.map(|j| (i, j))).collect();
        // Each surviving child's span: from its cached start (the first: the slot's start) to just
        // before the next survivor's cached start (the last: the slot's end). Vanished cached
        // children between them are absorbed by the survivor before them.
        let mut spans = vec![Span { lo: 0.0, hi: 0.0 }; children.len()];
        for (k, &(i, j)) in anchors.iter().enumerate() {
            let lo = if k == 0 { whole.lo } else { slots[j].lo };
            let hi = match anchors.get(k + 1) {
                Some(&(_, next)) => slots[next - 1].hi,
                None => whole.hi,
            };
            // New children before the next survivor (or before the first) share this span.
            let group_start = if k == 0 { 0 } else { i };
            let group_end = anchors.get(k + 1).map_or(children.len(), |&(ni, _)| ni);
            let parts = even(Span { lo, hi }, group_end - group_start, gap);
            for (offset, s) in parts.into_iter().enumerate() {
                spans[group_start + offset] = s;
            }
        }
        let unchanged = children.len() == split.children.len()
            && anchors.iter().all(|&(i, j)| i == j)
            && span(&split.children[0].bounds().unwrap_or_default(), axis).lo == whole.lo
            && (slots[slots.len() - 1].hi - whole.hi).abs() < EPSILON;
        let fractions = if unchanged {
            split.fractions.clone()
        } else {
            let total: f64 = spans.iter().map(|s| (s.hi - s.lo).max(0.0)).sum();
            spans
                .iter()
                .map(|s| {
                    if total > 0.0 {
                        (s.hi - s.lo).max(0.0) / total
                    } else {
                        1.0 / spans.len() as f64
                    }
                })
                .collect()
        };
        Some((spans, fractions))
    }
}

/// `n` equal spans with `gap` between them.
fn even(s: Span, n: usize, gap: f64) -> Vec<Span> {
    if n <= 1 {
        return vec![s; n];
    }
    let gap = gap.max(0.0).min((s.hi - s.lo) / (n as f64 - 1.0));
    let each = ((s.hi - s.lo) - gap * (n as f64 - 1.0)) / n as f64;
    (0..n)
        .map(|i| {
            let lo = s.lo + i as f64 * (each + gap);
            let hi = if i == n - 1 { s.hi } else { lo + each };
            Span { lo, hi }
        })
        .collect()
}

/// The deepest cached node whose leaves include every id in `ids`.
fn lowest_holding<'a>(n: &'a PaneNode, ids: &HashSet<&str>) -> Option<&'a PaneNode> {
    let holds = |n: &PaneNode| {
        let have: HashSet<&str> = n.leaves().iter().map(|l| l.pane_id.as_str()).collect();
        ids.iter().all(|id| have.contains(id))
    };
    if !holds(n) {
        return None;
    }
    if let PaneNode::Split(s) = n {
        for c in &s.children {
            if let Some(deeper) = lowest_holding(c, ids) {
                return Some(deeper);
            }
        }
    }
    Some(n)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    Removed,
    Added,
    Moved,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StripChange {
    pub id: String,
    pub kind: ChangeKind,
    /// Before (absent for an added tab).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub from_x: Option<f64>,
    /// After (absent for a removed tab).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub to_x: Option<f64>,
    pub width: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StripApplied {
    pub tabs: Vec<TabSlot>,
    /// Only what differs from the cache.
    pub changes: Vec<StripChange>,
}

/// The tab strip for `live` ids in order. Surviving tabs keep their cached width, and their x
/// while nothing before them changed; a gap a closed tab left closes and a new tab takes
/// `default_width` at its place.
pub fn reconcile_strip(cached: &[TabSlot], live: &[String], default_width: f64) -> StripApplied {
    let by_id: HashMap<&str, &TabSlot> = cached.iter().map(|t| (t.id.as_str(), t)).collect();
    let gap = cached.windows(2).next().map_or(0.0, |w| (w[1].x - w[0].x - w[0].width).max(0.0));
    let mut x = cached.first().map_or(0.0, |t| t.x);
    let mut tabs = Vec::with_capacity(live.len());
    let mut changes = Vec::new();
    for id in live {
        let slot = match by_id.get(id.as_str()) {
            Some(c) => {
                let at = if (c.x - x).abs() < EPSILON { c.x } else { x };
                if at != c.x {
                    changes.push(StripChange {
                        id: id.clone(),
                        kind: ChangeKind::Moved,
                        from_x: Some(c.x),
                        to_x: Some(at),
                        width: c.width,
                    });
                }
                TabSlot { id: id.clone(), x: at, width: c.width }
            }
            None => {
                changes.push(StripChange {
                    id: id.clone(),
                    kind: ChangeKind::Added,
                    from_x: None,
                    to_x: Some(x),
                    width: default_width,
                });
                TabSlot { id: id.clone(), x, width: default_width }
            }
        };
        x = slot.x + slot.width + gap;
        tabs.push(slot);
    }
    let live_set: HashSet<&str> = live.iter().map(String::as_str).collect();
    for c in cached.iter().filter(|c| !live_set.contains(c.id.as_str())) {
        changes.push(StripChange {
            id: c.id.clone(),
            kind: ChangeKind::Removed,
            from_x: Some(c.x),
            to_x: None,
            width: c.width,
        });
    }
    StripApplied { tabs, changes }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowsApplied {
    pub rows: Vec<RowHeight>,
    pub added: Vec<String>,
    pub removed: Vec<String>,
}

/// Sidebar rows for `live` ids in order: surviving rows keep their measured height, new rows
/// take `default_height` until measured.
pub fn reconcile_rows(cached: &[RowHeight], live: &[String], default_height: f64) -> RowsApplied {
    let by_id: HashMap<&str, f64> = cached.iter().map(|r| (r.id.as_str(), r.height)).collect();
    let live_set: HashSet<&str> = live.iter().map(String::as_str).collect();
    RowsApplied {
        rows: live
            .iter()
            .map(|id| RowHeight {
                id: id.clone(),
                height: by_id.get(id.as_str()).copied().unwrap_or(default_height),
            })
            .collect(),
        added: live.iter().filter(|id| !by_id.contains_key(id.as_str())).cloned().collect(),
        removed: cached
            .iter()
            .filter(|r| !live_set.contains(r.id.as_str()))
            .map(|r| r.id.clone())
            .collect(),
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct IdRect {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl IdRect {
    pub fn rect(&self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }
}

/// How much the layout jumped, like the web's cumulative layout shift: over every id in both,
/// (distance moved / viewport diagonal) * (union of its two rects / viewport area). The distance
/// is the larger of its top-left and bottom-right corners' moves, so a resize counts too. 0 when
/// nothing moved; appearing and vanishing elements are transitions, not shifts.
pub fn shift_score(before: &[IdRect], after: &[IdRect], viewport: &Rect) -> f64 {
    let diagonal = (viewport.width.powi(2) + viewport.height.powi(2)).sqrt();
    let area = viewport.area();
    if diagonal <= 0.0 || area <= 0.0 {
        return 0.0;
    }
    let after: HashMap<&str, Rect> = after.iter().map(|r| (r.id.as_str(), r.rect())).collect();
    before
        .iter()
        .filter_map(|b| Some((b.rect(), *after.get(b.id.as_str())?)))
        .map(|(a, b)| {
            let corner =
                |x0: f64, y0: f64, x1: f64, y1: f64| ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
            let moved =
                corner(a.x, a.y, b.x, b.y).max(corner(a.max_x(), a.max_y(), b.max_x(), b.max_y()));
            if moved == 0.0 {
                return 0.0;
            }
            let union = (a.intersection_area(viewport) + b.intersection_area(viewport)
                - clip_overlap(&a, &b, viewport))
            .max(0.0);
            (moved / diagonal) * (union / area)
        })
        .sum()
}

fn clip_overlap(a: &Rect, b: &Rect, viewport: &Rect) -> f64 {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let w = a.max_x().min(b.max_x()) - x;
    let h = a.max_y().min(b.max_y()) - y;
    if w <= 0.0 || h <= 0.0 { 0.0 } else { Rect::new(x, y, w, h).intersection_area(viewport) }
}

#[cfg(test)]
#[path = "reconcile_tests.rs"]
mod tests;
