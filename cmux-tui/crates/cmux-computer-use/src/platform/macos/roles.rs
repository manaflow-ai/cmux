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
/// window in front of the person's work. (`AXShowMenu` opens a context menu,
/// which `computerUse.menus` decides; see [`crate::menus`].)
pub fn is_foreground_action(ax: &str) -> bool {
    ax == "AXRaise"
}

/// Menu bar items and menu extras: their menus are the frontmost app's menu
/// bar, never opened in the background in any `computerUse.menus` mode.
pub fn is_menu_bar(role: &str) -> bool {
    matches!(role, "AXMenuBarItem" | "AXMenuExtra")
}

/// The AX action that opens an element's menu: its press, else its
/// show-menu action.
pub fn open_action(available: &[String]) -> Option<&'static str> {
    ["AXPress", "AXShowMenu"].into_iter().find(|a| available.iter().any(|x| x == a))
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
            "use set_value with the title of the item to choose (a pop-up that lists its items while closed is set without opening the menu)"
        }
        "AXComboBox" => "use set_value or type_text with element_id to change its text",
        _ => "use perform_action on the item you want if the tree shows it",
    };
    format!(
        "this {name} opens a menu, and Computer Use is set not to open menus in the background (Settings > Computer Use > Menus, computerUse.menus is \"refuse\"); {instead}, or click it with delivery foreground"
    )
}

/// Why a context menu (right click, control-click) is refused in the background.
pub const CONTEXT_MENU_REFUSAL: &str = "a right click, control-click or show_menu opens a context menu, and Computer Use is set not to open menus in the background (computerUse.menus is \"refuse\"); use perform_action with the element's own actions (get_ui_tree lists them), or click with delivery foreground";

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

/// Roles a plain click presses: what AXPress does is what the click does.
/// Pop-ups, menu buttons and combo boxes open menus (handled before), text
/// inputs take a caret, and containers hold what was meant.
const PRESS_ROLES: &[&str] = &[
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXLink",
    "AXDisclosureTriangle",
    "AXSwitch",
    "AXToggle",
    "AXMenuItem",
    "AXTab",
];

pub fn is_press_role(role: &str) -> bool {
    PRESS_ROLES.contains(&role)
}

/// A label or picture inside a control: the click is the control's.
pub fn is_label_role(role: &str) -> bool {
    matches!(role, "AXStaticText" | "AXImage")
}

/// How a plain background click on the element the point hits is done.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HitClick {
    /// Refused: the element is a menu item the deny list blocks.
    Refuse,
    /// AXPress on it.
    Press,
    /// Select its row (a list, table or outline row with no press).
    Select,
    /// Post the mouse events (text, canvas, web content, anything else).
    Events,
}

/// A text field in a row that is not selected counts as the row: a click in
/// a row selects it first (Finder's file name is a text field; AppKit tables
/// edit a cell only on a click in a row already selected, which gets the
/// events).
pub fn hit_click(role: &str, has_press: bool, in_unselected_row: bool, blocked: bool) -> HitClick {
    if blocked {
        HitClick::Refuse
    } else if has_press && is_press_role(role) {
        HitClick::Press
    } else if !has_press && in_unselected_row {
        HitClick::Select
    } else {
        HitClick::Events
    }
}

/// Whether the element a point hits may be acted on through accessibility:
/// the window is on screen (an off-screen window keeps refusing point
/// clicks) and the element is inside the target window (the app's hit test
/// can return a sibling window's element at an overlapping point).
pub fn hit_usable(on_screen: bool, in_target_window: bool) -> bool {
    on_screen && in_target_window
}

/// After a hit-test AXPress that returned `code`: fall back to the mouse
/// events only when the element did not take the press at all (unsupported
/// action or attribute, illegal argument). A timeout or "cannot complete"
/// may come back after the press ran (a modal loop, a menu that popped), so
/// posting a click too could act twice: that is reported as delivered.
pub fn press_error_falls_back(code: i32) -> bool {
    matches!(code, -25201 | -25205 | -25206)
}

