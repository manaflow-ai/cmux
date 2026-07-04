//! TUI configuration: `~/.config/cmux/mux.json` (override the path with
//! `CMUX_MUX_CONFIG`), with colors seeded from the user's Ghostty config
//! where sensible.
//!
//! ```json
//! {
//!   "theme": {
//!     "selection_background": "#3a3a3a",
//!     "selection_foreground": null,
//!     "sidebar_rail": "#87afd7",
//!     "sidebar_active_bg": 236,
//!     "tab_rail": "#87afd7",
//!     "tab_bg": 236,
//!     "tab_active_bg": null,
//!     "border_active": "#87afd7",
//!     "border_inactive": "#444444"
//!   },
//!   "tabs": {
//!     "min_width": 7,
//!     "solid_background": true,
//!     "show_titles": false,
//!     "agents": ["claude", "codex", "opencode", "pi"]
//!   },
//!   "sidebar": {
//!     "width": 22,
//!     "max_width": 0
//!   },
//!   "browser": {
//!     "chrome_binary": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
//!     "cdp_url": "http://127.0.0.1:9222",
//!     "discover": true,
//!     "discover_ports": [9222],
//!     "user_data_dir": "/Users/me/Library/Application Support/cmux-mux/chrome-profile",
//!     "ephemeral": false
//!   },
//!   "scrollbar": {
//!     "position": "column"
//!   },
//!   "keys": {
//!     "prefix": "ctrl+b",
//!     "alt_shortcuts": true,
//!     "new-tab": ["t", "alt+t"],
//!     "next-tab": "tab",
//!     "prev-tab": "backtab"
//!   }
//! }
//! ```
//!
//! Every key is optional. Colors are `#rrggbb`, `#rgb`, or an xterm-256
//! index (number or numeric string). Resolution order for the selection
//! colors: explicit config value, then the user's Ghostty config
//! (`selection-background`/`selection-foreground`), then the built-in
//! default.

