//! A `GlassMenu`'s rows (GlassMenu/GlassMenuRow.swift, GlassMenuTypeSelect.swift and the list's
//! sizing in GlassMenuListView.swift): which items show, which one a shortcut presses, how a
//! shortcut reads, type-to-jump, and the list's fitting size and row frames.

use super::Rect;
use serde::{Deserialize, Serialize};

/// The Command, Option, Control and Shift flags (the ones a menu shortcut compares).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Modifiers {
    pub command: bool,
    pub option: bool,
    pub control: bool,
    pub shift: bool,
}

/// An `NSMenuItem` as the row rules read it.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MenuItem {
    pub title: String,
    pub hidden: bool,
    pub separator: bool,
    /// The item has a view of its own (`item.view != nil`).
    pub has_view: bool,
    pub enabled: bool,
    pub key_equivalent: String,
    /// `keyEquivalentModifierMask`; an item with none set reads as Command (AppKit's default).
    pub modifiers: Option<Modifiers>,
    /// The item's submenu, already validated (`submenu.update()`).
    pub submenu: Option<Vec<MenuItem>>,
}

impl MenuItem {
    fn mask(&self) -> Modifiers {
        self.modifiers.unwrap_or(Modifiers { command: true, ..Modifiers::default() })
    }
}

/// `GlassMenuRow.rows(of:)`: the indices of the visible rows, `None` for a separator: no hidden
/// items, no item with its own view, no separator first, last or twice.
pub fn rows(items: &[MenuItem]) -> Vec<Option<usize>> {
    let mut rows: Vec<Option<usize>> = Vec::new();
    for (index, item) in items.iter().enumerate() {
        if item.hidden || item.has_view {
            continue;
        }
        if item.separator {
            if matches!(rows.last(), Some(Some(_))) {
                rows.push(None);
            }
        } else {
            rows.push(Some(index));
        }
    }
    if matches!(rows.last(), Some(None)) {
        rows.pop();
    }
    rows
}

/// `GlassMenuRow.item(matching:in:)`: the path (an index per menu level) of the enabled, visible
/// item whose key equivalent `characters` with `flags` presses, or `None`.
pub fn item_matching(characters: &str, flags: Modifiers, items: &[MenuItem]) -> Option<Vec<usize>> {
    let pressed = characters.to_lowercase();
    if pressed.is_empty() {
        return None;
    }
    find(&pressed, flags, items)
}

fn find(pressed: &str, flags: Modifiers, items: &[MenuItem]) -> Option<Vec<usize>> {
    for (index, item) in items.iter().enumerate() {
        if item.hidden || item.separator {
            continue;
        }
        if let Some(submenu) = &item.submenu {
            if let Some(mut path) = find(pressed, flags, submenu) {
                path.insert(0, index);
                return Some(path);
            }
            continue;
        }
        let key = &item.key_equivalent;
        if key.is_empty() || !item.enabled || key.to_lowercase() != pressed {
            continue;
        }
        let mut wanted = item.mask();
        if *key != key.to_lowercase() {
            wanted.shift = true;
        }
        if wanted == flags {
            return Some(vec![index]);
        }
    }
    None
}

/// `GlassMenuRow.shortcut(_:)`: the shortcut as the menu draws it (`⌘,`), or `None`.
pub fn shortcut(key: &str, mask: Modifiers) -> Option<String> {
    if key.is_empty() {
        return None;
    }
    let mut text = String::new();
    if mask.control {
        text.push('⌃');
    }
    if mask.option {
        text.push('⌥');
    }
    let shifted = key != key.to_lowercase();
    if mask.shift || shifted {
        text.push('⇧');
    }
    if mask.command {
        text.push('⌘');
    }
    let name = match key {
        "\r" => "↩".to_string(),
        "\u{1b}" => "⎋".to_string(),
        "\t" => "⇥".to_string(),
        " " => "Space".to_string(),
        "\u{8}" | "\u{7f}" => "⌫".to_string(),
        _ => key.to_uppercase(),
    };
    Some(text + &name)
}

