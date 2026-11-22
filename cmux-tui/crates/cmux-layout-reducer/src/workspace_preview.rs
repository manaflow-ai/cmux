//! The workspace hover card's shaped preview: the workspace's real split layout drawn to scale,
//! each pane holding its tabs' rows (icon, title, and the tab's CPU and memory inline).
//!
//! Leo, 2026-11-22: "i have this layout. so. the preview should be able to depict that." and
//! "maybe even fit symbols properly in the initial preview without doing stupid layout shifts now
//! or later to pack relevant useful info densely but elegantly."
//!
//! The rule lives here; the drawing does not. The app sends the active screen's split tree, how many
//! tabs each pane has and which one it shows, and the card's metrics; it gets back every pane's rect in
//! whole points, the tabs that pane lists (its shown tab always among them), how many more it holds,
//! and how much of each row's trailing room the numbers get. Nothing here reads a sample: the answer
//! depends on the layout and the width only, so numbers arriving later fill reserved room and move
//! nothing. The app reaches it once per card show through `cmux_layout_reducer_json`
//! (`workspace_preview`).

use serde::{Deserialize, Serialize};

/// A split's direction: `right` puts `b` beside `a`, `down` puts it under.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dir {
    Right,
    Down,
}

/// The split tree, in the daemon's own keys (`type`, `dir`, `a`, `b`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Node {
    Leaf {
        pane: String,
    },
    Split {
        dir: Dir,
        ratio: f64,
        a: Box<Node>,
        b: Box<Node>,
    },
    /// Panes stacked in one place, one expanded: the collapsed ones draw as a header row each.
    Stack {
        panes: Vec<String>,
        expanded: String,
    },
}

/// One pane's tabs, as the preview needs them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Pane {
    pub id: String,
    /// How many tabs the pane holds.
    pub tabs: u32,
    /// The tab the pane shows (its index); it is always listed.
    pub active: u32,
}

/// The card's sizes, in points, from the app's density tokens.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Metrics {
    /// The gap between two panes.
    pub gap: f64,
    /// A pane's inner padding.
    pub inset: f64,
    /// One tab row's height, and the space between two rows.
    pub row: f64,
    pub row_gap: f64,
    /// The narrowest a pane draws: an icon and a few letters.
    pub min_width: f64,
    /// The preview's height never passes this; panes past it list fewer rows.
    pub max_height: f64,
    /// A pane lists at most this many rows before "+N".
    pub max_rows: u32,
    /// Trailing room for both numbers (CPU and memory), and for one (memory).
    pub stats_both: f64,
    pub stats_one: f64,
    /// The least room a title keeps beside its icon before the numbers give way.
    pub title_min: f64,
    /// The icon's side plus its gap to the title.
    pub icon: f64,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            gap: 4.0,
            inset: 5.0,
            row: 16.0,
            row_gap: 2.0,
            min_width: 52.0,
            max_height: 220.0,
            max_rows: 4,
            stats_both: 70.0,
            stats_one: 34.0,
            title_min: 44.0,
            icon: 18.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub layout: Option<Node>,
    pub panes: Vec<Pane>,
    /// The preview's width: the card's text column at its widest, so it never changes with content.
    pub width: f64,
    /// The window's width over its height: the preview keeps the window's shape when its panes fit.
    pub aspect: f64,
    pub metrics: Metrics,
}

impl Default for Request {
    fn default() -> Self {
        Self {
            layout: None,
            panes: Vec::new(),
            width: 260.0,
            aspect: 1.6,
            metrics: Metrics::default(),
        }
    }
}

/// How much of a row's trailing room the numbers take, fixed by the pane's width.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stats {
    /// CPU and memory.
    Both,
    /// Memory only (a narrow pane).
    One,
    /// None: the title needs the room; the pane's header total carries them.
    None,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneOut {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// The tab indices the pane lists, in tab order; the active one is always in.
    pub shown: Vec<u32>,
    /// Tabs it holds beyond `shown`: the last row reads "+N".
    pub more: u32,
    pub stats: Stats,
    /// A stack's collapsed pane: one header row, no tabs.
    pub collapsed: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub width: f64,
    pub height: f64,
    pub panes: Vec<PaneOut>,
}

