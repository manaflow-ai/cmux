//! The cache's model: what a window looked like the last time it was laid out, in the units the app
//! drew it in (points, top-left origin inside a window, AppKit global points for window frames).
//! Every struct is `#[serde(default)]` and ignores unknown fields, so a newer app's extra field
//! reads in an older one and a missing one reads as its default; only `version` gates the format.
use serde::{Deserialize, Serialize};

/// The format version. A file with any other version is ignored, never migrated: a layout cache
/// is cheap to rebuild and a wrong one shifts the very thing it exists to keep still.
pub const FORMAT_VERSION: u32 = 1;
/// Rows kept per sidebar and per chat pane. The launch needs only the rows on screen and a little
/// past them; the cap keeps the file small and its read inside the launch's budget.
pub const MAX_ROWS: usize = 256;
/// Windows kept; more than any real session has open.
pub const MAX_WINDOWS: usize = 64;
/// Tabs kept per window's tab strip.
pub const MAX_TABS: usize = 256;
/// Split tree depth kept; a deeper tree is malformed.
pub const MAX_DEPTH: usize = 32;

/// A rectangle: origin `x`, `y`, size `width`, `height`.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn area(&self) -> f64 {
        self.width.max(0.0) * self.height.max(0.0)
    }
    pub fn is_finite(&self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
    }
    /// The smallest rectangle holding both.
    pub fn union(&self, o: &Rect) -> Rect {
        let (x, y) = (self.x.min(o.x), self.y.min(o.y));
        Rect::new(x, y, self.max_x().max(o.max_x()) - x, self.max_y().max(o.max_y()) - y)
    }
    pub fn intersection_area(&self, o: &Rect) -> f64 {
        let w = self.max_x().min(o.max_x()) - self.x.max(o.x);
        let h = self.max_y().min(o.max_y()) - self.y.max(o.y);
        if w > 0.0 && h > 0.0 { w * h } else { 0.0 }
    }
    /// Equal within `EPSILON` on every edge: the same place once float rounding is set aside.
    pub fn same_place(&self, o: &Rect) -> bool {
        (self.x - o.x).abs() < EPSILON
            && (self.y - o.y).abs() < EPSILON
            && (self.width - o.width).abs() < EPSILON
            && (self.height - o.height).abs() < EPSILON
    }
}

