//! Checks before an action that would do nothing, or something else than
//! the agent means. Each is decided from a tree of the window (global
//! frames) and returns a precise refusal with what to do instead; an action
//! that passes them runs as before. `force: true` skips them.
//!
//! The checks only refuse on positive evidence: a window the tree cannot
//! describe (no frames, a truncated walk, no text fields at all) is let
//! through, because refusing a working action is as wrong as a false success.

use crate::desktop::{Element, Point, Rect};

use super::outline::{clip, quote};

/// A guard's refusal: its code and what to tell the agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

fn refuse(code: &'static str, message: String) -> Option<Refusal> {
    Some(Refusal { code, message })
}

/// How tall a title bar is (macOS: 28 pt; a unified toolbar is taller, and
/// its controls are elements the hit test finds).
pub const TITLE_BAR: f64 = 28.0;

/// Roles that take no typed text: keys typed while one has focus press it
/// (Space) or do nothing.
pub fn is_non_text(role: &str) -> bool {
    matches!(
        role,
        "button"
            | "push_button"
            | "push button"
            | "checkbox"
            | "check_box"
            | "check box"
            | "radio"
            | "radio_button"
            | "radio button"
            | "popup_button"
            | "menu_button"
            | "slider"
            | "stepper"
            | "tab"
            | "tab_item"
            | "tab_button"
            | "link"
            | "hyperlink"
            | "switch"
            | "toggle"
            | "toggle_button"
            | "toggle button"
            | "disclosure_triangle"
            | "image"
            | "menu_item"
            | "menu item"
            | "menu_bar_item"
            | "color_well"
            | "close_button"
            | "minimize_button"
            | "zoom_button"
            | "full_screen_button"
            | "toolbar_button"
            | "split_button"
    )
}

/// Roles that take typed text.
pub fn is_text_input(role: &str) -> bool {
    matches!(
        role,
        "text_field"
            | "text_area"
            | "search_field"
            | "secure_text_field"
            | "combo_box"
            | "edit"
            | "entry"
            | "password_text"
            | "password text"
            | "spin_button"
    )
}

fn named(e: &Element) -> String {
    let role = e.role.replace('_', " ");
    if e.name.trim().is_empty() {
        role
    } else {
        format!("{role} {}", quote(&clip(e.name.trim(), 60)))
    }
}

fn walk<'a>(e: &'a Element, f: &mut dyn FnMut(&'a Element)) {
    f(e);
    for c in &e.children {
        walk(c, f);
    }
}

/// The deepest focused element.
pub fn focused(root: &Element) -> Option<&Element> {
    fn go<'a>(e: &'a Element, best: &mut Option<&'a Element>) {
        if e.focused {
            *best = Some(e);
        }
        for c in &e.children {
            if c.role != super::ids::MENU_BAR {
                go(c, best);
            }
        }
    }
    let mut best = None;
    go(root, &mut best);
    best
}

/// The window's enabled text inputs (outside the menu bar), first `max`.
fn text_inputs(root: &Element, max: usize) -> Vec<&Element> {
    let mut out = Vec::new();
    for c in root.children.iter().filter(|c| c.role != super::ids::MENU_BAR) {
        walk(c, &mut |e| {
            if out.len() < max && is_text_input(&e.role) && !e.disabled {
                out.push(e);
            }
        });
    }
    out
}

/// Roles a focused one of which takes keys as commands, not text, in a native
/// window: Space toggles a checkbox, arrows move a slider. Buttons and links
/// are left out: web apps keep focus on them while their own key handlers
/// take the text.
fn takes_keys_as_commands(role: &str) -> bool {
    matches!(
        role,
        "checkbox"
            | "check_box"
            | "check box"
            | "radio"
            | "radio_button"
            | "radio button"
            | "popup_button"
            | "menu_button"
            | "slider"
            | "stepper"
            | "switch"
            | "toggle"
            | "toggle_button"
            | "toggle button"
            | "disclosure_triangle"
            | "color_well"
            | "tab"
            | "tab_item"
    )
}

/// Whether `target` lies inside a web area of `root`.
fn in_web(root: &Element, target: &Element) -> bool {
    fn go(e: &Element, target: &Element, web: bool) -> Option<bool> {
        let web = web || e.role == "web_area";
        if std::ptr::eq(e, target) {
            return Some(web);
        }
        e.children.iter().find_map(|c| go(c, target, web))
    }
    go(root, target, false).unwrap_or(false)
}

/// type_text with no element_id: the text goes to the window's focused
/// element. Refused only when that is a native control that takes keys as
/// commands (Space would toggle it, arrows move it). No reported focus, a
/// focused button or link, and anything in web content are let through: the
/// state after typing shows whether the text landed.
pub fn typing_without_target(window: &str, root: &Element, _truncated: bool) -> Option<Refusal> {
    let fields = text_inputs(root, 4);
    let list =
        fields.iter().map(|e| format!("[{}] {}", e.id, named(e))).collect::<Vec<_>>().join(", ");
    match focused(root) {
        Some(f) if takes_keys_as_commands(&f.role) && !in_web(root, f) => refuse(
            "focus_not_on_text",
            format!(
                "keyboard focus in window {window} is on [{}] {}, which takes keys as commands, not text: typing there would toggle or move it. Pass element_id of the field to type into{} (it is focused through accessibility first), or click the field first.",
                f.id,
                named(f),
                if list.is_empty() { String::new() } else { format!(" ({list})") }
            ),
        ),
        _ => None,
    }
}

