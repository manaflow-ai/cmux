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
/// window in front of the person's work; `AXShowMenu` opens a menu, and an
/// open menu tracks the person's real pointer and takes their keyboard (the
/// window server moves key focus to it) until it closes.
pub fn is_foreground_action(ax: &str) -> bool {
    matches!(ax, "AXRaise" | "AXShowMenu")
}

/// Whether pressing, clicking or keyboard-activating an element of `role`
/// opens a menu or list pop-up that takes the person's pointer and keyboard
/// while it is open. Inside web content (`in_web`) only a pop-up button with
/// a menu of its own (an HTML `<select>`, drawn as a native menu) does; an
/// ARIA menu button opens DOM content in the page.
pub fn opens_menu(role: &str, in_web: bool, has_menu: bool) -> bool {
    if in_web {
        return role == "AXPopUpButton" && has_menu;
    }
    matches!(
        role,
        "AXPopUpButton" | "AXMenuButton" | "AXComboBox" | "AXMenuBarItem" | "AXMenuExtra"
    )
}

/// Keys that open a focused pop-up or menu button (an editable combo box
/// only types them).
pub fn key_opens_menu(key: &crate::keys::Key) -> bool {
    use crate::keys::Key;
    matches!(key, Key::Space | Key::Return | Key::Up | Key::Down) || *key == Key::Char(' ')
}

/// Text whose typing opens a focused pop-up (a space or a newline).
pub fn text_opens_menu(text: &str) -> bool {
    text.contains([' ', '\n', '\r'])
}

/// Why a menu-opening element is refused in the background, and what to
/// use instead.
pub fn menu_refusal(role: &str) -> String {
    let name = role_name(role, None);
    let instead = match role {
        "AXPopUpButton" | "AXMenuButton" => {
            "use set_value with the title of the item to choose (it picks the item without opening the menu)"
        }
        "AXComboBox" => "use set_value or type_text with element_id to change its text",
        _ => "use perform_action on the item you want if the tree shows it",
    };
    format!(
        "this {name} opens a menu, and an open menu takes the person's pointer and keyboard until it closes, so it is not opened in the background; {instead}, or click it with delivery foreground"
    )
}

/// Why a context menu (right click, control-click) is refused in the background.
pub const CONTEXT_MENU_REFUSAL: &str = "a right click or control-click opens a context menu, and an open menu takes the person's pointer and keyboard until it closes, so it is not done in the background; use perform_action with the element's own actions (get_ui_tree lists them), or click with delivery foreground";

/// Whether the case-insensitive, trimmed titles match (a menu item for a
/// `set_value` on a pop-up).
pub fn same_title(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
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

/// The number `value` asks a stepping element for: its own unit ("0.25",
/// "12") or a percentage of its range ("25%"). None for anything else.
pub fn step_target(value: &str, min: f64, max: f64) -> Option<f64> {
    let text = value.trim();
    let target = if let Some(percent) = text.strip_suffix('%') {
        let p: f64 = percent.trim().parse().ok()?;
        min + (max - min) * p / 100.0
    } else {
        text.parse().ok()?
    };
    target.is_finite().then(|| target.clamp(min.min(max), max.max(min)))
}

/// Whether a stepped value is as close to the target as one step allows:
/// within 2% of the range.
pub fn step_reached(read: f64, target: f64, min: f64, max: f64) -> bool {
    (read - target).abs() <= ((max - min).abs() * 0.02).max(f64::EPSILON)
}

/// Where a menu item sits in an app's menu bar, for the deny list. Built from
/// structure, never from titles, so it holds in every language.
#[derive(Clone, Debug, Default)]
pub struct MenuItemContext<'a> {
    /// The item's title.
    pub title: &'a str,
    /// Index of the menu bar item it is under (0: the Apple menu, 1: the
    /// app's own menu, which holds Services).
    pub top_index: Option<usize>,
    /// How many menus it is inside: 1 for an item of a menu bar menu, 2 or
    /// more inside a submenu.
    pub depth: usize,
    /// The titles of the items in the same menu (the item's own included).
    pub siblings: &'a [String],
}

