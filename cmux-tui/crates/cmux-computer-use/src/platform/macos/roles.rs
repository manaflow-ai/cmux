//! Accessibility roles and actions as plain names (`AXButton` -> `button`,
//! `AXShowMenu` -> `show_menu`) and back, plus the small geometry helpers the
//! desktop needs. Pure, so it is unit tested.

use crate::desktop::{Point, Rect};

/// `AXFooBarBaz` -> `foo_bar_baz`. Text without the `AX` prefix (custom
/// action names) is lowercased the same way.
pub fn snake(ax: &str) -> String {
    let name = ax.strip_prefix("AX").unwrap_or(ax);
    let mut out = String::with_capacity(name.len() + 4);
    let chars: Vec<char> = name.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if c.is_ascii_uppercase() {
            let prev_lower =
                i > 0 && (chars[i - 1].is_ascii_lowercase() || chars[i - 1].is_ascii_digit());
            let next_lower = chars.get(i + 1).is_some_and(char::is_ascii_lowercase);
            let prev_upper = i > 0 && chars[i - 1].is_ascii_uppercase();
            if i > 0 && (prev_lower || (prev_upper && next_lower)) && !out.ends_with('_') {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else if c.is_alphanumeric() {
            out.push(*c);
        } else if !out.is_empty() && !out.ends_with('_') {
            out.push('_');
        }
    }
    while out.ends_with('_') {
        out.pop();
    }
    out
}

/// `foo_bar` -> `AXFooBar`.
pub fn pascal_ax(plain: &str) -> String {
    let mut out = String::from("AX");
    for part in plain.split('_').filter(|p| !p.is_empty()) {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.push(first.to_ascii_uppercase());
            out.extend(chars);
        }
    }
    out
}

/// Subroles that say more than their role (a secure field is still an
/// `AXTextField`).
const MEANINGFUL_SUBROLES: &[&str] = &[
    "AXSecureTextField",
    "AXSearchField",
    "AXCloseButton",
    "AXMinimizeButton",
    "AXZoomButton",
    "AXFullScreenButton",
    "AXToolbarButton",
    "AXTabButton",
    "AXSwitch",
    "AXToggle",
    "AXDialog",
    "AXSystemDialog",
    "AXFloatingWindow",
    "AXOutlineRow",
    "AXTableRow",
    "AXSortButton",
    "AXIncrementArrow",
    "AXDecrementArrow",
    "AXTextAttachment",
    "AXTextLink",
];

/// The plain role of an element.
pub fn role_name(role: &str, subrole: Option<&str>) -> String {
    if let Some(sub) = subrole.filter(|s| MEANINGFUL_SUBROLES.contains(s)) {
        return snake(sub);
    }
    match role {
        "" => "unknown".into(),
        "AXIncrementor" => "stepper".into(),
        "AXProgressIndicator" | "AXBusyIndicator" => "progress".into(),
        "AXStaticText" => "text".into(),
        "AXPopUpButton" => "popup_button".into(),
        "AXCheckBox" => "checkbox".into(),
        "AXRadioButton" => "radio".into(),
        other => snake(other),
    }
}

/// Roles whose value is text the person edits.
pub fn is_text_input(role: &str) -> bool {
    matches!(role, "AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField")
}

pub fn is_secure(role: &str, subrole: Option<&str>) -> bool {
    subrole == Some("AXSecureTextField") || role == "AXSecureTextField"
}

/// AX actions never offered to agents in the background: `AXRaise` brings a
/// window in front of the person's work.
pub fn is_foreground_action(ax: &str) -> bool {
    ax == "AXRaise"
}

/// An AX action name as the plain name agents see. Custom actions
/// (`Name:Reply\nTarget:...`) keep their name part.
pub fn action_name(ax: &str) -> String {
    if let Some(rest) = ax.strip_prefix("Name:") {
        let name = rest.split('\n').next().unwrap_or(rest);
        return name.to_string();
    }
    snake(ax)
}

/// Actions that are attribute writes rather than AX actions: the plain
/// name, the attribute and the value written.
pub fn attribute_action(plain: &str) -> Option<(&'static str, bool)> {
    Some(match plain {
        "expand" => ("AXExpanded", true),
        "collapse" => ("AXExpanded", false),
        "select" => ("AXSelected", true),
        "focus" => ("AXFocused", true),
        _ => return None,
    })
}

/// The AX action an agent's name refers to among the element's actions:
/// exact AX name, the plain name, or a custom action's name.
pub fn resolve_action<'a>(requested: &str, available: &'a [String]) -> Option<&'a String> {
    let wanted = requested.trim();
    available.iter().find(|ax| {
        ax.as_str() == wanted
            || action_name(ax) == wanted
            || action_name(ax).eq_ignore_ascii_case(wanted)
            || pascal_ax(wanted) == ax.as_str()
    })
}

pub fn center(r: &Rect) -> Point {
    Point { x: r.x + r.width / 2.0, y: r.y + r.height / 2.0 }
}

/// Whether a global point lies in a rect (edges included, half a point of
/// slack for rounding of screenshot pixels).
pub fn contains(r: &Rect, p: Point) -> bool {
    const SLACK: f64 = 0.5;
    p.x >= r.x - SLACK
        && p.y >= r.y - SLACK
        && p.x <= r.x + r.width + SLACK
        && p.y <= r.y + r.height + SLACK
}

/// Clamps a point into a rect (after `contains` passed with slack).
pub fn clamp_into(r: &Rect, p: Point) -> Point {
    Point {
        x: p.x.clamp(r.x, r.x + (r.width - 1.0).max(0.0)),
        y: p.y.clamp(r.y, r.y + (r.height - 1.0).max(0.0)),
    }
}

/// Points along a drag, excluding `from` and including `to`: one per ~8
/// points of distance, at least 4 and at most 60.
pub fn drag_path(from: Point, to: Point) -> Vec<Point> {
    let distance = ((to.x - from.x).powi(2) + (to.y - from.y).powi(2)).sqrt();
    let steps = ((distance / 8.0).ceil() as usize).clamp(4, 60);
    (1..=steps)
        .map(|i| {
            let t = i as f64 / steps as f64;
            Point { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t }
        })
        .collect()
}

/// Pixels per point of a captured image of a `points`-wide area.
pub fn scale_of(pixels: usize, points: f64) -> f64 {
    if points <= 0.0 { 1.0 } else { pixels as f64 / points }
}

/// Lines to scroll-wheel deltas: CG's positive wheel moves content toward
/// the top (scrolls up), so `dy > 0` (down) is a negative wheel. A nonzero
/// fraction rounds away from zero to at least one line.
pub fn wheel_deltas(dx: f64, dy: f64) -> (i32, i32) {
    let lines = |v: f64| -> i32 {
        if v == 0.0 || !v.is_finite() {
            0
        } else {
            let r = v.abs().ceil().min(10_000.0) as i32;
            if v > 0.0 { r } else { -r }
        }
    };
    (-lines(dy), -lines(dx))
}

/// Element ids: `<generation>.<index>`.
pub fn element_id(generation: u64, index: usize) -> String {
    format!("{generation}.{index}")
}

pub fn parse_element_id(id: &str) -> Option<(u64, usize)> {
    let (g, i) = id.trim().split_once('.')?;
    Some((g.parse().ok()?, i.parse().ok()?))
}