/// Whether an item may be pressed inside a key-in-app scope (pure, for
/// tests): the scope is still live (not stopped, within its bound, the
/// person did not switch to the app), the app still reports the target as
/// its focused window, and the item is not a Services item (a Service runs
/// in another process against whatever the app hands it).
pub fn primed_press(
    live: bool,
    focus_on_target: bool,
    item_is_service: bool,
) -> Result<(), &'static str> {
    if !live {
        return Err("the target app came to the front, the call was stopped or the app did not answer in time while its menu item was being made available, so nothing was pressed");
    }
    if !focus_on_target {
        return Err("the target window stopped being its app's key window before the menu item was pressed (another window of the app took it), so nothing was pressed");
    }
    if item_is_service {
        return Err("the shortcut runs a Services item, which is never run from a background app's menu: nothing was pressed");
    }
    Ok(())
}

/// What a pid-routed mouse event carries to reach its window: the window
/// number (field 51) and the point inside the window (top-left origin),
/// when the window's origin is known. AppKit drops a posted mouse event
/// without both.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PidMouseStamp {
    pub window_number: i64,
    pub local: Option<Point>,
}

pub fn pid_mouse_stamp(window: u32, at: Point, origin: Option<Point>) -> PidMouseStamp {
    PidMouseStamp {
        window_number: i64::from(window),
        local: origin.map(|o| Point { x: at.x - o.x, y: at.y - o.y }),
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
    /// Whether its menu is a launch list by its items, when the caller
    /// worked that out once for the whole menu (else from `siblings`).
    pub launch: Option<bool>,
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

/// What a key does while a menu this desktop left open shows in its app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMenuKey {
    /// Escape: close the menu (through accessibility).
    Close,
    /// A bare arrow: it only moves the highlight.
    Post,
    /// Anything else could run or type-select an item, a hidden one too.
    Refuse,
}

pub fn key_with_open_menu(combo: &crate::keys::KeyCombo) -> OpenMenuKey {
    use crate::keys::Key;
    if !combo.modifiers.is_empty() {
        return OpenMenuKey::Refuse;
    }
    match combo.key {
        Key::Escape => OpenMenuKey::Close,
        Key::Up | Key::Down | Key::Left | Key::Right => OpenMenuKey::Post,
        _ => OpenMenuKey::Refuse,
    }
}

/// A submenu title as [`super::workspace::launch_submenu_titles`] keeps it:
/// trimmed, lower case, no trailing ellipsis, no-break spaces as spaces.
pub fn submenu_title_key(title: &str) -> String {
    let t = title.replace('\u{a0}', " ");
    let t = t.trim();
    let t = t.strip_suffix('\u{2026}').or_else(|| t.strip_suffix("...")).unwrap_or(t);
    t.trim().to_lowercase()
}

/// Whether an item of a menu the desktop opened (a context menu, a pop-up)
/// sits in a launch list: some item above it is titled as one of AppKit's
/// launch submenus (Services, Quick Actions, Share, Open With, Recent
/// Items, in any language). `path` is None when a title above it could not
/// be read: that counts as a launch list (fail closed).
pub fn in_opened_launch_list(path: Option<&[String]>, launch_titles: &[String]) -> bool {
    match path {
        None => true,
        Some(path) => path.iter().any(|p| launch_titles.contains(&submenu_title_key(p))),
    }
}

/// Whether a submenu is a launch list: under the Apple menu (Recent Items:
/// apps, documents, servers) or the app menu (Services), or one where most
/// items name installed apps (Open With in any app and any language).
pub fn is_launch_list(
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    if ctx.depth < 2 {
        return false;
    }
    if matches!(ctx.top_index, Some(0 | 1)) {
        return true;
    }
    if let Some(launch) = ctx.launch {
        return launch;
    }
    siblings_name_apps(ctx.siblings, resolve)
}

/// Whether a menu counts as a launch list by its items: by what its titles
/// name, or, when a title could not be read (unknown siblings), whenever
/// something is denied (fail closed: the rule then wants an item to name an
/// allowed app). Pure, for tests.
pub fn launch_by_items(
    titles: Option<&[String]>,
    denies_any: bool,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    match titles {
        Some(t) => siblings_name_apps(t, resolve),
        None => denies_any,
    }
}

/// Whether most of a menu's items name installed apps (Open With in any
/// app and any language): once per menu.
pub fn siblings_name_apps(
    siblings: &[String],
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    let named: Vec<&String> = siblings.iter().filter(|t| !t.trim().is_empty()).collect();
    let apps = named
        .iter()
        .filter(|t| resolve(menu_app_name(t).0).is_some_and(|ids| !ids.is_empty()))
        .count();
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
    menu_item_check(guard, ctx, resolve) != ItemCheck::Allowed
}

/// What [`menu_item_blocked`] decided, and why.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemCheck {
    Allowed,
    /// It reaches a denied or protected app.
    Blocked,
    /// A name it shows could not be resolved yet (the app names are still
    /// loading): blocked, and a refusal says the names are loading.
    Unknown,
    /// Its place in the menus could not be read while something is denied:
    /// blocked, and a refusal says an item above it cannot be read.
    Unplaced,
}