use std::collections::HashMap;
use std::path::PathBuf;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Color;
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    #[serde(default)]
    theme: RawTheme,
    #[serde(default)]
    tabs: RawTabs,
    #[serde(default)]
    sidebar: RawSidebar,
    #[serde(default)]
    browser: RawBrowser,
    #[serde(default)]
    scrollbar: RawScrollbar,
    /// Key bindings: `"prefix"` plus one entry per action. Values may be
    /// a chord string, an array of chord strings, `"none"`, or
    /// `"alt_shortcuts": false`.
    #[serde(default)]
    keys: HashMap<String, Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTheme {
    selection_background: Option<ColorValue>,
    selection_foreground: Option<ColorValue>,
    sidebar_rail: Option<ColorValue>,
    sidebar_active_bg: Option<ColorValue>,
    tab_rail: Option<ColorValue>,
    tab_bg: Option<ColorValue>,
    tab_active_bg: Option<ColorValue>,
    border_active: Option<ColorValue>,
    border_inactive: Option<ColorValue>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTabs {
    min_width: Option<u16>,
    solid_background: Option<bool>,
    show_titles: Option<bool>,
    agents: Option<Vec<String>>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebar {
    width: Option<u16>,
    max_width: Option<u16>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawBrowser {
    chrome_binary: Option<String>,
    cdp_url: Option<String>,
    discover: Option<bool>,
    discover_ports: Option<Vec<u16>>,
    user_data_dir: Option<String>,
    ephemeral: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawScrollbar {
    position: Option<ScrollbarPosition>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ScrollbarPosition {
    Column,
    Border,
}

#[derive(Debug, Clone, Copy)]
pub struct Scrollbar {
    pub position: ScrollbarPosition,
}

impl Default for Scrollbar {
    fn default() -> Self {
        Scrollbar { position: ScrollbarPosition::Column }
    }
}

/// A color in the config file: "#rrggbb", "#rgb", or an xterm-256 index.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum ColorValue {
    Index(u8),
    Text(String),
}

impl ColorValue {
    fn to_color(&self) -> Option<Color> {
        match self {
            ColorValue::Index(i) => Some(Color::Indexed(*i)),
            ColorValue::Text(s) => parse_color(s),
        }
    }
}

/// Resolved presentation colors used by the renderers.
#[derive(Debug, Clone, Copy)]
pub struct Theme {
    pub selection_bg: Color,
    /// None keeps each cell's own foreground under the selection.
    pub selection_fg: Option<Color>,
    pub sidebar_rail: Color,
    pub sidebar_active_bg: Color,
    pub tab_rail: Color,
    pub tab_bg: Color,
    /// None keeps the focused/unfocused active-tab two-tone default.
    pub tab_active_bg: Option<Color>,
    pub border_active: Color,
    pub border_inactive: Color,
}

impl Default for Theme {
    fn default() -> Self {
        Theme {
            // Dark grey: readable but clearly a selection.
            selection_bg: Color::Rgb(0x3a, 0x3a, 0x3a),
            selection_fg: None,
            sidebar_rail: Color::Indexed(110),
            sidebar_active_bg: Color::Indexed(236),
            tab_rail: Color::Indexed(110),
            tab_bg: Color::Indexed(236),
            tab_active_bg: None,
            border_active: Color::Indexed(110),
            border_inactive: Color::Indexed(238),
        }
    }
}

/// Tab-bar behavior.
#[derive(Debug, Clone)]
pub struct Tabs {
    /// Minimum label width in cells (padded with spaces).
    pub min_width: u16,
    /// Tabs render with a solid background instead of text on the border.
    pub solid_background: bool,
    /// Show the process title after the number for every tab. Off by
    /// default: tabs are just numbers, except recognized agent programs.
    pub show_titles: bool,
    /// Program names worth surfacing in the tab label even when
    /// `show_titles` is off (matched as words in the reported title).
    pub agents: Vec<String>,
}

impl Default for Tabs {
    fn default() -> Self {
        Tabs {
            min_width: 7,
            solid_background: true,
            show_titles: false,
            agents: ["claude", "codex", "opencode", "pi"].map(String::from).to_vec(),
        }
    }
}

/// Sidebar behavior.
#[derive(Debug, Clone, Copy)]
pub struct Sidebar {
    pub width: u16,
    pub max_width: u16,
}

impl Default for Sidebar {
    fn default() -> Self {
        Sidebar { width: 22, max_width: 0 }
    }
}

#[derive(Debug, Clone)]
pub struct Browser {
    pub chrome_binary: Option<String>,
    pub cdp_url: Option<String>,
    pub discover: bool,
    pub discover_ports: Vec<u16>,
    pub user_data_dir: Option<String>,
    pub ephemeral: bool,
}

impl Default for Browser {
    fn default() -> Self {
        Browser {
            chrome_binary: None,
            cdp_url: None,
            discover: true,
            discover_ports: vec![9222],
            user_data_dir: None,
            ephemeral: false,
        }
    }
}

/// Every prefix-key action, so bindings are configurable end to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Action {
    NewTab,
    NewBrowserTab,
    NewPaneSmart,
    NextTab,
    PrevTab,
    SplitRight,
    SplitDown,
    CloseTab,
    ClosePane,
    RenameTab,
    RenameScreen,
    RenameWorkspace,
    CloseScreen,
    PrevScreen,
    NextScreen,
    NewScreen,
    NextWorkspace,
    NewWorkspace,
    ToggleSidebar,
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    ResizeGrow,
    ResizeShrink,
    ScrollUp,
    ScrollDown,
    Detach,
}

impl Action {
    fn config_key(&self) -> &'static str {
        match self {
            Action::NewTab => "new-tab",
            Action::NewBrowserTab => "new_browser_tab",
            Action::NewPaneSmart => "new-pane-smart",
            Action::NextTab => "next-tab",
            Action::PrevTab => "prev-tab",
            Action::SplitRight => "split-right",
            Action::SplitDown => "split-down",
            Action::CloseTab => "close-tab",
            Action::ClosePane => "close-pane",
            Action::RenameTab => "rename-tab",
            Action::RenameScreen => "rename-screen",
            Action::RenameWorkspace => "rename-workspace",
            Action::CloseScreen => "close-screen",
            Action::PrevScreen => "prev-screen",
            Action::NextScreen => "next-screen",
            Action::NewScreen => "new-screen",
            Action::NextWorkspace => "next-workspace",
            Action::NewWorkspace => "new-workspace",
            Action::ToggleSidebar => "toggle-sidebar",
            Action::FocusLeft => "focus-left",
            Action::FocusRight => "focus-right",
            Action::FocusUp => "focus-up",
            Action::FocusDown => "focus-down",
            Action::ResizeGrow => "resize-grow",
            Action::ResizeShrink => "resize-shrink",
            Action::ScrollUp => "scroll-up",
            Action::ScrollDown => "scroll-down",
            Action::Detach => "detach",
        }
    }
}

/// A key chord: code plus required modifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

impl Chord {
    pub fn matches(&self, key: &KeyEvent) -> bool {
        // Shift is implied by uppercase/symbol chars; compare it only
        // for non-char codes.
        let mods_match = if matches!(self.code, KeyCode::Char(_)) {
            key.modifiers.contains(self.mods & !KeyModifiers::SHIFT)
        } else {
            key.modifiers & (KeyModifiers::CONTROL | KeyModifiers::ALT)
                == self.mods & (KeyModifiers::CONTROL | KeyModifiers::ALT)
        };
        self.code == key.code && mods_match
    }
}

/// Resolved key bindings: the prefix chord plus one chord per action.
#[derive(Debug, Clone)]
pub struct Keys {
    pub prefix: Chord,
    bindings: Vec<(Chord, Action)>,
}

impl Default for Keys {
    fn default() -> Self {
        let bind = |code, action| (Chord { code, mods: KeyModifiers::NONE }, action);
        let alt = |code, action| (Chord { code, mods: KeyModifiers::ALT }, action);
        Keys {
            prefix: Chord { code: KeyCode::Char('b'), mods: KeyModifiers::CONTROL },
            bindings: vec![
                bind(KeyCode::Char('t'), Action::NewTab),
                alt(KeyCode::Char('t'), Action::NewTab),
                bind(KeyCode::Char('B'), Action::NewBrowserTab),
                alt(KeyCode::Char('n'), Action::NewPaneSmart),
                bind(KeyCode::Tab, Action::NextTab),
                bind(KeyCode::BackTab, Action::PrevTab),
                bind(KeyCode::Char('%'), Action::SplitRight),
                bind(KeyCode::Char('"'), Action::SplitDown),
                bind(KeyCode::Char('x'), Action::CloseTab),
                bind(KeyCode::Char('X'), Action::ClosePane),
                bind(KeyCode::Char(','), Action::RenameScreen),
                bind(KeyCode::Char('$'), Action::RenameWorkspace),
                bind(KeyCode::Char('&'), Action::CloseScreen),
                bind(KeyCode::Char('p'), Action::PrevScreen),
                alt(KeyCode::Char('['), Action::PrevScreen),
                bind(KeyCode::Char('n'), Action::NextScreen),
                alt(KeyCode::Char(']'), Action::NextScreen),
                bind(KeyCode::Char('c'), Action::NewScreen),
                bind(KeyCode::Char('w'), Action::NextWorkspace),
                bind(KeyCode::Char('W'), Action::NewWorkspace),
                bind(KeyCode::Char('s'), Action::ToggleSidebar),
                bind(KeyCode::Char('h'), Action::FocusLeft),
                bind(KeyCode::Left, Action::FocusLeft),
                alt(KeyCode::Char('h'), Action::FocusLeft),
                alt(KeyCode::Left, Action::FocusLeft),
                bind(KeyCode::Char('l'), Action::FocusRight),
                bind(KeyCode::Right, Action::FocusRight),
                alt(KeyCode::Char('l'), Action::FocusRight),
                alt(KeyCode::Right, Action::FocusRight),
                bind(KeyCode::Char('k'), Action::FocusUp),
                bind(KeyCode::Up, Action::FocusUp),
                alt(KeyCode::Char('k'), Action::FocusUp),
                alt(KeyCode::Up, Action::FocusUp),
                bind(KeyCode::Char('j'), Action::FocusDown),
                bind(KeyCode::Down, Action::FocusDown),
                alt(KeyCode::Char('j'), Action::FocusDown),
                alt(KeyCode::Down, Action::FocusDown),
                alt(KeyCode::Char('='), Action::ResizeGrow),
                alt(KeyCode::Char('-'), Action::ResizeShrink),
                bind(KeyCode::PageUp, Action::ScrollUp),
                bind(KeyCode::PageDown, Action::ScrollDown),
                bind(KeyCode::Char('d'), Action::Detach),
            ],
        }
    }
}

impl Keys {
    /// The action bound to a key event (after the prefix).
    pub fn action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.bindings.iter().find(|(chord, _)| chord.matches(key)).map(|(_, a)| *a)
    }

    /// The modeless action bound to a key event. Only Alt-modified
    /// chords are modeless; non-Alt chords remain prefix-only.
    pub fn modeless_action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.bindings
            .iter()
            .find(|(chord, _)| chord.mods.contains(KeyModifiers::ALT) && chord.matches(key))
            .map(|(_, a)| *a)
    }

    /// Apply config overrides: `"prefix"` rebinds the prefix; any action
    /// name rebinds that action (replacing ALL default chords for it).
    fn apply(&mut self, raw: &HashMap<String, Value>) {
        if raw.get("alt_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::ALT));
        }
        for (name, value) in raw {
            if name == "alt_shortcuts" {
                continue;
            }
            if name == "prefix" {
                let Some(value) = value.as_str() else {
                    eprintln!("cmux-mux: ignoring non-string prefix binding {value:?}");
                    continue;
                };
                let Some(chord) = parse_chord(value) else {
                    eprintln!("cmux-mux: ignoring unparseable key binding prefix = {value:?}");
                    continue;
                };
                self.prefix = chord;
                continue;
            }
            match all_actions().iter().find(|a| {
                a.config_key() == name || (**a == Action::RenameTab && name == "rename-pane")
            }) {
                Some(action) => {
                    self.bindings.retain(|(_, a)| a != action);
                    for raw_chord in key_values(value) {
                        if raw_chord.eq_ignore_ascii_case("none") {
                            continue;
                        }
                        let Some(chord) = parse_chord(raw_chord) else {
                            eprintln!(
                                "cmux-mux: ignoring unparseable key binding {name} = {raw_chord:?}"
                            );
                            continue;
                        };
                        self.bindings.push((chord, *action));
                    }
                }
                None => eprintln!("cmux-mux: ignoring unknown key action {name:?}"),
            }
        }
    }
}

