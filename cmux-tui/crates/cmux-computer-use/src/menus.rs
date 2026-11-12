//! Menus in the background (`computerUse.menus`): whether a call may open a
//! pop-up, menu button, combo box list or context menu of an app the person
//! is not using, how an item is matched by title, and which items the deny
//! list hides. Pure, so every desktop and the engine share one decision.
//!
//! With `open` (the default, as Codex Computer Use does), a `set_value` on a
//! pop-up opens its menu, presses the item and closes it in one call; a press
//! or click on a pop-up, or a context menu, opens the menu and leaves it open
//! with its items in the result, so the next call picks one. With `refuse`,
//! nothing that opens a menu runs in the background. Menu bar menus never
//! open in the background (the app's menu bar is the frontmost app's).
//!
//! An open menu belongs to the app that opened it, and the deny list holds
//! inside it through the same [`MenuGuard`] as the menu bar: an item that
//! would launch, open or hand data to a denied or protected app (Open With,
//! Services, Recent Items, or any item whose title names one) is hidden from
//! the tree and refused on press, the same as that app's windows.

use serde::{Deserialize, Serialize};

use crate::desktop::MenuGuard;

/// `computerUse.menus`.
#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum MenuMode {
    /// Background calls may open a target app's menus (Codex parity).
    #[default]
    Open,
    /// Nothing that opens a menu runs in the background.
    Refuse,
}

/// Read leniently, so one bad value never drops a whole policy file (and its
/// deny list) on the floor: any case, and a value that is not a mode keeps
/// menus closed.
impl<'de> Deserialize<'de> for MenuMode {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        // Any value at all (null, false, a number) reads: not a mode means
        // refuse.
        let value = serde_json::Value::deserialize(d)?;
        Ok(value
            .as_str()
            .and_then(|text| MenuMode::parse(&text.trim().to_ascii_lowercase()))
            .unwrap_or(MenuMode::Refuse))
    }
}

impl MenuMode {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "open" => Some(Self::Open),
            "refuse" => Some(Self::Refuse),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Refuse => "refuse",
        }
    }
}

/// What a desktop needs to decide about menus: the setting. (The deny list
/// reaches menus through the desktop's [`MenuGuard`].)
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuPolicy {
    pub mode: MenuMode,
}

impl MenuPolicy {
    pub fn opens(&self) -> bool {
        self.mode == MenuMode::Open
    }
}

/// The longest app name, in words, a menu title is searched for.
const NAME_WORDS: usize = 4;

/// Whether some run of whole words in `title` names an app the guard blocks
/// (denied or protected): "New Terminal at Folder" and "Open in Terminal"
/// name Terminal, "Terminals Guide" does not. `resolve` gives the bundle ids
/// of the installed apps with a display name (none for an unknown name);
/// while it cannot answer yet (None) and anything is denied, the item counts
/// as blocked.
pub fn title_names_blocked_app(
    guard: &dyn MenuGuard,
    title: &str,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    let words: Vec<&str> = title
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|w| !w.is_empty())
        .collect();
    for start in 0..words.len() {
        for len in 1..=NAME_WORDS.min(words.len() - start) {
            let run = words[start..start + len].join(" ");
            if guard.app_blocked("", &run) {
                return true;
            }
            match resolve(&run) {
                None if guard.denies_any() => return true,
                Some(ids) if ids.iter().any(|id| guard.app_blocked(id, &run)) => return true,
                _ => {}
            }
        }
    }
    false
}

/// How a wanted title matched a menu's items.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ItemMatch {
    Found(usize),
    NotFound,
    /// More than one item starts with the wanted text.
    Ambiguous(Vec<usize>),
}

/// Trimmed, with `...` read as the ellipsis menus draw.
fn normalized(title: &str) -> String {
    title.trim().replace("...", "\u{2026}")
}

/// Finds the item titled `wanted`: the exact title, then the same title in
/// any case, then the one item whose title starts with it.
pub fn match_item(titles: &[String], wanted: &str) -> ItemMatch {
    let wanted = normalized(wanted);
    if wanted.is_empty() {
        return ItemMatch::NotFound;
    }
    let titles: Vec<String> = titles.iter().map(|t| normalized(t)).collect();
    if let Some(i) = titles.iter().position(|t| *t == wanted) {
        return ItemMatch::Found(i);
    }
    let lower = wanted.to_lowercase();
    if let Some(i) = titles.iter().position(|t| t.to_lowercase() == lower) {
        return ItemMatch::Found(i);
    }
    let prefixed: Vec<usize> = titles
        .iter()
        .enumerate()
        .filter(|(_, t)| !t.is_empty() && t.to_lowercase().starts_with(&lower))
        .map(|(i, _)| i)
        .collect();
    match prefixed.as_slice() {
        [] => ItemMatch::NotFound,
        [one] => ItemMatch::Found(*one),
        _ => ItemMatch::Ambiguous(prefixed),
    }
}

/// One item of an open menu, as a result lists it.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct MenuItemInfo {
    pub title: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disabled: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub checked: bool,
    /// It opens a submenu.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub submenu: bool,
}