/// [`menu_item_blocked`], telling a real block from a name not resolved yet.
pub fn menu_item_check(
    guard: &dyn crate::desktop::MenuGuard,
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> ItemCheck {
    let (name, version) = menu_app_name(ctx.title);
    if name.is_empty() {
        return ItemCheck::Allowed;
    }
    // Menus add text after an app's name ("System Settings…, 1 update"):
    // every leading part of the title is checked, so none hides an app.
    for candidate in menu_name_candidates(ctx.title) {
        if guard.app_blocked("", candidate) {
            return ItemCheck::Blocked;
        }
        match resolve(candidate) {
            // The name cannot be resolved yet: fail closed (the protected
            // apps always apply, whatever the deny list).
            None => return ItemCheck::Unknown,
            Some(ids) if ids.iter().any(|id| guard.app_blocked(id, candidate)) => {
                return ItemCheck::Blocked;
            }
            Some(_) => {}
        }
    }
    let ids = resolve(name).unwrap_or_default();
    if guard.denies_any()
        && is_launch_list(ctx, resolve)
        && (ids.is_empty() || version || ids.len() > 1)
    {
        ItemCheck::Blocked
    } else {
        ItemCheck::Allowed
    }
}

/// The refusal a chord gets: when the menu item that blocks it is blocked
/// only because a name it shows could not be resolved yet, it says the
/// names are loading, not "the deny list"; a real block keeps its refusal.
/// Pure, for tests.
pub fn loading_instead(why: &str, blocked_unknown: bool) -> Option<&'static str> {
    (why == REFUSE_BLOCKED && blocked_unknown).then_some(crate::menus::APP_NAMES_LOADING)
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
    /// Its title was read and held to the deny list and the protected apps.
    /// An unchecked match (its title could not be read) is blocked while
    /// something is denied; with nothing denied it is never pressed and the
    /// key is posted, as Codex does (a posted chord does not leave a menu
    /// under the person's keys).
    pub checked: bool,
    /// It is blocked only because a name it shows could not be resolved yet
    /// (the app names are still loading).
    pub unknown: bool,
    /// It is blocked because an item above it could not be read.
    pub unplaced: bool,
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
        return if m.blocked {
            ShortcutPick::Blocked(m.title.clone())
        } else {
            ShortcutPick::Press(i)
        };
    }
    match matches.first() {
        Some(m) => ShortcutPick::Disabled(m.title.clone()),
        None => ShortcutPick::None,
    }
}