fn key_values(value: &Value) -> Vec<&str> {
    match value {
        Value::String(s) => vec![s.as_str()],
        Value::Array(values) => values.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    }
}

fn all_actions() -> &'static [Action] {
    &[
        Action::NewTab,
        Action::NewBrowserTab,
        Action::NewPaneSmart,
        Action::NextTab,
        Action::PrevTab,
        Action::SplitRight,
        Action::SplitDown,
        Action::CloseTab,
        Action::ClosePane,
        Action::RenameTab,
        Action::RenameScreen,
        Action::RenameWorkspace,
        Action::CloseScreen,
        Action::PrevScreen,
        Action::NextScreen,
        Action::NewScreen,
        Action::NextWorkspace,
        Action::NewWorkspace,
        Action::ToggleSidebar,
        Action::FocusLeft,
        Action::FocusRight,
        Action::FocusUp,
        Action::FocusDown,
        Action::ResizeGrow,
        Action::ResizeShrink,
        Action::ScrollUp,
        Action::ScrollDown,
        Action::Detach,
    ]
}

/// Parse "c", "%", "ctrl+b", "alt+enter", "tab", "pageup", ...
fn parse_chord(s: &str) -> Option<Chord> {
    let mut mods = KeyModifiers::NONE;
    let mut code = None;
    for part in s.split('+') {
        let part = part.trim();
        match part.to_lowercase().as_str() {
            "ctrl" | "control" => mods |= KeyModifiers::CONTROL,
            "alt" | "option" => mods |= KeyModifiers::ALT,
            "shift" => mods |= KeyModifiers::SHIFT,
            "tab" => code = Some(KeyCode::Tab),
            "backtab" => code = Some(KeyCode::BackTab),
            "enter" | "return" => code = Some(KeyCode::Enter),
            "esc" | "escape" => code = Some(KeyCode::Esc),
            "space" => code = Some(KeyCode::Char(' ')),
            "left" => code = Some(KeyCode::Left),
            "right" => code = Some(KeyCode::Right),
            "up" => code = Some(KeyCode::Up),
            "down" => code = Some(KeyCode::Down),
            "pageup" => code = Some(KeyCode::PageUp),
            "pagedown" => code = Some(KeyCode::PageDown),
            "home" => code = Some(KeyCode::Home),
            "end" => code = Some(KeyCode::End),
            _ => {
                // Single character, case-sensitive (uppercase = shifted).
                let mut chars = part.chars();
                let c = chars.next()?;
                if chars.next().is_some() {
                    return None;
                }
                code = Some(KeyCode::Char(c));
            }
        }
    }
    let mut code = code?;
    if code == KeyCode::Tab && mods.contains(KeyModifiers::SHIFT) {
        code = KeyCode::BackTab;
        mods.remove(KeyModifiers::SHIFT);
    }
    Some(Chord { code, mods })
}