/// `GlassMenuTypeSelect.timeout`: the pause (seconds) after which typing starts a new search.
pub const TYPE_SELECT_TIMEOUT: f64 = 1.0;

/// `GlassMenuTypeSelect`'s state.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TypeSelect {
    pub typed: String,
    /// The last typing's time; `None` before any (Swift's `-infinity`).
    pub last_time: Option<f64>,
}

impl TypeSelect {
    /// `pick(_:at:titles:current:)`: the row `characters` typed at `time` picks.
    pub fn pick(
        &mut self,
        characters: &str,
        time: f64,
        titles: &[Option<String>],
        current: Option<usize>,
    ) -> Option<usize> {
        let typed_now = fold(characters);
        if typed_now.is_empty() {
            return None;
        }
        if self.last_time.is_none_or(|last| time - last > TYPE_SELECT_TIMEOUT) {
            self.typed.clear();
        }
        self.last_time = Some(time);
        self.typed.push_str(&typed_now);
        let folded: Vec<Option<String>> = titles.iter().map(|t| t.as_deref().map(fold)).collect();
        let first = self.typed.chars().next()?;
        if self.typed.chars().all(|c| c == first) {
            let start = current.map_or(0, |c| c + 1);
            let count = folded.len();
            let prefix = first.to_string();
            return (start..count)
                .chain(0..start.min(count))
                .find(|&i| folded[i].as_deref().is_some_and(|t| t.starts_with(&prefix)));
        }
        folded.iter().position(|t| t.as_deref().is_some_and(|t| t.starts_with(&self.typed)))
    }
}

/// Case- and diacritic-insensitive folding (Foundation's `folding([.caseInsensitive,
/// .diacriticInsensitive])` for Latin text): lowercase, accents dropped.
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars().flat_map(char::to_lowercase) {
        if ('\u{300}'..='\u{36f}').contains(&c) {
            continue;
        }
        out.push(strip_accent(c));
    }
    out
}

fn strip_accent(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => 'c',
        'ď' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => 'g',
        'ĥ' => 'h',
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' => 'i',
        'ĵ' => 'j',
        'ķ' => 'k',
        'ĺ' | 'ļ' | 'ľ' => 'l',
        'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ō' | 'ŏ' | 'ő' => 'o',
        'ŕ' | 'ŗ' | 'ř' => 'r',
        'ś' | 'ŝ' | 'ş' | 'š' => 's',
        'ţ' | 'ť' => 't',
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => 'u',
        'ŵ' => 'w',
        'ý' | 'ÿ' | 'ŷ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

/// `GlassMenuListView.minWidth`.
pub const LIST_MIN_WIDTH: f64 = 220.0;
/// `GlassMenuListView.maxWidth`.
pub const LIST_MAX_WIDTH: f64 = 360.0;
/// `GlassMenuListView.separatorHeight`.
pub const SEPARATOR_HEIGHT: f64 = 9.0;

/// A loaded row's view as the list sizes it.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RowView {
    pub separator: bool,
    /// The view's `fittingSize`.
    pub width: f64,
    pub height: f64,
}

/// `GlassMenuListView.fittingMenuSize()`: `(width, height)`, each rounded up.
pub fn fitting_size(views: &[RowView], padding: f64, row_height: f64) -> (f64, f64) {
    let mut width = LIST_MIN_WIDTH;
    let mut height = padding * 2.0;
    for view in views {
        width = width.max(view.width + padding * 2.0);
        height += if view.separator { SEPARATOR_HEIGHT } else { view.height.max(row_height) };
    }
    (width.min(LIST_MAX_WIDTH).ceil(), height.ceil())
}

/// `GlassMenuListView.layout()`: each row's frame in a list `bounds_width` wide.
pub fn layout(views: &[RowView], padding: f64, row_height: f64, bounds_width: f64) -> Vec<Rect> {
    let mut y = padding;
    views
        .iter()
        .map(|view| {
            let height =
                if view.separator { SEPARATOR_HEIGHT } else { view.height.max(row_height) };
            let frame = Rect { x: padding, y, width: bounds_width - padding * 2.0, height };
            y += height;
            frame
        })
        .collect()
}
