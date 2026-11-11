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
//! inside it: an item that would launch, open or hand data to a denied or
//! protected app (Open With, Services, Recent Items) is hidden from the tree
//! and refused on press, the same as that app's windows.

use serde::{Deserialize, Serialize};

use crate::desktop::{App, Element};
use crate::policy::{self, PolicyConfig, TargetApp};

/// `computerUse.menus`.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum MenuMode {
    /// Background calls may open a target app's menus (Codex parity).
    #[default]
    Open,
    /// Nothing that opens a menu runs in the background.
    Refuse,
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

/// What a desktop needs to decide about menus: the setting, and the names
/// (as menus show them) of the apps the deny list or protection covers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuPolicy {
    pub mode: MenuMode,
    pub denied_names: Vec<String>,
}

impl MenuPolicy {
    pub fn opens(&self) -> bool {
        self.mode == MenuMode::Open
    }

    /// The denied app an item names, by its own title or a menu above it
    /// (`Open With > Terminal`, `Services > New Terminal at Folder`).
    pub fn denied_item(&self, title: &str, path: &[String]) -> Option<&str> {
        self.denied_names
            .iter()
            .map(String::as_str)
            .find(|name| names_app(title, name) || path.iter().any(|p| names_app(p, name)))
    }
}

/// Whether `text` names `app` as a whole word or words, ignoring case.
fn names_app(text: &str, app: &str) -> bool {
    let (text, app) = (text.to_lowercase(), app.to_lowercase());
    if app.is_empty() {
        return false;
    }
    let mut from = 0;
    while let Some(at) = text[from..].find(&app) {
        let start = from + at;
        let end = start + app.len();
        let before = text[..start].chars().next_back();
        let after = text[end..].chars().next();
        let edge = |c: Option<char>| c.is_none_or(|c| !c.is_alphanumeric());
        if edge(before) && edge(after) {
            return true;
        }
        from = start + app.chars().next().map_or(1, char::len_utf8);
    }
    false
}

/// Known menu names of the apps on the engine's default deny list and of
/// protected UI, keyed by a representative app id: the deny list matches ids,
/// menus show names.
const KNOWN_NAMES: &[(&str, &[&str])] = &[
    ("com.apple.keychainaccess", &["Keychain Access"]),
    ("com.apple.Passwords", &["Passwords"]),
    ("com.1password.1password", &["1Password"]),
    ("com.agilebits.onepassword7", &["1Password 7"]),
    ("com.bitwarden.desktop", &["Bitwarden"]),
    ("com.dashlane.dashlanephonefinal", &["Dashlane"]),
    ("com.lastpass.lastpassmacdesktop", &["LastPass"]),
    ("com.nordpass.macos.NordPass", &["NordPass"]),
    ("me.proton.pass", &["Proton Pass"]),
    ("org.keepassxc.keepassxc", &["KeePassXC"]),
    ("com.markmcguill.strongbox", &["Strongbox"]),
    ("in.sinew.enpass-desktop", &["Enpass"]),
    ("com.keepersecurity.passwordmanager", &["Keeper Password Manager", "Keeper"]),
    ("com.apple.systempreferences", &["System Settings", "System Preferences"]),
    ("com.apple.Terminal", &["Terminal"]),
    ("com.googlecode.iterm2", &["iTerm", "iTerm2"]),
    ("com.mitchellh.ghostty", &["Ghostty"]),
    ("net.kovidgoyal.kitty", &["kitty"]),
    ("com.github.wez.wezterm", &["WezTerm"]),
    ("org.alacritty", &["Alacritty"]),
    ("dev.warp.Warp-Stable", &["Warp"]),
    ("com.cmuxterm.app", &["cmux"]),
    ("com.apple.securityagent", &["SecurityAgent"]),
    ("com.cmuxterm.remote", &["cmux Remote"]),
];

/// The names of the apps `config` denies or protects, as menus show them:
/// the known names of denied ids, the deny list's `name:` entries, and every
/// running app that is denied.
pub fn denied_names(config: &PolicyConfig, running: &[App]) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let mut add = |name: &str| {
        let name = name.trim();
        if name.chars().count() >= 3 && !names.iter().any(|n| n.eq_ignore_ascii_case(name)) {
            names.push(name.to_string());
        }
    };
    for (id, known) in KNOWN_NAMES {
        let app = TargetApp { id: (*id).into(), name: known[0].into() };
        if policy::is_blocked(config, &app).is_some() {
            known.iter().for_each(|n| add(n));
        }
    }
    for entry in &config.denied_apps {
        if let Some(name) = entry.trim().strip_prefix("name:") {
            add(name);
        }
    }
    for app in running {
        let target = TargetApp { id: app.id.clone(), name: app.name.clone() };
        if policy::is_blocked(config, &target).is_some() {
            add(&app.name);
        }
    }
    names
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

    pub fn picked(title: &str, open_ms: Option<u64>) -> Self {
        Self { state: "picked".into(), picked: title.into(), open_ms, ..Self::default() }
    }
}

/// How the agent continues after a call left a menu open.
pub const OPEN_NEXT: &str = "the menu is open: press an item (perform_action press or click on its element in get_ui_tree), or press_key Escape to close it";

/// Why `refuse` keeps a menu closed, and what to use instead.
pub fn refused_by_setting(what: &str) -> String {
    format!(
        "{what} opens a menu, and Computer Use is set not to open menus in the background (Settings > Computer Use > Menus, computerUse.menus is \"refuse\"); use set_value with an item title on a pop-up that lists its items while closed, perform_action on an element's own actions, or delivery foreground"
    )
}

/// Why a menu bar menu stays closed in the background.
pub const MENU_BAR_REFUSAL: &str = "menu bar menus are not opened in the background: the menu bar is the frontmost app's, so opening one would take over the person's menu bar; use the item's keyboard shortcut with press_key, the app's own controls, or delivery foreground";

/// Why an item leading to a denied app is refused.
pub fn denied_item_refusal(title: &str, app: &str) -> String {
    format!(
        "the menu item {title:?} would open or hand data to {app}, which Computer Use may not use (it is protected or on the deny list)"
    )
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

/// The plain role names of menu items in a tree.
const ITEM_ROLES: &[&str] = &["menu_item", "menu_bar_item"];

/// Removes the menu items of `root` that lead to a denied app (and their
/// submenus) and returns how many it removed.
pub fn hide_denied(root: &mut Element, policy: &MenuPolicy) -> usize {
    if policy.denied_names.is_empty() {
        return 0;
    }
    fn walk(e: &mut Element, policy: &MenuPolicy, path: &mut Vec<String>) -> usize {
        let mut removed = 0;
        e.children.retain(|c| {
            let denied = ITEM_ROLES.contains(&c.role.as_str())
                && policy.denied_item(&c.name, path).is_some();
            removed += usize::from(denied);
            !denied
        });
        for c in &mut e.children {
            let item = ITEM_ROLES.contains(&c.role.as_str());
            if item {
                path.push(c.name.clone());
            }
            removed += walk(c, policy, path);
            if item {
                path.pop();
            }
        }
        removed
    }
    walk(root, policy, &mut Vec::new())
}

#[cfg(test)]
#[path = "menus_tests.rs"]
mod tests;