/// Full resolved configuration.
#[derive(Debug, Clone, Default)]
pub struct Config {
    pub theme: Theme,
    pub tabs: Tabs,
    pub sidebar: Sidebar,
    pub browser: Browser,
    pub scrollbar: Scrollbar,
    pub keys: Keys,
}

/// Load the config: defaults, overlaid with the user's Ghostty selection
/// colors, overlaid with `mux.json`.
pub fn load() -> Config {
    let mut config = Config::default();

    if let Some((bg, fg)) = ghostty_selection_colors() {
        if let Some(bg) = bg {
            config.theme.selection_bg = bg;
        }
        config.theme.selection_fg = fg;
    }

    let raw = load_raw_config();
    let t = &raw.theme;
    if let Some(c) = t.selection_background.as_ref().and_then(ColorValue::to_color) {
        config.theme.selection_bg = c;
    }
    if let Some(c) = t.selection_foreground.as_ref().and_then(ColorValue::to_color) {
        config.theme.selection_fg = Some(c);
    }
    if let Some(c) = t.sidebar_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_rail = c;
    }
    if let Some(c) = t.sidebar_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_active_bg = c;
    }
    if let Some(c) = t.tab_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_rail = c;
    }
    if let Some(c) = t.tab_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_bg = c;
    }
    if let Some(c) = t.tab_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_active_bg = Some(c);
    }
    if let Some(c) = t.border_active.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_active = c;
    }
    if let Some(c) = t.border_inactive.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_inactive = c;
    }
    if let Some(w) = raw.tabs.min_width {
        config.tabs.min_width = w.clamp(3, 40);
    }
    if let Some(b) = raw.tabs.solid_background {
        config.tabs.solid_background = b;
    }
    if let Some(b) = raw.tabs.show_titles {
        config.tabs.show_titles = b;
    }
    if let Some(agents) = raw.tabs.agents {
        config.tabs.agents = agents.into_iter().map(|a| a.to_lowercase()).collect();
    }
    if let Some(w) = raw.sidebar.width {
        config.sidebar.width = w.clamp(10, 60);
    }
    if let Some(w) = raw.sidebar.max_width {
        config.sidebar.max_width = w;
    }
    config.browser.chrome_binary = raw.browser.chrome_binary.filter(|s| !s.trim().is_empty());
    config.browser.cdp_url = raw.browser.cdp_url.filter(|s| !s.trim().is_empty());
    if let Some(discover) = raw.browser.discover {
        config.browser.discover = discover;
    }
    if let Some(ports) = raw.browser.discover_ports {
        config.browser.discover_ports = ports;
    }
    config.browser.user_data_dir = raw.browser.user_data_dir.filter(|s| !s.trim().is_empty());
    if let Some(ephemeral) = raw.browser.ephemeral {
        config.browser.ephemeral = ephemeral;
    }
    if let Some(position) = raw.scrollbar.position {
        config.scrollbar.position = position;
    }
    config.keys.apply(&raw.keys);
    config
}