/// Every value of each NSKeyEquivalent dictionary in `pbs -dump` output
/// (default and localized ones), keeping those that are a key equivalent:
/// modifier marks ($ ^ ~ @) and one key, which may be a function-key
/// character such as \Uf704 (written that way in the dump).
pub fn service_equivalents(dump: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = dump;
    while let Some(i) = rest.find("NSKeyEquivalent") {
        rest = &rest[i + "NSKeyEquivalent".len()..];
        let after = rest.trim_start();
        let Some(after) = after.strip_prefix('=') else { continue };
        let after = after.trim_start();
        // Only a dictionary value: "{ ... }".
        let Some(body_start) = after.strip_prefix('{') else { continue };
        let (values, consumed) = dump_dict_values(body_start);
        for value in values {
            if is_key_equivalent(&value) && !out.contains(&value) {
                out.push(value);
            }
        }
        rest = &body_start[consumed..];
    }
    out
}

/// The values of one old-style plist dictionary body (after its "{"), with
/// quoted strings read whole (";", "}" and escapes inside them), and how
/// many bytes it took up to and including the closing "}".
fn dump_dict_values(body: &str) -> (Vec<String>, usize) {
    let mut values = Vec::new();
    let mut in_value = false;
    // An unquoted value's text, trimmed when stored.
    let mut bare = String::new();
    // A quoted value, verbatim (spaces, \t and \r are keys).
    let mut quoted: Option<String> = None;
    let mut chars = body.char_indices();
    let take = |bare: &mut String, quoted: &mut Option<String>, values: &mut Vec<String>| {
        match quoted.take() {
            Some(q) => values.push(q),
            None if !bare.trim().is_empty() => values.push(bare.trim().to_string()),
            None => {}
        }
        bare.clear();
    };
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => {
                let mut q = String::new();
                while let Some((_, ch)) = chars.next() {
                    match ch {
                        '\\' => match chars.next().map(|(_, e)| e) {
                            Some('"') => q.push('"'),
                            Some('\\') => q.push('\\'),
                            Some('n') => q.push('\n'),
                            Some('t') => q.push('\t'),
                            Some('a') => q.push('\u{7}'),
                            Some('b') => q.push('\u{8}'),
                            Some('f') => q.push('\u{c}'),
                            Some('r') => q.push('\r'),
                            Some('v') => q.push('\u{b}'),
                            Some('U') => {
                                let hex: String = chars.clone().take(4).map(|(_, h)| h).collect();
                                match u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                                    Some(x) if hex.len() == 4 => {
                                        q.push(x);
                                        for _ in 0..4 {
                                            chars.next();
                                        }
                                    }
                                    _ => q.push('U'),
                                }
                            }
                            Some(d @ '0'..='7') => {
                                let mut n = d.to_digit(8).unwrap_or(0);
                                for _ in 0..2 {
                                    match chars.clone().next() {
                                        Some((_, o @ '0'..='7')) => {
                                            n = n * 8 + o.to_digit(8).unwrap_or(0);
                                            chars.next();
                                        }
                                        _ => break,
                                    }
                                }
                                if let Some(x) = char::from_u32(n) {
                                    q.push(x);
                                }
                            }
                            Some(other) => q.push(other),
                            None => {}
                        },
                        '"' => break,
                        other => q.push(other),
                    }
                }
                if in_value {
                    quoted = Some(q);
                }
            }
            '=' => {
                in_value = true;
                bare.clear();
                quoted = None;
            }
            ';' => {
                if in_value {
                    take(&mut bare, &mut quoted, &mut values);
                }
                in_value = false;
                bare.clear();
            }
            '}' => {
                // A last entry may have no trailing ";".
                if in_value {
                    take(&mut bare, &mut quoted, &mut values);
                }
                return (values, i + 1);
            }
            other => {
                if quoted.is_none() {
                    bare.push(other);
                }
            }
        }
    }
    (values, body.len())
}

