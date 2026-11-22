//! The `overflow` check: whether a widget's scene fits the tile it was mounted at.
//!
//! There is no layout engine here, so the sizes are estimates from the scene alone: a Text is
//! its character count times a width per character for its size and weight (about 0.55 of the
//! size, 0.58 semibold or bolder, 0.6 monospaced), one line is 1.2 times the size; stacks add
//! their children and spacing (8 by default), a fixed `frame` wins, and the controls take the
//! heights the host draws them at. The estimate errs short, so a finding means a real overflow
//! is likely; a scene that passes can still be cut by a long word or a wide glyph.
//!
//! The content box is the tile ([`Tile`]: the New Tab grid's 148 pt unit) less the 16 pt inset
//! the SDK's `WidgetFrame` draws on each side, or less the root's own `padding` when it sets one.
//!
//! - A Text with a line limit whose words need more lines than the limit at this size: cut.
//! - The root's content taller than the content box: the bottom is clipped by the tile.

use std::collections::BTreeMap;

use serde_json::Value;

use super::design::{Findings, Tile, number};
use super::scene::Node;

/// Width per character, as a fraction of the font size.
const REGULAR_EM: f64 = 0.55;
const BOLD_EM: f64 = 0.58;
const MONO_EM: f64 = 0.6;
/// One line's height, as a multiple of the font size.
const LINE_HEIGHT: f64 = 1.2;
/// A stack's spacing when it sets none (SwiftUI's default).
const STACK_SPACING: f64 = 8.0;
/// Points the content may run past the box before it counts (rounding in the estimate).
const TOLERANCE: f64 = 4.0;
/// Depth past which the estimate stops descending (the runtime's own cap).
const MAX_DEPTH: usize = 64;

/// Apple's text styles, in points, for a `font` given by name.
const STYLES: [(&str, f64); 11] = [
    ("largeTitle", 34.0),
    ("title", 28.0),
    ("title2", 22.0),
    ("title3", 20.0),
    ("headline", 17.0),
    ("body", 17.0),
    ("callout", 16.0),
    ("subheadline", 15.0),
    ("footnote", 13.0),
    ("caption", 12.0),
    ("caption2", 11.0),
];

#[derive(Debug, Clone, Copy, PartialEq)]
struct Size {
    width: f64,
    height: f64,
}

const ZERO: Size = Size { width: 0.0, height: 0.0 };

/// Adds the `overflow` findings for the scene at `root` drawn in `tile`.
pub(super) fn overflow(
    root: &str,
    nodes: &BTreeMap<String, Node>,
    tile: &Tile,
    findings: &mut Findings,
) {
    let Some(node) = nodes.get(root) else { return };
    let [top, leading, bottom, trailing] = match padding(node) {
        [0.0, 0.0, 0.0, 0.0] => [tile.inset; 4],
        edges => edges,
    };
    let width = tile.width - leading - trailing;
    let height = tile.height - top - bottom;
    let mut layout = Layout { nodes, findings, size: &tile.size };
    let content = layout.content(node, width, 0, true);
    if content.height > height + TOLERANCE {
        layout.findings.add(
            "overflow",
            Some(node),
            format!(
                "the content is about {:.0} pt tall and a {} tile has {:.0} pt inside its inset: the bottom is cut off",
                content.height, tile.size, height
            ),
            "show less at this size: read ctx.size and drop rows or the secondary lines (or declare only the sizes it fits in options.sizes)".into(),
        );
    }
}

struct Layout<'a> {
    nodes: &'a BTreeMap<String, Node>,
    findings: &'a mut Findings,
    size: &'a str,
}