/// The label for a tab: user name if set, otherwise its 1-based number
/// plus a recognized agent program name (or the full title when
/// `show_titles` is on).
pub fn tab_label(tabs: &Tabs, index: usize, title: &str, name: Option<&str>) -> String {
    if let Some(name) = name {
        if !name.is_empty() {
            return name.to_string();
        }
    }
    let number = index + 1;
    let suffix = if tabs.show_titles {
        (!title.is_empty()).then(|| title.to_string())
    } else {
        agent_in_title(tabs, title)
    };
    match suffix {
        Some(suffix) => format!("{number} {suffix}"),
        None => format!("{number}"),
    }
}

/// The first configured agent program appearing as a word in the title.
fn agent_in_title(tabs: &Tabs, title: &str) -> Option<String> {
    let lower = title.to_lowercase();
    let words: Vec<&str> =
        lower.split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_').collect();
    tabs.agents.iter().find(|agent| words.contains(&agent.as_str())).cloned()
}

fn config_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("CMUX_MUX_CONFIG") {
        return Some(PathBuf::from(path));
    }
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".config/cmux/mux.json"))
}

fn load_raw_config() -> RawConfig {
    let Some(path) = config_path() else { return RawConfig::default() };
    let Ok(text) = std::fs::read_to_string(&path) else { return RawConfig::default() };
    match serde_json::from_str(&text) {
        Ok(config) => config,
        Err(e) => {
            // A broken config should not take the TUI down; complain on
            // stderr (visible pre-alternate-screen and in logs).
            eprintln!("cmux-mux: ignoring invalid config {}: {e}", path.display());
            RawConfig::default()
        }
    }
}