/// What a call did with a menu, in its result as `menu`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct MenuReport {
    /// `open` (left open for the next call to pick from), `picked` or `cancelled`.
    pub state: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<MenuItemInfo>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub picked: String,
    /// How long the menu was on screen, for a call that opened and closed it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_ms: Option<u64>,
    /// Where the person's keyboard went while the menu was open: `person`
    /// (given back to their app) or `menu` (the menu held it).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub keyboard: String,
    /// Items hidden because they lead to a denied app.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hidden: usize,
    /// Visible items past the first LISTED_ITEMS_MAX, not listed (pick one
    /// by title with set_value).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub more: usize,
    /// What to do next.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub next: String,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

impl MenuReport {
    /// A menu left open: its items, and how to pick one.
    pub fn open(items: Vec<MenuItemInfo>, hidden: usize) -> Self {
        Self { state: "open".into(), items, hidden, next: OPEN_NEXT.into(), ..Self::default() }
    }

    /// A menu that was closed again rather than left open (it would hold
    /// the person's keyboard): its items, for a one-call pick.
    pub fn listed(items: Vec<MenuItemInfo>, hidden: usize) -> Self {
        Self { state: "listed".into(), items, hidden, next: LISTED_NEXT.into(), ..Self::default() }
    }

    pub fn picked(title: &str, open_ms: Option<u64>) -> Self {
        Self { state: "picked".into(), picked: title.into(), open_ms, ..Self::default() }
    }
}

/// The most items a result lists of an open menu (a font pop-up has
/// thousands): the rest are counted in `more`.
pub const LISTED_ITEMS_MAX: usize = 200;

/// How the agent continues after a menu was listed and closed.
pub const LISTED_NEXT: &str = "the menu was closed again: left open it would hold the person's keyboard (their own keys could reach an item Computer Use hides). Choose an item in one call: click the same place with menu_item set to its title, or a path for an item in a submenu (\"Open With > TextEdit\")";

/// How the agent continues after a call left a menu open.
pub const OPEN_NEXT: &str = "the menu is open: press an item (perform_action press or click on its element in get_ui_tree), or press_key Escape to close it";

/// Why `refuse` keeps a menu closed, and what to use instead.
pub fn refused_by_setting(what: &str) -> String {
    format!(
        "{what} opens a menu, and Computer Use is set not to open menus in the background (Settings > Computer Use > Menus, computerUse.menus is \"refuse\"); use set_value with an item title on a pop-up that lists its items while closed, perform_action on an element's own actions, or delivery foreground"
    )
}

/// Why keys that open a focused pop-up's menu are refused.
pub const MENU_KEYS_REFUSAL: &str = "Space, Return and the arrow keys open this focused pop-up's menu outside Computer Use's menu handling; use set_value with the item's title, or click the pop-up to open its menu";

/// Why a menu is not left open in the app the person is using.
pub const PERSONS_APP_REFUSAL: &str = "this menu belongs to the app the person is using, and a menu left open there takes their pointer and keyboard; use set_value with the item's title (it picks and closes the menu in one call), or delivery foreground";

/// Why Return or Space is refused while a menu is open.
pub const OPEN_MENU_KEYS_REFUSAL: &str = "a menu is open in this app: keys and typed text would reach the menu, not the window. Press its item by element (perform_action press, or click with element_id), move with the arrow keys, or press_key Escape to close it";

/// Why a drag is refused while a menu is open.
pub const OPEN_MENU_DRAG_REFUSAL: &str = "a menu is open in this app, and a drag would release over one of its items and run it; press the item by element, or press_key Escape to close the menu first";

/// Why a menu bar menu stays closed in the background.
pub const MENU_BAR_REFUSAL: &str = "menu bar menus are not opened in the background: the menu bar is the frontmost app's, so opening one would take over the person's menu bar; use the item's keyboard shortcut with press_key, the app's own controls, or delivery foreground";

/// Why an item leading to a denied app is refused. It is named only by the
/// text the agent gave (`wanted`): a hidden item's own title stays hidden.
pub fn denied_item_refusal(wanted: Option<&str>) -> String {
    let which = match wanted {
        Some(w) => format!("the menu item matching {w:?}"),
        None => "this menu item".to_string(),
    };
    format!(
        "{which} would open or hand data to an app Computer Use may not use (it is protected or on the deny list)"
    )
}

/// Why a pick fails while the installed app names are still being read
/// (menu items are checked against them and stay hidden until then).
pub const APP_NAMES_LOADING: &str = "the menu's items are still being checked against the installed apps (app names are loading); retry in a moment";

/// Why a menu that opened was closed again: the person's keyboard could
/// not be given back while it showed.
pub const KEYBOARD_KEPT_REFUSAL: &str = "the menu opened, but the person's keyboard could not be given back to their app while it showed, so it was closed again; use set_value with the item's title (it picks and closes the menu in one call), or delivery foreground";