impl Layout<'_> {
    /// The node's size in `width`, padding and fixed frame included.
    fn measure(&mut self, node: &Node, width: f64, depth: usize) -> Size {
        let [top, leading, bottom, trailing] = padding(node);
        let frame = node.props.get("frame").and_then(Value::as_object);
        let fixed = |key: &str| frame.and_then(|f| number(f.get(key)));
        let fills =
            frame.and_then(|f| f.get("maxWidth")).and_then(Value::as_str) == Some("infinity");
        let outer = fixed("width").unwrap_or(width);
        let inner = (outer - leading - trailing).max(0.0);
        let content = self.content(node, inner, depth, false);
        let mut size = Size {
            width: content.width + leading + trailing,
            height: content.height + top + bottom,
        };
        if fills {
            size.width = width;
        }
        if let Some(w) = fixed("width") {
            size.width = w;
        }
        if let Some(h) = fixed("height") {
            size.height = h;
        }
        if let Some(h) = fixed("minHeight") {
            size.height = size.height.max(h);
        }
        size
    }

    /// The node's content in `width`, its own padding and frame left out.
    fn content(&mut self, node: &Node, width: f64, depth: usize, root: bool) -> Size {
        if depth > MAX_DEPTH {
            return ZERO;
        }
        let gap = number(node.props.get("spacing")).unwrap_or(STACK_SPACING);
        match node.kind.as_str() {
            "Text" => self.text(node, width),
            "HStack" => self.row(&node.children, width, gap, depth),
            "ZStack" => {
                let mut size = ZERO;
                let nodes = self.nodes;
                for child in node.children.iter().filter_map(|id| nodes.get(id)) {
                    // A positioned child does not size the stack.
                    if child.props.contains_key("position") {
                        continue;
                    }
                    let s = self.measure(child, width, depth + 1);
                    size =
                        Size { width: size.width.max(s.width), height: size.height.max(s.height) };
                }
                size
            }
            "Spacer" => ZERO,
            "Divider" | "Line" => Size { width, height: 1.0 },
            "Icon" | "Image" => {
                let side = number(node.props.get("size")).unwrap_or(16.0);
                Size { width: side, height: side }
            }
            "Badge" => {
                Size { width: words(node).chars().count() as f64 * 7.0 + 12.0, height: 18.0 }
            }
            "Button" | "Menu" if node.children.is_empty() => {
                Size { width: words(node).chars().count() as f64 * 7.0 + 20.0, height: 24.0 }
            }
            "Toggle" => Size { width: 38.0, height: 22.0 },
            "Slider" | "TextField" => Size { width, height: 24.0 },
            "ProgressView" => Size { width, height: 6.0 },
            "Row" => {
                let inner = self.column(&node.children, width, 4.0, depth);
                Size { width, height: inner.height.max(28.0) }
            }
            "EmptyState" => Size { width, height: 60.0 },
            "Circle" | "Rectangle" | "RoundedRectangle" | "Capsule" => ZERO,
            _ => {
                let mut size = self.column(&node.children, width, gap, depth);
                // A nested Panel draws its own inset; the root one is the tile's.
                if node.kind == "Panel" && !root {
                    size.height += 24.0;
                    size.width += 24.0;
                }
                size
            }
        }
    }

    fn column(&mut self, ids: &[String], width: f64, gap: f64, depth: usize) -> Size {
        let nodes = self.nodes;
        let children: Vec<&Node> = ids.iter().filter_map(|id| nodes.get(id)).collect();
        let mut size = ZERO;
        for (i, child) in children.iter().enumerate() {
            let s = self.measure(child, width, depth + 1);
            size.width = size.width.max(s.width);
            size.height += s.height + if i > 0 { gap } else { 0.0 };
        }
        size
    }

    /// An HStack: the children that are not Text take their own width; the Texts share what is
    /// left, each in proportion to the width it wants.
    fn row(&mut self, ids: &[String], width: f64, gap: f64, depth: usize) -> Size {
        let nodes = self.nodes;
        let children: Vec<&Node> = ids.iter().filter_map(|id| nodes.get(id)).collect();
        let gaps = gap * children.len().saturating_sub(1) as f64;
        let mut fixed = 0.0;
        let mut wanted = 0.0;
        for child in &children {
            if child.kind == "Text" && number(frame_of(child, "width")).is_none() {
                wanted += natural(child).0;
            } else if child.kind != "Spacer" {
                fixed += self.measure_quiet(child, width, depth + 1).width;
            }
        }
        let room = (width - fixed - gaps).max(0.0);
        let mut size = Size { width: fixed + gaps, height: 0.0 };
        for child in &children {
            let s = if child.kind == "Text" && number(frame_of(child, "width")).is_none() {
                let want = natural(child).0;
                let share = if wanted > 0.0 { room * want / wanted } else { room };
                let s = self.measure(child, share.min(room), depth + 1);
                size.width += s.width;
                s
            } else {
                self.measure(child, width, depth + 1)
            };
            size.height = size.height.max(s.height);
        }
        size
    }

    /// A measure that reports nothing: the row's first pass, before the room is known.
    fn measure_quiet(&mut self, node: &Node, width: f64, depth: usize) -> Size {
        let mut quiet = Findings::default();
        let mut layout = Layout { nodes: self.nodes, findings: &mut quiet, size: self.size };
        layout.measure(node, width, depth)
    }

    fn text(&mut self, node: &Node, width: f64) -> Size {
        let (wants, points) = natural(node);
        let line = points * LINE_HEIGHT;
        if width <= 0.0 || wants <= 0.0 {
            return Size { width: 0.0, height: line };
        }
        let needs = (wants / width).ceil().max(1.0);
        let limit = number(node.props.get("lineLimit"));
        if let Some(limit) = limit
            && needs > limit
        {
            let text = words(node);
            self.findings.add(
                "overflow",
                Some(node),
                format!(
                    "\"{}\" needs about {needs:.0} lines of {width:.0} pt at {points} pt in a {} tile and its line limit is {limit}: it is cut off",
                    cut(&text),
                    self.size
                ),
                "show less at this size (read ctx.size), allow .lineLimit(2), or use a smaller type role".into(),
            );
        }
        let lines = limit.map_or(needs, |l| needs.min(l.max(1.0)));
        Size { width: wants.min(width), height: lines * line }
    }
}