/// Modifier marks and exactly one key. When every character is a mark
/// ("@$"), the last one is the key ("$" with Command).
pub fn is_key_equivalent(value: &str) -> bool {
    let keys = value.chars().filter(|c| !matches!(c, '$' | '^' | '~' | '@')).count();
    // One key; or marks only, the last being the key (a single "@" is the
    // "@" key, Command implied).
    keys == 1 || (keys == 0 && !value.is_empty())
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

/// One node kept by [`breadth_first`] and its parent's slot.
pub struct BfsSlot<N> {
    pub node: N,
    pub parent: Option<usize>,
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
        slots.push(BfsSlot { node, parent });
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

/// How much of the ANSI key codes in keymap.rs a keyboard layout keeps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    /// Every character key (U.S., ABC and their variants).
    Ansi,
    /// The letters and the unshifted digits; punctuation and the shifted
    /// digits differ (British: Shift-3 is £, # is Option-3).
    LettersDigits,
    /// Unknown, or letters elsewhere (German, French, Dvorak).
    Other,
}

/// The layout from its input source ID. With no current layout recorded,
/// only a default install (no enabled input sources recorded either) counts
/// as U.S.; anything else is unknown and fails closed.
pub fn layout_of(input_source_id: Option<&str>, enabled_sources_recorded: bool) -> Layout {
    match input_source_id {
        None if !enabled_sources_recorded => Layout::Ansi,
        None => Layout::Other,
        Some(
            "com.apple.keylayout.US"
            | "com.apple.keylayout.ABC"
            | "com.apple.keylayout.USExtended"
            | "com.apple.keylayout.USInternational-PC"
            | "com.apple.keylayout.Australian"
            | "com.apple.keylayout.Canadian",
        ) => Layout::Ansi,
        Some(
            "com.apple.keylayout.British"
            | "com.apple.keylayout.British-PC"
            | "com.apple.keylayout.Irish"
            | "com.apple.keylayout.IrishExtended",
        ) => Layout::LettersDigits,
        Some(_) => Layout::Other,
    }
}

/// Whether the Services check can place `key` on `layout`: arrows, function
/// keys, Return, Tab, Space, Escape, Delete and the navigation keys have the
/// same codes on every layout; letters and unshifted digits need their ANSI
/// positions; other characters need the whole ANSI layout.
pub fn layout_places(key: &crate::keys::Key, shift: bool, layout: Layout) -> bool {
    use crate::keys::Key;
    match key {
        Key::Char(c) if c.is_ascii_alphabetic() => layout != Layout::Other,
        Key::Char(c) if c.is_ascii_digit() => {
            layout == Layout::Ansi || (layout == Layout::LettersDigits && !shift)
        }
        Key::Char(_) => layout == Layout::Ansi,
        _ => true,
    }
}

/// What to do with a key chord (any with Command, Control or Option, or a
/// function key) after the menu search, for either delivery.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChordAction {
    /// Press the matched menu item (its index) through AX; no key is posted.
    PressItem(usize),
    /// Post the chord as key events.
    Post,
    /// Refuse, with why.
    Refuse(&'static str),
}

/// Facts the chord decision needs (the menu search, the deny list, the
/// keyboard layout and the Services shortcuts), so it is one tested place.
/// The layout and Services facts are read only when the rule gets to them
/// (`needs_key_checks`).
#[derive(Clone, Debug)]
pub struct ChordFacts<'a> {
    /// Matches in menu order: every one in the foreground, up to and
    /// including the first enabled one in the background.
    pub matches: &'a [ShortcutMatch],
    /// The menu search saw every item (no AX error, no branch cut).
    pub complete: bool,
    pub background: bool,
    pub denies_any: bool,
    /// The Services check can place this chord's key on the current layout
    /// (`layout_places`).
    pub layout_known: bool,
    /// Whether the chord is a registered Services shortcut.
    pub is_service: ServiceCheck,
}

pub const REFUSE_TOO_DEEP: &str = "this app's menus could not all be read to check this shortcut against the Computer Use deny list; use the app's menu items in the tree";
pub const REFUSE_LAYOUT: &str = "this shortcut cannot be checked against the Computer Use deny list on this keyboard layout; use the app's menu items in the tree";
pub const REFUSE_SERVICES_UNREAD: &str = "the Services shortcuts could not be read yet; try again in a moment, or use the app's menu items in the tree";
pub const REFUSE_SERVICE: &str = "this shortcut runs a Service, which can hand the selection to an app on the Computer Use deny list; use the app's menu items in the tree";
pub const REFUSE_BLOCKED: &str =
    "the menu item for this shortcut would reach an app on the Computer Use deny list";