/// Why a menu that opened was closed again: it could not be read.
pub const MENU_UNREAD: &str = "the app showed a menu that could not be read, so it was closed again; try perform_action on an element's own actions, or delivery foreground";

/// Why a call fails when the menu it opened could not be read or closed.
pub const MENU_UNREAD_OPEN: &str = "the app showed a menu that could not be read, and it is still open (it ignored Escape); keys, typing and drags into this app are refused until it closes: click elsewhere in the window, or try perform_action on an element's own actions";

/// Why Escape fails: the open menu did not close.
pub const MENU_DID_NOT_CLOSE: &str = "the menu did not close (it ignored AXCancel and Escape); it stays open, and keys, typing and drags into this app are refused until it closes";

/// Why keys are refused while another app's menu stays open.
pub const OTHER_MENU_KEYS_REFUSAL: &str = "a menu left open in another app did not close, and it holds the keyboard: keys and typing would reach it; press_key Escape in that app's window, or click elsewhere first";

/// Why a menu is not left open: it hides items and would hold the
/// person's keyboard while open.
pub const HIDDEN_ITEMS_HELD_REFUSAL: &str = "this menu has items Computer Use hides (they lead to an app it may not use), and left open it would hold the person's keyboard, so their typing could reach a hidden item; it was closed again. Choose the item in one call: click with menu_item (right click or a pop-up), or set_value on a pop-up";

/// Why a submenu is not opened (or arrows sent) into a menu holding the
/// person's keyboard.
pub const SUBMENU_HELD_REFUSAL: &str = "this open menu holds the person's keyboard and hides an item at some level, so a submenu (or arrows) could put the highlight on a hidden item and their Return would run it; press the item you want by element, or choose it in one call with click and menu_item, a path for a submenu's item (\"Sort By > Name\")";

/// The titles of a menu path ("Sort By > Name", "View ▸ as Icons"): each
/// level's item, outermost first. A title with no separator is one level.
pub fn menu_path(value: &str) -> Vec<String> {
    let parts: Vec<String> = value
        .split(['\u{25B8}', '>'])
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.is_empty() { vec![value.to_string()] } else { parts }
}

/// How a wanted title picks among a menu's items, the visible ones first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pick {
    /// The index (into all items) of the visible item to press.
    Item(usize),
    /// It matches only a hidden item.
    Hidden,
    /// Nothing visible matched (the match over the visible titles).
    Missing(ItemMatch),
}

/// Matches `wanted`: the exact title, then the same title in any case, over
/// every item (a hidden exact match is refused, never passed over for a
/// visible item that merely starts the same: "Terminal" with Terminal
/// hidden does not press "Terminals Guide"); then a unique prefix among
/// the visible items; a prefix only a hidden item has is refused. An
/// ambiguous prefix's indices are among the visible items.
pub fn pick(titles: &[String], hidden: &[bool], wanted: &str) -> Pick {
    let want = normalized(wanted);
    if want.is_empty() {
        return Pick::Missing(ItemMatch::NotFound);
    }
    let norm: Vec<String> = titles.iter().map(|t| normalized(t)).collect();
    let lower = want.to_lowercase();
    let exact = norm.iter().position(|t| *t == want);
    let case = || norm.iter().position(|t| t.to_lowercase() == lower);
    if let Some(i) = exact.or_else(case) {
        return if hidden[i] { Pick::Hidden } else { Pick::Item(i) };
    }
    let starts = |i: &usize| !norm[*i].is_empty() && norm[*i].to_lowercase().starts_with(&lower);
    let visible: Vec<usize> = (0..titles.len()).filter(|i| !hidden[*i]).filter(starts).collect();
    match visible.as_slice() {
        [one] => Pick::Item(*one),
        [] if (0..titles.len()).any(|i| hidden[i] && starts(&i)) => Pick::Hidden,
        [] => Pick::Missing(ItemMatch::NotFound),
        // Indices among the visible items, as the caller lists them.
        _ => {
            let shown: Vec<usize> = (0..titles.len()).filter(|i| !hidden[*i]).collect();
            Pick::Missing(ItemMatch::Ambiguous(
                visible.iter().filter_map(|v| shown.iter().position(|s| s == v)).collect(),
            ))
        }
    }
}

/// Why no item matched, with the items there are.
pub fn not_found(wanted: &str, found: &ItemMatch, titles: &[String]) -> String {
    let list = |idx: &mut dyn Iterator<Item = &String>| {
        let names: Vec<&str> = idx.map(String::as_str).take(40).collect();
        if names.is_empty() { "none".to_string() } else { names.join(", ") }
    };
    match found {
        ItemMatch::Ambiguous(idx) => format!(
            "more than one menu item starts with {wanted:?}: {}; give the full title",
            list(&mut idx.iter().filter_map(|i| titles.get(*i)))
        ),
        _ => format!(
            "the menu has no item titled {wanted:?} (it was closed again); its items: {}",
            list(&mut titles.iter().filter(|t| !t.trim().is_empty()))
        ),
    }
}

#[cfg(test)]
#[path = "menus_tests.rs"]
mod tests;