/// An item title as an app name: without a trailing "…" or "...", and
/// without a trailing " (…)" ("TextEdit (default)"). The second value says
/// whether that suffix was a version ("Xcode (16.4)"), which names one of
/// several installed copies.
pub fn menu_app_name(title: &str) -> (&str, bool) {
    let mut t = title.trim();
    t = t.strip_suffix('\u{2026}').or_else(|| t.strip_suffix("...")).unwrap_or(t).trim_end();
    if t.ends_with(')')
        && let Some(i) = t.rfind(" (")
    {
        let inner = &t[i + 2..t.len() - 1];
        let version = !inner.is_empty() && inner.chars().all(|c| c.is_ascii_digit() || c == '.');
        return (t[..i].trim_end(), version);
    }
    (t, false)
}

/// The app names a menu item title could start with: the whole title, and
/// the title cut at each "…", "...", ", ", " (" and " – " (one to four
/// candidates, longest first, each trimmed).
pub fn menu_name_candidates(title: &str) -> Vec<&str> {
    let t = title.trim();
    let mut out = vec![menu_app_name(t).0];
    for sep in ["\u{2026}", "...", ", ", " (", " \u{2013} ", " - "] {
        if let Some(i) = t.find(sep) {
            let head = menu_app_name(&t[..i]).0;
            if !head.is_empty() && !out.contains(&head) {
                out.push(head);
            }
        }
    }
    out
}

/// Whether a submenu is a launch list: under the Apple menu (Recent Items:
/// apps, documents, servers) or the app menu (Services), or one where most
/// items name installed apps (Open With in any app and any language).
pub fn is_launch_list(ctx: &MenuItemContext, resolve: &dyn Fn(&str) -> Option<Vec<String>>) -> bool {
    if ctx.depth < 2 {
        return false;
    }
    if matches!(ctx.top_index, Some(0 | 1)) {
        return true;
    }
    let named: Vec<&String> = ctx.siblings.iter().filter(|t| !t.trim().is_empty()).collect();
    let apps = named.iter().filter(|t| resolve(menu_app_name(t).0).is_some_and(|ids| !ids.is_empty())).count();
    named.len() >= 2 && apps * 2 >= named.len()
}

/// Whether the deny list hides and refuses a menu item. `resolve` gives the
/// bundle ids of every installed app with a display name (in any language),
/// several for a shared name, none for an unknown one.
/// - In any menu, an item whose title names an app is blocked when any app
///   of that name is denied or protected ("System Settings…", "Terminal",
///   "Benutzte Objekte > Terminal").
/// - In a launch list (Recent Items, Services, Open With), while any app is
///   denied, an item that names no app, names it only by version, or is a
///   document or service is blocked too: it could reach a denied app.
pub fn menu_item_blocked(
    guard: &dyn crate::desktop::MenuGuard,
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    let (name, version) = menu_app_name(ctx.title);
    if name.is_empty() {
        return false;
    }
    // Menus add text after an app's name ("System Settings…, 1 update"):
    // every leading part of the title is checked, so none hides an app.
    for candidate in menu_name_candidates(ctx.title) {
        if guard.app_blocked("", candidate) {
            return true;
        }
        match resolve(candidate) {
            // The name index is still being built: fail closed while any
            // app is denied.
            None => return guard.denies_any(),
            Some(ids) if ids.iter().any(|id| guard.app_blocked(id, candidate)) => return true,
            Some(_) => {}
        }
    }
    let ids = resolve(name).unwrap_or_default();
    guard.denies_any() && is_launch_list(ctx, resolve) && (ids.is_empty() || version || ids.len() > 1)
}

/// Why pressing a menu-bar element is refused, if it is: one that opens a
/// submenu would open a menu over the person's screen.
pub fn submenu_refusal(role: &str, has_submenu: bool) -> Option<&'static str> {
    (role == "AXMenuItem" && has_submenu).then_some(
        "this menu item opens a submenu; press one of the submenu's items (they are in the tree under it)",
    )
}

/// A key-equivalent match found while searching the menus in AppKit's order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShortcutMatch {
    pub title: String,
    pub enabled: bool,
    pub blocked: bool,
}

/// What a shortcut does, given its matches in menu order (depth-first).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShortcutPick {
    /// Press the match at this index.
    Press(usize),
    /// The first enabled match is blocked: AppKit would run it, so nothing runs.
    Blocked(String),
    /// Only disabled matches.
    Disabled(String),
    /// No match.
    None,
}

/// AppKit runs the first enabled item with the key equivalent; disabled
/// ones are passed over. A blocked first enabled match refuses the shortcut
/// (a later item must not run in its place).
pub fn pick_shortcut(matches: &[ShortcutMatch]) -> ShortcutPick {
    if let Some((i, m)) = matches.iter().enumerate().find(|(_, m)| m.enabled) {
        return if m.blocked { ShortcutPick::Blocked(m.title.clone()) } else { ShortcutPick::Press(i) };
    }
    match matches.first() {
        Some(m) => ShortcutPick::Disabled(m.title.clone()),
        None => ShortcutPick::None,
    }
}

