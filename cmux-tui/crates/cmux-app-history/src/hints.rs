//! Window hints (`WindowHintTargets.swift`): which accessibility frames
//! become targets, and where a page's links sit in its web view. The app walks
//! the accessibility tree, converts coordinates and clicks.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

/// A rect as `[x, y, width, height]` (AppKit window coordinates).
pub type Rect = [f64; 4];

/// The smallest side a target keeps.
pub const MIN_SIDE: f64 = 4.0;

/// `CGRect.intersection`; nil when they do not meet (`CGRect.null`).
pub fn intersection(a: Rect, b: Rect) -> Option<Rect> {
    let (ax, ay, aw, ah) = standardized(a);
    let (bx, by, bw, bh) = standardized(b);
    let (x0, y0) = (ax.max(bx), ay.max(by));
    let (x1, y1) = ((ax + aw).min(bx + bw), (ay + ah).min(by + bh));
    (x1 >= x0 && y1 >= y0).then_some([x0, y0, x1 - x0, y1 - y0])
}

fn standardized([x, y, w, h]: Rect) -> (f64, f64, f64, f64) {
    (if w < 0.0 { x + w } else { x }, if h < 0.0 { y + h } else { y }, w.abs(), h.abs())
}

fn big_enough(rect: &Rect) -> bool {
    rect[2] >= MIN_SIDE && rect[3] >= MIN_SIDE
}

/// The accessibility frames that become targets, by index into `frames` (in walk
/// order): clipped to `bounds`, at least 4 by 4, one per rounded rect, at most `limit`.
/// Each kept index comes with its clipped rect.
pub fn accept(frames: &[Rect], bounds: Rect, limit: usize) -> Vec<(usize, Rect)> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for (index, frame) in frames.iter().enumerate() {
        if out.len() >= limit {
            break;
        }
        let Some(rect) = intersection(*frame, bounds).filter(big_enough) else { continue };
        let key = rect.map(|side| side.round() as i64);
        if seen.insert(key) {
            out.push((index, rect));
        }
    }
    out
}

/// One link the page's collect script found: its center and top-left corner in CSS pixels.
#[derive(Debug, Clone, Deserialize)]
pub struct PageLink {
    pub x: f64,
    pub y: f64,
    pub left: f64,
    pub top: f64,
    #[serde(default)]
    pub text: Option<String>,
}

/// The web view's geometry: zoom (page zoom times magnification), whether it is flipped, its height.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageView {
    pub zoom: f64,
    #[serde(default)]
    pub flipped: bool,
    pub height: f64,
}

/// One link's corners in the web view's own coordinates, for the app to convert to the window.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PagePoints {
    pub near: [f64; 2],
    pub far: [f64; 2],
    pub x: f64,
    pub y: f64,
    pub text: String,
}

/// The script's answer (JSON) as view-local corners: the far corner mirrors the near one
/// through the center. An answer that does not parse has no links.
pub fn page_points(answer: &str, view: PageView) -> Vec<PagePoints> {
    let Ok(links) = serde_json::from_str::<Vec<PageLink>>(answer) else { return Vec::new() };
    let point = |x: f64, y: f64| {
        [x * view.zoom, if view.flipped { y * view.zoom } else { view.height - y * view.zoom }]
    };
    links
        .into_iter()
        .map(|link| PagePoints {
            near: point(link.left, link.top),
            far: point(2.0 * link.x - link.left, 2.0 * link.y - link.top),
            x: link.x,
            y: link.y,
            text: link.text.unwrap_or_default(),
        })
        .collect()
}

/// A page link's target rect from its window-converted corners: the box between them, clipped, at least 4 by 4.
pub fn page_rect(near: [f64; 2], far: [f64; 2], clip: Rect) -> Option<Rect> {
    let rect = [
        near[0].min(far[0]),
        near[1].min(far[1]),
        (far[0] - near[0]).abs(),
        (far[1] - near[1]).abs(),
    ];
    intersection(rect, clip).filter(big_enough)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BOUNDS: Rect = [0.0, 0.0, 100.0, 100.0];

    #[test]
    fn intersection_is_cgrects() {
        assert_eq!(intersection([10.0, 10.0, 20.0, 20.0], BOUNDS), Some([10.0, 10.0, 20.0, 20.0]));
        assert_eq!(intersection([90.0, 90.0, 20.0, 20.0], BOUNDS), Some([90.0, 90.0, 10.0, 10.0]));
        assert_eq!(intersection([200.0, 0.0, 5.0, 5.0], BOUNDS), None);
        assert_eq!(intersection([100.0, 0.0, 5.0, 5.0], BOUNDS), Some([100.0, 0.0, 0.0, 5.0]));
        assert_eq!(
            intersection([30.0, 30.0, -20.0, -20.0], BOUNDS),
            Some([10.0, 10.0, 20.0, 20.0])
        );
    }

    #[test]
    fn accept_clips_drops_small_dedups_and_limits() {
        let frames = [
            [10.0, 10.0, 20.0, 20.0],
            [10.2, 9.8, 20.1, 19.9],    // the same rounded rect
            [98.0, 0.0, 10.0, 10.0],    // clipped to 2 wide
            [500.0, 500.0, 10.0, 10.0], // offscreen
            [40.0, 40.0, 4.0, 4.0],
            [60.0, 60.0, 8.0, 8.0],
        ];
        let kept = accept(&frames, BOUNDS, 10);
        assert_eq!(kept.iter().map(|(index, _)| *index).collect::<Vec<_>>(), vec![0, 4, 5]);
        assert_eq!(accept(&frames, BOUNDS, 2).len(), 2);
        assert!(accept(&frames, BOUNDS, 0).is_empty());
    }

    #[test]
    fn page_points_flip_and_zoom() {
        let answer =
            r#"[{"x":20,"y":10,"left":10,"top":5,"text":"Docs"},{"x":1,"y":1,"left":0,"top":0}]"#;
        let unflipped = page_points(answer, PageView { zoom: 2.0, flipped: false, height: 100.0 });
        assert_eq!(
            unflipped[0],
            PagePoints {
                near: [20.0, 90.0],
                far: [60.0, 70.0],
                x: 20.0,
                y: 10.0,
                text: "Docs".into()
            }
        );
        assert_eq!(unflipped[1].text, "");
        let flipped = page_points(answer, PageView { zoom: 1.0, flipped: true, height: 100.0 });
        assert_eq!(flipped[0].near, [10.0, 5.0]);
        assert_eq!(flipped[0].far, [30.0, 15.0]);
        assert!(page_points("not json", PageView::default()).is_empty());
        assert!(page_points("{}", PageView::default()).is_empty());
    }

    #[test]
    fn page_rect_boxes_clips_and_drops_small() {
        assert_eq!(page_rect([60.0, 70.0], [20.0, 90.0], BOUNDS), Some([20.0, 70.0, 40.0, 20.0]));
        assert_eq!(page_rect([0.0, 0.0], [3.0, 30.0], BOUNDS), None);
        assert_eq!(page_rect([98.0, 0.0], [130.0, 30.0], BOUNDS), None);
        assert_eq!(page_rect([200.0, 200.0], [230.0, 230.0], BOUNDS), None);
    }
}
