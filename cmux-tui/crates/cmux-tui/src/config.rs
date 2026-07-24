//! TUI configuration: `~/.config/cmux/cmux-tui.json`, falling back to legacy
//! `mux.json` when present (override the path with `CMUX_TUI_CONFIG`, or
//! legacy `CMUX_MUX_CONFIG`), with colors seeded from the user's Ghostty config
//! where sensible.
//!
//! ```json
//! {
//!   "theme": {
//!     "chrome": "auto",
//!     "selection_background": "#3a3a3a",
//!     "selection_foreground": null,
//!     "sidebar_rail": "#87afd7",
//!     "sidebar_active_bg": 236,
//!     "tab_rail": "#87afd7",
//!     "tab_bg": 236,
//!     "tab_active_bg": null,
//!     "border_active": "#87afd7",
//!     "border_inactive": "#444444",
//!     "notification_info": "#87afd7",
//!     "notification_warning": "#d7af5f",
//!     "notification_error": "#d75f5f"
//!   },
//!   "tabs": {
//!     "min_width": 7,
//!     "solid_background": true,
//!     "show_titles": false,
//!     "agents": ["claude", "codex", "opencode", "pi"]
//!   },
//!   "sidebar": {
//!     "view": "files",
//!     "width": 22,
//!     "max_width": 0,
//!     "plugin": {
//!       "command": ["/path/to/plugin-binary"],
//!       "cwd": "/optional"
//!     }
//!   },
//!   "machine_sidebar": {
//!     "enabled": false,
//!     "width": 22,
//!     "max_width": 0
//!   },
//!   "machine_provider": {
//!     "cloud": {
//!       "enabled": false,
//!       "host": "cmux.cloud",
//!       "user": null,
//!       "port": null,
//!       "identity_file": null
//!     }
//!   },
//!   "browser": {
//!     "chrome_binary": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
//!     "mode": "headful",
//!     "cdp_url": "http://127.0.0.1:9222",
//!     "discover": false,
//!     "discover_ports": [9222],
//!     "user_data_dir": "/Users/me/Library/Application Support/cmux-tui/chrome-profile",
//!     "ephemeral": false,
//!     "max_capture_megapixels": 2.0,
//!     "capture_scale": null
//!   },
//!   "scrollbar": {
//!     "position": "column"
//!   },
//!   "server": {
//!     "ws": "127.0.0.1:7681",
//!     "ws_token": "replace-with-a-secret"
//!   },
//!   "keys": {
//!     "prefix": "ctrl+b",
//!     "alt_shortcuts": true,
//!     "super_shortcuts": true,
//!     "new-tab": ["t", "alt+t", "cmd+t"],
//!     "next-tab": "tab",
//!     "prev-tab": "backtab",
//!     "select-screen-0": "0",
//!     "browser-edit-url": "u"
//!   }
//! }
//! ```
//!
//! Every key is optional. Colors are `#rrggbb`, `#rgb`, or an xterm-256
//! index (number or numeric string). Resolution order for the selection
//! colors: explicit config value, then the user's Ghostty config
//! (`selection-background`/`selection-foreground`), then the built-in
//! default.
//!
//! Key bindings are configured under `"keys"`. Each action accepts a
//! chord string, an array of chord strings, or `"none"`. Overrides replace
//! all default chords for that action. Action names are:
//! `new-tab`, `new-browser-tab` (alias: `new_browser_tab`),
//! `new-pane-smart`, `next-tab`, `prev-tab`, `select-tab-0` through
//! `select-tab-9`, `split-right`, `split-down`, `close-tab`,
//! `close-pane`, `rename-tab` (alias: `rename-pane`), `rename-screen`,
//! `rename-workspace`, `close-screen`, `prev-screen`, `next-screen`,
//! `select-screen-0` through `select-screen-9`, `new-screen`,
//! `next-workspace`, `new-workspace`, `toggle-sidebar`, `toggle-sidebar-view`, `focus-sidebar`,
//! `focus-left`, `focus-right`, `focus-up`, `focus-down`, `focus-next-pane`,
//! `swap-pane-prev`, `swap-pane-next`, `zoom-pane`, `resize-grow`,
//! `resize-shrink`, `scroll-up`, `scroll-down`, `clear-history`, `browser-back`,
//! `browser-forward`, `browser-reload`, `browser-edit-url`, and `detach`.
//!
//! The defaults intentionally match tmux where cmux has the same
//! capability. `x` closes the active pane and `X` closes the active tab;
//! set `"close-pane": "X"` and `"close-tab": "x"` to restore the old
//! cmux defaults. Screen positions are zero-based, so each
//! `select-screen-N` action selects the screen at index `N`. Zellij's modal
//! `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are a
//! deliberate non-goal because they conflict with shell/editor control
//! keys.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::BrowserMode;
use cmux_tui_core::SidebarPluginOptions;
use cmux_tui_core::SurfaceOptions;
use cmux_tui_core::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS;
use cmux_tui_core::platform;
use cmux_tui_core::{CursorShape, DefaultColors, Rgb};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Color;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};