/// `#rrggbb`, `#rgb`, or an xterm-256 index in a string.
fn parse_color(s: &str) -> Option<Color> {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix('#') {
        return match hex.len() {
            6 => {
                let n = u32::from_str_radix(hex, 16).ok()?;
                Some(Color::Rgb((n >> 16) as u8, (n >> 8) as u8, n as u8))
            }
            3 => {
                let n = u16::from_str_radix(hex, 16).ok()?;
                let (r, g, b) = ((n >> 8) & 0xf, (n >> 4) & 0xf, n & 0xf);
                Some(Color::Rgb((r * 17) as u8, (g * 17) as u8, (b * 17) as u8))
            }
            _ => None,
        };
    }
    s.parse::<u8>().ok().map(Color::Indexed)
}

/// The user's Ghostty selection colors, if a Ghostty config exists.
/// Returns (background, foreground); either may be absent. Ghostty's
/// config is `key = value` lines; later entries win, matching Ghostty.
fn ghostty_selection_colors() -> Option<(Option<Color>, Option<Color>)> {
    let home = std::env::var("HOME").ok()?;
    let candidates = [
        PathBuf::from(&home).join(".config/ghostty/config"),
        PathBuf::from(&home).join("Library/Application Support/com.mitchellh.ghostty/config"),
    ];
    let text = candidates.iter().find_map(|p| std::fs::read_to_string(p).ok())?;
    let mut bg = None;
    let mut fg = None;
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        match key.trim() {
            "selection-background" => bg = parse_color(value.trim()),
            "selection-foreground" => fg = parse_color(value.trim()),
            _ => {}
        }
    }
    Some((bg, fg))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hex_and_indexed_colors() {
        assert_eq!(parse_color("#3a3a3a"), Some(Color::Rgb(0x3a, 0x3a, 0x3a)));
        assert_eq!(parse_color("#fff"), Some(Color::Rgb(255, 255, 255)));
        assert_eq!(parse_color("110"), Some(Color::Indexed(110)));
        assert_eq!(parse_color("not-a-color"), None);
        assert_eq!(parse_color("#12345"), None);
    }

    #[test]
    fn tab_labels_are_numbers_except_agents() {
        let tabs = Tabs::default();
        assert_eq!(tab_label(&tabs, 0, "", None), "1");
        assert_eq!(tab_label(&tabs, 1, "zsh", None), "2");
        assert_eq!(tab_label(&tabs, 2, "vim src/main.rs", None), "3");
        // Recognized agent programs surface in the label.
        assert_eq!(tab_label(&tabs, 0, "claude", None), "1 claude");
        assert_eq!(tab_label(&tabs, 3, "✳ Codex CLI", None), "4 codex");
        assert_eq!(tab_label(&tabs, 4, "opencode - fix bug", None), "5 opencode");
        // "pi" matches only as a word, not inside other words.
        assert_eq!(tab_label(&tabs, 5, "pick a file", None), "6");
        assert_eq!(tab_label(&tabs, 5, "pi chat", None), "6 pi");
        assert_eq!(tab_label(&tabs, 5, "pi chat", Some("api")), "api");

        let titled = Tabs { show_titles: true, ..Tabs::default() };
        assert_eq!(tab_label(&titled, 1, "zsh", None), "2 zsh");
    }

    #[test]
    fn default_key_table_has_no_duplicate_chords_or_reserved_alt_words() {
        let keys = Keys::default();
        for (i, (left, _)) in keys.bindings.iter().enumerate() {
            assert!(
                !keys.bindings.iter().skip(i + 1).any(|(right, _)| left == right),
                "duplicate default chord: {left:?}"
            );
        }
        for c in ['b', 'f', 'd', '.'] {
            assert_eq!(
                keys.modeless_action_for(&KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)),
                None
            );
        }
    }

    #[test]
    fn config_overrides_defaults() {
        let dir = std::env::temp_dir().join(format!("mux-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(
            &path,
            r##"{
                "theme": {
                    "selection_background": "#101010",
                    "sidebar_rail": 42,
                    "sidebar_active_bg": "#202020",
                    "tab_bg": 44
                },
                "tabs": {"min_width": 9, "solid_background": false},
                "sidebar": {"width": 30, "max_width": 38},
                "scrollbar": {"position": "border"},
                "keys": {
                    "alt_shortcuts": false,
                    "rename-pane": "r",
                    "focus-left": ["left", "alt+h"],
                    "next-tab": "none"
                }
            }"##,
        )
        .unwrap();
        std::env::set_var("CMUX_MUX_CONFIG", &path);
        let config = load();
        std::env::remove_var("CMUX_MUX_CONFIG");
        let _ = std::fs::remove_file(&path);
        assert_eq!(config.theme.selection_bg, Color::Rgb(0x10, 0x10, 0x10));
        assert_eq!(config.theme.sidebar_rail, Color::Indexed(42));
        assert_eq!(config.theme.sidebar_active_bg, Color::Rgb(0x20, 0x20, 0x20));
        assert_eq!(config.theme.tab_bg, Color::Indexed(44));
        assert_eq!(config.tabs.min_width, 9);
        assert!(!config.tabs.solid_background);
        assert_eq!(config.sidebar.width, 30);
        assert_eq!(config.sidebar.max_width, 38);
        assert_eq!(config.scrollbar.position, ScrollbarPosition::Border);
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)),
            Some(Action::RenameTab)
        );
        assert_eq!(config.keys.action_for(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)), None);
        assert_eq!(
            config.keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)),
            None
        );
        assert_eq!(
            config.keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('h'), KeyModifiers::ALT)),
            Some(Action::FocusLeft)
        );
        // Untouched keys keep their default.
        assert_eq!(config.theme.border_inactive, Theme::default().border_inactive);
    }
}
