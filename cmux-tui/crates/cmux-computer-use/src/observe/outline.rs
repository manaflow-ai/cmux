//! The compact text form of a tree: one line per element, children indented
//! under their parent.
//!
//! ```text
//! [1] window "Untitled"
//!   [4] text field "To" = "ada@example.com" focused
//!   [7] button "Send" disabled
//!   [9] checkbox "Bcc" = off
//!   [12] menu bar (click a menu's id to list its items)
//!     [13] menu bar item "File"
//! Focus: [4] text field "To"
//! ```
//!
//! Unnamed containers with nothing to act on are folded (their children move
//! up), a label that repeats its parent's name is left out, and frames are
//! left out unless asked for.

use crate::desktop::{Element, Rect};

/// The most characters of a name shown.
pub const NAME_MAX: usize = 100;
/// The most characters of a value shown in a full view.
pub const VALUE_MAX: usize = 300;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Options {
    /// Each line ends with its frame (`@x,y wxh`, screenshot pixels).
    pub frames: bool,
    /// Every menu of the menu bar with its items, not only the menus' titles.
    pub menus: bool,
    pub value_max: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self { frames: false, menus: false, value_max: VALUE_MAX }
    }
}

/// One shown element.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub id: u32,
    pub depth: usize,
    /// The nearest shown ancestor.
    pub parent: Option<u32>,
    /// The element's own parent in the tree (shown or folded).
    pub tree_parent: Option<u32>,
    pub role: String,
    /// Its name (a static text's text).
    pub label: String,
    pub value: String,
    pub identifier: String,
    pub shortcut: String,
    pub focused: bool,
    pub disabled: bool,
    pub checked: bool,
    pub selected: bool,
    /// Actions beyond a plain press.
    pub actions: Vec<String>,
    pub frame: Option<Rect>,
    /// Inside the app's menu bar.
    pub menu_bar: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outline {
    pub lines: Vec<Line>,
    /// The focused element's line.
    pub focused: Option<usize>,
    pub truncated: bool,
    /// Elements in the tree, shown or folded.
    pub elements: usize,
    /// The ids of every element of the tree outside the menu bar, shown or
    /// folded: one folded in one look and shown in the next is no new element.
    pub present: std::collections::HashSet<u32>,
}

/// Roles that are only layout when they have no name, value or action.
const STRUCTURAL: &[&str] = &[
    "group",
    "unknown",
    "layout_area",
    "layout_item",
    "split_group",
    "generic",
    "section",
    "filler",
    "panel",
    "pane",
    "custom",
    "none",
    "grouping",
];

/// Actions every clickable element has, left out of the line (click on the
/// id does them).
const PLAIN_ACTIONS: &[&str] = &[
    "press",
    "click",
    "activate",
    "invoke",
    "default",
    "focus",
    "set_value",
    "scroll_to_visible",
    "show_alternate_ui",
    "show_default_ui",
    "raise",
];

/// A static text role (macOS `text`, Windows `text`, AT-SPI `label`/`static`).
pub fn is_static_text(role: &str) -> bool {
    matches!(role, "text" | "static_text" | "static text" | "label" | "static")
}

/// Roles whose value is on/off.
fn is_toggle(role: &str) -> bool {
    matches!(
        role,
        "checkbox"
            | "check_box"
            | "check box"
            | "radio"
            | "radio_button"
            | "radio button"
            | "switch"
            | "toggle"
            | "toggle_button"
            | "toggle button"
    )
}

pub fn secondary_actions(actions: &[String]) -> Vec<String> {
    actions.iter().filter(|a| !PLAIN_ACTIONS.contains(&a.as_str())).cloned().collect()
}

/// At most `max` characters, with an ellipsis when cut.
pub fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut s: String = text.chars().take(max.saturating_sub(1)).collect();
    s.push('\u{2026}');
    s
}

/// A quoted string on one line.
pub fn quote(text: &str) -> String {
    let mut s = String::with_capacity(text.len() + 2);
    s.push('"');
    for c in text.chars() {
        match c {
            '"' => s.push_str("\\\""),
            '\\' => s.push_str("\\\\"),
            '\n' => s.push_str("\\n"),
            '\r' => {}
            '\t' => s.push(' '),
            c if c.is_control() => {}
            // Direction marks and zero-width characters (Calculator's "\u{200e}0").
            '\u{200b}'..='\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2066}'..='\u{2069}'
            | '\u{feff}' => {}
            c => s.push(c),
        }
    }
    s.push('"');
    s
}

/// A value as a line shows it: on/off for toggles, else quoted and cut at
/// `max` characters with how many more there are.
pub fn value_text(role: &str, value: &str, max: usize) -> String {
    if is_toggle(role) {
        match value.trim() {
            "1" | "true" => return "on".into(),
            "0" | "false" => return "off".into(),
            "2" => return "mixed".into(),
            _ => {}
        }
    }
    let n = value.chars().count();
    if n <= max {
        quote(value)
    } else {
        let head: String = value.chars().take(max).collect();
        format!("{}\u{2026} (+{} chars)", quote(&head), n - max)
    }
}