impl Response {
    fn empty(width: f64) -> Self {
        Self { width, height: 0.0, panes: Vec::new() }
    }
}

/// The preview for `request`: every pane's rect, rows and numbers' room.
pub fn layout(request: &Request) -> Response {
    let m = &request.metrics;
    let width = request.width.max(0.0).floor();
    let Some(root) = request.layout.as_ref() else { return Response::empty(width) };
    if width <= 0.0 {
        return Response::empty(width);
    }
    let tabs = |id: &str| request.panes.iter().find(|p| p.id == id);
    let wants = |id: &str| -> u32 { tabs(id).map_or(1, |p| p.tabs.clamp(1, m.max_rows.max(1))) };
    let pane_height = |rows: u32| -> f64 {
        let rows = f64::from(rows.max(1));
        2.0 * m.inset + rows * m.row + (rows - 1.0) * m.row_gap
    };
    let one_row = pane_height(1);

    // The least height each subtree needs to list its panes' rows, and the most it can use.
    fn need(
        node: &Node,
        wants: &dyn Fn(&str) -> u32,
        pane_height: &dyn Fn(u32) -> f64,
        gap: f64,
        one_row: f64,
    ) -> f64 {
        match node {
            Node::Leaf { pane } => pane_height(wants(pane)),
            Node::Split { dir: Dir::Right, a, b, .. } => need(a, wants, pane_height, gap, one_row)
                .max(need(b, wants, pane_height, gap, one_row)),
            Node::Split { dir: Dir::Down, ratio, a, b } => {
                let r = clamp_ratio(*ratio);
                let na = need(a, wants, pane_height, gap, one_row);
                let nb = need(b, wants, pane_height, gap, one_row);
                // Keep the split's proportion when it can; never less than both halves stacked.
                ((na + gap / 2.0) / r)
                    .max((nb + gap / 2.0) / (1.0 - r))
                    .min(na + nb + gap * 4.0)
                    .max(na + nb + gap)
            }
            Node::Stack { panes, expanded } => {
                let collapsed = panes.iter().filter(|p| *p != expanded).count() as f64;
                pane_height(wants(expanded)) + collapsed * (one_row + gap)
            }
        }
    }
    let needed = need(root, &wants, &pane_height, m.gap, one_row);
    let aspect =
        if request.aspect.is_finite() && request.aspect > 0.2 { request.aspect } else { 1.6 };
    let floor = one_row.min(m.max_height);
    let height = (width / aspect).max(needed).min(m.max_height.max(floor)).max(floor).round();

    let mut out = Vec::new();
    place(root, Rect { x: 0.0, y: 0.0, w: width, h: height }, m, one_row, &mut out);
    for pane in &mut out {
        fill(pane, tabs(&pane.id), m);
    }
    Response { width, height, panes: out }
}

#[derive(Clone, Copy)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

fn clamp_ratio(ratio: f64) -> f64 {
    if ratio.is_finite() { ratio.clamp(0.05, 0.95) } else { 0.5 }
}

/// How many panes a subtree puts side by side (`Right`) or one under another (`Down`).
fn across(node: &Node, dir: Dir) -> usize {
    match node {
        Node::Leaf { .. } => 1,
        Node::Split { dir: d, a, b, .. } if *d == dir => across(a, dir) + across(b, dir),
        Node::Split { a, b, .. } => across(a, dir).max(across(b, dir)),
        Node::Stack { panes, .. } => {
            if dir == Dir::Down {
                panes.len().max(1)
            } else {
                1
            }
        }
    }
}

/// Splits `len` at `ratio` less a gap, each side at least `min_a` / `min_b` when the length allows.
fn cut(len: f64, ratio: f64, gap: f64, min_a: f64, min_b: f64) -> (f64, f64) {
    let room = (len - gap).max(0.0);
    let mut a = (room * clamp_ratio(ratio)).round();
    if min_a + min_b <= room {
        a = a.clamp(min_a, room - min_b);
    } else {
        a = (room * min_a / (min_a + min_b).max(1.0)).round();
    }
    (a, room - a)
}