/// A Text's width on one line and its font size, in points.
fn natural(node: &Node) -> (f64, f64) {
    let points = match node.props.get("font") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(13.0),
        Some(Value::String(name)) => {
            STYLES.iter().find(|(n, _)| n == name).map_or(13.0, |(_, size)| *size)
        }
        _ => 13.0,
    };
    let weight = node.props.get("weight").and_then(Value::as_str).unwrap_or("");
    let em = if node.props.get("monospaced").and_then(Value::as_bool) == Some(true) {
        MONO_EM
    } else if matches!(weight, "semibold" | "bold" | "heavy" | "black") {
        BOLD_EM
    } else {
        REGULAR_EM
    };
    (words(node).chars().count() as f64 * points * em, points)
}

/// The words a node draws.
pub(super) fn words(node: &Node) -> String {
    ["text", "title", "label"]
        .iter()
        .find_map(|key| node.props.get(*key).and_then(Value::as_str))
        .unwrap_or("")
        .to_string()
}

fn cut(text: &str) -> String {
    if text.chars().count() > 40 {
        format!("{}...", text.chars().take(40).collect::<String>())
    } else {
        text.to_string()
    }
}

fn frame_of<'a>(node: &'a Node, key: &str) -> Option<&'a Value> {
    node.props.get("frame")?.as_object()?.get(key)
}

/// A node's padding as top, leading, bottom, trailing.
fn padding(node: &Node) -> [f64; 4] {
    let mut edges = match node.props.get("padding") {
        Some(Value::Number(n)) => [n.as_f64().unwrap_or(0.0); 4],
        Some(Value::Object(sides)) => {
            let side = |key: &str| number(sides.get(key)).unwrap_or(0.0);
            [side("top"), side("leading"), side("bottom"), side("trailing")]
        }
        _ => [0.0; 4],
    };
    if let Some(h) = number(node.props.get("paddingHorizontal")) {
        edges[1] = h;
        edges[3] = h;
    }
    if let Some(v) = number(node.props.get("paddingVertical")) {
        edges[0] = v;
        edges[2] = v;
    }
    edges
}
