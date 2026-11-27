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
//! left out unless asked for. So is what says nothing to act on:
//!
//! - elements scrolled out of view (wholly outside their scroll area): their
//!   container counts them (`out of view: 176 below`) until `offscreen`;
//! - a scroll bar's parts (its scroll area scrolls: `scroll` an element_id);
//! - a table cell that only repeats its row, an empty row (a separator), a
//!   picture inside a control;
//! - actions every element has (`show_menu`, a scroll area's page scrolls, a
//!   menu's `cancel` and `pick`);
//! - `focused` on anything but the one element with keyboard focus (AppKit
//!   reports every cell of a focused table focused).

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
    /// Elements scrolled out of view are shown too, not only counted.
    pub offscreen: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self { frames: false, menus: false, value_max: VALUE_MAX, offscreen: false }
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
    /// Its elements scrolled out of view, not shown: above, below, left, right.
    pub out_of_view: [usize; 4],
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
    /// The ids of the elements scrolled out of view, not shown: one shown in
    /// the last look and scrolled away in this one is neither removed nor
    /// changed.
    pub clipped: std::collections::HashSet<u32>,
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
            | "tab_button"
            | "tab button"
            | "disclosure_triangle"
            | "disclosure triangle"
    )
}

pub fn secondary_actions(actions: &[String]) -> Vec<String> {
    actions.iter().filter(|a| !PLAIN_ACTIONS.contains(&a.as_str())).cloned().collect()
}

/// Actions nearly every element has, left out of its line: a context menu
/// (perform_action show_menu works on any element), a scroll area's page
/// scrolls (scroll with its element_id).
const COMMON_ACTIONS: &[&str] = &[
    "show_menu",
    "scroll_left_by_page",
    "scroll_right_by_page",
    "scroll_up_by_page",
    "scroll_down_by_page",
];

/// The actions a line shows: secondary, not common, and none for the menu
/// bar's menus and items (clicking one lists or runs it).
fn shown_actions(e: &Element, in_menu_bar: bool) -> Vec<String> {
    if in_menu_bar || e.role == super::ids::MENU_BAR {
        return Vec::new();
    }
    secondary_actions(&e.actions)
        .into_iter()
        .filter(|a| !COMMON_ACTIONS.contains(&a.as_str()))
        .collect()
}

/// A table or list item: AppKit gives each of them its table's focus, and an
/// empty one is a separator.
fn is_item(role: &str) -> bool {
    matches!(
        role,
        "row"
            | "cell"
            | "outline_row"
            | "table_row"
            | "table row"
            | "table_cell"
            | "table cell"
            | "list_item"
            | "list item"
    )
}

fn is_cell(role: &str) -> bool {
    matches!(role, "cell" | "table_cell" | "table cell")
}

fn is_row(role: &str) -> bool {
    matches!(role, "row" | "outline_row" | "table_row" | "table row" | "list_item" | "list item")
}

/// A control a picture inside of only decorates.
fn is_control(role: &str) -> bool {
    matches!(
        role,
        "button"
            | "tab_button"
            | "tab button"
            | "menu_button"
            | "popup_button"
            | "pop_up_button"
            | "checkbox"
            | "radio_button"
            | "link"
            | "menu_item"
            | "menu_bar_item"
    )
}

/// The element with keyboard focus, as the path of nodes from `root` to it:
/// the deepest focused element that is not a table's row or cell when there
/// is one (a focused table marks all of them focused), else the deepest
/// focused item; the first on a tie. Inside the menu bar only with `menus`.
fn focus_path(root: &Element, menus: bool) -> Vec<*const Element> {
    fn go<'a>(
        e: &'a Element,
        menus: bool,
        path: &mut Vec<&'a Element>,
        best: &mut Option<(bool, usize, Vec<*const Element>)>,
    ) {
        if !menus && e.role == super::ids::MENU_BAR {
            return;
        }
        path.push(e);
        if e.focused {
            let key = (!is_item(&e.role), path.len());
            if best.as_ref().is_none_or(|(o, d, _)| key > (*o, *d)) {
                *best = Some((key.0, key.1, path.iter().map(|n| *n as *const Element).collect()));
            }
        }
        for c in &e.children {
            go(c, menus, path, best);
        }
        path.pop();
    }
    let mut best = None;
    go(root, menus, &mut Vec::new(), &mut best);
    best.map(|(_, _, p)| p).unwrap_or_default()
}

/// Where an element wholly outside `clip` lies: 0 above, 1 below, 2 left,
/// 3 right; None when it shows (or has no frame to tell).
fn out_of_view(e: &Element, clip: Option<Rect>) -> Option<usize> {
    let (f, c) = (e.frame?, clip?);
    if f.width <= 0.0 || f.height <= 0.0 || f.intersects(&c) {
        return None;
    }
    Some(if f.y + f.height <= c.y {
        0
    } else if f.y >= c.y + c.height {
        1
    } else if f.x + f.width <= c.x {
        2
    } else {
        3
    })
}