/// Whether an identifier says something (not AppKit's generated `_NS:12`).
fn shows_identifier(id: &str) -> bool {
    !id.is_empty()
        && id.chars().count() <= 40
        && !id.starts_with("_NS:")
        && !id.chars().all(|c| c.is_ascii_digit())
        && !id.chars().any(char::is_whitespace)
}

/// Whether a node is only layout: folded, its children shown in its place.
fn folds(e: &Element, parent_label: &str) -> bool {
    if e.focused || e.selected {
        return false;
    }
    let bare = e.name.trim().is_empty()
        && e.value.trim().is_empty()
        && secondary_actions(&e.actions).is_empty();
    if bare && STRUCTURAL.contains(&e.role.as_str()) {
        return true;
    }
    // A label inside a control that says what the control is named.
    if is_static_text(&e.role) && e.children.is_empty() && secondary_actions(&e.actions).is_empty()
    {
        let text = if e.name.trim().is_empty() { e.value.trim() } else { e.name.trim() };
        return text.is_empty() || text == parent_label.trim();
    }
    // An unnamed picture with nothing to do.
    e.role == "image" && bare && e.children.is_empty()
}

pub fn build(root: &Element, truncated: bool, opts: &Options) -> Outline {
    let mut out = Outline { truncated, ..Outline::default() };
    let mut focused: Option<(usize, usize)> = None; // (tree depth, line)
    visit(root, 0, 0, None, None, "", false, opts, &mut out, &mut focused);
    out.focused = focused.map(|(_, line)| line);
    out
}

#[allow(clippy::too_many_arguments)] // the walk's position, carried down
fn visit(
    e: &Element,
    tree_depth: usize,
    depth: usize,
    parent: Option<u32>,
    tree_parent: Option<u32>,
    parent_label: &str,
    in_menu_bar: bool,
    opts: &Options,
    out: &mut Outline,
    focused: &mut Option<(usize, usize)>,
) {
    out.elements += 1;
    let menu_bar = in_menu_bar || e.role == super::ids::MENU_BAR;
    let own_id = e.id.parse::<u32>().ok();
    if !menu_bar && let Some(id) = own_id {
        out.present.insert(id);
    }
    // With the menus folded, the menu bar shows only its menus' titles.
    if in_menu_bar && !opts.menus && e.role != "menu_bar_item" {
        count(e, out);
        return;
    }
    // A menu inside the menu bar is the item's own list: shown as the item's children.
    let fold = tree_depth > 0
        && (folds(e, parent_label) || (in_menu_bar && e.role == "menu" && e.name.is_empty()));
    let label = if e.name.trim().is_empty() && is_static_text(&e.role) {
        e.value.trim().to_string()
    } else {
        e.name.trim().to_string()
    };
    let (child_depth, child_parent, child_label) = if fold {
        (depth, parent, parent_label.to_string())
    } else {
        let id = e.id.parse::<u32>().unwrap_or(0);
        let value = if is_static_text(&e.role) && e.name.trim().is_empty() {
            String::new()
        } else {
            e.value.clone()
        };
        out.lines.push(Line {
            id,
            depth,
            parent,
            tree_parent,
            role: e.role.clone(),
            label: label.clone(),
            value,
            identifier: if shows_identifier(&e.identifier) {
                e.identifier.clone()
            } else {
                String::new()
            },
            shortcut: e.shortcut.clone(),
            focused: e.focused,
            disabled: e.disabled,
            checked: e.checked,
            selected: e.selected,
            actions: secondary_actions(&e.actions),
            frame: e.frame,
            menu_bar,
        });
        if e.focused && focused.is_none_or(|(d, _)| tree_depth >= d) {
            *focused = Some((tree_depth, out.lines.len() - 1));
        }
        (depth + 1, Some(id), label)
    };
    if in_menu_bar && !opts.menus && e.role == "menu_bar_item" {
        for c in &e.children {
            count(c, out);
        }
        return;
    }
    for c in &e.children {
        visit(
            c,
            tree_depth + 1,
            child_depth,
            child_parent,
            own_id,
            &child_label,
            menu_bar,
            opts,
            out,
            focused,
        );
    }
}

fn count(e: &Element, out: &mut Outline) {
    for c in &e.children {
        out.elements += 1;
        count(c, out);
    }
}

/// One line's text, without its id and indentation.
pub fn line_text(l: &Line, opts: &Options) -> String {
    line_text_with(l, opts, None)
}