fn place(node: &Node, r: Rect, m: &Metrics, one_row: f64, out: &mut Vec<PaneOut>) {
    match node {
        Node::Leaf { pane } => out.push(pane_out(pane, r, false)),
        Node::Split { dir: Dir::Right, ratio, a, b } => {
            let min_a = across(a, Dir::Right) as f64 * (m.min_width + m.gap) - m.gap;
            let min_b = across(b, Dir::Right) as f64 * (m.min_width + m.gap) - m.gap;
            let (wa, wb) = cut(r.w, *ratio, m.gap, min_a, min_b);
            place(a, Rect { w: wa, ..r }, m, one_row, out);
            place(b, Rect { x: r.x + wa + m.gap, w: wb, ..r }, m, one_row, out);
        }
        Node::Split { dir: Dir::Down, ratio, a, b } => {
            let min_a = across(a, Dir::Down) as f64 * (one_row + m.gap) - m.gap;
            let min_b = across(b, Dir::Down) as f64 * (one_row + m.gap) - m.gap;
            let (ha, hb) = cut(r.h, *ratio, m.gap, min_a, min_b);
            place(a, Rect { h: ha, ..r }, m, one_row, out);
            place(b, Rect { y: r.y + ha + m.gap, h: hb, ..r }, m, one_row, out);
        }
        Node::Stack { panes, expanded } => {
            let mut y = r.y;
            let collapsed = panes.iter().filter(|p| *p != expanded).count() as f64;
            let open = (r.h - collapsed * (one_row + m.gap)).max(one_row);
            for pane in panes {
                let h = if pane == expanded { open } else { one_row };
                out.push(pane_out(pane, Rect { y, h, ..r }, pane != expanded));
                y += h + m.gap;
            }
            if !panes.contains(expanded) {
                out.push(pane_out(expanded, Rect { y, h: open, ..r }, false));
            }
        }
    }
}

fn pane_out(id: &str, r: Rect, collapsed: bool) -> PaneOut {
    PaneOut {
        id: id.to_owned(),
        x: r.x.round(),
        y: r.y.round(),
        w: r.w.round().max(0.0),
        h: r.h.round().max(0.0),
        shown: Vec::new(),
        more: 0,
        stats: Stats::None,
        collapsed,
    }
}