/// type_text into `element`: refused when it is a control that takes no text.
pub fn typing_into(element: &Element) -> Option<Refusal> {
    is_non_text(&element.role).then(|| Refusal {
        code: "not_a_text_field",
        message: format!(
            "[{}] {} takes no typed text. Type into a text field (its element_id), use set_value for a value, or click to press it.",
            element.id,
            named(element)
        ),
    })
}

/// An action on a disabled element does nothing.
pub fn disabled(element: &Element) -> Option<Refusal> {
    element.disabled.then(|| Refusal {
        code: "element_disabled",
        message: format!(
            "[{}] {} is disabled (dimmed), so acting on it does nothing. Do what enables it first (for example fill the fields it needs), then check its state in the result before trying again.",
            element.id,
            named(element)
        ),
    })
}

fn contains(r: &Rect, p: Point) -> bool {
    p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height
}

fn intersect(a: &Rect, b: &Rect) -> Option<Rect> {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let r = (a.x + a.width).min(b.x + b.width);
    let btm = (a.y + a.height).min(b.y + b.height);
    (r > x && btm > y).then_some(Rect { x, y, width: r - x, height: btm - y })
}

/// Whether an element does something when clicked: an action, or a control.
fn clickable(e: &Element) -> bool {
    !e.actions.is_empty()
        || is_text_input(&e.role)
        || is_non_text(&e.role) && e.role != "image"
        || matches!(
            e.role.as_str(),
            "web_area" | "row" | "cell" | "list" | "table" | "outline" | "canvas"
        )
}

/// The deepest element under `p` that does something when clicked (outside
/// the menu bar), with its depth.
fn hit(root: &Element, p: Point) -> Option<&Element> {
    fn go<'a>(e: &'a Element, p: Point, best: &mut Option<&'a Element>) {
        for c in &e.children {
            if c.role == super::ids::MENU_BAR {
                continue;
            }
            let inside = c.frame.is_some_and(|f| contains(&f, p));
            if inside && clickable(c) {
                *best = Some(c);
            }
            // Children can lie outside an unframed or smaller parent.
            go(c, p, best);
        }
    }
    let mut best = None;
    go(root, p, &mut best);
    best
}

/// A background pixel click at global `p` in `window` (its tree `root`).
/// Refused outside the window, and on the title bar where nothing under the
/// point does anything (a background click there neither raises nor moves
/// the window).
pub fn pixel_click(
    window: &str,
    frame: &Rect,
    root: &Element,
    truncated: bool,
    p: Point,
    quartz: bool,
) -> Option<Refusal> {
    // A point of the screenshot's last pixel row or column maps onto the edge.
    let edge = Rect {
        x: frame.x - 1.0,
        y: frame.y - 1.0,
        width: frame.width + 2.0,
        height: frame.height + 2.0,
    };
    if !contains(&edge, p) {
        return refuse(
            "point_outside_window",
            format!(
                "that point is outside window {window} (pixels count from the top-left of your latest screenshot of it). Take a screenshot of the window and use its pixels, or pass element_id."
            ),
        );
    }
    if p.y >= frame.y + TITLE_BAR || truncated || !quartz {
        return None;
    }
    // Only a real title bar: the window's own close, minimize or zoom button
    // drawn in its top strip (a full-screen window, a hidden or custom-drawn
    // title bar has none there).
    let strip = frame.y + TITLE_BAR;
    let real = root.children.iter().any(|c| {
        matches!(
            c.role.as_str(),
            "close_button" | "minimize_button" | "zoom_button" | "full_screen_button"
        ) && c.frame.is_some_and(|f| f.y >= frame.y && f.y + f.height <= strip + 1.0)
    });
    if !real || hit(root, p).is_some() {
        return None;
    }
    refuse(
        "title_bar",
        format!(
            "that point is on window {window}'s title bar, where a background click does nothing (it would only raise or move the window, which background input never does). Click a control by element_id, or pass delivery foreground to bring the window to the front."
        ),
    )
}

/// A click on `element` that would land at its center, refused when that
/// center is out of view: outside the window or scrolled out of an
/// enclosing scroll area (`clips`: the frames of the window and of its
/// scroll areas above the element). An element with a press, pick or
/// confirm action is pressed through accessibility wherever it is.
pub fn offscreen(
    element: &Element,
    clips: &[(u32, Rect)],
    scroll_to_visible: bool,
) -> Option<Refusal> {
    let pressable = element.actions.iter().any(|a| {
        matches!(a.as_str(), "press" | "pick" | "confirm" | "click" | "invoke" | "activate")
    });
    if pressable {
        return None;
    }
    let frame = element.frame?;
    let mut visible = Some(frame);
    for (_, clip) in clips {
        visible = visible.and_then(|f| intersect(&f, clip));
    }
    if visible.is_some() {
        return None;
    }
    // The innermost scroll area (clips run from the window inward; id 0 is
    // the window itself).
    let area = clips.iter().rev().find(|(id, _)| *id != 0).map(|(id, _)| *id);
    let how = if scroll_to_visible {
        format!("perform_action scroll_to_visible on [{}]", element.id)
    } else {
        match area {
            Some(a) => format!("scroll [{a}] (scroll with its element_id) until it shows"),
            None => "scroll the window until it shows".into(),
        }
    };
    refuse(
        "element_offscreen",
        format!(
            "[{}] {} is out of view, so a click at it would land on something else. First {how}, then click it.",
            element.id,
            named(element)
        ),
    )
}