/// Whether a chord the menu search did not find may still be posted as key
/// events: yes, unless it is a registered Services shortcut while any app is
/// denied (AppKit would run that service, which can hand the selection to a
/// denied app). Page shortcuts (a web app's cmd+shift+7) are posted, as
/// Codex does.
pub fn unmatched_chord_allowed(is_service_shortcut: bool, denies_any: bool) -> bool {
    !(is_service_shortcut && denies_any)
}

/// The NSKeyEquivalent "default" values in `pbs -dump` output (one per
/// service that has a shortcut).
pub fn service_equivalents(dump: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = dump;
    while let Some(i) = rest.find("NSKeyEquivalent") {
        rest = &rest[i..];
        let Some(open) = rest.find('{') else { break };
        let Some(close) = rest[open..].find('}') else { break };
        let body = &rest[open + 1..open + close];
        if let Some(d) = body.find("default") {
            let value = body[d + "default".len()..]
                .trim_start()
                .trim_start_matches('=')
                .trim()
                .trim_end_matches(';')
                .trim()
                .trim_matches('"');
            // A key equivalent is a few modifier marks and one key; longer
            // values are menu titles that this dump also files here.
            if !value.is_empty() && value.chars().count() <= 5 {
                out.push(value.to_string());
            }
        }
        rest = &rest[open + close..];
    }
    out
}

/// Whether background keys may go to the target window: it is the key
/// window, or the app's only standard window while no other unminimized
/// window (a dialog, a panel) is the key window.
pub fn keys_reach_target(
    is_key: bool,
    standard_windows: usize,
    target_is_standard: bool,
    other_key_window: bool,
) -> bool {
    is_key || (standard_windows <= 1 && target_is_standard && !other_key_window)
}

/// One step of stepping a value toward `target`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Step {
    /// Keep stepping from `next`.
    Continue,
    /// The value did not move: the end of the range.
    AtEnd,
    /// The step passed the target; `back` says whether to step back (the
    /// previous value was nearer).
    Passed { back: bool },
    /// The step moved away from the target.
    Away,
}

pub fn step_outcome(current: f64, next: f64, target: f64, going_up: bool) -> Step {
    if (next - current).abs() < f64::EPSILON {
        return Step::AtEnd;
    }
    if (next > current) != going_up {
        return Step::Away;
    }
    let passed = if going_up { next > target } else { next < target };
    if passed {
        return Step::Passed { back: (next - target).abs() > (current - target).abs() };
    }
    Step::Continue
}

/// Whether a stepped value is reported confirmed: the stepping ended on its
/// own (not at the step cap) within one step of the target.
pub fn step_confirmed(capped: bool, read: f64, target: f64, min: f64, max: f64) -> bool {
    !capped && step_reached(read, target, min, max)
}

/// One node kept by [`breadth_first`]: its parent's slot and its depth.
pub struct BfsSlot<N> {
    pub node: N,
    pub parent: Option<usize>,
    pub depth: usize,
}

/// Breadth-first from `root`, keeping at most `budget` nodes and not
/// expanding below `max_depth` levels. `visit` returns a node's children
/// (kept) or None (left out with everything under it). The bool says whether
/// the budget or the depth cut the walk short.
pub fn breadth_first<N>(
    root: N,
    budget: usize,
    max_depth: usize,
    mut visit: impl FnMut(&N, usize) -> Option<Vec<N>>,
) -> (Vec<BfsSlot<N>>, bool) {
    let mut slots: Vec<BfsSlot<N>> = Vec::new();
    let mut truncated = false;
    let mut queue = std::collections::VecDeque::new();
    queue.push_back((root, None::<usize>, 0usize));
    while let Some((node, parent, depth)) = queue.pop_front() {
        if slots.len() >= budget {
            truncated = true;
            break;
        }
        let Some(children) = visit(&node, depth) else { continue };
        let slot = slots.len();
        slots.push(BfsSlot { node, parent, depth });
        if children.is_empty() {
            continue;
        }
        if depth + 1 >= max_depth {
            truncated = true;
            continue;
        }
        for child in children {
            queue.push_back((child, Some(slot), depth + 1));
        }
    }
    (slots, truncated)
}