/// `clip` narrowed to a scroll area's frame.
fn narrow(clip: Option<Rect>, frame: Option<Rect>) -> Option<Rect> {
    let Some(f) = frame.filter(|f| f.width > 0.0 && f.height > 0.0) else { return clip };
    let Some(c) = clip else { return Some(f) };
    let x = c.x.max(f.x);
    let y = c.y.max(f.y);
    let r = (c.x + c.width).min(f.x + f.width);
    let b = (c.y + c.height).min(f.y + f.height);
    Some(Rect { x, y, width: (r - x).max(0.0), height: (b - y).max(0.0) })
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
/// `focus`: it has the keyboard focus; `parent`: its parent in the tree.
fn folds(
    e: &Element,
    parent: Option<&Element>,
    parent_label: &str,
    focus: bool,
    in_menu_bar: bool,
) -> bool {
    if focus {
        return false;
    }
    let actions = shown_actions(e, in_menu_bar);
    let bare = e.name.trim().is_empty() && e.value.trim().is_empty() && actions.is_empty();
    // A cell that is its row's only child and says nothing its row does not
    // (Settings' sidebar, Notes' list): the row stands for it.
    if let Some(p) = parent
        && is_cell(&e.role)
        && is_row(&p.role)
        && p.children.len() == 1
        && e.name.trim().is_empty()
        && e.value.trim().is_empty()
        && (!e.selected || p.selected)
        && actions.iter().all(|a| shown_actions(p, in_menu_bar).contains(a))
    {
        return true;
    }
    // A row that only holds one cell (Finder's sidebar): the cell stands for it.
    if bare
        && is_row(&e.role)
        && let [only] = e.children.as_slice()
        && is_cell(&only.role)
        && (!e.selected || only.selected)
    {
        return true;
    }
    if e.selected {
        return false;
    }
    if bare && STRUCTURAL.contains(&e.role.as_str()) {
        return true;
    }
    // A cell that only holds one element (a list's date or size column).
    if bare && is_cell(&e.role) && e.children.len() == 1 {
        return true;
    }
    // A label inside a control that says what the control is named.
    if is_static_text(&e.role) && e.children.is_empty() && actions.is_empty() {
        let text = if e.name.trim().is_empty() { e.value.trim() } else { e.name.trim() };
        return text.is_empty() || text == parent_label.trim();
    }
    // A picture with nothing to do: unnamed, inside a control (a tab's
    // favicon, a button's icon), or beside the text of its item (a sidebar
    // row's icon).
    e.role == "image"
        && e.children.is_empty()
        && actions.is_empty()
        && (bare
            || parent.is_some_and(|p| {
                is_control(&p.role)
                    || (is_item(&p.role)
                        && p.children.iter().any(|c| {
                            is_static_text(&c.role)
                                && !(c.name.trim().is_empty() && c.value.trim().is_empty())
                        }))
            }))
}

pub fn build(root: &Element, truncated: bool, opts: &Options) -> Outline {
    let mut out = Outline { truncated, ..Outline::default() };
    let focus = focus_path(root, opts.menus);
    let mut w = Walk { opts, focus: &focus, out: &mut out };
    w.visit(root, &Place::default());
    out
}

/// What the walk carries down to a node.
#[derive(Clone, Default)]
struct Place<'a> {
    tree_depth: usize,
    depth: usize,
    /// The nearest shown ancestor's id and line.
    parent: Option<u32>,
    owner: Option<usize>,
    tree_parent: Option<u32>,
    parent_el: Option<&'a Element>,
    parent_label: String,
    in_menu_bar: bool,
    /// What its scroll areas show, in its frames' units; None outside a
    /// scroll area and inside a menu (a menu can reach past its window).
    clip: Option<Rect>,
}

struct Walk<'o> {
    opts: &'o Options,
    focus: &'o [*const Element],
    out: &'o mut Outline,
}