/// AppKit's routing, held to the deny list. AppKit offers a key to the key
/// view's performKeyEquivalent first (web content, editors), then to the
/// menus (the first enabled item with the equivalent, revalidated at key
/// time), then to Services. A posted chord keeps its Shift on every route
/// (see press_keys).
/// - Foreground: post the key, as the person's key would go, when posting is
///   safe: no match is blocked and, while something is denied, the walk was
///   complete, the layout places the key and no Services shortcut has it.
///   Otherwise fall through to the rules below, which press the app's item
///   instead when one can be pressed (so a Service on the same chord cannot
///   run).
/// - The first enabled match is not blocked: press that item through AX
///   (disabled matches before it, blocked or not, do not run). No key is
///   posted, so no Service, other item or key-time revalidation can take it.
///   The background always does this: a background window's key view does
///   not handle key equivalents the way the key window's does.
/// - The first enabled match is blocked: refuse.
/// - No enabled match, but a disabled one is blocked: refuse (it may be
///   revalidated at key time). This holds with nothing denied too (protected
///   apps: sign-in, security prompts, cmux Remote).
/// - Otherwise the key is posted: as typed with nothing denied; while
///   something is denied only after a complete walk, when the layout places
///   the key, and when it is no Services shortcut (read).
///
/// With nothing denied an incomplete walk is posted: what it may miss is a
/// protected app's item (sign-in, security prompts, cmux Remote) deep in a
/// menu with a key equivalent of its own; none is known, and refusing would
/// refuse every unmatched chord in an app with deep menus.
pub fn decide_chord(f: &ChordFacts) -> ChordAction {
    let any_blocked = f.matches.iter().any(|m| m.blocked);
    let checks_pass = |f: &ChordFacts| {
        !f.denies_any || (f.complete && f.layout_known && f.is_service == ServiceCheck::NoMatch)
    };
    if !f.background && !any_blocked && checks_pass(f) {
        return ChordAction::Post;
    }
    match pick_shortcut(f.matches) {
        ShortcutPick::Press(i) if !f.matches[i].checked => return ChordAction::Post,
        ShortcutPick::Press(i) => return ChordAction::PressItem(i),
        ShortcutPick::Blocked(_) => return ChordAction::Refuse(REFUSE_BLOCKED),
        ShortcutPick::Disabled(_) | ShortcutPick::None => {}
    }
    if any_blocked {
        return ChordAction::Refuse(REFUSE_BLOCKED);
    }
    if !f.denies_any {
        return ChordAction::Post;
    }
    if !f.complete {
        return ChordAction::Refuse(REFUSE_TOO_DEEP);
    }
    if !f.layout_known {
        return ChordAction::Refuse(REFUSE_LAYOUT);
    }
    match f.is_service {
        ServiceCheck::Unread => ChordAction::Refuse(REFUSE_SERVICES_UNREAD),
        ServiceCheck::Match => ChordAction::Refuse(REFUSE_SERVICE),
        ServiceCheck::NoMatch => ChordAction::Post,
    }
}

/// Whether a background chord's menu matches need the app to validate its
/// menus first: there are matches, none is blocked and none is enabled (an
/// app with no key window disables every item that acts on one).
pub fn needs_menu_validation(matches: &[ShortcutMatch]) -> bool {
    !matches.is_empty() && !matches.iter().any(|m| m.blocked || m.enabled)
}

/// Whether the rule reads the layout and the Services shortcuts: while
/// something is denied and no match is blocked, for a foreground chord
/// (which is posted when they pass) and for a background one with no
/// enabled match (pressed otherwise).
pub fn needs_key_checks(matches: &[ShortcutMatch], denies_any: bool, background: bool) -> bool {
    denies_any
        && !matches.iter().any(|m| m.blocked)
        && (!background || !matches.iter().any(|m| m.enabled))
}

/// Whether a chord is a Services shortcut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServiceCheck {
    NoMatch,
    Match,
    /// The Services shortcuts have not been read.
    Unread,
}