/// Points below which two edges are the same edge (far under a device pixel).
pub const EPSILON: f64 = 1e-6;

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Display {
    /// CGDirectDisplayID.
    pub id: u32,
    pub frame: Rect,
    pub backing_scale: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Appearance {
    #[default]
    Light,
    Dark,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Theme {
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accent_rgba: Option<[u8; 4]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font_family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font_size: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RowHeight {
    pub id: String,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Sidebar {
    pub width: f64,
    pub collapsed: bool,
    pub scroll_y: f64,
    /// Measured row heights, top first, capped at `MAX_ROWS`: the rows draw at their measured
    /// height on the first frame instead of an estimate that settles.
    pub row_heights: Vec<RowHeight>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TabSlot {
    pub id: String,
    pub x: f64,
    pub width: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum Axis {
    /// Children side by side, left to right (the split divides `x`).
    #[default]
    #[serde(rename = "h")]
    Horizontal,
    /// Children stacked, top to bottom (the split divides `y`).
    #[serde(rename = "v")]
    Vertical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaneKind {
    Terminal,
    Chat,
    Browser,
    Home,
    /// Also any kind a newer app names: read, kept, drawn as a plain pane.
    #[default]
    #[serde(other)]
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Scroll {
    pub offset_y: f64,
    pub content_height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TerminalGrid {
    pub cols: u32,
    pub rows: u32,
    pub cell_w: f64,
    pub cell_h: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ChatRowHeight {
    pub id: String,
    pub h: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ChatAnchor {
    /// The row the view was anchored to and its offset from the viewport top: the transcript
    /// reopens on the same line, not at a recomputed bottom.
    pub anchor_row_id: String,
    pub anchor_offset: f64,
    /// Capped at `MAX_ROWS`.
    pub row_heights: Vec<ChatRowHeight>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct LastContent {
    pub image_key: String,
    pub pixel_w: u32,
    pub pixel_h: u32,
    /// When the picture was taken; 0 means the cache's `written_at_ms`.
    #[serde(skip_serializing_if = "is_zero")]
    pub captured_at_ms: u64,
}

fn is_zero(v: &u64) -> bool {
    *v == 0
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Leaf {
    pub pane_id: String,
    pub kind: PaneKind,
    /// Content points, top-left origin, in the window's content view.
    pub frame: Rect,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scroll: Option<Scroll>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalGrid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat: Option<ChatAnchor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_content: Option<LastContent>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Split {
    pub axis: Axis,
    /// One per child, summing to 1.
    pub fractions: Vec<f64>,
    pub children: Vec<PaneNode>,
}

/// A window's split tree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PaneNode {
    Split(Split),
    Leaf(Leaf),
}

impl Default for PaneNode {
    fn default() -> Self {
        PaneNode::Leaf(Leaf::default())
    }
}

impl PaneNode {
    /// Every leaf, in tree order.
    pub fn leaves(&self) -> Vec<&Leaf> {
        let mut out = Vec::new();
        fn walk<'a>(n: &'a PaneNode, out: &mut Vec<&'a Leaf>) {
            match n {
                PaneNode::Leaf(l) => out.push(l),
                PaneNode::Split(s) => s.children.iter().for_each(|c| walk(c, out)),
            }
        }
        walk(self, &mut out);
        out
    }
    pub fn leaves_mut(&mut self) -> Vec<&mut Leaf> {
        let mut out = Vec::new();
        fn walk<'a>(n: &'a mut PaneNode, out: &mut Vec<&'a mut Leaf>) {
            match n {
                PaneNode::Leaf(l) => out.push(l),
                PaneNode::Split(s) => s.children.iter_mut().for_each(|c| walk(c, out)),
            }
        }
        walk(self, &mut out);
        out
    }
    /// The bounding box of every leaf's frame: the space the node occupies.
    pub fn bounds(&self) -> Option<Rect> {
        self.leaves().iter().map(|l| l.frame).reduce(|a, b| a.union(&b))
    }
    /// A tree the reconciler can trust: splits have as many finite positive fractions as
    /// children, at least one child, no deeper than `MAX_DEPTH`, frames finite, ids unique.
    pub fn is_well_formed(&self) -> bool {
        fn ok(n: &PaneNode, depth: usize) -> bool {
            if depth > MAX_DEPTH {
                return false;
            }
            match n {
                PaneNode::Leaf(l) => l.frame.is_finite(),
                PaneNode::Split(s) => {
                    !s.children.is_empty()
                        && s.fractions.len() == s.children.len()
                        && s.fractions.iter().all(|f| f.is_finite() && *f > 0.0)
                        && s.children.iter().all(|c| ok(c, depth + 1))
                }
            }
        }
        let ids = self.leaves().iter().map(|l| l.pane_id.as_str()).collect::<Vec<_>>();
        let unique = ids.iter().collect::<std::collections::HashSet<_>>().len() == ids.len();
        unique && ok(self, 0)
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct WindowLayout {
    pub id: String,
    /// AppKit global points.
    pub frame: Rect,
    pub display_id: u32,
    pub backing_scale: f64,
    pub fullscreen: bool,
    /// Window opacity, 0 to 1.
    pub alpha: f64,
    pub appearance: Appearance,
    pub theme: Theme,
    pub sidebar: Sidebar,
    pub workspace_id: String,
    pub tab_id: String,
    pub tab_strip: Vec<TabSlot>,
    pub panes: PaneNode,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LayoutCache {
    pub version: u32,
    /// The build that drew `last_content` pictures; geometry outlives it, pictures do not.
    pub build_key: String,
    pub written_at_ms: u64,
    pub displays: Vec<Display>,
    pub windows: Vec<WindowLayout>,
}

impl Default for LayoutCache {
    fn default() -> Self {
        Self {
            version: FORMAT_VERSION,
            build_key: String::new(),
            written_at_ms: 0,
            displays: Vec::new(),
            windows: Vec::new(),
        }
    }
}

impl LayoutCache {
    /// Parses a cache; None for garbage, a wrong version, or no well-formed window left. Windows
    /// with a malformed split tree or a non-finite frame are dropped one by one (the others still
    /// launch placed), and every list is cut to its cap.
    pub fn from_json(json: &str) -> Option<Self> {
        // An object only: serde would read `[]` as a struct of defaults.
        let value: serde_json::Value = serde_json::from_str(json).ok()?;
        if !value.is_object() {
            return None;
        }
        let cache: LayoutCache = serde_json::from_value(value).ok()?;
        if cache.version != FORMAT_VERSION {
            return None;
        }
        Some(cache.capped())
    }

    /// The cache as the store keeps it: caps applied, malformed windows dropped.
    pub fn capped(mut self) -> Self {
        self.windows.retain(|w| w.frame.is_finite() && w.panes.is_well_formed());
        self.windows.truncate(MAX_WINDOWS);
        for w in &mut self.windows {
            w.sidebar.row_heights.truncate(MAX_ROWS);
            w.tab_strip.truncate(MAX_TABS);
            for l in w.panes.leaves_mut() {
                if let Some(c) = &mut l.chat {
                    c.row_heights.truncate(MAX_ROWS);
                }
            }
        }
        self
    }

    /// The bytes that decide whether a write is needed: the JSON with `written_at_ms` cleared,
    /// so a change of clock alone never rewrites the file.
    pub fn content_bytes(&self) -> Vec<u8> {
        let mut c = self.clone();
        c.written_at_ms = 0;
        serde_json::to_vec(&c).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_fields_and_kinds_read() {
        let json = r#"{"version":1,"future":true,"windows":[{"id":"w","later":1,
            "panes":{"type":"leaf","pane_id":"p","kind":"hologram","frame":{"x":0,"y":0,"width":10,"height":10}}}]}"#;
        let c = LayoutCache::from_json(json).unwrap();
        assert_eq!(c.windows[0].panes.leaves()[0].kind, PaneKind::Other);
    }

    #[test]
    fn a_malformed_tree_drops_only_its_window() {
        let json = r#"{"version":1,"windows":[
            {"id":"bad","panes":{"type":"split","axis":"h","fractions":[1],"children":[]}},
            {"id":"good"}]}"#;
        let c = LayoutCache::from_json(json).unwrap();
        assert_eq!(c.windows.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(), ["good"]);
    }

    #[test]
    fn wrong_version_is_none() {
        assert!(LayoutCache::from_json(r#"{"version":2}"#).is_none());
        assert!(LayoutCache::from_json(r#"{}"#).is_some());
        assert!(LayoutCache::from_json("nonsense").is_none());
    }
}