/// The rows a pane lists and its numbers' room.
fn fill(out: &mut PaneOut, pane: Option<&Pane>, m: &Metrics) {
    let total = pane.map_or(0, |p| p.tabs);
    let text = out.w - 2.0 * m.inset - m.icon;
    out.stats = if text - m.stats_both >= m.title_min {
        Stats::Both
    } else if text - m.stats_one >= m.title_min {
        Stats::One
    } else {
        Stats::None
    };
    if total == 0 {
        return;
    }
    let active = pane.map_or(0, |p| p.active.min(total - 1));
    if out.collapsed {
        out.shown = vec![active];
        out.more = total - 1;
        return;
    }
    let pitch = m.row + m.row_gap;
    let fit = (((out.h - 2.0 * m.inset + m.row_gap) / pitch).floor().max(1.0) as u32)
        .min(m.max_rows.max(1));
    if total <= fit {
        out.shown = (0..total).collect();
        return;
    }
    // The last row says how many more; the active tab is always one of the listed rows.
    let rows = fit.saturating_sub(1).max(1);
    let start = if active < rows { 0 } else { active + 1 - rows };
    out.shown = (start..start + rows).collect();
    out.more = total - rows;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(id: &str) -> Node {
        Node::Leaf { pane: id.into() }
    }
    fn split(dir: Dir, ratio: f64, a: Node, b: Node) -> Node {
        Node::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }
    }
    fn pane(id: &str, tabs: u32, active: u32) -> Pane {
        Pane { id: id.into(), tabs, active }
    }

    /// Leo's layout: a chat with tabs, a terminal, a browser, three columns.
    fn three_columns() -> Request {
        Request {
            layout: Some(split(
                Dir::Right,
                0.4,
                leaf("chat"),
                split(Dir::Right, 0.5, leaf("term"), leaf("web")),
            )),
            panes: vec![pane("chat", 3, 1), pane("term", 1, 0), pane("web", 1, 0)],
            width: 300.0,
            ..Request::default()
        }
    }

    #[test]
    fn three_columns_keep_their_proportions_and_tile_the_width() {
        let r = layout(&three_columns());
        assert_eq!(
            r.panes.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
            ["chat", "term", "web"]
        );
        let [chat, term, web] = &r.panes[..] else { panic!() };
        assert!((chat.w - 118.0).abs() <= 1.0, "chat {}", chat.w);
        assert_eq!(term.x, chat.x + chat.w + 4.0);
        assert_eq!(web.x + web.w, 300.0);
        assert!(r.panes.iter().all(|p| p.y == 0.0 && p.h == r.height));
        assert_eq!(chat.shown, [0, 1, 2]);
        assert_eq!(chat.more, 0);
    }

    #[test]
    fn the_answer_never_depends_on_numbers_so_it_never_shifts() {
        let a = layout(&three_columns());
        let b = layout(&three_columns());
        assert_eq!(a, b);
        // Every value is a whole point.
        for p in &a.panes {
            for v in [p.x, p.y, p.w, p.h] {
                assert_eq!(v, v.round());
            }
        }
    }

    #[test]
    fn a_narrow_pane_gives_its_numbers_room_to_the_title() {
        let mut req = three_columns();
        req.width = 200.0;
        let r = layout(&req);
        assert_eq!(r.panes[1].stats, Stats::None);
        let mut wide = three_columns();
        wide.width = 600.0;
        assert!(layout(&wide).panes.iter().all(|p| p.stats == Stats::Both));
    }

    #[test]
    fn a_tiny_ratio_still_draws_a_pane_wide_enough_for_an_icon() {
        let req = Request {
            layout: Some(split(Dir::Right, 0.02, leaf("a"), leaf("b"))),
            panes: vec![pane("a", 1, 0), pane("b", 1, 0)],
            width: 260.0,
            ..Request::default()
        };
        let r = layout(&req);
        assert!(r.panes[0].w >= req.metrics.min_width);
    }

    #[test]
    fn many_tabs_list_the_active_one_and_count_the_rest() {
        let req = Request {
            layout: Some(leaf("a")),
            panes: vec![pane("a", 12, 9)],
            width: 260.0,
            ..Request::default()
        };
        let r = layout(&req);
        let p = &r.panes[0];
        assert!(p.shown.contains(&9));
        assert_eq!(p.shown.len() as u32 + p.more, 12);
        assert!(r.height <= req.metrics.max_height);
    }

    #[test]
    fn a_down_split_grows_the_preview_to_list_both_halves() {
        let req = Request {
            layout: Some(split(Dir::Down, 0.5, leaf("a"), leaf("b"))),
            panes: vec![pane("a", 3, 0), pane("b", 3, 0)],
            width: 300.0,
            aspect: 3.0,
            ..Request::default()
        };
        let r = layout(&req);
        assert!(r.panes.iter().all(|p| p.more == 0 && p.shown.len() == 3), "{r:?}");
        assert_eq!(r.panes[1].y, r.panes[0].h + 4.0);
    }

    #[test]
    fn a_stack_draws_its_collapsed_panes_as_one_row() {
        let req = Request {
            layout: Some(Node::Stack { panes: vec!["a".into(), "b".into()], expanded: "b".into() }),
            panes: vec![pane("a", 2, 1), pane("b", 2, 0)],
            width: 260.0,
            ..Request::default()
        };
        let r = layout(&req);
        assert!(r.panes[0].collapsed);
        assert_eq!(r.panes[0].shown, [1]);
        assert_eq!(r.panes[0].more, 1);
        assert!(!r.panes[1].collapsed);
    }

    #[test]
    fn no_layout_draws_nothing() {
        assert_eq!(layout(&Request::default()).panes, []);
    }

    #[test]
    fn decodes_the_daemon_keys() {
        let req: Request = serde_json::from_str(
            r#"{"layout":{"type":"split","dir":"right","ratio":0.5,"a":{"type":"leaf","pane":"1"},"b":{"type":"leaf","pane":"2"}},
                "panes":[{"id":"1","tabs":2,"active":1},{"id":"2","tabs":1}],"width":240}"#,
        )
        .unwrap();
        assert_eq!(layout(&req).panes.len(), 2);
    }
}