/// [`line_text`] with the value shown as `value` (a diff's cut around a change).
pub fn line_text_with(l: &Line, opts: &Options, value: Option<String>) -> String {
    let mut s = l.role.replace('_', " ");
    if !l.label.is_empty() {
        s.push(' ');
        s.push_str(&quote(&clip(&l.label, NAME_MAX)));
    }
    if let Some(v) = value {
        s.push_str(" = ");
        s.push_str(&v);
    } else if !l.value.is_empty() {
        s.push_str(" = ");
        s.push_str(&value_text(&l.role, &l.value, opts.value_max));
    }
    if !l.identifier.is_empty() {
        s.push_str(" id=");
        s.push_str(&l.identifier);
    }
    if !l.shortcut.is_empty() {
        s.push(' ');
        s.push_str(&l.shortcut);
    }
    if l.checked {
        s.push_str(" checked");
    }
    if l.selected {
        s.push_str(" selected");
    }
    if l.focused {
        s.push_str(" focused");
    }
    if l.disabled {
        s.push_str(" disabled");
    }
    if !l.actions.is_empty() {
        s.push_str(" actions: ");
        s.push_str(&l.actions.join(", "));
    }
    if l.role == super::ids::MENU_BAR && !opts.menus {
        s.push_str(" (click a menu's id to list its items)");
    }
    if opts.frames
        && let Some(f) = l.frame
    {
        s.push_str(&format!(
            " @{},{} {}x{}",
            f.x.round(),
            f.y.round(),
            f.width.round(),
            f.height.round()
        ));
    }
    s
}

/// `[12] button "Save"`.
pub fn line(l: &Line, opts: &Options) -> String {
    format!("[{}] {}", l.id, line_text(l, opts))
}

/// The items under `parent` (a menu bar item, or a menu an action opened),
/// the menus between them folded.
pub fn build_items(parent: &Element, opts: &Options) -> Outline {
    let opts = Options { menus: true, ..*opts };
    let mut out = Outline::default();
    let mut focused = None;
    let id = parent.id.parse::<u32>().ok();
    for c in &parent.children {
        visit(c, 1, 0, id, id, parent.name.trim(), true, &opts, &mut out, &mut focused);
    }
    out
}

/// The lines, indented, one per row.
pub fn render_lines(o: &Outline, opts: &Options) -> String {
    let mut s = String::new();
    for (i, l) in o.lines.iter().enumerate() {
        if i > 0 {
            s.push('\n');
        }
        for _ in 0..l.depth {
            s.push_str("  ");
        }
        s.push_str(&line(l, opts));
    }
    s
}

/// The whole outline, then the focus.
pub fn render(o: &Outline, opts: &Options) -> String {
    let mut s = render_lines(o, opts);
    if !s.is_empty() {
        s.push('\n');
    }
    s.push_str(&focus_line(o));
    if o.truncated {
        s.push_str("\n(The tree was cut at the element limit; pass a larger max_nodes, up to 5000, for the rest.)");
    }
    s
}

/// `Focus: [4] text field "To"`, or that nothing in the window has it.
pub fn focus_line(o: &Outline) -> String {
    match o.focused.and_then(|i| o.lines.get(i)) {
        Some(l) => format!("Focus: [{}] {}", l.id, short(l)),
        None => "Focus: no element of this window has keyboard focus".into(),
    }
}

/// `text field "To"`.
pub fn short(l: &Line) -> String {
    let role = l.role.replace('_', " ");
    if l.label.is_empty() { role } else { format!("{role} {}", quote(&clip(&l.label, 60))) }
}

/// A menu item's shortcut as press_key takes it, from AXMenuItemCmdChar and
/// AXMenuItemCmdModifiers (0 is Command alone; bit 0 Shift, 1 Option, 2
/// Control, 3 no Command). Empty for an item with no shortcut or a key with
/// no name here.
pub fn menu_shortcut(cmd_char: &str, modifiers: i64) -> String {
    let mut chars = cmd_char.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else { return String::new() };
    let key = match c {
        '\r' | '\u{3}' => "Return".to_string(),
        '\t' => "Tab".to_string(),
        ' ' => "Space".to_string(),
        '\u{1b}' => "Escape".to_string(),
        '\u{8}' | '\u{7f}' => "Backspace".to_string(),
        '\u{F728}' => "Delete".to_string(),
        '\u{F700}' => "Up".to_string(),
        '\u{F701}' => "Down".to_string(),
        '\u{F702}' => "Left".to_string(),
        '\u{F703}' => "Right".to_string(),
        '\u{F729}' => "Home".to_string(),
        '\u{F72B}' => "End".to_string(),
        '\u{F72C}' => "PageUp".to_string(),
        '\u{F72D}' => "PageDown".to_string(),
        '+' => "plus".to_string(),
        c if ('\u{F704}'..='\u{F71B}').contains(&c) => format!("F{}", c as u32 - 0xF704 + 1),
        c if c.is_ascii_graphic() => c.to_ascii_lowercase().to_string(),
        _ => return String::new(),
    };
    let mut parts: Vec<&str> = Vec::new();
    if modifiers & 8 == 0 {
        parts.push("cmd");
    }
    if modifiers & 4 != 0 {
        parts.push("ctrl");
    }
    if modifiers & 2 != 0 {
        parts.push("alt");
    }
    if modifiers & 1 != 0 {
        parts.push("shift");
    }
    parts.push(&key);
    parts.join("+")
}