impl Walk<'_> {
    fn has_focus(&self, e: &Element) -> bool {
        self.focus.last().is_some_and(|f| std::ptr::eq(*f, e))
    }

    fn on_focus_path(&self, e: &Element) -> bool {
        self.focus.iter().any(|f| std::ptr::eq(*f, e))
    }

    /// Counts `e` and everything inside it without showing them; `clipped`:
    /// because they are scrolled out of view.
    fn hide(&mut self, e: &Element, in_menu_bar: bool, clipped: bool) {
        self.out.elements += 1;
        if !in_menu_bar && let Ok(id) = e.id.parse::<u32>() {
            if clipped {
                self.out.clipped.insert(id);
            } else {
                self.out.present.insert(id);
            }
        }
        for c in &e.children {
            self.hide(c, in_menu_bar, clipped);
        }
    }

    fn visit<'a>(&mut self, e: &'a Element, at: &Place<'a>) {
        let opts = self.opts;
        let menu_bar = at.in_menu_bar || e.role == super::ids::MENU_BAR;
        // Scrolled out of view: counted on the nearest shown ancestor.
        if at.tree_depth > 0
            && !opts.offscreen
            && !menu_bar
            && !self.on_focus_path(e)
            && let Some(side) = out_of_view(e, at.clip)
        {
            if let Some(owner) = at.owner
                && let Some(n) =
                    self.out.lines.get_mut(owner).and_then(|l| l.out_of_view.get_mut(side))
            {
                *n += 1;
            }
            self.hide(e, false, true);
            return;
        }
        // A scroll bar's parts: its scroll area scrolls.
        if at.tree_depth > 0 && e.role == "scroll_bar" && !self.on_focus_path(e) {
            self.hide(e, menu_bar, false);
            return;
        }
        self.out.elements += 1;
        let own_id = e.id.parse::<u32>().ok();
        if !menu_bar && let Some(id) = own_id {
            self.out.present.insert(id);
        }
        // With the menus folded, the menu bar shows only its menus' titles.
        if at.in_menu_bar && !opts.menus && e.role != "menu_bar_item" {
            for c in &e.children {
                self.hide(c, true, false);
            }
            return;
        }
        let focus = self.has_focus(e);
        // A menu inside the menu bar is the item's own list: shown as the item's children.
        let fold = at.tree_depth > 0
            && (folds(e, at.parent_el, &at.parent_label, focus, at.in_menu_bar)
                || (at.in_menu_bar && e.role == "menu" && e.name.is_empty()));
        let label = if e.name.trim().is_empty() && is_static_text(&e.role) {
            e.value.trim().to_string()
        } else {
            e.name.trim().to_string()
        };
        let clip = match e.role.as_str() {
            "scroll_area" => narrow(at.clip, e.frame),
            "menu" => None,
            _ => at.clip,
        };
        let mut next = Place {
            tree_depth: at.tree_depth + 1,
            tree_parent: own_id,
            parent_el: Some(e),
            in_menu_bar: menu_bar,
            clip,
            ..at.clone()
        };
        let mut line_at = None;
        if !fold {
            let id = own_id.unwrap_or(0);
            let value = if is_static_text(&e.role) && e.name.trim().is_empty() {
                String::new()
            } else {
                e.value.clone()
            };
            self.out.lines.push(Line {
                id,
                depth: at.depth,
                parent: at.parent,
                tree_parent: at.tree_parent,
                role: e.role.clone(),
                label: label.clone(),
                value,
                identifier: if shows_identifier(&e.identifier) {
                    e.identifier.clone()
                } else {
                    String::new()
                },
                shortcut: e.shortcut.clone(),
                focused: focus,
                disabled: e.disabled,
                checked: e.checked,
                selected: e.selected,
                actions: shown_actions(e, menu_bar),
                frame: e.frame,
                menu_bar,
                out_of_view: [0; 4],
            });
            let index = self.out.lines.len() - 1;
            if focus {
                self.out.focused = Some(index);
            }
            line_at = Some(index);
            next.depth = at.depth + 1;
            next.parent = Some(id);
            next.owner = Some(index);
            next.parent_label = label;
        }
        if at.in_menu_bar && !opts.menus && e.role == "menu_bar_item" {
            for c in &e.children {
                self.hide(c, true, false);
            }
            return;
        }
        for c in &e.children {
            self.visit(c, &next);
        }
        // An item that shows nothing (a list's separator row): left out.
        if let Some(index) = line_at
            && index + 1 == self.out.lines.len()
        {
            let Some(l) = self.out.lines.get(index) else { return };
            if is_item(&l.role)
                && l.label.is_empty()
                && l.identifier.is_empty()
                && l.value.trim().is_empty()
                && l.actions.is_empty()
                && !l.focused
                && !l.selected
                && l.out_of_view == [0; 4]
            {
                self.out.lines.pop();
            }
        }
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
    if let Some(v) = out_of_view_text(&l.out_of_view) {
        s.push_str(" (");
        s.push_str(&v);
        s.push(')');
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

/// `out of view: 3 above, 176 below`, or None when everything shows.
pub fn out_of_view_text(n: &[usize; 4]) -> Option<String> {
    let parts: Vec<String> = ["above", "below", "left", "right"]
        .iter()
        .zip(n)
        .filter(|(_, n)| **n > 0)
        .map(|(side, n)| format!("{n} {side}"))
        .collect();
    (!parts.is_empty()).then(|| format!("out of view: {}", parts.join(", ")))
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
    let id = parent.id.parse::<u32>().ok();
    let at = Place {
        tree_depth: 1,
        tree_parent: id,
        parent: id,
        parent_el: Some(parent),
        parent_label: parent.name.trim().to_string(),
        in_menu_bar: true,
        ..Place::default()
    };
    let mut w = Walk { opts: &opts, focus: &[], out: &mut out };
    for c in &parent.children {
        w.visit(c, &at);
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
        s.push_str("\n(Cut at the element limit: a larger max_nodes, up to 5000, reads the rest.)");
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