/// For a field typed `Option<Option<T>>`: makes an explicit `null` in the
/// input deserialize to `Some(None)` rather than the `None` an absent key
/// also produces, so callers can tell "not set" from "set to null".
fn deserialize_some<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Deserialize::deserialize(deserializer).map(Some)
}

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
    machine_sidebar: RawMachineSidebar,
    #[serde(default)]
    machine_provider: RawMachineProvider,
    #[serde(default)]
    machines: Vec<RawMachine>,
    #[serde(default)]
    browser: RawBrowser,
    #[serde(default)]
    scrollbar: RawScrollbar,
    #[serde(default)]
    server: RawServer,
    /// Key bindings: `"prefix"` plus one entry per action. Values may be
    /// a chord string, an array of chord strings, `"none"`, or
    /// `"alt_shortcuts": false`, or `"super_shortcuts": false`.
    #[serde(default)]
    keys: HashMap<String, Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawServer {
    ws: Option<String>,
    ws_token: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMachineProvider {
    #[serde(default)]
    cloud: RawCloudProvider,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCloudProvider {
    enabled: Option<bool>,
    host: Option<String>,
    user: Option<String>,
    port: Option<u16>,
    identity_file: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTheme {
    chrome: Option<ChromeMode>,
    selection_background: Option<ColorValue>,
    /// Distinguishes an absent key (keep the Ghostty-seeded value) from an
    /// explicit `null` (clear it back to "no override"), which `Option`
    /// alone cannot: serde maps both to `None`.
    #[serde(default, deserialize_with = "deserialize_some")]
    selection_foreground: Option<Option<ColorValue>>,
    sidebar_rail: Option<ColorValue>,
    sidebar_active_bg: Option<ColorValue>,
    tab_rail: Option<ColorValue>,
    tab_bg: Option<ColorValue>,
    tab_active_bg: Option<ColorValue>,
    border_active: Option<ColorValue>,
    border_inactive: Option<ColorValue>,
    notification_info: Option<ColorValue>,
    notification_warning: Option<ColorValue>,
    notification_error: Option<ColorValue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum ChromeMode {
    #[default]
    Auto,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChromeTheme {
    pub selection_bg: Color,
    pub selection_fg: Option<Color>,
    pub menu_bg: Color,
    pub menu_fg: Color,
    pub menu_border: Color,
    pub menu_selected_bg: Color,
    pub menu_selected_fg: Color,
    pub prompt_bg: Color,
    pub prompt_fg: Color,
    pub prompt_border: Color,
    pub prompt_title_fg: Color,
    pub prompt_input_bg: Color,
    pub prompt_input_fg: Color,
    pub prompt_button_accent_fg: Color,
    pub prompt_button_hover_bg: Color,
    pub toast_bg: Color,
    pub toast_fg: Color,
    pub status_bg: Color,
    pub status_fg: Color,
    pub status_dim_fg: Color,
    pub status_active_bg: Color,
    pub status_active_fg: Color,
    pub tab_bar_bg: Color,
    pub tab_fg: Color,
    pub tab_active_bg: Color,
    pub tab_active_fg: Color,
    pub tab_active_unfocused_bg: Color,
    pub tab_active_unfocused_fg: Color,
    pub tab_plain_fg: Color,
    pub tab_plain_active_fg: Color,
    pub tab_plain_unfocused_fg: Color,
    pub tab_control_hover_fg: Color,
    pub sidebar_dim_fg: Color,
    pub sidebar_selected_bg: Color,
    pub sidebar_selected_fg: Color,
    pub sidebar_border: Color,
    pub omnibar_fg: Color,
    pub omnibar_sep_fg: Color,
    pub omnibar_dim_fg: Color,
    pub omnibar_edit_bg: Color,
    pub omnibar_edit_fg: Color,
    pub omnibar_hover_fg: Color,
    pub border_active_fg: Color,
    pub border_fg: Color,
    pub browser_message_fg: Color,
    pub scrollbar_thumb_fg: Color,
    pub scrollbar_thumb_active_fg: Color,
    pub foreign_viewport_bg: Color,
    pub foreign_viewport_boundary_fg: Color,
    pub foreign_viewport_hint_fg: Color,
}

impl ChromeTheme {
    pub fn dark() -> Self {
        Self {
            selection_bg: Color::Rgb(0x3a, 0x3a, 0x3a),
            selection_fg: None,
            menu_bg: Color::Indexed(237),
            menu_fg: Color::Indexed(252),
            menu_border: Color::Indexed(244),
            menu_selected_bg: Color::Indexed(242),
            menu_selected_fg: Color::Indexed(255),
            prompt_bg: Color::Indexed(236),
            prompt_fg: Color::Indexed(252),
            prompt_border: Color::Indexed(244),
            prompt_title_fg: Color::Indexed(255),
            prompt_input_bg: Color::Indexed(233),
            prompt_input_fg: Color::Indexed(255),
            prompt_button_accent_fg: Color::Indexed(114),
            prompt_button_hover_bg: Color::Indexed(240),
            toast_bg: Color::Indexed(240),
            toast_fg: Color::Indexed(255),
            status_bg: Color::Indexed(236),
            status_fg: Color::Indexed(250),
            status_dim_fg: Color::Indexed(244),
            status_active_bg: Color::Indexed(240),
            status_active_fg: Color::Indexed(255),
            tab_bar_bg: Color::Indexed(236),
            tab_fg: Color::Indexed(248),
            tab_active_bg: Color::Indexed(240),
            tab_active_fg: Color::Indexed(255),
            tab_active_unfocused_bg: Color::Indexed(238),
            tab_active_unfocused_fg: Color::Indexed(252),
            tab_plain_fg: Color::Indexed(246),
            tab_plain_active_fg: Color::Indexed(255),
            tab_plain_unfocused_fg: Color::Indexed(250),
            tab_control_hover_fg: Color::Indexed(255),
            sidebar_dim_fg: Color::Indexed(242),
            sidebar_selected_bg: Color::Indexed(236),
            sidebar_selected_fg: Color::Indexed(255),
            sidebar_border: Color::Indexed(237),
            omnibar_fg: Color::Indexed(244),
            omnibar_sep_fg: Color::Indexed(238),
            omnibar_dim_fg: Color::Indexed(241),
            omnibar_edit_bg: Color::Indexed(236),
            omnibar_edit_fg: Color::Indexed(252),
            omnibar_hover_fg: Color::Indexed(255),
            border_active_fg: Color::Indexed(110),
            border_fg: Color::Indexed(238),
            browser_message_fg: Color::Indexed(244),
            scrollbar_thumb_fg: Color::Indexed(246),
            scrollbar_thumb_active_fg: Color::Indexed(252),
            foreign_viewport_bg: Color::Indexed(235),
            foreign_viewport_boundary_fg: Color::Indexed(240),
            foreign_viewport_hint_fg: Color::Indexed(244),
        }
    }

    pub fn light() -> Self {
        Self {
            selection_bg: Color::Rgb(0xcc, 0xdd, 0xf5),
            selection_fg: None,
            menu_bg: Color::Indexed(254),
            menu_fg: Color::Indexed(236),
            menu_border: Color::Indexed(246),
            menu_selected_bg: Color::Indexed(252),
            menu_selected_fg: Color::Indexed(234),
            prompt_bg: Color::Indexed(254),
            prompt_fg: Color::Indexed(236),
            prompt_border: Color::Indexed(246),
            prompt_title_fg: Color::Indexed(234),
            prompt_input_bg: Color::Indexed(255),
            prompt_input_fg: Color::Indexed(234),
            prompt_button_accent_fg: Color::Indexed(28),
            prompt_button_hover_bg: Color::Indexed(252),
            toast_bg: Color::Indexed(252),
            toast_fg: Color::Indexed(234),
            status_bg: Color::Indexed(254),
            status_fg: Color::Indexed(238),
            status_dim_fg: Color::Indexed(242),
            status_active_bg: Color::Indexed(252),
            status_active_fg: Color::Indexed(234),
            tab_bar_bg: Color::Indexed(254),
            tab_fg: Color::Indexed(240),
            tab_active_bg: Color::Indexed(252),
            tab_active_fg: Color::Indexed(234),
            tab_active_unfocused_bg: Color::Indexed(253),
            tab_active_unfocused_fg: Color::Indexed(236),
            tab_plain_fg: Color::Indexed(242),
            tab_plain_active_fg: Color::Indexed(234),
            tab_plain_unfocused_fg: Color::Indexed(238),
            tab_control_hover_fg: Color::Indexed(234),
            sidebar_dim_fg: Color::Indexed(242),
            sidebar_selected_bg: Color::Indexed(253),
            sidebar_selected_fg: Color::Indexed(234),
            sidebar_border: Color::Indexed(246),
            omnibar_fg: Color::Indexed(240),
            omnibar_sep_fg: Color::Indexed(246),
            omnibar_dim_fg: Color::Indexed(242),
            omnibar_edit_bg: Color::Indexed(255),
            omnibar_edit_fg: Color::Indexed(234),
            omnibar_hover_fg: Color::Indexed(234),
            border_active_fg: Color::Indexed(31),
            border_fg: Color::Indexed(246),
            browser_message_fg: Color::Indexed(242),
            scrollbar_thumb_fg: Color::Indexed(246),
            scrollbar_thumb_active_fg: Color::Indexed(240),
            foreign_viewport_bg: Color::Indexed(250),
            foreign_viewport_boundary_fg: Color::Indexed(246),
            foreign_viewport_hint_fg: Color::Indexed(242),
        }
    }

    pub fn for_defaults(mode: ChromeMode, colors: DefaultColors) -> Self {
        match mode {
            ChromeMode::Light => Self::light(),
            ChromeMode::Dark => Self::dark(),
            ChromeMode::Auto => match colors.bg {
                Some(bg) if is_light_background(bg) => Self::light(),
                _ => Self::dark(),
            },
        }
    }
}

pub fn is_light_background(bg: Rgb) -> bool {
    let luminance = 0.2126 * f64::from(bg.r) + 0.7152 * f64::from(bg.g) + 0.0722 * f64::from(bg.b);
    luminance > 128.0
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
    view: Option<String>,
    width: Option<u16>,
    max_width: Option<u16>,
    plugin: Option<RawSidebarPlugin>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebarPlugin {
    command: Option<Vec<String>>,
    cwd: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMachineSidebar {
    enabled: Option<bool>,
    width: Option<u16>,
    max_width: Option<u16>,
}

#[derive(Debug)]
struct RawMachine {
    id: String,
    name: String,
    subtitle: String,
    target: RawMachineTarget,
}

#[derive(Debug)]
enum RawMachineTarget {
    Unix {
        socket: String,
    },
    Ssh {
        host: String,
        user: Option<String>,
        port: Option<u16>,
        identity_file: Option<String>,
        session: Option<String>,
        binary: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum RawMachineTransport {
    Unix,
    Ssh,
}

/// The public machine shape stays flat for compatibility, while this wire
/// type gives serde one exact field set to validate before transport-specific
/// checks run. `flatten` and `deny_unknown_fields` cannot safely be combined.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMachineWire {
    id: String,
    name: String,
    #[serde(default)]
    subtitle: String,
    transport: RawMachineTransport,
    socket: Option<String>,
    host: Option<String>,
    user: Option<String>,
    port: Option<u16>,
    identity_file: Option<String>,
    session: Option<String>,
    binary: Option<String>,
}

impl<'de> Deserialize<'de> for RawMachine {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawMachineWire::deserialize(deserializer)?;
        let target = match raw.transport {
            RawMachineTransport::Unix => {
                if raw.host.is_some()
                    || raw.user.is_some()
                    || raw.port.is_some()
                    || raw.identity_file.is_some()
                    || raw.session.is_some()
                    || raw.binary.is_some()
                {
                    return Err(serde::de::Error::custom(
                        "SSH fields are not valid for a unix machine transport",
                    ));
                }
                RawMachineTarget::Unix {
                    socket: raw.socket.ok_or_else(|| serde::de::Error::missing_field("socket"))?,
                }
            }
            RawMachineTransport::Ssh => {
                if raw.socket.is_some() {
                    return Err(serde::de::Error::custom(
                        "socket is not valid for an ssh machine transport",
                    ));
                }
                RawMachineTarget::Ssh {
                    host: raw.host.ok_or_else(|| serde::de::Error::missing_field("host"))?,
                    user: raw.user,
                    port: raw.port,
                    identity_file: raw.identity_file,
                    session: raw.session,
                    binary: raw.binary,
                }
            }
        };
        Ok(Self { id: raw.id, name: raw.name, subtitle: raw.subtitle, target })
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawBrowser {
    chrome_binary: Option<String>,
    mode: Option<ConfigBrowserMode>,
    cdp_url: Option<String>,
    discover: Option<bool>,
    discover_ports: Option<Vec<u16>>,
    user_data_dir: Option<String>,
    ephemeral: Option<bool>,
    max_capture_megapixels: Option<f64>,
    capture_scale: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum ConfigBrowserMode {
    Headful,
    Headless,
}

impl From<ConfigBrowserMode> for BrowserMode {
    fn from(mode: ConfigBrowserMode) -> Self {
        match mode {
            ConfigBrowserMode::Headful => BrowserMode::Headful,
            ConfigBrowserMode::Headless => BrowserMode::Headless,
        }
    }
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
    pub notification_info: Color,
    pub notification_warning: Color,
    pub notification_error: Color,
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
            notification_info: Color::Indexed(110),
            notification_warning: Color::Indexed(179),
            notification_error: Color::Indexed(167),
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
#[derive(Debug, Clone)]
pub struct Sidebar {
    /// Built-in view used when `plugin` is unset. The default is the file browser.
    pub view: SidebarView,
    pub width: u16,
    pub max_width: u16,
    pub plugin: Option<SidebarPluginOptions>,
}

impl Default for Sidebar {
    fn default() -> Self {
        Sidebar { view: SidebarView::Workspaces, width: 22, max_width: 0, plugin: None }
    }
}

/// Optional client-local rail listing connection targets. It is disabled for
/// ordinary local cmux sessions and enabled by a machine provider or config.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MachineSidebar {
    pub enabled: bool,
    pub width: u16,
    pub max_width: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MachineProviderConfig {
    pub cloud: CloudProviderConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudProviderConfig {
    pub enabled: bool,
    pub host: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<PathBuf>,
}

impl Default for CloudProviderConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            host: "cmux.cloud".to_string(),
            user: None,
            port: None,
            identity_file: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineConfig {
    pub id: String,
    pub name: String,
    pub subtitle: String,
    pub target: MachineTargetConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineTargetConfig {
    Unix {
        socket: PathBuf,
    },
    Ssh {
        host: String,
        user: Option<String>,
        port: Option<u16>,
        identity_file: Option<PathBuf>,
        session: String,
        binary: String,
    },
}

impl Default for MachineSidebar {
    fn default() -> Self {
        Self { enabled: false, width: 22, max_width: 0 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SidebarView {
    #[default]
    Files,
    Workspaces,
}

impl SidebarView {
    pub fn toggled(self) -> Self {
        match self {
            Self::Files => Self::Workspaces,
            Self::Workspaces => Self::Files,
        }
    }
}

fn parse_sidebar_view(value: &str) -> Result<SidebarView, String> {
    match value {
        "files" => Ok(SidebarView::Files),
        "workspaces" => Ok(SidebarView::Workspaces),
        _ => Err(format!(
            "cmux-tui: ignoring unknown sidebar.view {value:?}; expected \"files\" or \"workspaces\""
        )),
    }
}

#[derive(Debug, Clone)]
pub struct Browser {
    pub chrome_binary: Option<String>,
    pub mode: BrowserMode,
    pub cdp_url: Option<String>,
    pub discover: bool,
    pub discover_ports: Vec<u16>,
    pub user_data_dir: Option<String>,
    pub ephemeral: bool,
    pub max_capture_megapixels: f64,
    pub capture_scale: Option<f64>,
}

impl Default for Browser {
    fn default() -> Self {
        Browser {
            chrome_binary: None,
            mode: BrowserMode::Headful,
            cdp_url: None,
            discover: false,
            discover_ports: vec![9222],
            user_data_dir: None,
            ephemeral: false,
            max_capture_megapixels: TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            capture_scale: None,
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
    SelectTab(u8),
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
    SelectScreen(u8),
    NewScreen,
    NextWorkspace,
    NewWorkspace,
    ToggleSidebar,
    ToggleSidebarView,
    FocusSidebar,
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    FocusNextPane,
    SwapPanePrev,
    SwapPaneNext,
    ZoomPane,
    ResizeGrow,
    ResizeShrink,
    ScrollUp,
    ScrollDown,
    ClearHistory,
    BrowserBack,
    BrowserForward,
    BrowserReload,
    BrowserEditUrl,
    Detach,
}

impl Action {
    fn config_key(&self) -> String {
        match self {
            Action::NewTab => "new-tab".to_string(),
            Action::NewBrowserTab => "new-browser-tab".to_string(),
            Action::NewPaneSmart => "new-pane-smart".to_string(),
            Action::NextTab => "next-tab".to_string(),
            Action::PrevTab => "prev-tab".to_string(),
            Action::SelectTab(number) => format!("select-tab-{number}"),
            Action::SplitRight => "split-right".to_string(),
            Action::SplitDown => "split-down".to_string(),
            Action::CloseTab => "close-tab".to_string(),
            Action::ClosePane => "close-pane".to_string(),
            Action::RenameTab => "rename-tab".to_string(),
            Action::RenameScreen => "rename-screen".to_string(),
            Action::RenameWorkspace => "rename-workspace".to_string(),
            Action::CloseScreen => "close-screen".to_string(),
            Action::PrevScreen => "prev-screen".to_string(),
            Action::NextScreen => "next-screen".to_string(),
            Action::SelectScreen(number) => format!("select-screen-{number}"),
            Action::NewScreen => "new-screen".to_string(),
            Action::NextWorkspace => "next-workspace".to_string(),
            Action::NewWorkspace => "new-workspace".to_string(),
            Action::ToggleSidebar => "toggle-sidebar".to_string(),
            Action::ToggleSidebarView => "toggle-sidebar-view".to_string(),
            Action::FocusSidebar => "focus-sidebar".to_string(),
            Action::FocusLeft => "focus-left".to_string(),
            Action::FocusRight => "focus-right".to_string(),
            Action::FocusUp => "focus-up".to_string(),
            Action::FocusDown => "focus-down".to_string(),
            Action::FocusNextPane => "focus-next-pane".to_string(),
            Action::SwapPanePrev => "swap-pane-prev".to_string(),
            Action::SwapPaneNext => "swap-pane-next".to_string(),
            Action::ZoomPane => "zoom-pane".to_string(),
            Action::ResizeGrow => "resize-grow".to_string(),
            Action::ResizeShrink => "resize-shrink".to_string(),
            Action::ScrollUp => "scroll-up".to_string(),
            Action::ScrollDown => "scroll-down".to_string(),
            Action::ClearHistory => "clear-history".to_string(),
            Action::BrowserBack => "browser-back".to_string(),
            Action::BrowserForward => "browser-forward".to_string(),
            Action::BrowserReload => "browser-reload".to_string(),
            Action::BrowserEditUrl => "browser-edit-url".to_string(),
            Action::Detach => "detach".to_string(),
        }
    }

    pub fn screen_index(&self) -> Option<usize> {
        match self {
            Action::SelectScreen(number @ 0..=9) => Some(*number as usize),
            _ => None,
        }
    }

    pub fn tab_index(&self) -> Option<usize> {
        match self {
            Action::SelectTab(number @ 0..=9) => Some(*number as usize),
            _ => None,
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
        const TRACKED: KeyModifiers = KeyModifiers::CONTROL
            .union(KeyModifiers::ALT)
            .union(KeyModifiers::SHIFT)
            .union(KeyModifiers::SUPER)
            .union(KeyModifiers::HYPER)
            .union(KeyModifiers::META);
        let normalize = |code, mut mods: KeyModifiers| match code {
            KeyCode::Char(c) if mods.contains(KeyModifiers::SHIFT) => {
                mods.remove(KeyModifiers::SHIFT);
                (KeyCode::Char(crate::keys::shifted_ascii_char(c)), mods)
            }
            KeyCode::BackTab => {
                // Crossterm reports BackTab with an implied Shift modifier.
                mods.remove(KeyModifiers::SHIFT);
                (KeyCode::BackTab, mods)
            }
            _ => (code, mods),
        };
        let (configured_code, configured_mods) = normalize(self.code, self.mods);
        let (event_code, event_mods) = normalize(key.code, key.modifiers);
        configured_code == event_code && configured_mods & TRACKED == event_mods & TRACKED
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
        let command = |code, action| (Chord { code, mods: KeyModifiers::SUPER }, action);
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
                bind(KeyCode::Char('x'), Action::ClosePane),
                bind(KeyCode::Char('X'), Action::CloseTab),
                bind(KeyCode::Char(','), Action::RenameScreen),
                bind(KeyCode::Char('$'), Action::RenameWorkspace),
                bind(KeyCode::Char('&'), Action::CloseScreen),
                bind(KeyCode::Char('p'), Action::PrevScreen),
                alt(KeyCode::Char('['), Action::PrevScreen),
                bind(KeyCode::Char('n'), Action::NextScreen),
                alt(KeyCode::Char(']'), Action::NextScreen),
                bind(KeyCode::Char('1'), Action::SelectScreen(1)),
                bind(KeyCode::Char('2'), Action::SelectScreen(2)),
                bind(KeyCode::Char('3'), Action::SelectScreen(3)),
                bind(KeyCode::Char('4'), Action::SelectScreen(4)),
                bind(KeyCode::Char('5'), Action::SelectScreen(5)),
                bind(KeyCode::Char('6'), Action::SelectScreen(6)),
                bind(KeyCode::Char('7'), Action::SelectScreen(7)),
                bind(KeyCode::Char('8'), Action::SelectScreen(8)),
                bind(KeyCode::Char('9'), Action::SelectScreen(9)),
                bind(KeyCode::Char('0'), Action::SelectScreen(0)),
                bind(KeyCode::Char('c'), Action::NewScreen),
                bind(KeyCode::Char('w'), Action::NextWorkspace),
                bind(KeyCode::Char('W'), Action::NewWorkspace),
                bind(KeyCode::Char('s'), Action::ToggleSidebar),
                bind(KeyCode::Char('e'), Action::ToggleSidebarView),
                bind(KeyCode::Char('S'), Action::FocusSidebar),
                bind(KeyCode::Char('o'), Action::FocusNextPane),
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
                bind(KeyCode::Char('z'), Action::ZoomPane),
                bind(KeyCode::Char('{'), Action::SwapPanePrev),
                bind(KeyCode::Char('}'), Action::SwapPaneNext),
                bind(KeyCode::Char('['), Action::ScrollUp),
                bind(KeyCode::PageUp, Action::ScrollUp),
                bind(KeyCode::PageDown, Action::ScrollDown),
                command(KeyCode::Char('k'), Action::ClearHistory),
                bind(KeyCode::Char('<'), Action::BrowserBack),
                bind(KeyCode::Char('>'), Action::BrowserForward),
                bind(KeyCode::Char('r'), Action::BrowserReload),
                bind(KeyCode::Char('u'), Action::BrowserEditUrl),
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

    /// The modeless action bound to a key event. Alt- and Super-modified
    /// chords are modeless; other chords remain prefix-only.
    pub fn modeless_action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.bindings
            .iter()
            .find(|(chord, _)| {
                chord.mods.intersects(KeyModifiers::ALT | KeyModifiers::SUPER) && chord.matches(key)
            })
            .map(|(_, a)| *a)
    }

    /// Apply config overrides: `"prefix"` rebinds the prefix; any action
    /// name rebinds that action (replacing ALL default chords for it).
    fn apply(&mut self, raw: &HashMap<String, Value>) {
        if raw.get("alt_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::ALT));
        }
        if raw.get("super_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::SUPER));
        }
        for (name, value) in raw {
            if name == "alt_shortcuts" || name == "super_shortcuts" {
                continue;
            }
            if name == "prefix" {
                let Some(value) = value.as_str() else {
                    eprintln!("cmux-tui: ignoring non-string prefix binding {value:?}");
                    continue;
                };
                let Some(chord) = parse_chord(value) else {
                    eprintln!("cmux-tui: ignoring unparseable key binding prefix = {value:?}");
                    continue;
                };
                self.prefix = chord;
                continue;
            }
            // The numbered families accept both spellings: select-screen-N /
            // select_screen_N and select-tab-N / select_tab_N.
            let normalized =
                if name.starts_with("select_screen_") || name.starts_with("select_tab_") {
                    name.replace('_', "-")
                } else {
                    name.clone()
                };
            match all_actions().iter().find(|a| {
                a.config_key() == normalized.as_str()
                    || (**a == Action::RenameTab && name == "rename-pane")
                    || (**a == Action::NewBrowserTab && name == "new_browser_tab")
            }) {
                Some(action) => {
                    self.bindings.retain(|(_, a)| a != action);
                    for raw_chord in key_values(value) {
                        if raw_chord.eq_ignore_ascii_case("none") {
                            continue;
                        }
                        let Some(chord) = parse_chord(raw_chord) else {
                            eprintln!(
                                "cmux-tui: ignoring unparseable key binding {name} = {raw_chord:?}"
                            );
                            continue;
                        };
                        self.bindings.retain(|(existing, _)| existing != &chord);
                        self.bindings.push((chord, *action));
                    }
                }
                None => eprintln!("cmux-tui: ignoring unknown key action {name:?}"),
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
        Action::SelectTab(0),
        Action::SelectTab(1),
        Action::SelectTab(2),
        Action::SelectTab(3),
        Action::SelectTab(4),
        Action::SelectTab(5),
        Action::SelectTab(6),
        Action::SelectTab(7),
        Action::SelectTab(8),
        Action::SelectTab(9),
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
        Action::SelectScreen(0),
        Action::SelectScreen(1),
        Action::SelectScreen(2),
        Action::SelectScreen(3),
        Action::SelectScreen(4),
        Action::SelectScreen(5),
        Action::SelectScreen(6),
        Action::SelectScreen(7),
        Action::SelectScreen(8),
        Action::SelectScreen(9),
        Action::NewScreen,
        Action::NextWorkspace,
        Action::NewWorkspace,
        Action::ToggleSidebar,
        Action::ToggleSidebarView,
        Action::FocusSidebar,
        Action::FocusLeft,
        Action::FocusRight,
        Action::FocusUp,
        Action::FocusDown,
        Action::FocusNextPane,
        Action::SwapPanePrev,
        Action::SwapPaneNext,
        Action::ZoomPane,
        Action::ResizeGrow,
        Action::ResizeShrink,
        Action::ScrollUp,
        Action::ScrollDown,
        Action::ClearHistory,
        Action::BrowserBack,
        Action::BrowserForward,
        Action::BrowserReload,
        Action::BrowserEditUrl,
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
            "cmd" | "command" | "super" => mods |= KeyModifiers::SUPER,
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
    } else if let KeyCode::Char(c) = code
        && mods.contains(KeyModifiers::SHIFT)
    {
        code = KeyCode::Char(crate::keys::shifted_ascii_char(c));
        // Store the resulting character so `D` and `shift+d` stay equivalent.
        // `Chord::matches` applies the same conversion to enhanced base-key
        // events before comparison.
        mods.remove(KeyModifiers::SHIFT);
    }
    Some(Chord { code, mods })
}

/// Full resolved configuration.
#[derive(Debug, Clone, Default)]
pub struct Config {
    pub theme: Theme,
    pub theme_overrides: ThemeOverrides,
    pub terminal_defaults: DefaultColors,
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    pub chrome: ChromeMode,
    pub tabs: Tabs,
    pub sidebar: Sidebar,
    pub machine_sidebar: MachineSidebar,
    pub machine_provider: MachineProviderConfig,
    pub machines: Vec<MachineConfig>,
    pub browser: Browser,
    pub scrollbar: Scrollbar,
    pub server: Server,
    pub keys: Keys,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Server {
    pub ws: Option<String>,
    pub ws_token: Option<String>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ThemeOverrides {
    pub selection: bool,
    pub sidebar_active_bg: bool,
    pub tab_bg: bool,
    pub border_active: bool,
    pub border_inactive: bool,
}

impl Config {
    pub fn apply_chrome_defaults(&mut self, chrome: ChromeTheme) {
        if !self.theme_overrides.selection {
            self.theme.selection_bg = chrome.selection_bg;
            self.theme.selection_fg = chrome.selection_fg;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarPluginConfig {
    pub command: Vec<String>,
    pub cwd: Option<String>,
}

/// Load the config: defaults, overlaid with the user's Ghostty selection
/// colors, overlaid with `cmux-tui.json` or legacy `mux.json`.
pub fn load() -> Config {
    let mut config = Config::default();

    let defaults = ghostty_defaults();
    config.terminal_defaults = defaults;
    if let Some(bg) = defaults.selection_bg {
        config.theme.selection_bg = Color::Rgb(bg.r, bg.g, bg.b);
        config.theme_overrides.selection = true;
    }
    if defaults.selection_fg.is_some() {
        config.theme_overrides.selection = true;
    }
    config.theme.selection_fg =
        defaults.selection_fg.map(|color| Color::Rgb(color.r, color.g, color.b));
    config.cursor_style = defaults.cursor_style;
    config.cursor_blink = defaults.cursor_blink;

    let raw = load_raw_config();
    let t = &raw.theme;
    if let Some(chrome) = t.chrome {
        config.chrome = chrome;
    }
    if let Some(c) = t.selection_background.as_ref().and_then(ColorValue::to_color) {
        config.theme.selection_bg = c;
        config.theme_overrides.selection = true;
    }
    match t.selection_foreground.as_ref() {
        None => {}
        Some(None) => {
            config.theme.selection_fg = None;
            config.theme_overrides.selection = true;
        }
        Some(Some(c)) => {
            if let Some(color) = c.to_color() {
                config.theme.selection_fg = Some(color);
                config.theme_overrides.selection = true;
            }
        }
    }
    if let Some(c) = t.sidebar_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_rail = c;
    }
    if let Some(c) = t.sidebar_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_active_bg = c;
        config.theme_overrides.sidebar_active_bg = true;
    }
    if let Some(c) = t.tab_rail.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_rail = c;
    }
    if let Some(c) = t.tab_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_bg = c;
        config.theme_overrides.tab_bg = true;
    }
    if let Some(c) = t.tab_active_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.tab_active_bg = Some(c);
    }
    if let Some(c) = t.border_active.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_active = c;
        config.theme_overrides.border_active = true;
    }
    if let Some(c) = t.border_inactive.as_ref().and_then(ColorValue::to_color) {
        config.theme.border_inactive = c;
        config.theme_overrides.border_inactive = true;
    }
    if let Some(c) = t.notification_info.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_info = c;
    }
    if let Some(c) = t.notification_warning.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_warning = c;
    }
    if let Some(c) = t.notification_error.as_ref().and_then(ColorValue::to_color) {
        config.theme.notification_error = c;
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
    if let Some(view) = raw.sidebar.view {
        match parse_sidebar_view(&view) {
            Ok(view) => config.sidebar.view = view,
            Err(warning) => eprintln!("{warning}"),
        }
    }
    if let Some(w) = raw.sidebar.max_width {
        config.sidebar.max_width = w;
    }
    if let Some(plugin) = raw.sidebar.plugin {
        let command = plugin
            .command
            .unwrap_or_default()
            .into_iter()
            .filter(|arg| !arg.is_empty())
            .collect::<Vec<_>>();
        if command.is_empty() {
            eprintln!("cmux-tui: ignoring sidebar.plugin with empty command");
        } else {
            config.sidebar.plugin = Some(SidebarPluginOptions {
                command,
                cwd: plugin.cwd.filter(|cwd| !cwd.trim().is_empty()),
            });
        }
    }
    if let Some(enabled) = raw.machine_sidebar.enabled {
        config.machine_sidebar.enabled = enabled;
    }
    if let Some(width) = raw.machine_sidebar.width {
        config.machine_sidebar.width = width.clamp(10, 60);
    }
    if let Some(max_width) = raw.machine_sidebar.max_width {
        config.machine_sidebar.max_width = max_width;
    }
    let cloud = raw.machine_provider.cloud;
    if let Some(enabled) = cloud.enabled {
        config.machine_provider.cloud.enabled = enabled;
    }
    if let Some(host) = cloud.host {
        let host = host.trim();
        if host.is_empty() {
            eprintln!("cmux-tui: ignoring empty machine_provider.cloud.host");
        } else {
            config.machine_provider.cloud.host = host.to_string();
        }
    }
    config.machine_provider.cloud.user =
        cloud.user.map(|user| user.trim().to_string()).filter(|user| !user.is_empty());
    config.machine_provider.cloud.port = match cloud.port {
        Some(0) => {
            eprintln!("cmux-tui: ignoring zero machine_provider.cloud.port");
            None
        }
        port => port,
    };
    config.machine_provider.cloud.identity_file = cloud
        .identity_file
        .map(|path| path.trim().to_string())
        .filter(|path| !path.is_empty())
        .map(PathBuf::from);
    let mut machine_ids = HashSet::new();
    for machine in raw.machines {
        let id = machine.id.trim().to_string();
        let name = machine.name.trim().to_string();
        if id.is_empty() || name.is_empty() || !machine_ids.insert(id.clone()) {
            eprintln!("cmux-tui: ignoring machine with an empty or duplicate id/name");
            continue;
        }
        let target = match machine.target {
            RawMachineTarget::Unix { socket } if !socket.trim().is_empty() => {
                MachineTargetConfig::Unix { socket: PathBuf::from(socket) }
            }
            RawMachineTarget::Ssh { host, user, port, identity_file, session, binary }
                if !host.trim().is_empty() =>
            {
                let port = normalize_ssh_machine_port(&id, port);
                MachineTargetConfig::Ssh {
                    host: host.trim().to_string(),
                    user: user.filter(|value| !value.trim().is_empty()),
                    port,
                    identity_file: identity_file
                        .filter(|value| !value.trim().is_empty())
                        .map(PathBuf::from),
                    session: session
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| "main".to_string()),
                    binary: binary
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| "cmux-tui".to_string()),
                }
            }
            _ => {
                eprintln!("cmux-tui: ignoring machine {id:?} with an empty transport target");
                continue;
            }
        };
        config.machines.push(MachineConfig { id, name, subtitle: machine.subtitle, target });
    }
    config.browser.chrome_binary = raw.browser.chrome_binary.filter(|s| !s.trim().is_empty());
    if let Some(mode) = raw.browser.mode {
        config.browser.mode = mode.into();
    }
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
    if let Some(megapixels) = raw.browser.max_capture_megapixels {
        if megapixels.is_finite()
            && megapixels > 0.0
            && megapixels <= TRANSPORT_SAFE_CAPTURE_MEGAPIXELS
        {
            config.browser.max_capture_megapixels = megapixels;
        } else {
            eprintln!(
                "cmux-tui: ignoring browser.max_capture_megapixels={megapixels:?}; expected 0 < value <= {TRANSPORT_SAFE_CAPTURE_MEGAPIXELS}"
            );
        }
    }
    if let Some(scale) = raw.browser.capture_scale {
        if scale.is_finite() && scale > 0.0 && scale <= 1.0 {
            config.browser.capture_scale = Some(scale);
        } else {
            eprintln!(
                "cmux-tui: ignoring browser.capture_scale={scale:?}; expected 0 < scale <= 1"
            );
        }
    }
    if let Some(position) = raw.scrollbar.position {
        config.scrollbar.position = position;
    }
    config.server.ws = raw.server.ws.filter(|value| !value.trim().is_empty());
    config.server.ws_token = raw.server.ws_token.filter(|value| !value.trim().is_empty());
    config.keys.apply(&raw.keys);
    config
}

fn normalize_ssh_machine_port(id: &str, port: Option<u16>) -> Option<u16> {
    match port {
        Some(0) => {
            eprintln!("cmux-tui: ignoring zero SSH machine port for {id:?}");
            None
        }
        port => port,
    }
}

pub fn apply_browser_to_surface_options(config: &Config, options: &mut SurfaceOptions) {
    options.chrome_binary = config.browser.chrome_binary.clone();
    options.browser_mode = config.browser.mode;
    options.cdp_url = config.browser.cdp_url.clone();
    options.browser_discover = config.browser.discover;
    options.browser_discover_ports = config.browser.discover_ports.clone();
    options.browser_user_data_dir = config.browser.user_data_dir.clone();
    options.browser_ephemeral = config.browser.ephemeral;
    options.browser_max_capture_megapixels = config.browser.max_capture_megapixels;
    options.browser_capture_scale = config.browser.capture_scale;
}

/// The label for a tab: user name if set, otherwise its zero-based index
/// plus a recognized agent program name (or the full title when
/// `show_titles` is on).
pub fn tab_label(tabs: &Tabs, index: usize, title: &str, name: Option<&str>) -> String {
    if let Some(name) = name
        && !name.is_empty()
    {
        return name.to_string();
    }
    let number = index;
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

fn load_raw_config() -> RawConfig {
    let Some(path) = platform::config_path() else { return RawConfig::default() };
    let Ok(text) = std::fs::read_to_string(&path) else { return RawConfig::default() };
    match serde_json::from_str(&text) {
        Ok(config) => config,
        Err(e) => {
            // A broken config should not take the TUI down; complain on
            // stderr (visible pre-alternate-screen and in logs).
            eprintln!("cmux-tui: ignoring invalid config {}: {e}", path.display());
            RawConfig::default()
        }
    }
}

pub fn config_path() -> anyhow::Result<PathBuf> {
    platform::config_path().ok_or_else(|| anyhow::anyhow!("could not resolve mux config path"))
}

pub fn write_sidebar_plugin(plugin: Option<&SidebarPluginConfig>) -> anyhow::Result<PathBuf> {
    let path = config_path()?;
    write_sidebar_plugin_at_path(&path, plugin)?;
    Ok(path)
}

pub fn write_sidebar_plugin_at_path(
    path: &Path,
    plugin: Option<&SidebarPluginConfig>,
) -> anyhow::Result<()> {
    let mut root = read_config_value(path)?;
    let Some(root_object) = root.as_object_mut() else {
        anyhow::bail!("{} must contain a JSON object", path.display());
    };
    match plugin {
        Some(plugin) => {
            let sidebar = root_object.entry("sidebar").or_insert_with(|| json!({}));
            if !sidebar.is_object() {
                *sidebar = json!({});
            }
            let sidebar_object = sidebar.as_object_mut().expect("sidebar was just made an object");
            let mut plugin_value = json!({ "command": &plugin.command });
            if let Some(cwd) = &plugin.cwd {
                plugin_value["cwd"] = json!(cwd);
            }
            sidebar_object.insert("plugin".to_string(), plugin_value);
        }
        None => {
            if let Some(sidebar) = root_object.get_mut("sidebar")
                && let Some(sidebar_object) = sidebar.as_object_mut()
            {
                sidebar_object.remove("plugin");
            }
        }
    }
    write_config_value_atomic(path, &root)
}

fn read_config_value(path: &Path) -> anyhow::Result<Value> {
    match std::fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok(json!({})),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(anyhow::anyhow!("failed to read {}: {err}", path.display())),
    }
}

fn write_config_value_atomic(path: &Path, value: &Value) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path.file_name().and_then(|name| name.to_str()).unwrap_or("cmux-tui.json");
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let tmp_path = parent.join(format!(".{file_name}.{}.{}.tmp", std::process::id(), stamp));
    let result = (|| -> anyhow::Result<()> {
        let mut file = std::fs::File::create(&tmp_path)?;
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp_path, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp_path);
    }
    result
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

/// The user's relevant Ghostty settings with non-optional application defaults
/// resolved for values that the low-level terminal otherwise leaves unset.
fn ghostty_defaults() -> DefaultColors {
    let parsed = resolved_ghostty_defaults()
        .or_else(|| {
            let text = platform::ghostty_config_paths()
                .iter()
                .find_map(|path| std::fs::read_to_string(path).ok())?;
            Some(parse_ghostty_defaults(&text))
        })
        .unwrap_or_default();
    resolve_ghostty_application_defaults(parsed)
}

fn resolve_ghostty_application_defaults(mut defaults: DefaultColors) -> DefaultColors {
    defaults.cursor_style.get_or_insert(CursorShape::Block);
    // `cursor-style-blink = null` is semantically different from `true` in
    // Ghostty: both start blinking, but only the unset form lets DEC mode 12
    // control the live cursor. Keep that absence intact for the terminal
    // application boundary to resolve without losing its provenance.
    defaults
}

/// Ask Ghostty to resolve its configuration so cmux-tui inherits precisely the
/// same theme-loading behavior as the graphical terminal. A failed or slow
/// invocation is deliberately ignored; startup then uses the file fallback.
fn resolved_ghostty_defaults() -> Option<DefaultColors> {
    resolved_ghostty_defaults_from(&platform::ghostty_installations())
}

fn resolved_ghostty_defaults_from(
    installations: &[platform::GhosttyInstallation],
) -> Option<DefaultColors> {
    installations.iter().find_map(|installation| {
        let text = run_ghostty_show_config(installation)?;
        let defaults = parse_resolved_ghostty_defaults(&text);
        // `+show-config` serializes Ghostty's effective application defaults,
        // including both colors. An executable that exits successfully but
        // emits no resolved config (for example a packaging stub) is not a
        // usable resolver and must not suppress later pinned candidates.
        (defaults.fg.is_some() && defaults.bg.is_some()).then_some(defaults)
    })
}

fn run_ghostty_show_config(installation: &platform::GhosttyInstallation) -> Option<String> {
    let mut command = Command::new(&installation.binary);
    command
        .args(["+show-config", "--no-pager"])
        .env_remove("GHOSTTY_RESOURCES_DIR")
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(resources_dir) = installation.resources_dir.as_deref() {
        command.env("GHOSTTY_RESOURCES_DIR", resources_dir);
    }
    let mut child = command.spawn().ok()?;
    let deadline = Instant::now() + Duration::from_secs(2);
    let status = loop {
        match child.try_wait().ok()? {
            Some(status) => break status,
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    };
    if !status.success() {
        return None;
    }

    let mut output = String::new();
    child.stdout.take()?.read_to_string(&mut output).ok()?;
    Some(output)
}

/// Parse the subset of Ghostty's `key = value` config used by cmux-tui.
///
/// When the Ghostty executable is unavailable, a theme is only accepted if
/// its file can be read. This preserves Ghostty's fail-soft behavior: a
/// later theme entries are ignored, matching Ghostty's first-theme-wins
/// behavior.
pub(crate) fn parse_ghostty_defaults(text: &str) -> DefaultColors {
    parse_ghostty_defaults_with_theme_dirs(text, &platform::ghostty_theme_dirs())
}

fn parse_ghostty_defaults_with_theme_dirs(text: &str, theme_dirs: &[PathBuf]) -> DefaultColors {
    let mut overrides = DefaultColors::default();
    let mut theme = None;
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() == "theme" {
            if theme.is_none()
                && let Some(theme_defaults) = load_ghostty_theme(value.trim(), theme_dirs)
            {
                theme = Some(theme_defaults);
            }
        } else {
            apply_ghostty_default(&mut overrides, key.trim(), value.trim());
        }
    }

    let mut defaults = theme.unwrap_or_default();
    overlay_ghostty_defaults(&mut defaults, overrides);
    defaults
}

/// Parse the fully resolved `ghostty +show-config` output. Theme lines are
/// intentionally ignored because the output already contains their resolved
/// color and cursor settings.
fn parse_resolved_ghostty_defaults(text: &str) -> DefaultColors {
    let mut defaults = DefaultColors::default();
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        apply_ghostty_default(&mut defaults, key.trim(), value.trim());
    }
    defaults
}

fn apply_ghostty_default(defaults: &mut DefaultColors, key: &str, value: &str) {
    let value = value.strip_prefix('"').and_then(|value| value.strip_suffix('"')).unwrap_or(value);
    match key {
        "foreground" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.fg = Some(color);
            }
        }
        "background" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.bg = Some(color);
            }
        }
        "cursor-color" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.cursor = Some(color);
            }
        }
        "selection-background" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.selection_bg = Some(color);
            }
        }
        "selection-foreground" => {
            if let Some(color) = ghostty_vt::parse_color(value) {
                defaults.selection_fg = Some(color);
            }
        }
        "cursor-style" => {
            let style = match value {
                "block" => Some(CursorShape::Block),
                "underline" => Some(CursorShape::Underline),
                "bar" => Some(CursorShape::Bar),
                _ => None,
            };
            if style.is_some() {
                defaults.cursor_style = style;
            }
        }
        "cursor-style-blink" => {
            if let Ok(blink) = value.parse::<bool>() {
                defaults.cursor_blink = Some(blink);
            }
        }
        "palette" => {
            if let Some((index, color)) = ghostty_vt::parse_palette_entry(value) {
                defaults.palette[index as usize] = Some(color);
            }
        }
        _ => {}
    }
}

fn load_ghostty_theme(value: &str, theme_dirs: &[PathBuf]) -> Option<DefaultColors> {
    let theme = value.trim_matches('"');
    let path = if Path::new(theme).is_absolute() {
        PathBuf::from(theme)
    } else if Path::new(theme).file_name().is_some_and(|name| name == theme) {
        theme_dirs.iter().map(|dir| dir.join(theme)).find(|path| path.is_file())?
    } else {
        return None;
    };
    let text = std::fs::read_to_string(path).ok()?;
    Some(parse_resolved_ghostty_defaults(&text))
}

fn overlay_ghostty_defaults(defaults: &mut DefaultColors, overrides: DefaultColors) {
    if overrides.fg.is_some() {
        defaults.fg = overrides.fg;
    }
    if overrides.bg.is_some() {
        defaults.bg = overrides.bg;
    }
    if overrides.cursor.is_some() {
        defaults.cursor = overrides.cursor;
    }
    if overrides.selection_bg.is_some() {
        defaults.selection_bg = overrides.selection_bg;
    }
    if overrides.selection_fg.is_some() {
        defaults.selection_fg = overrides.selection_fg;
    }
    if overrides.cursor_style.is_some() {
        defaults.cursor_style = overrides.cursor_style;
    }
    if overrides.cursor_blink.is_some() {
        defaults.cursor_blink = overrides.cursor_blink;
    }
    for (default, override_) in defaults.palette.iter_mut().zip(overrides.palette) {
        if override_.is_some() {
            *default = override_;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::sync::Mutex;

    /// Config env vars are process-global state; tests that set them must not
    /// run concurrently with each other.
    static CONFIG_ENV_LOCK: Mutex<()> = Mutex::new(());

    fn restore_env_var(key: &str, value: Option<OsString>) {
        match value {
            // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
            Some(value) => unsafe { std::env::set_var(key, value) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn parses_hex_and_indexed_colors() {
        assert_eq!(parse_color("#3a3a3a"), Some(Color::Rgb(0x3a, 0x3a, 0x3a)));
        assert_eq!(parse_color("#fff"), Some(Color::Rgb(255, 255, 255)));
        assert_eq!(parse_color("110"), Some(Color::Indexed(110)));
        assert_eq!(parse_color("not-a-color"), None);
        assert_eq!(parse_color("#12345"), None);
    }

    #[test]
    fn parses_ghostty_cursor_defaults_with_later_entry_wins() {
        let defaults = parse_ghostty_defaults(
            "cursor-style = block\n\
             cursor-style-blink = true\n\
             cursor-style = bar\n\
             cursor-style-blink = false\n",
        );
        assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
        assert_eq!(defaults.cursor_blink, Some(false));

        let invalid = parse_ghostty_defaults(
            "cursor-style = underline\n\
             cursor-style-blink = true\n\
             cursor-style = beam\n\
             cursor-style-blink = sometimes\n",
        );
        assert_eq!(invalid.cursor_style, Some(CursorShape::Underline));
        assert_eq!(invalid.cursor_blink, Some(true));

        let quoted = parse_ghostty_defaults(
            "cursor-style = \"bar\"\n\
             cursor-style-blink = \"false\"\n",
        );
        assert_eq!(quoted.cursor_style, Some(CursorShape::Bar));
        assert_eq!(quoted.cursor_blink, Some(false));
    }

    #[test]
    fn resolves_ghostty_cursor_defaults_without_erasing_nullable_blink_semantics() {
        let absent = resolve_ghostty_application_defaults(parse_ghostty_defaults(""));
        assert_eq!(absent.cursor_style, Some(CursorShape::Block));
        assert_eq!(absent.cursor_blink, None);

        for (value, expected) in [("true", true), ("false", false)] {
            let explicit = resolve_ghostty_application_defaults(parse_ghostty_defaults(&format!(
                "cursor-style-blink = {value}\n"
            )));
            assert_eq!(explicit.cursor_blink, Some(expected));
        }
    }

    #[test]
    fn ghostty_option_policy_is_explicit_and_fail_closed() {
        assert_eq!(parse_ghostty_macos_option_as_alt("macos-option-as-alt = false"), Some(false));
        assert_eq!(parse_ghostty_macos_option_as_alt("macos-option-as-alt = true"), Some(true));
        assert_eq!(parse_ghostty_macos_option_as_alt("macos-option-as-alt = left"), None);
        assert_eq!(parse_ghostty_macos_option_as_alt(""), None);
    }

    #[test]
    fn parses_ghostty_terminal_colors_and_palette_with_later_valid_entry_wins() {
        let defaults = parse_ghostty_defaults(
            "foreground = #010203\n\
             background = 131415\n\
             selection-background = #223344\n\
             selection-foreground = GhostWhite\n\
             palette = 1=#112233\n\
             palette = 15=#abcdef\n\
             palette = 1=#445566\n\
             palette = 1=not-a-color\n\
             palette = 256=#ffffff\n\
             palette = malformed\n",
        );

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
        assert_eq!(defaults.selection_bg, Some(Rgb { r: 0x22, g: 0x33, b: 0x44 }));
        assert_eq!(defaults.selection_fg, Some(Rgb { r: 0xf8, g: 0xf8, b: 0xff }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
        assert_eq!(defaults.palette[15], Some(Rgb { r: 0xab, g: 0xcd, b: 0xef }));
        assert!(defaults.palette[2..15].iter().all(Option::is_none));
        assert!(defaults.palette[16..].iter().all(Option::is_none));
    }

    #[test]
    fn parses_resolved_ghostty_show_config_output() {
        let defaults = parse_resolved_ghostty_defaults(
            "# Ghostty resolved configuration\n\
             theme = \"Monokai Classic\"\n\
             background = #272822\n\
             foreground = #fdfff1\n\
             selection-background = #57584f\n\
             selection-foreground = #fdfff1\n\
             cursor-color = #c0c1b5\n\
             cursor-style = bar\n\
             cursor-style-blink = false\n\
             palette = 0=#272822\n\
             palette = 1=#f92672\n\
             palette = 15=#fdfff1\n",
        );

        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        assert_eq!(defaults.selection_bg, Some(Rgb { r: 0x57, g: 0x58, b: 0x4f }));
        assert_eq!(defaults.selection_fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        assert_eq!(defaults.cursor, Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }));
        assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
        assert_eq!(defaults.cursor_blink, Some(false));
        assert_eq!(defaults.palette[0], Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf9, g: 0x26, b: 0x72 }));
        assert_eq!(defaults.palette[15], Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    }

    #[cfg(unix)]
    #[test]
    fn packaged_ghostty_resolver_receives_matching_resources() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-resolver-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let resources = root.join("ghostty");
        let binary = root.join("ghostty-config-helper");
        std::fs::create_dir_all(&resources).unwrap();
        std::fs::write(
            &binary,
            "#!/bin/sh\n\
             printf 'resource-path = %s\\n' \"$GHOSTTY_RESOURCES_DIR\"\n\
             printf 'background = #272822\\nforeground = #fdfff1\\n'\n",
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();

        let output = run_ghostty_show_config(&platform::GhosttyInstallation {
            binary,
            resources_dir: Some(resources.clone()),
        })
        .unwrap();
        assert!(output.contains(&format!("resource-path = {}", resources.display())));
        let defaults = parse_resolved_ghostty_defaults(&output);
        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn unusable_packaged_ghostty_resolver_falls_through() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-fallback-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let broken = root.join("copied-app-binary");
        let working = root.join("standalone-cli-helper");
        std::fs::write(&broken, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::write(
            &working,
            "#!/bin/sh\nprintf 'background = #272822\\nforeground = #fdfff1\\n'\n",
        )
        .unwrap();
        std::fs::set_permissions(&broken, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(&working, std::fs::Permissions::from_mode(0o700)).unwrap();

        let defaults = resolved_ghostty_defaults_from(&[
            platform::GhosttyInstallation { binary: broken, resources_dir: None },
            platform::GhosttyInstallation { binary: working, resources_dir: None },
        ])
        .unwrap();
        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn fallback_theme_selection_matches_ghostty_first_theme_wins() {
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Monokai Classic"),
            "background = #272822\nforeground = #fdfff1\npalette = 1=#f92672\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("Aizen Light"),
            "background = #f0f2f6\nforeground = #1f2329\npalette = 1=#cc3768\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_with_theme_dirs(
            "theme = \"Monokai Classic\"\ntheme = \"Aizen Light\"\n",
            std::slice::from_ref(&dir),
        );

        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf9, g: 0x26, b: 0x72 }));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn injected_ghostty_defaults_drive_headless_render_state() {
        use std::io::{BufRead, BufReader, Write};
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::Duration;

        use cmux_tui_core::platform::transport;
        use cmux_tui_core::{Mux, SurfaceOptions, server};

        static NEXT: AtomicU64 = AtomicU64::new(1);
        let defaults = parse_ghostty_defaults(
            "foreground = #010203\n\
             background = #131415\n\
             selection-background = #223344\n\
             selection-foreground = #fefefe\n\
             cursor-color = #c0c1b5\n\
             cursor-style = bar\n\
             cursor-style-blink = false\n\
             palette = 1=#445566\n",
        );
        let session = format!(
            "headless-config-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let mux = Mux::new(
            session,
            SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() },
        );
        mux.set_default_colors(defaults);
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        surface.try_with_terminal(|term| term.vt_write(b"\x1b[31mR")).unwrap();
        // Re-applying through the mux exercises the existing-surface path and
        // publishes a fresh immutable render frame for the protocol server.
        mux.set_default_colors(defaults);

        let socket = server::serve(mux.clone(), None).unwrap();
        let stream = transport::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(
            writer,
            r#"{{"id":1,"cmd":"attach-surface","surface":{},"mode":"render"}}"#,
            surface.id
        )
        .unwrap();

        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let state: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(state["event"], "render-state");
        assert_eq!(state["default_fg"], "#010203");
        assert_eq!(state["default_bg"], "#131415");
        assert_eq!(state["cursor"]["color"], "#c0c1b5");
        assert_eq!(state["cursor"]["style"], "bar");
        assert_eq!(state["cursor"]["blink"], false);
        let red_run = state["rows"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|row| row["runs"].as_array().into_iter().flatten())
            .find(|run| run["text"].as_str().is_some_and(|text| text.contains('R')))
            .expect("configured palette run");
        assert_eq!(red_run["fg"], "#445566");

        let colors = surface.attach_stream().unwrap().colors;
        assert_eq!(colors.selection_bg, Some(Rgb { r: 0x22, g: 0x33, b: 0x44 }));
        assert_eq!(colors.selection_fg, Some(Rgb { r: 0xfe, g: 0xfe, b: 0xfe }));

        mux.close_surface(surface.id).unwrap();
        mux.shutdown();
        server::cleanup(&socket);
    }

    #[test]
    fn detects_light_background_from_luminance() {
        assert!(is_light_background(Rgb { r: 255, g: 255, b: 255 }));
        assert!(!is_light_background(Rgb { r: 0, g: 0, b: 0 }));
        assert!(!is_light_background(Rgb { r: 128, g: 128, b: 128 }));
        assert!(is_light_background(Rgb { r: 129, g: 129, b: 129 }));
    }

    #[test]
    fn dark_chrome_matches_legacy_indices() {
        let chrome = ChromeTheme::dark();
        assert_eq!(chrome.selection_bg, Color::Rgb(0x3a, 0x3a, 0x3a));
        assert_eq!(chrome.selection_fg, None);
        assert_eq!(chrome.menu_bg, Color::Indexed(237));
        assert_eq!(chrome.menu_selected_bg, Color::Indexed(242));
        assert_eq!(chrome.prompt_bg, Color::Indexed(236));
        assert_eq!(chrome.status_bg, Color::Indexed(236));
        assert_eq!(chrome.status_active_bg, Color::Indexed(240));
        assert_eq!(chrome.tab_bar_bg, Color::Indexed(236));
        assert_eq!(chrome.tab_active_bg, Color::Indexed(240));
        assert_eq!(chrome.tab_active_unfocused_bg, Color::Indexed(238));
        assert_eq!(chrome.sidebar_selected_bg, Color::Indexed(236));
        assert_eq!(chrome.omnibar_edit_bg, Color::Indexed(236));
        assert_eq!(chrome.border_fg, Color::Indexed(238));
        assert_eq!(chrome.scrollbar_thumb_active_fg, Color::Indexed(252));
    }

    #[test]
    fn light_chrome_replaces_default_selection() {
        let mut config = Config::default();
        config.apply_chrome_defaults(ChromeTheme::light());
        assert_eq!(config.theme.selection_bg, Color::Rgb(0xcc, 0xdd, 0xf5));
        assert_eq!(config.theme.selection_fg, None);
    }

    #[test]
    fn mux_json_selection_survives_light_chrome_defaults() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir =
            std::env::temp_dir().join(format!("mux-config-test-selection-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(
            &path,
            r##"{"theme": {"selection_background": "#112233", "selection_foreground": "#ddeeff"}}"##,
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
        let mut config = load();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        let _ = std::fs::remove_file(&path);
        config.apply_chrome_defaults(ChromeTheme::light());
        assert_eq!(config.theme.selection_bg, Color::Rgb(0x11, 0x22, 0x33));
        assert_eq!(config.theme.selection_fg, Some(Color::Rgb(0xdd, 0xee, 0xff)));
    }

    #[test]
    fn ghostty_defaults_survive_light_chrome_defaults() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
        let dir =
            std::env::temp_dir().join(format!("mux-ghostty-selection-{}", std::process::id()));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "foreground = #010203\n\
             background = #131415\n\
             selection-background = #445566\n\
             selection-foreground = #abcdef\n\
             palette = 1=#778899\n\
             cursor-style = bar\n\
             cursor-style-blink = false\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };

        let mut config = load();

        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
        let _ = std::fs::remove_dir_all(&dir);

        config.apply_chrome_defaults(ChromeTheme::light());
        assert_eq!(config.theme.selection_bg, Color::Rgb(0x44, 0x55, 0x66));
        assert_eq!(config.theme.selection_fg, Some(Color::Rgb(0xab, 0xcd, 0xef)));
        assert_eq!(config.cursor_style, Some(CursorShape::Bar));
        assert_eq!(config.cursor_blink, Some(false));
        assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
        assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0x77, g: 0x88, b: 0x99 }));
    }

    #[test]
    fn omitted_ghostty_cursor_blink_remains_unspecified() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
        let dir =
            std::env::temp_dir().join(format!("mux-ghostty-cursor-default-{}", std::process::id()));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::write(ghostty_dir.join("config"), "cursor-style = \"bar\"\n").unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };

        let config = load();

        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(config.terminal_defaults.cursor_style, Some(CursorShape::Bar));
        assert_eq!(config.terminal_defaults.cursor_blink, None);
        assert_eq!(config.cursor_blink, None);
    }

    #[test]
    fn chrome_theme_selection_honors_auto_and_overrides() {
        let light_defaults = DefaultColors {
            fg: None,
            bg: Some(Rgb { r: 240, g: 240, b: 240 }),
            ..Default::default()
        };
        let dark_defaults =
            DefaultColors { fg: None, bg: Some(Rgb { r: 20, g: 20, b: 20 }), ..Default::default() };
        assert_eq!(
            ChromeTheme::for_defaults(ChromeMode::Auto, light_defaults),
            ChromeTheme::light()
        );
        assert_eq!(ChromeTheme::for_defaults(ChromeMode::Auto, dark_defaults), ChromeTheme::dark());
        assert_eq!(
            ChromeTheme::for_defaults(ChromeMode::Auto, DefaultColors::default()),
            ChromeTheme::dark()
        );
        assert_eq!(
            ChromeTheme::for_defaults(ChromeMode::Dark, light_defaults),
            ChromeTheme::dark()
        );
        assert_eq!(
            ChromeTheme::for_defaults(ChromeMode::Light, dark_defaults),
            ChromeTheme::light()
        );
    }

    #[test]
    fn parses_chrome_config_and_rejects_unknown_values() {
        let raw: RawConfig = serde_json::from_str(r##"{"theme": {"chrome": "light"}}"##).unwrap();
        assert_eq!(raw.theme.chrome, Some(ChromeMode::Light));

        let err = serde_json::from_str::<RawConfig>(r##"{"theme": {"chrome": "solarized"}}"##)
            .unwrap_err()
            .to_string();
        assert!(err.contains("unknown variant"), "{err}");
        assert!(err.contains("light"), "{err}");
        assert!(err.contains("dark"), "{err}");
        assert!(err.contains("auto"), "{err}");
    }

    #[test]
    fn machine_config_rejects_misspelled_and_cross_transport_fields() {
        for invalid in [
            r#"{"machines":[{"id":"mini","name":"Mini","transport":"ssh","host":"mini","sesion":"main"}]}"#,
            r#"{"machines":[{"id":"mini","name":"Mini","transport":"ssh","host":"mini","socket":"/tmp/mux.sock"}]}"#,
            r#"{"machines":[{"id":"mini","name":"Mini","transport":"unix","socket":"/tmp/mux.sock","host":"mini"}]}"#,
        ] {
            assert!(serde_json::from_str::<RawConfig>(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn zero_static_ssh_port_falls_back_to_the_ssh_default() {
        assert_eq!(normalize_ssh_machine_port("mini", Some(0)), None);
        assert_eq!(normalize_ssh_machine_port("mini", Some(22)), Some(22));
        assert_eq!(normalize_ssh_machine_port("mini", None), None);
    }

    #[test]
    fn parses_websocket_server_config() {
        let raw: RawConfig =
            serde_json::from_str(r#"{"server":{"ws":"127.0.0.1:7681","ws_token":"secret"}}"#)
                .unwrap();
        assert_eq!(raw.server.ws.as_deref(), Some("127.0.0.1:7681"));
        assert_eq!(raw.server.ws_token.as_deref(), Some("secret"));
    }

    #[test]
    fn cloud_provider_defaults_are_inert_and_target_cmux_cloud() {
        let config = Config::default();

        assert!(!config.machine_provider.cloud.enabled);
        assert_eq!(config.machine_provider.cloud.host, "cmux.cloud");
        assert_eq!(config.machine_provider.cloud.user, None);
        assert_eq!(config.machine_provider.cloud.port, None);
        assert_eq!(config.machine_provider.cloud.identity_file, None);
    }

    #[test]
    fn ignores_empty_websocket_server_config_values() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let dir = std::env::temp_dir()
            .join(format!("mux-config-test-empty-websocket-values-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(&path, r#"{"server":{"ws":"","ws_token":"   "}}"#).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

        let config = load();

        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(config.server.ws, None);
        assert_eq!(config.server.ws_token, None);
    }

    #[test]
    fn tab_labels_are_numbers_except_agents() {
        let tabs = Tabs::default();
        assert_eq!(tab_label(&tabs, 0, "", None), "0");
        assert_eq!(tab_label(&tabs, 1, "zsh", None), "1");
        assert_eq!(tab_label(&tabs, 2, "vim src/main.rs", None), "2");
        // Recognized agent programs surface in the label.
        assert_eq!(tab_label(&tabs, 0, "claude", None), "0 claude");
        assert_eq!(tab_label(&tabs, 3, "✳ Codex CLI", None), "3 codex");
        assert_eq!(tab_label(&tabs, 4, "opencode - fix bug", None), "4 opencode");
        // "pi" matches only as a word, not inside other words.
        assert_eq!(tab_label(&tabs, 5, "pick a file", None), "5");
        assert_eq!(tab_label(&tabs, 5, "pi chat", None), "5 pi");
        assert_eq!(tab_label(&tabs, 5, "pi chat", Some("api")), "api");

        let titled = Tabs { show_titles: true, ..Tabs::default() };
        assert_eq!(tab_label(&titled, 1, "zsh", None), "1 zsh");
    }

    #[test]
    fn tab_selection_actions_use_zero_based_indexes() {
        assert_eq!(Action::SelectTab(0).tab_index(), Some(0));
        assert_eq!(Action::SelectTab(9).tab_index(), Some(9));
        assert_eq!(Action::SelectTab(10).tab_index(), None);
    }

    #[test]
    fn config_overrides_defaults() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!("mux-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(
            &path,
            r##"{
                "theme": {
                    "chrome": "dark",
                    "selection_background": "#101010",
                    "sidebar_rail": 42,
                    "sidebar_active_bg": "#202020",
                    "tab_bg": 44
                },
                "tabs": {"min_width": 9, "solid_background": false},
                "sidebar": {
                    "view": "workspaces",
                    "width": 30,
                    "max_width": 38,
                    "plugin": {
                        "command": ["/tmp/sidebar-plugin", "--mode", "test"],
                        "cwd": "/tmp"
                    }
                },
                "machine_sidebar": {
                    "enabled": true,
                    "width": 26,
                    "max_width": 34
                },
                "machine_provider": {
                    "cloud": {
                        "enabled": true,
                        "host": "edge.example.com",
                        "user": "lawrence",
                        "port": 2200,
                        "identity_file": "/tmp/cloud-key"
                    }
                },
                "machines": [
                    {
                        "id": "mini",
                        "name": "Mac mini",
                        "subtitle": "studio",
                        "transport": "ssh",
                        "host": "mini.local",
                        "user": "lawrence",
                        "session": "main"
                    }
                ],
                "scrollbar": {"position": "border"},
                "keys": {
                    "alt_shortcuts": false,
                    "rename-pane": "r",
                    "focus-left": ["left", "alt+h"],
                    "next-tab": "none",
                    "select-tab-0": "q",
                    "browser-edit-url": "u"
                }
            }"##,
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
        let config = load();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        let _ = std::fs::remove_file(&path);
        assert_eq!(config.theme.selection_bg, Color::Rgb(0x10, 0x10, 0x10));
        assert_eq!(config.chrome, ChromeMode::Dark);
        assert!(config.theme_overrides.selection);
        assert_eq!(config.theme.sidebar_rail, Color::Indexed(42));
        assert_eq!(config.theme.sidebar_active_bg, Color::Rgb(0x20, 0x20, 0x20));
        assert_eq!(config.theme.tab_bg, Color::Indexed(44));
        assert!(config.theme_overrides.sidebar_active_bg);
        assert!(config.theme_overrides.tab_bg);
        assert_eq!(config.tabs.min_width, 9);
        assert!(!config.tabs.solid_background);
        assert_eq!(config.sidebar.width, 30);
        assert_eq!(config.sidebar.max_width, 38);
        assert_eq!(config.sidebar.view, SidebarView::Workspaces);
        assert_eq!(
            config.machine_sidebar,
            MachineSidebar { enabled: true, width: 26, max_width: 34 }
        );
        assert_eq!(
            config.machine_provider.cloud,
            CloudProviderConfig {
                enabled: true,
                host: "edge.example.com".into(),
                user: Some("lawrence".into()),
                port: Some(2200),
                identity_file: Some(PathBuf::from("/tmp/cloud-key")),
            }
        );
        assert_eq!(config.machines.len(), 1);
        assert_eq!(config.machines[0].id, "mini");
        assert_eq!(config.machines[0].name, "Mac mini");
        assert!(matches!(
            &config.machines[0].target,
            MachineTargetConfig::Ssh { host, user: Some(user), session, .. }
                if host == "mini.local" && user == "lawrence" && session == "main"
        ));
        let plugin = config.sidebar.plugin.as_ref().expect("sidebar plugin config");
        assert_eq!(plugin.command, vec!["/tmp/sidebar-plugin", "--mode", "test"]);
        assert_eq!(plugin.cwd.as_deref(), Some("/tmp"));
        assert_eq!(config.scrollbar.position, ScrollbarPosition::Border);
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)),
            Some(Action::RenameTab)
        );
        assert_eq!(config.keys.action_for(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)), None);
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
            Some(Action::SelectTab(0))
        );
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('u'), KeyModifiers::NONE)),
            Some(Action::BrowserEditUrl)
        );
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('S'), KeyModifiers::SHIFT)),
            Some(Action::FocusSidebar)
        );
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

    #[test]
    fn browser_mode_defaults_headful_parses_headless_and_rejects_invalid_values() {
        let raw: RawConfig = serde_json::from_str(r##"{}"##).unwrap();
        assert!(raw.browser.mode.is_none());
        assert_eq!(Browser::default().mode, BrowserMode::Headful);

        let raw: RawConfig =
            serde_json::from_str(r##"{"browser": {"mode": "headless"}}"##).unwrap();
        assert_eq!(raw.browser.mode.map(BrowserMode::from), Some(BrowserMode::Headless));

        let err = serde_json::from_str::<RawConfig>(r##"{"browser": {"mode": "stealth"}}"##)
            .unwrap_err()
            .to_string();
        assert!(err.contains("unknown variant `stealth`"), "{err}");
    }

    #[test]
    fn config_path_prefers_cmux_tui_json_and_falls_back_to_legacy_mux_json() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-config-path-test-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let config_dir = dir.join("cmux");
        std::fs::create_dir_all(&config_dir).unwrap();
        let preferred = config_dir.join("cmux-tui.json");
        let legacy = config_dir.join("mux.json");
        let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
        let old_cmux_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");

        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe {
            std::env::remove_var("CMUX_TUI_CONFIG");
            std::env::remove_var("CMUX_MUX_CONFIG");
            std::env::set_var("XDG_CONFIG_HOME", &dir);
        }

        assert_eq!(platform::config_path().as_deref(), Some(preferred.as_path()));

        std::fs::write(&legacy, "{}").unwrap();
        assert_eq!(platform::config_path().as_deref(), Some(legacy.as_path()));

        std::fs::write(&preferred, "{}").unwrap();
        assert_eq!(platform::config_path().as_deref(), Some(preferred.as_path()));

        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe {
            match old_cmux_tui_config {
                Some(value) => std::env::set_var("CMUX_TUI_CONFIG", value),
                None => std::env::remove_var("CMUX_TUI_CONFIG"),
            }
            match old_cmux_mux_config {
                Some(value) => std::env::set_var("CMUX_MUX_CONFIG", value),
                None => std::env::remove_var("CMUX_MUX_CONFIG"),
            }
            match old_xdg_config_home {
                Some(value) => std::env::set_var("XDG_CONFIG_HOME", value),
                None => std::env::remove_var("XDG_CONFIG_HOME"),
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
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
        assert!(
            !keys.bindings.iter().any(|(chord, _)| chord == &keys.prefix),
            "default binding shadows prefix passthrough: {:?}",
            keys.prefix
        );
        for c in ['b', 'f', 'd', '.'] {
            assert_eq!(
                keys.modeless_action_for(&KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)),
                None
            );
        }
    }

    #[test]
    fn default_super_shortcut_clears_history() {
        let keys = Keys::default();
        let action = |code, modifiers| keys.modeless_action_for(&KeyEvent::new(code, modifiers));
        assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER), Some(Action::ClearHistory));
        assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER | KeyModifiers::CONTROL), None);
        assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER | KeyModifiers::ALT), None);
        assert_eq!(action(KeyCode::Char('t'), KeyModifiers::SUPER), None);
        assert_eq!(action(KeyCode::Char('w'), KeyModifiers::SUPER), None);
        assert_eq!(action(KeyCode::Char('d'), KeyModifiers::SUPER), None);
    }

    #[test]
    fn super_shortcuts_can_be_disabled_or_configured_explicitly() {
        let mut keys = Keys::default();
        keys.apply(&HashMap::from([("super_shortcuts".to_string(), Value::Bool(false))]));
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER)),
            None
        );

        keys.apply(&HashMap::from([(
            "clear-history".to_string(),
            Value::String("command+l".to_string()),
        )]));
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('l'), KeyModifiers::SUPER)),
            Some(Action::ClearHistory)
        );
        assert_eq!(
            parse_chord("cmd+shift+d"),
            Some(Chord { code: KeyCode::Char('D'), mods: KeyModifiers::SUPER })
        );
        assert_eq!(
            parse_chord("super+shift+["),
            Some(Chord { code: KeyCode::Char('{'), mods: KeyModifiers::SUPER })
        );
    }

    #[test]
    fn shifted_character_chords_match_enhanced_base_key_events() {
        let shifted_letter = parse_chord("super+shift+d").unwrap();
        assert!(shifted_letter.matches(&KeyEvent::new(
            KeyCode::Char('d'),
            KeyModifiers::SUPER | KeyModifiers::SHIFT,
        )));

        let shifted_symbol = parse_chord("super+shift+[").unwrap();
        assert!(shifted_symbol.matches(&KeyEvent::new(
            KeyCode::Char('['),
            KeyModifiers::SUPER | KeyModifiers::SHIFT,
        )));

        let plain_letter = parse_chord("super+d").unwrap();
        assert!(!plain_letter.matches(&KeyEvent::new(
            KeyCode::Char('d'),
            KeyModifiers::SUPER | KeyModifiers::SHIFT,
        )));
    }

    #[test]
    fn sidebar_view_defaults_parses_and_unknown_values_fall_back_with_warning() {
        assert_eq!(Sidebar::default().view, SidebarView::Workspaces);
        assert_eq!(parse_sidebar_view("files"), Ok(SidebarView::Files));
        assert_eq!(parse_sidebar_view("workspaces"), Ok(SidebarView::Workspaces));

        let warning = parse_sidebar_view("tree").unwrap_err();
        assert!(warning.contains("unknown sidebar.view \"tree\""));
        let mut sidebar = Sidebar::default();
        if let Ok(view) = parse_sidebar_view("tree") {
            sidebar.view = view;
        }
        assert_eq!(sidebar.view, SidebarView::Workspaces);
    }

    #[test]
    fn tmux_close_pane_flip_is_default() {
        let keys = Keys::default();
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            Some(Action::ClosePane)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)),
            Some(Action::CloseTab)
        );
    }

    #[test]
    fn new_action_names_parse_from_config_overrides() {
        let cases = [
            ("zoom-pane", Action::ZoomPane),
            ("focus-next-pane", Action::FocusNextPane),
            ("swap-pane-prev", Action::SwapPanePrev),
            ("swap-pane-next", Action::SwapPaneNext),
            ("scroll-up", Action::ScrollUp),
            ("toggle-sidebar-view", Action::ToggleSidebarView),
        ];
        for (name, action) in cases {
            let mut keys = Keys::default();
            let mut raw = HashMap::new();
            raw.insert(name.to_string(), Value::String("f".to_string()));
            keys.apply(&raw);
            assert_eq!(
                keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
                Some(action),
                "{name} did not parse"
            );
        }
    }

    #[test]
    fn select_screen_action_names_round_trip_and_parse() {
        for number in 0..=9 {
            let action = Action::SelectScreen(number);
            let name = format!("select-screen-{number}");
            assert_eq!(action.config_key(), name);
            assert!(all_actions().contains(&action));

            let mut keys = Keys::default();
            let mut raw = HashMap::new();
            raw.insert(name.clone(), Value::String("f".to_string()));
            keys.apply(&raw);
            assert_eq!(
                keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
                Some(action),
                "{name} did not parse"
            );

            // The snake_case spelling is accepted as an alias.
            let mut keys = Keys::default();
            let mut raw = HashMap::new();
            raw.insert(format!("select_screen_{number}"), Value::String("g".to_string()));
            keys.apply(&raw);
            assert_eq!(
                keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
                Some(action),
                "select_screen_{number} alias did not parse"
            );
        }

        assert_eq!(Action::SelectScreen(0).screen_index(), Some(0));
        assert_eq!(Action::SelectScreen(1).screen_index(), Some(1));
        assert_eq!(Action::SelectScreen(9).screen_index(), Some(9));
    }

    #[test]
    fn chord_matches_requires_shift_for_non_char_codes() {
        let shift_left = Chord { code: KeyCode::Left, mods: KeyModifiers::SHIFT };
        assert!(shift_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)));
        assert!(!shift_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)));

        let plain_left = Chord { code: KeyCode::Left, mods: KeyModifiers::NONE };
        assert!(plain_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)));
        assert!(!plain_left.matches(&KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)));
    }

    #[test]
    fn default_backtab_accepts_crossterm_implied_shift() {
        let keys = Keys::default();
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::BackTab, KeyModifiers::SHIFT)),
            Some(Action::PrevTab)
        );
    }

    #[test]
    fn selection_foreground_absent_vs_null_are_distinct() {
        // Absent key: `Option<Option<_>>` outer is None, meaning "no
        // override" (the Ghostty-seeded value, if any, is kept).
        let absent: RawConfig = serde_json::from_str(r##"{"theme": {}}"##).unwrap();
        assert!(absent.theme.selection_foreground.is_none());

        // Explicit `null`: outer is `Some(None)`, meaning "clear it".
        let explicit_null: RawConfig =
            serde_json::from_str(r##"{"theme": {"selection_foreground": null}}"##).unwrap();
        assert!(matches!(explicit_null.theme.selection_foreground, Some(None)));
    }

    #[test]
    fn selection_foreground_null_clears_ghostty_seeded_default() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir =
            std::env::temp_dir().join(format!("mux-config-test-selfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(&path, r##"{"theme": {"selection_foreground": null}}"##).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
        // `load()` always seeds `selection_fg` from the Ghostty selection
        // colors (or leaves it `None` if there aren't any) before applying
        // this override, so regardless of the ambient Ghostty config, an
        // explicit `null` here must land back on `None`.
        let config = load();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        let _ = std::fs::remove_file(&path);
        assert_eq!(config.theme.selection_fg, None);
    }

    #[test]
    fn browser_capture_config_validates_bounds() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir()
            .join(format!("mux-config-test-browser-capture-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(
            &path,
            r##"{"browser": {"max_capture_megapixels": 1.5, "capture_scale": 0.5}}"##,
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
        let config = load();
        assert_eq!(config.browser.max_capture_megapixels, 1.5);
        assert_eq!(config.browser.capture_scale, Some(0.5));

        std::fs::write(
            &path,
            r##"{"browser": {"max_capture_megapixels": 3.5, "capture_scale": 0.5}}"##,
        )
        .unwrap();
        let config = load();
        assert_eq!(config.browser.max_capture_megapixels, TRANSPORT_SAFE_CAPTURE_MEGAPIXELS);
        assert_eq!(config.browser.capture_scale, Some(0.5));

        std::fs::write(
            &path,
            r##"{"browser": {"max_capture_megapixels": 0, "capture_scale": 1.5}}"##,
        )
        .unwrap();
        let config = load();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            config.browser.max_capture_megapixels,
            Browser::default().max_capture_megapixels
        );
        assert_eq!(config.browser.capture_scale, None);
    }

    #[test]
    fn sidebar_plugin_write_preserves_unrelated_config_keys() {
        let dir = std::env::temp_dir().join(format!(
            "mux-config-write-test-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mux.json");
        std::fs::write(
            &path,
            r#"{
                "theme": {"sidebar_rail": 42},
                "sidebar": {"width": 31},
                "future": {"unknown": true}
            }"#,
        )
        .unwrap();

        write_sidebar_plugin_at_path(
            &path,
            Some(&SidebarPluginConfig {
                command: vec!["/tmp/plugin".to_string(), "--mode".to_string(), "test".to_string()],
                cwd: Some("/tmp".to_string()),
            }),
        )
        .unwrap();
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["theme"]["sidebar_rail"], json!(42));
        assert_eq!(value["sidebar"]["width"], json!(31));
        assert_eq!(value["future"]["unknown"], json!(true));
        assert_eq!(value["sidebar"]["plugin"]["command"][0], json!("/tmp/plugin"));
        assert_eq!(value["sidebar"]["plugin"]["cwd"], json!("/tmp"));

        write_sidebar_plugin_at_path(&path, None).unwrap();
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["sidebar"]["width"], json!(31));
        assert!(value["sidebar"].get("plugin").is_none());
        assert_eq!(value["future"]["unknown"], json!(true));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
