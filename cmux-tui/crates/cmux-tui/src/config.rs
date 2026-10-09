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
//!     "compact_width": 10,
//!     "max_width": 0,
//!     "views": [
//!       {"id": "machines", "levels": ["machines"], "width": 18},
//!       {
//!         "id": "workspace-agents",
//!         "levels": ["workspaces", "agents"],
//!         "actions": ["new-workspace"],
//!         "width": 28
//!       }
//!     ],
//!     "plugin": {
//!       "command": ["/path/to/plugin-binary"],
//!       "cwd": "/optional"
//!     }
//!   },
//!   "agents": {
//!     "screen_detection": true,
//!     "plugin": {
//!       "id": "example_agent_screen_detection",
//!       "command": ["/path/to/agent-plugin"],
//!       "cwd": "/optional",
//!       "revision": "sha256-..."
//!     }
//!   },
//!   "machine_sidebar": {
//!     "enabled": false,
//!     "width": 22,
//!     "max_width": 0,
//!     "create_sources": []
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
//!     "cdp_url": "http://127.0.0.1:9222",
//!     "max_capture_megapixels": 2.0,
//!     "capture_scale": null
//!   },
//!   "scrollbar": {
//!     "position": "column"
//!   },
//!   "viewport": {
//!     "animation": true
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
//! `prev-workspace`, `next-workspace`, `new-workspace`, `close-workspace`,
//! `send-prefix`, `toggle-sidebar`, `toggle-sidebar-compact`,
//! `toggle-sidebar-view`, `focus-sidebar`, `new-pane-right`, `undo-layout`,
//! `focus-left`, `focus-right`, `focus-up`, `focus-down`, `focus-next-pane`,
//! `swap-pane-prev`, `swap-pane-next`, `zoom-pane`, `resize-grow`,
//! `resize-shrink`, `scroll-up`, `scroll-down`, `clear-history`, `browser-back`,
//! `browser-forward`, `browser-reload`, `browser-edit-url`, `show-shortcuts`,
//! and `detach`.
//!
//! The defaults intentionally match tmux where cmux has the same
//! capability, except that `x` closes the more commonly managed tab and
//! `X` closes its containing pane. Both actions remain independently
//! configurable. Screen positions are zero-based, so each
//! `select-screen-N` action selects the screen at index `N`. Zellij's modal
//! `ctrl+p`, `ctrl+t`, `ctrl+s`, `ctrl+n`, and `ctrl+o` modes are a
//! deliberate non-goal because they conflict with shell/editor control
//! keys.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::OpenOptions;
use std::io::{self, Read, Write};
use std::ops::Deref;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::Child;
use std::process::Command;
use std::process::Stdio;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::cli::BIN;
use cmux_tui_core::SidebarPluginOptions;
use cmux_tui_core::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS;
use cmux_tui_core::platform;
use cmux_tui_core::{CursorShape, DefaultColors, Rgb};
use cmux_tui_core::{DEFAULT_SCROLLBACK_LIMIT_BYTES, SurfaceOptions};

const MAX_SCROLLBACK_LIMIT_BYTES: usize = 1_000_000_000;
/// Bound every JSON config read before parsing it into a dynamic value.
/// Normal hand-written configs are far smaller, while a damaged or hostile
/// file must not be allowed to consume unbounded TUI memory.
pub(crate) const CONFIG_FILE_MAX_BYTES: usize = 4 * 1024 * 1024;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::buffer::CellWidth;
use ratatui::style::Color;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use unicode_segmentation::UnicodeSegmentation;
use wait_timeout::ChildExt;

use crate::localization::catalog;

mod ghostty_config;
mod ghostty_helper;
mod ghostty_theme_mode;

use ghostty_config::*;
use ghostty_helper::*;
pub(crate) use ghostty_helper::{is_ghostty_config_helper_invocation, run_ghostty_config_helper};
use ghostty_theme_mode::*;

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
    agents: crate::agent_plugin_config::RawAgents,
    #[serde(default)]
    machine_sidebar: RawMachineSidebar,
    #[serde(default)]
    machine_provider: RawMachineProvider,
    #[serde(default)]
    machines: Vec<RawMachine>,
    /// User commands: named argv programs, each optionally bound to key
    /// chords, opened as a new PTY tab in the active pane.
    #[serde(default)]
    commands: Vec<RawUserCommand>,
    #[serde(default)]
    browser: RawBrowser,
    #[serde(default)]
    scrollbar: RawScrollbar,
    #[serde(default)]
    pane: RawPane,
    #[serde(default)]
    status_bar: RawStatusBar,
    #[serde(default)]
    viewport: RawViewport,
    #[serde(default)]
    server: RawServer,
    /// Key bindings: `"prefix"` plus one entry per action. Values may be
    /// a chord string, an array of chord strings, `"none"`, or
    /// `"alt_shortcuts": false`, `"super_shortcuts": false`, or the host
    /// input mode `"macos_option_as_alt": false`.
    #[serde(default)]
    keys: HashMap<String, Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawServer {
    ws: Option<String>,
    ws_token: Option<String>,
    detached_owner: Option<bool>,
    /// `loopback-forward-v1` policy; validated when the daemon starts.
    loopback_forward: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPane {
    /// Blank cells between the pane border and the terminal content.
    padding: Option<u16>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawStatusBar {
    visible: Option<bool>,
    show_screens: Option<bool>,
    show_session: Option<bool>,
    left: Option<Vec<RawStatusSegment>>,
    right: Option<Vec<RawStatusSegment>>,
    left_separator: Option<String>,
    right_separator: Option<String>,
    screens_style: Option<ChipStyle>,
    screens_plus: Option<RawPlusButton>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawStatusSegment {
    /// Literal text with `{variable}` interpolation.
    text: Option<String>,
    /// Argv run on an interval; the last stdout line replaces the segment.
    run: Option<Vec<String>>,
    /// Refresh interval in seconds for `run` segments.
    interval: Option<u64>,
    fg: Option<ColorValue>,
    bg: Option<ColorValue>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawUserCommand {
    id: Option<String>,
    name: Option<String>,
    /// Chord string, array of chord strings, or absent for an unbound
    /// command. Alt- and Super-modified chords are modeless; other chords
    /// run after the prefix.
    keys: Option<Value>,
    /// Argv executed directly, without a shell.
    run: Option<Vec<String>>,
    /// Working directory; defaults to the target pane's current directory.
    cwd: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMachineProvider {
    #[serde(default)]
    cloud: RawCloudProvider,
    /// Config parity with `--machine-provider-command`: the argv of a
    /// provider process to spawn, no shell. The CLI flag wins when both are
    /// given.
    #[serde(default)]
    command: Option<Vec<String>>,
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
    border_style: Option<BorderStyle>,
    status_bg: Option<ColorValue>,
    status_fg: Option<ColorValue>,
    sidebar_fg: Option<ColorValue>,
    sidebar_selected_fg: Option<ColorValue>,
    dim_inactive: Option<bool>,
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
    style: Option<ChipStyle>,
    plus: Option<RawPlusButton>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebar {
    view: Option<String>,
    profile: Option<String>,
    width: Option<u16>,
    compact_width: Option<u16>,
    max_width: Option<u16>,
    profiles: Option<Vec<RawSidebarProfile>>,
    views: Option<Vec<RawSidebarView>>,
    columns: Option<Vec<RawSidebarColumn>>,
    plugin: Option<RawSidebarPlugin>,
    /// Rows per rail entry: 2 (default) keeps the subtitle line, 1 is a
    /// dense name-only list.
    row_height: Option<u16>,
    /// Blank rows between rail entries: 1 (default) or 0 for no padding.
    row_gap: Option<u16>,
    /// Accent glyph on active rail rows; `"none"` removes it.
    rail_glyph: Option<String>,
    /// Workspace row label template with `{index}` and `{name}`.
    workspace_label: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebarProfile {
    id: String,
    name: Option<String>,
    views: Vec<RawSidebarView>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebarView {
    id: String,
    levels: Vec<String>,
    actions: Option<Vec<RawSidebarAction>>,
    actions_position: Option<ActionsPosition>,
    width: Option<u16>,
    max_width: Option<u16>,
    collapse_priority: Option<u16>,
}

/// One pinned action: an action name, or an object that also renames its
/// button. `"command:<id>"` references a user command from `commands`.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawSidebarAction {
    Name(String),
    Detailed { action: String, label: Option<String> },
}

impl RawSidebarAction {
    fn action(&self) -> &str {
        match self {
            RawSidebarAction::Name(name) => name,
            RawSidebarAction::Detailed { action, .. } => action,
        }
    }

    fn label(&self) -> Option<&str> {
        match self {
            RawSidebarAction::Name(_) => None,
            RawSidebarAction::Detailed { label, .. } => label.as_deref(),
        }
    }
}

/// Raw form of a configurable `+` button.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPlusButton {
    label: Option<String>,
    /// Left-click action override; action name or `command:<id>`.
    action: Option<String>,
    /// Right-click menu entries; same grammar as sidebar view actions.
    menu: Option<Vec<RawSidebarAction>>,
}

/// Where a view's pinned action buttons render.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ActionsPosition {
    Top,
    #[default]
    Bottom,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawSidebarColumn {
    kind: String,
    width: Option<u16>,
    max_width: Option<u16>,
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
    create_sources: Option<Vec<RawMachineCreationSource>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMachineCreationSource {
    id: String,
    name: String,
    subtitle: Option<String>,
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
    cdp_url: Option<String>,
    max_capture_megapixels: Option<f64>,
    capture_scale: Option<f64>,
    // Compatibility keys of the removed Chrome launcher (cx-2u5k, cx-kyn5):
    // older files keep loading whatever these hold; they select nothing.
    #[serde(rename = "chrome_binary")]
    _chrome_binary: Option<serde::de::IgnoredAny>,
    #[serde(rename = "mode")]
    _mode: Option<serde::de::IgnoredAny>,
    #[serde(rename = "discover")]
    _discover: Option<serde::de::IgnoredAny>,
    #[serde(rename = "discover_ports")]
    _discover_ports: Option<serde::de::IgnoredAny>,
    #[serde(rename = "user_data_dir")]
    _user_data_dir: Option<serde::de::IgnoredAny>,
    #[serde(rename = "ephemeral")]
    _ephemeral: Option<serde::de::IgnoredAny>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawScrollbar {
    position: Option<ScrollbarPosition>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawViewport {
    animation: Option<bool>,
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

#[derive(Debug, Clone, Copy)]
pub struct Viewport {
    pub animation: bool,
}

impl Default for Viewport {
    fn default() -> Self {
        Self { animation: true }
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

/// Pane border line style. `None` keeps the border cells blank so panes
/// separate by empty space; geometry is unchanged in every style.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BorderStyle {
    #[default]
    Single,
    Rounded,
    Thick,
    Double,
    None,
}

/// Chip cap style for tab labels and the active screen chip: `pill` wraps
/// solid chips in rounded caps, `slant` in angled caps, `block` (default)
/// keeps the flat rectangle. Cap glyphs come from the Nerd Font powerline
/// range, the same glyphs tmux and zellij themes use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ChipStyle {
    #[default]
    Block,
    Pill,
    Slant,
}

impl ChipStyle {
    /// Left and right cap glyphs, or `None` for the flat block style.
    pub fn caps(self) -> Option<(&'static str, &'static str)> {
        match self {
            ChipStyle::Block => None,
            ChipStyle::Pill => Some(("\u{e0b6}", "\u{e0b4}")),
            ChipStyle::Slant => Some(("\u{e0be}", "\u{e0b8}")),
        }
    }
}

/// The six glyphs a pane box is drawn with.
#[derive(Debug, Clone, Copy)]
pub struct BorderGlyphs {
    pub horizontal: &'static str,
    pub vertical: &'static str,
    pub top_left: &'static str,
    pub top_right: &'static str,
    pub bottom_left: &'static str,
    pub bottom_right: &'static str,
}

impl BorderStyle {
    pub fn glyphs(self) -> BorderGlyphs {
        match self {
            BorderStyle::Single => BorderGlyphs {
                horizontal: "─",
                vertical: "│",
                top_left: "┌",
                top_right: "┐",
                bottom_left: "└",
                bottom_right: "┘",
            },
            BorderStyle::Rounded => BorderGlyphs {
                horizontal: "─",
                vertical: "│",
                top_left: "╭",
                top_right: "╮",
                bottom_left: "╰",
                bottom_right: "╯",
            },
            BorderStyle::Thick => BorderGlyphs {
                horizontal: "━",
                vertical: "┃",
                top_left: "┏",
                top_right: "┓",
                bottom_left: "┗",
                bottom_right: "┛",
            },
            BorderStyle::Double => BorderGlyphs {
                horizontal: "═",
                vertical: "║",
                top_left: "╔",
                top_right: "╗",
                bottom_left: "╚",
                bottom_right: "╝",
            },
            BorderStyle::None => BorderGlyphs {
                horizontal: " ",
                vertical: " ",
                top_left: " ",
                top_right: " ",
                bottom_left: " ",
                bottom_right: " ",
            },
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
    pub border_style: BorderStyle,
    /// Status bar background/foreground; `None` follows the chrome theme.
    pub status_bg: Option<Color>,
    pub status_fg: Option<Color>,
    /// Sidebar row foregrounds; `None` follows terminal/chrome defaults.
    pub sidebar_fg: Option<Color>,
    pub sidebar_selected_fg: Option<Color>,
    /// Render unfocused terminal panes with the DIM attribute.
    pub dim_inactive: bool,
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
            border_style: BorderStyle::Single,
            status_bg: None,
            status_fg: None,
            sidebar_fg: None,
            sidebar_selected_fg: None,
            dim_inactive: false,
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
    /// Cap style for solid tab chips.
    pub style: ChipStyle,
    /// The tab bar's `+` button: label, click override, right-click menu.
    pub plus: PlusButton,
}

impl Default for Tabs {
    fn default() -> Self {
        Tabs {
            min_width: 7,
            solid_background: true,
            show_titles: false,
            agents: ["claude", "codex", "opencode", "pi"].map(String::from).to_vec(),
            style: ChipStyle::Block,
            plus: PlusButton::default(),
        }
    }
}

/// Sidebar behavior.
#[derive(Debug, Clone)]
pub struct Sidebar {
    /// Built-in view used when `plugin` is unset. The default is the file browser.
    pub view: SidebarView,
    pub width: u16,
    pub compact_width: u16,
    pub max_width: u16,
    /// Ordered native columns. The legacy width fields remain the defaults for
    /// machine/workspace columns when this list is omitted from the config.
    pub columns: Vec<SidebarColumn>,
    pub columns_explicit: bool,
    /// Ordered native projections. A one-level projection uses the existing
    /// list behavior; multiple levels render as one native tree column.
    pub views: Vec<SidebarViewSpec>,
    pub views_explicit: bool,
    /// Named native layouts. `views` is always the currently selected
    /// profile's resolved rail list so older consumers remain compatible.
    pub profiles: Vec<SidebarProfileSpec>,
    pub active_profile: String,
    pub plugin: Option<SidebarPluginOptions>,
    /// Rows per rail entry: 2 keeps the subtitle line, 1 is name-only.
    pub row_height: u16,
    /// Blank rows between rail entries.
    pub row_gap: u16,
    /// Accent glyph on active rail rows; empty removes it.
    pub rail_glyph: String,
    /// Workspace row label template with `{index}` and `{name}`.
    pub workspace_label: String,
}

/// Background agent integrations. The process is optional and runs outside
/// the core detector. Its events enter through the journal producer API.
#[derive(Debug, Clone, Default)]
pub struct Agents {
    pub plugin: Option<cmux_tui_core::JournalPluginOptions>,
}

impl Default for Sidebar {
    fn default() -> Self {
        let views = vec![
            SidebarViewSpec::legacy(SidebarColumnKind::Machines, 22, 0),
            SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 22, 0),
        ];
        Sidebar {
            view: SidebarView::Workspaces,
            width: 22,
            compact_width: 10,
            max_width: 0,
            columns: vec![
                SidebarColumn { kind: SidebarColumnKind::Machines, width: 22, max_width: 0 },
                SidebarColumn { kind: SidebarColumnKind::Workspaces, width: 22, max_width: 0 },
            ],
            columns_explicit: false,
            views: views.clone(),
            views_explicit: false,
            profiles: vec![SidebarProfileSpec {
                id: "default".to_string(),
                name: "Default".to_string(),
                views,
            }],
            active_profile: "default".to_string(),
            plugin: None,
            row_height: 2,
            row_gap: 1,
            rail_glyph: "\u{258e}".to_string(),
            workspace_label: "{name}".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarProfileSpec {
    pub id: String,
    pub name: String,
    pub views: Vec<SidebarViewSpec>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SidebarColumnKind {
    Machines,
    Workspaces,
    Tabs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarColumn {
    pub kind: SidebarColumnKind,
    pub width: u16,
    pub max_width: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SidebarResourceKind {
    Machines,
    Workspaces,
    Panes,
    Tabs,
    Agents,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarViewSpec {
    pub id: String,
    pub levels: Vec<SidebarResourceKind>,
    /// Canonical native commands pinned to this view, with optional
    /// user-facing button labels.
    pub actions: Vec<SidebarActionSpec>,
    /// Whether the pinned actions render above or below the resource rows.
    pub actions_position: ActionsPosition,
    pub width: u16,
    pub max_width: u16,
    /// Lower values collapse first when pane space becomes constrained.
    pub collapse_priority: u16,
}

/// One pinned sidebar action and its optional label override.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarActionSpec {
    pub action: Action,
    pub label: Option<String>,
}

impl SidebarActionSpec {
    pub fn plain(action: Action) -> Self {
        Self { action, label: None }
    }
}

/// A configurable `+` button: its rendered label, an optional left-click
/// action override, and an optional right-click menu of actions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlusButton {
    pub label: String,
    pub action: Option<Action>,
    pub menu: Vec<SidebarActionSpec>,
}

impl Default for PlusButton {
    fn default() -> Self {
        Self { label: " + ".to_string(), action: None, menu: Vec::new() }
    }
}

fn resolve_plus_button(raw: RawPlusButton, command_ids: &[String], owner: &str) -> PlusButton {
    let mut plus = PlusButton::default();
    if let Some(label) = raw.label {
        // Keep at least one visible cell so the button stays clickable.
        if !label.trim().is_empty() {
            plus.label = label;
        }
    }
    if let Some(action) = raw.action.as_deref() {
        match parse_sidebar_action(action.trim(), command_ids) {
            Ok(action) => plus.action = Some(action),
            Err(warning) => {
                crate::client_log::stderr_log!("config", "{warning} in {owner} plus button");
            }
        }
    }
    if let Some(menu) = raw.menu {
        let mut seen = HashSet::new();
        for raw_action in &menu {
            match parse_sidebar_action(raw_action.action().trim(), command_ids) {
                Ok(action) if seen.insert(action) => plus.menu.push(SidebarActionSpec {
                    action,
                    label: raw_action
                        .label()
                        .map(str::trim)
                        .filter(|label| !label.is_empty())
                        .map(str::to_string),
                }),
                Ok(_) => crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring duplicate {owner} plus menu action {:?}",
                    raw_action.action().trim()
                ),
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning} in {owner} plus menu");
                }
            }
        }
    }
    plus
}

impl SidebarViewSpec {
    pub fn legacy(kind: SidebarColumnKind, width: u16, max_width: u16) -> Self {
        let (id, level, collapse_priority) = match kind {
            SidebarColumnKind::Machines => ("machines", SidebarResourceKind::Machines, 10),
            SidebarColumnKind::Workspaces => ("workspaces", SidebarResourceKind::Workspaces, 30),
            SidebarColumnKind::Tabs => ("tabs", SidebarResourceKind::Tabs, 20),
        };
        let levels = vec![level];
        let actions = default_sidebar_actions(&levels);
        Self {
            id: id.to_string(),
            levels,
            actions,
            actions_position: ActionsPosition::Bottom,
            width,
            max_width,
            collapse_priority,
        }
    }

    pub fn legacy_kind(&self) -> Option<SidebarColumnKind> {
        match self.levels.as_slice() {
            [SidebarResourceKind::Machines] => Some(SidebarColumnKind::Machines),
            [SidebarResourceKind::Workspaces] => Some(SidebarColumnKind::Workspaces),
            [SidebarResourceKind::Tabs] if self.actions.is_empty() => Some(SidebarColumnKind::Tabs),
            _ => None,
        }
    }

    pub fn includes(&self, kind: SidebarResourceKind) -> bool {
        self.levels.contains(&kind)
    }
}

/// Optional client-local rail listing connection targets. It is disabled for
/// ordinary local cmux sessions and enabled by a machine provider or config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineSidebar {
    pub enabled: bool,
    pub width: u16,
    pub max_width: u16,
    /// Session-local prototype sources. They exercise the native provider
    /// picker without starting containers or consuming cloud resources.
    pub create_sources: Vec<MachineCreationSourceConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineCreationSourceConfig {
    pub id: String,
    pub name: String,
    pub subtitle: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MachineProviderConfig {
    pub cloud: CloudProviderConfig,
    /// Argv of a machine-provider process to spawn, exactly like
    /// `--machine-provider-command program arg -- `. CLI provider modes
    /// override it.
    pub command: Option<Vec<String>>,
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
        Self { enabled: false, width: 22, max_width: 0, create_sources: Vec::new() }
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
            "{BIN}: ignoring unknown sidebar.view {value:?}; expected \"files\" or \"workspaces\""
        )),
    }
}

fn parse_sidebar_column_kind(value: &str) -> Result<SidebarColumnKind, String> {
    match value {
        "machines" => Ok(SidebarColumnKind::Machines),
        "workspaces" => Ok(SidebarColumnKind::Workspaces),
        "tabs" => Ok(SidebarColumnKind::Tabs),
        _ => Err(format!(
            "{BIN}: ignoring unknown sidebar column {value:?}; expected \"machines\", \"workspaces\", or \"tabs\""
        )),
    }
}

fn parse_sidebar_resource_kind(value: &str) -> Result<SidebarResourceKind, String> {
    match value {
        "machines" => Ok(SidebarResourceKind::Machines),
        "workspaces" => Ok(SidebarResourceKind::Workspaces),
        "panes" => Ok(SidebarResourceKind::Panes),
        "tabs" => Ok(SidebarResourceKind::Tabs),
        "agents" => Ok(SidebarResourceKind::Agents),
        _ => Err(format!(
            "{BIN}: ignoring unknown sidebar resource {value:?}; expected \"machines\", \"workspaces\", \"panes\", \"tabs\", or \"agents\""
        )),
    }
}

fn validate_sidebar_levels(levels: &[SidebarResourceKind]) -> Result<(), &'static str> {
    if levels.is_empty() {
        return Err("levels cannot be empty");
    }
    if levels.len() > 3 {
        return Err("at most three resource levels are supported");
    }
    let mut seen = HashSet::new();
    if levels.iter().any(|level| !seen.insert(*level)) {
        return Err("resource levels cannot repeat");
    }
    if levels.contains(&SidebarResourceKind::Machines) {
        return (levels == [SidebarResourceKind::Machines])
            .then_some(())
            .ok_or("machines must be a one-level view");
    }
    if let Some(index) = levels.iter().position(|level| *level == SidebarResourceKind::Workspaces)
        && index != 0
    {
        return Err("workspaces must be the first level");
    }
    if let Some(index) = levels.iter().position(|level| *level == SidebarResourceKind::Panes)
        && index > 1
    {
        return Err("panes must be first or directly below workspaces");
    }
    for leaf in [SidebarResourceKind::Tabs, SidebarResourceKind::Agents] {
        if let Some(index) = levels.iter().position(|level| *level == leaf)
            && index + 1 != levels.len()
        {
            return Err("tabs and agents must be the final level");
        }
    }
    Ok(())
}

fn default_sidebar_collapse_priority(levels: &[SidebarResourceKind]) -> u16 {
    match levels {
        [SidebarResourceKind::Machines] => 10,
        [SidebarResourceKind::Workspaces] => 30,
        _ => 20,
    }
}

fn default_sidebar_actions(levels: &[SidebarResourceKind]) -> Vec<SidebarActionSpec> {
    if levels.first() == Some(&SidebarResourceKind::Workspaces) {
        vec![SidebarActionSpec::plain(Action::NewWorkspace)]
    } else {
        Vec::new()
    }
}

/// Parse one pinned action name: an action catalog key, or `command:<id>`
/// referencing a user command from the top-level `commands` section.
fn parse_sidebar_action(value: &str, command_ids: &[String]) -> Result<Action, String> {
    if let Some(command_id) = value.strip_prefix("command:") {
        return command_ids
            .iter()
            .position(|id| id == command_id)
            .and_then(Action::user_command)
            .ok_or_else(|| {
                format!("{BIN}: ignoring sidebar action for unknown command {command_id:?}")
            });
    }
    action_definitions()
        .iter()
        .find(|definition| definition.config_key == value)
        .map(|definition| definition.action)
        .ok_or_else(|| format!("{BIN}: ignoring unknown sidebar action {value:?}"))
}

fn resolve_sidebar_view_specs(
    views: &[RawSidebarView],
    machine_width: u16,
    machine_max_width: u16,
    workspace_width: u16,
    workspace_max_width: u16,
    owner: &str,
    command_ids: &[String],
) -> Vec<SidebarViewSpec> {
    let mut ids = HashSet::new();
    let mut legacy_kinds = HashSet::new();
    let mut resolved = Vec::new();
    for view in views {
        let id = view.id.trim();
        if id.is_empty() || ids.contains(id) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view with an empty or duplicate id"
            );
            continue;
        }
        let mut levels = Vec::with_capacity(view.levels.len());
        let mut valid = true;
        for level in &view.levels {
            match parse_sidebar_resource_kind(level.trim()) {
                Ok(level) => levels.push(level),
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning}");
                    valid = false;
                    break;
                }
            }
        }
        if !valid {
            continue;
        }
        if let Err(reason) = validate_sidebar_levels(&levels) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view {id:?}: {reason}"
            );
            continue;
        }
        let legacy_kind = SidebarViewSpec {
            id: id.to_string(),
            levels: levels.clone(),
            actions: Vec::new(),
            actions_position: ActionsPosition::Bottom,
            width: 0,
            max_width: 0,
            collapse_priority: 0,
        }
        .legacy_kind();
        if legacy_kind.is_some_and(|kind| !legacy_kinds.insert(kind)) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring {owner} view {id:?}: a one-level view for that resource already exists"
            );
            continue;
        }
        ids.insert(id.to_string());
        let (default_width, default_max_width) = match legacy_kind {
            Some(SidebarColumnKind::Machines) => (machine_width, machine_max_width),
            Some(SidebarColumnKind::Workspaces) => (workspace_width, workspace_max_width),
            Some(SidebarColumnKind::Tabs) | None => (22, 0),
        };
        let actions = if levels == [SidebarResourceKind::Machines]
            && view.actions.as_ref().is_some_and(|actions| !actions.is_empty())
        {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar actions in {owner} machine view {id:?}; machine actions come from provider capabilities"
            );
            Vec::new()
        } else if let Some(raw_actions) = view.actions.as_ref() {
            let mut seen = HashSet::new();
            raw_actions
                .iter()
                .filter_map(|raw_action| {
                    match parse_sidebar_action(raw_action.action().trim(), command_ids) {
                        Ok(action) if seen.insert(action) => Some(SidebarActionSpec {
                            action,
                            label: raw_action
                                .label()
                                .map(str::trim)
                                .filter(|label| !label.is_empty())
                                .map(str::to_string),
                        }),
                        Ok(_) => {
                            crate::client_log::stderr_log!("config",
                                "{BIN}: ignoring duplicate sidebar action {:?} in {owner} view {id:?}",
                                raw_action.action().trim()
                            );
                            None
                        }
                        Err(warning) => {
                            crate::client_log::stderr_log!("config", "{warning} in {owner} view {id:?}");
                            None
                        }
                    }
                })
                .collect()
        } else {
            default_sidebar_actions(&levels)
        };
        resolved.push(SidebarViewSpec {
            id: id.to_string(),
            collapse_priority: view
                .collapse_priority
                .unwrap_or_else(|| default_sidebar_collapse_priority(&levels)),
            levels,
            actions,
            actions_position: view.actions_position.unwrap_or_default(),
            width: view.width.unwrap_or(default_width).clamp(10, 60),
            max_width: view.max_width.unwrap_or(default_max_width),
        });
    }
    resolved
}

#[derive(Debug, Clone)]
pub struct Browser {
    pub cdp_url: Option<String>,
    pub max_capture_megapixels: f64,
    pub capture_scale: Option<f64>,
}

impl Default for Browser {
    fn default() -> Self {
        Browser {
            cdp_url: None,
            max_capture_megapixels: TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            capture_scale: None,
        }
    }
}

/// A validated zero-based index for the ten directly selectable tabs and
/// screens. Its private field prevents unregistered numbered actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ActionIndex(u8);

impl ActionIndex {
    pub const fn new(value: u8) -> Option<Self> {
        if value <= 9 { Some(Self(value)) } else { None }
    }

    pub const fn get(self) -> u8 {
        self.0
    }
}

/// The maximum number of configurable user commands. Chords bound past this
/// limit are rejected at config load with a visible warning.
pub const MAX_USER_COMMANDS: usize = 32;

/// The maximum number of chords one command may bind.
pub const MAX_USER_COMMAND_CHORDS: usize = 8;

/// A validated zero-based index into the configured `commands` list. Its
/// private field prevents unregistered command actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UserCommandIndex(u8);

impl UserCommandIndex {
    pub const fn new(value: usize) -> Option<Self> {
        if value < MAX_USER_COMMANDS { Some(Self(value as u8)) } else { None }
    }

    pub const fn get(self) -> usize {
        self.0 as usize
    }
}

/// Every prefix-key action, so bindings are configurable end to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Action {
    SendPrefix,
    NewTab,
    NewBrowserTab,
    NewPaneSmart,
    NextTab,
    PrevTab,
    SelectTab(ActionIndex),
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
    SelectScreen(ActionIndex),
    NewScreen,
    PrevWorkspace,
    NextWorkspace,
    NewWorkspace,
    CloseWorkspace,
    ToggleSidebar,
    ToggleSidebarCompact,
    ToggleSidebarView,
    FocusSidebar,
    ProviderMenu,
    NewPaneRight,
    UndoLayout,
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
    ShowShortcuts,
    Detach,
    /// A user-configured command from the top-level `commands` section,
    /// opened as a new PTY tab through the mux `run` command.
    UserCommand(UserCommandIndex),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(crate) enum ActionExecution {
    SendPrefix,
    NewTab,
    NewBrowserTab,
    NewPaneSmart,
    NextTab,
    PrevTab,
    SelectTab(ActionIndex),
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
    SelectScreen(ActionIndex),
    NewScreen,
    PrevWorkspace,
    NextWorkspace,
    NewWorkspace,
    CloseWorkspace,
    ToggleSidebar,
    ToggleSidebarCompact,
    ToggleSidebarView,
    FocusSidebar,
    ProviderMenu,
    NewPaneRight,
    UndoLayout,
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
    ShowShortcuts,
    Detach,
    UserCommand(UserCommandIndex),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum ActionClassification {
    Direct,
    Composite,
    PresentationOnly,
}

#[cfg(test)]
impl ActionClassification {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Composite => "composite",
            Self::PresentationOnly => "presentation-only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum WorkspaceOwnershipSource {
    ActiveWorkspaceSession,
}

#[cfg(test)]
impl WorkspaceOwnershipSource {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::ActiveWorkspaceSession => "active-workspace-session",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum ActionRouteTarget {
    MuxCommand(&'static str),
    MachineProviderRequest(&'static str),
}

#[cfg(test)]
impl ActionRouteTarget {
    const fn inventory_kind(self) -> &'static str {
        match self {
            Self::MuxCommand(_) => "mux-command",
            Self::MachineProviderRequest(_) => "machine-provider-request",
        }
    }

    const fn operation(self) -> &'static str {
        match self {
            Self::MuxCommand(operation) | Self::MachineProviderRequest(operation) => operation,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum UnknownOwnership {
    Reject,
}

#[cfg(test)]
impl UnknownOwnership {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::Reject => "reject",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
enum ActionRoute {
    Static(&'static str),
    WorkspaceOwnership {
        source: WorkspaceOwnershipSource,
        session_owned: ActionRouteTarget,
        provider_owned: ActionRouteTarget,
        unknown: UnknownOwnership,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(crate) struct ActionMetadata {
    key: &'static str,
    classification: ActionClassification,
    route: ActionRoute,
    execution: ActionExecution,
}

#[cfg(test)]
impl ActionMetadata {
    const fn new(
        key: &'static str,
        classification: ActionClassification,
        route: &'static str,
        execution: ActionExecution,
    ) -> Self {
        Self { key, classification, route: ActionRoute::Static(route), execution }
    }

    const fn workspace_ownership(
        key: &'static str,
        classification: ActionClassification,
        source: WorkspaceOwnershipSource,
        session_owned: ActionRouteTarget,
        provider_owned: ActionRouteTarget,
        unknown: UnknownOwnership,
        execution: ActionExecution,
    ) -> Self {
        Self {
            key,
            classification,
            route: ActionRoute::WorkspaceOwnership {
                source,
                session_owned,
                provider_owned,
                unknown,
            },
            execution,
        }
    }

    pub(crate) fn execution(self) -> ActionExecution {
        debug_assert!(!self.key.is_empty());
        debug_assert!(!self.classification.inventory_name().is_empty());
        match self.route {
            ActionRoute::Static(route) => debug_assert!(!route.is_empty()),
            ActionRoute::WorkspaceOwnership { source, session_owned, provider_owned, unknown } => {
                debug_assert!(!source.inventory_name().is_empty());
                debug_assert_eq!(session_owned.inventory_kind(), "mux-command");
                debug_assert!(!session_owned.operation().is_empty());
                debug_assert_eq!(provider_owned.inventory_kind(), "machine-provider-request");
                debug_assert!(!provider_owned.operation().is_empty());
                debug_assert_eq!(unknown.inventory_name(), "reject");
            }
        }
        self.execution
    }
}

/// One executable TUI action and the metadata shared by key configuration,
/// context menus, shortcut help, and future command surfaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionDefinition {
    pub action: Action,
    pub config_key: &'static str,
    pub label_en: &'static str,
    pub label_ja: &'static str,
}

macro_rules! action_definition {
    ($action:expr, $config_key:literal, $label_en:literal, $label_ja:literal) => {
        ActionDefinition {
            action: $action,
            config_key: $config_key,
            label_en: $label_en,
            label_ja: $label_ja,
        }
    };
}

macro_rules! define_named_action_definitions {
    ($( $name:ident => ($action:expr, $config_key:literal, $label_en:literal, $label_ja:literal); )+) => {
        $(
            static $name: ActionDefinition =
                action_definition!($action, $config_key, $label_en, $label_ja);
        )+
    };
}

define_named_action_definitions! {
    SEND_PREFIX_DEFINITION => (Action::SendPrefix, "send-prefix", "Send prefix", "プレフィックスを送信");
    NEW_TAB_DEFINITION => (Action::NewTab, "new-tab", "New tab", "新しいタブ");
    NEW_BROWSER_TAB_DEFINITION => (Action::NewBrowserTab, "new-browser-tab", "New browser tab", "新しいブラウザタブ");
    NEW_PANE_SMART_DEFINITION => (Action::NewPaneSmart, "new-pane-smart", "New pane", "新しいペイン");
    NEXT_TAB_DEFINITION => (Action::NextTab, "next-tab", "Next tab", "次のタブ");
    PREV_TAB_DEFINITION => (Action::PrevTab, "prev-tab", "Previous tab", "前のタブ");
    SPLIT_RIGHT_DEFINITION => (Action::SplitRight, "split-right", "Split right", "右に分割");
    SPLIT_DOWN_DEFINITION => (Action::SplitDown, "split-down", "Split down", "下に分割");
    CLOSE_TAB_DEFINITION => (Action::CloseTab, "close-tab", "Close tab", "タブを閉じる");
    CLOSE_PANE_DEFINITION => (Action::ClosePane, "close-pane", "Close pane", "ペインを閉じる");
    RENAME_TAB_DEFINITION => (Action::RenameTab, "rename-tab", "Rename tab", "タブ名を変更");
    RENAME_SCREEN_DEFINITION => (Action::RenameScreen, "rename-screen", "Rename screen", "スクリーン名を変更");
    RENAME_WORKSPACE_DEFINITION => (Action::RenameWorkspace, "rename-workspace", "Rename workspace", "ワークスペース名を変更");
    CLOSE_SCREEN_DEFINITION => (Action::CloseScreen, "close-screen", "Close screen", "スクリーンを閉じる");
    PREV_SCREEN_DEFINITION => (Action::PrevScreen, "prev-screen", "Previous screen", "前のスクリーン");
    NEXT_SCREEN_DEFINITION => (Action::NextScreen, "next-screen", "Next screen", "次のスクリーン");
    NEW_SCREEN_DEFINITION => (Action::NewScreen, "new-screen", "New screen", "新しいスクリーン");
    PREV_WORKSPACE_DEFINITION => (Action::PrevWorkspace, "prev-workspace", "Previous workspace", "前のワークスペース");
    NEXT_WORKSPACE_DEFINITION => (Action::NextWorkspace, "next-workspace", "Next workspace", "次のワークスペース");
    NEW_WORKSPACE_DEFINITION => (Action::NewWorkspace, "new-workspace", "New workspace", "新しいワークスペース");
    CLOSE_WORKSPACE_DEFINITION => (Action::CloseWorkspace, "close-workspace", "Close workspace", "ワークスペースを閉じる");
    TOGGLE_SIDEBAR_DEFINITION => (Action::ToggleSidebar, "toggle-sidebar", "Show or hide sidebar", "サイドバーの表示を切り替え");
    TOGGLE_SIDEBAR_COMPACT_DEFINITION => (Action::ToggleSidebarCompact, "toggle-sidebar-compact", "Compact or expand sidebar", "サイドバーの幅を切り替え");
    TOGGLE_SIDEBAR_VIEW_DEFINITION => (Action::ToggleSidebarView, "toggle-sidebar-view", "Switch sidebar view", "サイドバー表示を切り替え");
    FOCUS_SIDEBAR_DEFINITION => (Action::FocusSidebar, "focus-sidebar", "Focus sidebar", "サイドバーにフォーカス");
    PROVIDER_MENU_DEFINITION => (Action::ProviderMenu, "provider-menu", "Machine provider menu", "マシンプロバイダーメニュー");
    NEW_PANE_RIGHT_DEFINITION => (Action::NewPaneRight, "new-pane-right", "New column to the right", "右に新しい列");
    UNDO_LAYOUT_DEFINITION => (Action::UndoLayout, "undo-layout", "Undo layout", "レイアウトを元に戻す");
    FOCUS_LEFT_DEFINITION => (Action::FocusLeft, "focus-left", "Focus left", "左へフォーカス");
    FOCUS_RIGHT_DEFINITION => (Action::FocusRight, "focus-right", "Focus right", "右へフォーカス");
    FOCUS_UP_DEFINITION => (Action::FocusUp, "focus-up", "Focus up", "上へフォーカス");
    FOCUS_DOWN_DEFINITION => (Action::FocusDown, "focus-down", "Focus down", "下へフォーカス");
    FOCUS_NEXT_PANE_DEFINITION => (Action::FocusNextPane, "focus-next-pane", "Focus next pane", "次のペインにフォーカス");
    SWAP_PANE_PREV_DEFINITION => (Action::SwapPanePrev, "swap-pane-prev", "Move pane backward", "ペインを前へ移動");
    SWAP_PANE_NEXT_DEFINITION => (Action::SwapPaneNext, "swap-pane-next", "Move pane forward", "ペインを後ろへ移動");
    ZOOM_PANE_DEFINITION => (Action::ZoomPane, "zoom-pane", "Maximize or restore pane", "ペインを最大化または復元");
    RESIZE_GROW_DEFINITION => (Action::ResizeGrow, "resize-grow", "Grow pane", "ペインを拡大");
    RESIZE_SHRINK_DEFINITION => (Action::ResizeShrink, "resize-shrink", "Shrink pane", "ペインを縮小");
    SCROLL_UP_DEFINITION => (Action::ScrollUp, "scroll-up", "Scroll up", "上にスクロール");
    SCROLL_DOWN_DEFINITION => (Action::ScrollDown, "scroll-down", "Scroll down", "下にスクロール");
    CLEAR_HISTORY_DEFINITION => (Action::ClearHistory, "clear-history", "Clear terminal history", "ターミナル履歴を消去");
    BROWSER_BACK_DEFINITION => (Action::BrowserBack, "browser-back", "Browser back", "ブラウザで戻る");
    BROWSER_FORWARD_DEFINITION => (Action::BrowserForward, "browser-forward", "Browser forward", "ブラウザで進む");
    BROWSER_RELOAD_DEFINITION => (Action::BrowserReload, "browser-reload", "Reload browser", "ブラウザを再読み込み");
    BROWSER_EDIT_URL_DEFINITION => (Action::BrowserEditUrl, "browser-edit-url", "Edit browser URL", "ブラウザ URL を編集");
    SHOW_SHORTCUTS_DEFINITION => (Action::ShowShortcuts, "show-shortcuts", "Keyboard shortcuts", "キーボードショートカット");
    DETACH_DEFINITION => (Action::Detach, "detach", "Detach", "デタッチ");
}

static SELECT_TAB_DEFINITIONS: [ActionDefinition; 10] = [
    action_definition!(
        Action::select_tab(0).unwrap(),
        "select-tab-0",
        "Select tab 0",
        "タブ 0 を選択"
    ),
    action_definition!(
        Action::select_tab(1).unwrap(),
        "select-tab-1",
        "Select tab 1",
        "タブ 1 を選択"
    ),
    action_definition!(
        Action::select_tab(2).unwrap(),
        "select-tab-2",
        "Select tab 2",
        "タブ 2 を選択"
    ),
    action_definition!(
        Action::select_tab(3).unwrap(),
        "select-tab-3",
        "Select tab 3",
        "タブ 3 を選択"
    ),
    action_definition!(
        Action::select_tab(4).unwrap(),
        "select-tab-4",
        "Select tab 4",
        "タブ 4 を選択"
    ),
    action_definition!(
        Action::select_tab(5).unwrap(),
        "select-tab-5",
        "Select tab 5",
        "タブ 5 を選択"
    ),
    action_definition!(
        Action::select_tab(6).unwrap(),
        "select-tab-6",
        "Select tab 6",
        "タブ 6 を選択"
    ),
    action_definition!(
        Action::select_tab(7).unwrap(),
        "select-tab-7",
        "Select tab 7",
        "タブ 7 を選択"
    ),
    action_definition!(
        Action::select_tab(8).unwrap(),
        "select-tab-8",
        "Select tab 8",
        "タブ 8 を選択"
    ),
    action_definition!(
        Action::select_tab(9).unwrap(),
        "select-tab-9",
        "Select tab 9",
        "タブ 9 を選択"
    ),
];

static SELECT_SCREEN_DEFINITIONS: [ActionDefinition; 10] = [
    action_definition!(
        Action::select_screen(0).unwrap(),
        "select-screen-0",
        "Select screen 0",
        "スクリーン 0 を選択"
    ),
    action_definition!(
        Action::select_screen(1).unwrap(),
        "select-screen-1",
        "Select screen 1",
        "スクリーン 1 を選択"
    ),
    action_definition!(
        Action::select_screen(2).unwrap(),
        "select-screen-2",
        "Select screen 2",
        "スクリーン 2 を選択"
    ),
    action_definition!(
        Action::select_screen(3).unwrap(),
        "select-screen-3",
        "Select screen 3",
        "スクリーン 3 を選択"
    ),
    action_definition!(
        Action::select_screen(4).unwrap(),
        "select-screen-4",
        "Select screen 4",
        "スクリーン 4 を選択"
    ),
    action_definition!(
        Action::select_screen(5).unwrap(),
        "select-screen-5",
        "Select screen 5",
        "スクリーン 5 を選択"
    ),
    action_definition!(
        Action::select_screen(6).unwrap(),
        "select-screen-6",
        "Select screen 6",
        "スクリーン 6 を選択"
    ),
    action_definition!(
        Action::select_screen(7).unwrap(),
        "select-screen-7",
        "Select screen 7",
        "スクリーン 7 を選択"
    ),
    action_definition!(
        Action::select_screen(8).unwrap(),
        "select-screen-8",
        "Select screen 8",
        "スクリーン 8 を選択"
    ),
    action_definition!(
        Action::select_screen(9).unwrap(),
        "select-screen-9",
        "Select screen 9",
        "スクリーン 9 を選択"
    ),
];

/// The canonical action catalog. Presentation surfaces derive their labels
/// and ordering from these named definitions instead of positional offsets.
pub fn action_definitions() -> &'static [&'static ActionDefinition] {
    static DEFINITIONS: [&ActionDefinition; 67] = [
        &SEND_PREFIX_DEFINITION,
        &NEW_TAB_DEFINITION,
        &NEW_BROWSER_TAB_DEFINITION,
        &NEW_PANE_SMART_DEFINITION,
        &NEXT_TAB_DEFINITION,
        &PREV_TAB_DEFINITION,
        &SELECT_TAB_DEFINITIONS[0],
        &SELECT_TAB_DEFINITIONS[1],
        &SELECT_TAB_DEFINITIONS[2],
        &SELECT_TAB_DEFINITIONS[3],
        &SELECT_TAB_DEFINITIONS[4],
        &SELECT_TAB_DEFINITIONS[5],
        &SELECT_TAB_DEFINITIONS[6],
        &SELECT_TAB_DEFINITIONS[7],
        &SELECT_TAB_DEFINITIONS[8],
        &SELECT_TAB_DEFINITIONS[9],
        &SPLIT_RIGHT_DEFINITION,
        &SPLIT_DOWN_DEFINITION,
        &CLOSE_TAB_DEFINITION,
        &CLOSE_PANE_DEFINITION,
        &RENAME_TAB_DEFINITION,
        &RENAME_SCREEN_DEFINITION,
        &RENAME_WORKSPACE_DEFINITION,
        &CLOSE_SCREEN_DEFINITION,
        &PREV_SCREEN_DEFINITION,
        &NEXT_SCREEN_DEFINITION,
        &SELECT_SCREEN_DEFINITIONS[0],
        &SELECT_SCREEN_DEFINITIONS[1],
        &SELECT_SCREEN_DEFINITIONS[2],
        &SELECT_SCREEN_DEFINITIONS[3],
        &SELECT_SCREEN_DEFINITIONS[4],
        &SELECT_SCREEN_DEFINITIONS[5],
        &SELECT_SCREEN_DEFINITIONS[6],
        &SELECT_SCREEN_DEFINITIONS[7],
        &SELECT_SCREEN_DEFINITIONS[8],
        &SELECT_SCREEN_DEFINITIONS[9],
        &NEW_SCREEN_DEFINITION,
        &PREV_WORKSPACE_DEFINITION,
        &NEXT_WORKSPACE_DEFINITION,
        &NEW_WORKSPACE_DEFINITION,
        &CLOSE_WORKSPACE_DEFINITION,
        &TOGGLE_SIDEBAR_DEFINITION,
        &TOGGLE_SIDEBAR_COMPACT_DEFINITION,
        &TOGGLE_SIDEBAR_VIEW_DEFINITION,
        &FOCUS_SIDEBAR_DEFINITION,
        &PROVIDER_MENU_DEFINITION,
        &NEW_PANE_RIGHT_DEFINITION,
        &UNDO_LAYOUT_DEFINITION,
        &FOCUS_LEFT_DEFINITION,
        &FOCUS_RIGHT_DEFINITION,
        &FOCUS_UP_DEFINITION,
        &FOCUS_DOWN_DEFINITION,
        &FOCUS_NEXT_PANE_DEFINITION,
        &SWAP_PANE_PREV_DEFINITION,
        &SWAP_PANE_NEXT_DEFINITION,
        &ZOOM_PANE_DEFINITION,
        &RESIZE_GROW_DEFINITION,
        &RESIZE_SHRINK_DEFINITION,
        &SCROLL_UP_DEFINITION,
        &SCROLL_DOWN_DEFINITION,
        &CLEAR_HISTORY_DEFINITION,
        &BROWSER_BACK_DEFINITION,
        &BROWSER_FORWARD_DEFINITION,
        &BROWSER_RELOAD_DEFINITION,
        &BROWSER_EDIT_URL_DEFINITION,
        &SHOW_SHORTCUTS_DEFINITION,
        &DETACH_DEFINITION,
    ];
    &DEFINITIONS
}

/// Fallback definition for `Action::UserCommand`. It is intentionally not in
/// `action_definitions()`: user commands are named by the user's config, and
/// presentation surfaces look the display name up there. The `action` field
/// pins index 0 only because a definition must carry one concrete action.
static USER_COMMAND_FALLBACK_DEFINITION: ActionDefinition = action_definition!(
    Action::UserCommand(UserCommandIndex(0)),
    "user-command",
    "User command",
    "ユーザーコマンド"
);

impl Action {
    /// Compiled source of truth for programmability classification and
    /// execution routing. The specification inventory checker reads this
    /// exhaustive catalog.
    #[cfg(test)]
    pub(crate) fn metadata(&self) -> ActionMetadata {
        match self {
            Action::SendPrefix => ActionMetadata::new(
                "send-prefix",
                ActionClassification::Composite,
                "frontend prefix config + active surface + send-key",
                ActionExecution::SendPrefix,
            ),
            Action::NewTab => ActionMetadata::new(
                "new-tab",
                ActionClassification::Direct,
                "new-tab",
                ActionExecution::NewTab,
            ),
            Action::NewBrowserTab => ActionMetadata::new(
                "new-browser-tab",
                ActionClassification::Composite,
                "frontend omnibar + new-browser-tab",
                ActionExecution::NewBrowserTab,
            ),
            Action::NewPaneSmart => ActionMetadata::new(
                "new-pane-smart",
                ActionClassification::Composite,
                "list-workspaces + new-pane",
                ActionExecution::NewPaneSmart,
            ),
            Action::NextTab => ActionMetadata::new(
                "next-tab",
                ActionClassification::Direct,
                "select-tab delta:+1",
                ActionExecution::NextTab,
            ),
            Action::PrevTab => ActionMetadata::new(
                "prev-tab",
                ActionClassification::Direct,
                "select-tab delta:-1",
                ActionExecution::PrevTab,
            ),
            Action::SelectTab(index) => ActionMetadata::new(
                "select-tab-{number}",
                ActionClassification::Direct,
                "select-tab index",
                ActionExecution::SelectTab(*index),
            ),
            Action::SplitRight => ActionMetadata::new(
                "split-right",
                ActionClassification::Direct,
                "split dir:right",
                ActionExecution::SplitRight,
            ),
            Action::SplitDown => ActionMetadata::new(
                "split-down",
                ActionClassification::Direct,
                "split dir:down",
                ActionExecution::SplitDown,
            ),
            Action::CloseTab => ActionMetadata::new(
                "close-tab",
                ActionClassification::Direct,
                "close-surface",
                ActionExecution::CloseTab,
            ),
            Action::ClosePane => ActionMetadata::new(
                "close-pane",
                ActionClassification::Direct,
                "close-pane",
                ActionExecution::ClosePane,
            ),
            Action::RenameTab => ActionMetadata::new(
                "rename-tab",
                ActionClassification::Composite,
                "frontend prompt + rename-surface",
                ActionExecution::RenameTab,
            ),
            Action::RenameScreen => ActionMetadata::new(
                "rename-screen",
                ActionClassification::Composite,
                "frontend prompt + rename-screen",
                ActionExecution::RenameScreen,
            ),
            Action::RenameWorkspace => ActionMetadata::new(
                "rename-workspace",
                ActionClassification::Composite,
                "frontend prompt + rename-workspace",
                ActionExecution::RenameWorkspace,
            ),
            Action::CloseScreen => ActionMetadata::new(
                "close-screen",
                ActionClassification::Direct,
                "close-screen",
                ActionExecution::CloseScreen,
            ),
            Action::PrevScreen => ActionMetadata::new(
                "prev-screen",
                ActionClassification::Direct,
                "select-screen delta:-1",
                ActionExecution::PrevScreen,
            ),
            Action::NextScreen => ActionMetadata::new(
                "next-screen",
                ActionClassification::Direct,
                "select-screen delta:+1",
                ActionExecution::NextScreen,
            ),
            Action::SelectScreen(index) => ActionMetadata::new(
                "select-screen-{number}",
                ActionClassification::Direct,
                "select-screen index",
                ActionExecution::SelectScreen(*index),
            ),
            Action::NewScreen => ActionMetadata::new(
                "new-screen",
                ActionClassification::Direct,
                "new-screen",
                ActionExecution::NewScreen,
            ),
            Action::PrevWorkspace => ActionMetadata::new(
                "prev-workspace",
                ActionClassification::Direct,
                "select-workspace delta:-1",
                ActionExecution::PrevWorkspace,
            ),
            Action::NextWorkspace => ActionMetadata::new(
                "next-workspace",
                ActionClassification::Direct,
                "select-workspace delta:+1",
                ActionExecution::NextWorkspace,
            ),
            Action::NewWorkspace => ActionMetadata::workspace_ownership(
                "new-workspace",
                ActionClassification::Composite,
                WorkspaceOwnershipSource::ActiveWorkspaceSession,
                ActionRouteTarget::MuxCommand("new-workspace"),
                ActionRouteTarget::MachineProviderRequest("create_workspace"),
                UnknownOwnership::Reject,
                ActionExecution::NewWorkspace,
            ),
            Action::CloseWorkspace => ActionMetadata::workspace_ownership(
                "close-workspace",
                ActionClassification::Composite,
                WorkspaceOwnershipSource::ActiveWorkspaceSession,
                ActionRouteTarget::MuxCommand("close-workspace"),
                ActionRouteTarget::MachineProviderRequest("delete_workspace"),
                UnknownOwnership::Reject,
                ActionExecution::CloseWorkspace,
            ),
            Action::ToggleSidebar => ActionMetadata::new(
                "toggle-sidebar",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebar,
            ),
            Action::ToggleSidebarCompact => ActionMetadata::new(
                "toggle-sidebar-compact",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebarCompact,
            ),
            Action::ToggleSidebarView => ActionMetadata::new(
                "toggle-sidebar-view",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebarView,
            ),
            Action::FocusSidebar => ActionMetadata::new(
                "focus-sidebar",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::FocusSidebar,
            ),
            Action::ProviderMenu => ActionMetadata::new(
                "provider-menu",
                ActionClassification::PresentationOnly,
                "frontend machine provider menu",
                ActionExecution::ProviderMenu,
            ),
            Action::NewPaneRight => ActionMetadata::new(
                "new-pane-right",
                ActionClassification::Direct,
                "new-pane-right",
                ActionExecution::NewPaneRight,
            ),
            Action::UndoLayout => ActionMetadata::new(
                "undo-layout",
                ActionClassification::Direct,
                "undo-layout",
                ActionExecution::UndoLayout,
            ),
            Action::FocusLeft => ActionMetadata::new(
                "focus-left",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusLeft,
            ),
            Action::FocusRight => ActionMetadata::new(
                "focus-right",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusRight,
            ),
            Action::FocusUp => ActionMetadata::new(
                "focus-up",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusUp,
            ),
            Action::FocusDown => ActionMetadata::new(
                "focus-down",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusDown,
            ),
            Action::FocusNextPane => ActionMetadata::new(
                "focus-next-pane",
                ActionClassification::Composite,
                "list-workspaces + focus-pane",
                ActionExecution::FocusNextPane,
            ),
            Action::SwapPanePrev => ActionMetadata::new(
                "swap-pane-prev",
                ActionClassification::Composite,
                "list-workspaces + swap-pane",
                ActionExecution::SwapPanePrev,
            ),
            Action::SwapPaneNext => ActionMetadata::new(
                "swap-pane-next",
                ActionClassification::Composite,
                "list-workspaces + swap-pane",
                ActionExecution::SwapPaneNext,
            ),
            Action::ZoomPane => ActionMetadata::new(
                "zoom-pane",
                ActionClassification::Direct,
                "zoom-pane",
                ActionExecution::ZoomPane,
            ),
            Action::ResizeGrow => ActionMetadata::new(
                "resize-grow",
                ActionClassification::Composite,
                "list-workspaces + set-split-ratio",
                ActionExecution::ResizeGrow,
            ),
            Action::ResizeShrink => ActionMetadata::new(
                "resize-shrink",
                ActionClassification::Composite,
                "list-workspaces + set-split-ratio",
                ActionExecution::ResizeShrink,
            ),
            Action::ScrollUp => ActionMetadata::new(
                "scroll-up",
                ActionClassification::PresentationOnly,
                "frontend viewport adapter; scroll-surface for shared local viewport",
                ActionExecution::ScrollUp,
            ),
            Action::ScrollDown => ActionMetadata::new(
                "scroll-down",
                ActionClassification::PresentationOnly,
                "frontend viewport adapter; scroll-surface for shared local viewport",
                ActionExecution::ScrollDown,
            ),
            Action::ClearHistory => ActionMetadata::new(
                "clear-history",
                ActionClassification::Direct,
                "clear-history",
                ActionExecution::ClearHistory,
            ),
            Action::BrowserBack => ActionMetadata::new(
                "browser-back",
                ActionClassification::Direct,
                "browser-back",
                ActionExecution::BrowserBack,
            ),
            Action::BrowserForward => ActionMetadata::new(
                "browser-forward",
                ActionClassification::Direct,
                "browser-forward",
                ActionExecution::BrowserForward,
            ),
            Action::BrowserReload => ActionMetadata::new(
                "browser-reload",
                ActionClassification::Direct,
                "browser-reload",
                ActionExecution::BrowserReload,
            ),
            Action::BrowserEditUrl => ActionMetadata::new(
                "browser-edit-url",
                ActionClassification::Composite,
                "frontend prompt + browser-navigate",
                ActionExecution::BrowserEditUrl,
            ),
            Action::ShowShortcuts => ActionMetadata::new(
                "show-shortcuts",
                ActionClassification::PresentationOnly,
                "frontend shortcut overlay",
                ActionExecution::ShowShortcuts,
            ),
            Action::Detach => ActionMetadata::new(
                "detach",
                ActionClassification::PresentationOnly,
                "close frontend transport",
                ActionExecution::Detach,
            ),
            Action::UserCommand(index) => ActionMetadata::new(
                "user-command-{index}",
                ActionClassification::Composite,
                "frontend command config + run",
                ActionExecution::UserCommand(*index),
            ),
        }
    }
}

impl Action {
    pub fn definition(self) -> &'static ActionDefinition {
        match self {
            Action::SendPrefix => &SEND_PREFIX_DEFINITION,
            Action::NewTab => &NEW_TAB_DEFINITION,
            Action::NewBrowserTab => &NEW_BROWSER_TAB_DEFINITION,
            Action::NewPaneSmart => &NEW_PANE_SMART_DEFINITION,
            Action::NextTab => &NEXT_TAB_DEFINITION,
            Action::PrevTab => &PREV_TAB_DEFINITION,
            Action::SelectTab(index) => &SELECT_TAB_DEFINITIONS[index.get() as usize],
            Action::SplitRight => &SPLIT_RIGHT_DEFINITION,
            Action::SplitDown => &SPLIT_DOWN_DEFINITION,
            Action::CloseTab => &CLOSE_TAB_DEFINITION,
            Action::ClosePane => &CLOSE_PANE_DEFINITION,
            Action::RenameTab => &RENAME_TAB_DEFINITION,
            Action::RenameScreen => &RENAME_SCREEN_DEFINITION,
            Action::RenameWorkspace => &RENAME_WORKSPACE_DEFINITION,
            Action::CloseScreen => &CLOSE_SCREEN_DEFINITION,
            Action::PrevScreen => &PREV_SCREEN_DEFINITION,
            Action::NextScreen => &NEXT_SCREEN_DEFINITION,
            Action::SelectScreen(index) => &SELECT_SCREEN_DEFINITIONS[index.get() as usize],
            Action::NewScreen => &NEW_SCREEN_DEFINITION,
            Action::PrevWorkspace => &PREV_WORKSPACE_DEFINITION,
            Action::NextWorkspace => &NEXT_WORKSPACE_DEFINITION,
            Action::NewWorkspace => &NEW_WORKSPACE_DEFINITION,
            Action::CloseWorkspace => &CLOSE_WORKSPACE_DEFINITION,
            Action::ToggleSidebar => &TOGGLE_SIDEBAR_DEFINITION,
            Action::ToggleSidebarCompact => &TOGGLE_SIDEBAR_COMPACT_DEFINITION,
            Action::ToggleSidebarView => &TOGGLE_SIDEBAR_VIEW_DEFINITION,
            Action::FocusSidebar => &FOCUS_SIDEBAR_DEFINITION,
            Action::ProviderMenu => &PROVIDER_MENU_DEFINITION,
            Action::NewPaneRight => &NEW_PANE_RIGHT_DEFINITION,
            Action::UndoLayout => &UNDO_LAYOUT_DEFINITION,
            Action::FocusLeft => &FOCUS_LEFT_DEFINITION,
            Action::FocusRight => &FOCUS_RIGHT_DEFINITION,
            Action::FocusUp => &FOCUS_UP_DEFINITION,
            Action::FocusDown => &FOCUS_DOWN_DEFINITION,
            Action::FocusNextPane => &FOCUS_NEXT_PANE_DEFINITION,
            Action::SwapPanePrev => &SWAP_PANE_PREV_DEFINITION,
            Action::SwapPaneNext => &SWAP_PANE_NEXT_DEFINITION,
            Action::ZoomPane => &ZOOM_PANE_DEFINITION,
            Action::ResizeGrow => &RESIZE_GROW_DEFINITION,
            Action::ResizeShrink => &RESIZE_SHRINK_DEFINITION,
            Action::ScrollUp => &SCROLL_UP_DEFINITION,
            Action::ScrollDown => &SCROLL_DOWN_DEFINITION,
            Action::ClearHistory => &CLEAR_HISTORY_DEFINITION,
            Action::BrowserBack => &BROWSER_BACK_DEFINITION,
            Action::BrowserForward => &BROWSER_FORWARD_DEFINITION,
            Action::BrowserReload => &BROWSER_RELOAD_DEFINITION,
            Action::BrowserEditUrl => &BROWSER_EDIT_URL_DEFINITION,
            Action::ShowShortcuts => &SHOW_SHORTCUTS_DEFINITION,
            Action::Detach => &DETACH_DEFINITION,
            // One shared fallback: presentation surfaces resolve the
            // configured display name through the command list instead of
            // this static definition, which is deliberately outside the
            // action catalog.
            Action::UserCommand(_) => &USER_COMMAND_FALLBACK_DEFINITION,
        }
    }

    pub const fn select_screen(number: u8) -> Option<Self> {
        match ActionIndex::new(number) {
            Some(index) => Some(Self::SelectScreen(index)),
            None => None,
        }
    }

    pub const fn user_command(number: usize) -> Option<Self> {
        match UserCommandIndex::new(number) {
            Some(index) => Some(Self::UserCommand(index)),
            None => None,
        }
    }

    pub fn user_command_index(&self) -> Option<usize> {
        match self {
            Action::UserCommand(index) => Some(index.get()),
            _ => None,
        }
    }

    pub const fn select_tab(number: u8) -> Option<Self> {
        match ActionIndex::new(number) {
            Some(index) => Some(Self::SelectTab(index)),
            None => None,
        }
    }

    pub fn screen_index(&self) -> Option<usize> {
        match self {
            Action::SelectScreen(number) => Some(number.get() as usize),
            _ => None,
        }
    }

    pub fn tab_index(&self) -> Option<usize> {
        match self {
            Action::SelectTab(number) => Some(number.get() as usize),
            _ => None,
        }
    }
}

/// A key chord: code plus required modifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Chord {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

fn normalize_chord(code: KeyCode, mut mods: KeyModifiers) -> (KeyCode, KeyModifiers) {
    match code {
        KeyCode::Tab if mods.contains(KeyModifiers::SHIFT) => {
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::BackTab, mods)
        }
        KeyCode::Char(c) if mods.contains(KeyModifiers::SHIFT) => {
            let Some(shifted) = crate::keys::shifted_ascii_char(c) else {
                return (code, mods);
            };
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::Char(shifted), mods)
        }
        KeyCode::BackTab => {
            // Crossterm reports BackTab with an implied Shift modifier.
            mods.remove(KeyModifiers::SHIFT);
            (KeyCode::BackTab, mods)
        }
        _ => (code, mods),
    }
}

fn canonical_chord(chord: Chord) -> Chord {
    const TRACKED: KeyModifiers = KeyModifiers::CONTROL
        .union(KeyModifiers::ALT)
        .union(KeyModifiers::SHIFT)
        .union(KeyModifiers::SUPER)
        .union(KeyModifiers::HYPER)
        .union(KeyModifiers::META);
    let (code, mods) = normalize_chord(chord.code, chord.mods);
    Chord { code, mods: mods & TRACKED }
}

impl Chord {
    pub fn matches(&self, key: &KeyEvent) -> bool {
        canonical_chord(*self) == canonical_chord(Chord { code: key.code, mods: key.modifiers })
    }

    /// Human-readable form used beside context-menu actions. Keep this
    /// derived from the resolved chord so config overrides teach the keys
    /// that are actually active.
    pub fn display_label(&self) -> Option<String> {
        let mut modifiers = Vec::new();
        if self.mods.contains(KeyModifiers::CONTROL) {
            modifiers.push("Ctrl");
        }
        if self.mods.contains(KeyModifiers::ALT) {
            modifiers.push("Alt");
        }
        if self.mods.contains(KeyModifiers::SHIFT) {
            modifiers.push("Shift");
        }
        if self.mods.contains(KeyModifiers::SUPER) {
            modifiers.push("Super");
        }
        let key = match self.code {
            KeyCode::Char(' ') => "Space".to_string(),
            KeyCode::Char(character) => character.to_string(),
            KeyCode::Tab => "Tab".to_string(),
            KeyCode::BackTab => "BackTab".to_string(),
            KeyCode::Enter => "Enter".to_string(),
            KeyCode::Esc => "Esc".to_string(),
            KeyCode::Left => "Left".to_string(),
            KeyCode::Right => "Right".to_string(),
            KeyCode::Up => "Up".to_string(),
            KeyCode::Down => "Down".to_string(),
            KeyCode::PageUp => "PageUp".to_string(),
            KeyCode::PageDown => "PageDown".to_string(),
            KeyCode::Home => "Home".to_string(),
            KeyCode::End => "End".to_string(),
            _ => return None,
        };
        if modifiers.is_empty() {
            Some(key)
        } else {
            Some(format!("{}-{key}", modifiers.join("-")))
        }
    }
}

/// Resolved key bindings: the prefix chord plus one chord per action.
#[derive(Debug, Clone)]
pub struct Keys {
    pub prefix: Chord,
    /// Resolve empty-text Alt character events using the host terminal's
    /// macOS Option mode instead of guessing from each event.
    pub macos_option_as_alt: bool,
    bindings: Vec<(Chord, Action)>,
    action_by_chord: HashMap<Chord, Action>,
    modeless_action_by_chord: HashMap<Chord, Action>,
    pub(crate) provider_menu_overridden: bool,
}

impl Default for Keys {
    fn default() -> Self {
        let bind = |code, action| (Chord { code, mods: KeyModifiers::NONE }, action);
        let alt = |code, action| (Chord { code, mods: KeyModifiers::ALT }, action);
        let command = |code, action| (Chord { code, mods: KeyModifiers::SUPER }, action);
        let prefix = Chord { code: KeyCode::Char('b'), mods: KeyModifiers::CONTROL };
        let mut keys = Keys {
            prefix,
            macos_option_as_alt: true,
            bindings: vec![
                (prefix, Action::SendPrefix),
                bind(KeyCode::Char('t'), Action::NewTab),
                alt(KeyCode::Char('t'), Action::NewTab),
                bind(KeyCode::Char('B'), Action::NewBrowserTab),
                alt(KeyCode::Char('n'), Action::NewPaneSmart),
                bind(KeyCode::Char('N'), Action::NewPaneSmart),
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
                bind(KeyCode::Char('1'), Action::select_screen(1).unwrap()),
                bind(KeyCode::Char('2'), Action::select_screen(2).unwrap()),
                bind(KeyCode::Char('3'), Action::select_screen(3).unwrap()),
                bind(KeyCode::Char('4'), Action::select_screen(4).unwrap()),
                bind(KeyCode::Char('5'), Action::select_screen(5).unwrap()),
                bind(KeyCode::Char('6'), Action::select_screen(6).unwrap()),
                bind(KeyCode::Char('7'), Action::select_screen(7).unwrap()),
                bind(KeyCode::Char('8'), Action::select_screen(8).unwrap()),
                bind(KeyCode::Char('9'), Action::select_screen(9).unwrap()),
                bind(KeyCode::Char('0'), Action::select_screen(0).unwrap()),
                bind(KeyCode::Char('c'), Action::NewScreen),
                bind(KeyCode::Char('('), Action::PrevWorkspace),
                alt(KeyCode::Char('{'), Action::PrevWorkspace),
                bind(KeyCode::Char('w'), Action::NextWorkspace),
                bind(KeyCode::Char(')'), Action::NextWorkspace),
                alt(KeyCode::Char('}'), Action::NextWorkspace),
                bind(KeyCode::Char('W'), Action::NewWorkspace),
                bind(KeyCode::Char('D'), Action::CloseWorkspace),
                bind(KeyCode::Char('s'), Action::ToggleSidebar),
                bind(KeyCode::Char('m'), Action::ToggleSidebarCompact),
                bind(KeyCode::Char('e'), Action::ToggleSidebarView),
                bind(KeyCode::Char('S'), Action::FocusSidebar),
                bind(KeyCode::Char('g'), Action::NewPaneRight),
                bind(KeyCode::Char('U'), Action::UndoLayout),
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
                bind(KeyCode::Char('+'), Action::ResizeGrow),
                alt(KeyCode::Char('-'), Action::ResizeShrink),
                bind(KeyCode::Char('-'), Action::ResizeShrink),
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
                bind(KeyCode::Char('?'), Action::ShowShortcuts),
                bind(KeyCode::Char('d'), Action::Detach),
            ],
            action_by_chord: HashMap::new(),
            modeless_action_by_chord: HashMap::new(),
            provider_menu_overridden: false,
        };
        keys.rebuild_dispatch_maps();
        keys
    }
}

impl Keys {
    fn rebuild_dispatch_maps(&mut self) {
        self.action_by_chord.clear();
        self.modeless_action_by_chord.clear();
        for &(chord, action) in &self.bindings {
            let canonical = canonical_chord(chord);
            // Keep the first binding in canonical order. Config mutation
            // resolves intentional collisions before this cache is built.
            self.action_by_chord.entry(canonical).or_insert(action);
            if self.is_modeless_binding(&chord, action) {
                self.modeless_action_by_chord.entry(canonical).or_insert(action);
            }
        }
    }

    fn is_modeless_binding(&self, chord: &Chord, action: Action) -> bool {
        if action == Action::SendPrefix && *chord == self.prefix {
            return false;
        }
        chord.mods.intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
            || (action == Action::ClearHistory && chord.mods.contains(KeyModifiers::CONTROL))
    }

    fn shortcut_label_for_chord(&self, action: Action, chord: &Chord) -> Option<String> {
        let chord_label = chord.display_label()?;
        if self.is_modeless_binding(chord, action) {
            Some(chord_label)
        } else {
            Some(format!("{} {chord_label}", self.prefix.display_label()?))
        }
    }

    /// The action bound to a key event (after the prefix).
    pub fn action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.action_by_chord
            .get(&canonical_chord(Chord { code: key.code, mods: key.modifiers }))
            .copied()
    }

    /// The modeless action bound to a key event. Alt- and Super-modified
    /// chords are modeless, as are Control-modified clear-history chords;
    /// other chords remain prefix-only.
    pub fn modeless_action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.modeless_action_by_chord
            .get(&canonical_chord(Chord { code: key.code, mods: key.modifiers }))
            .copied()
    }

    /// The first configured shortcut for an action, including the prefix
    /// for prefix-only chords. Returns `None` when the action is unbound.
    pub fn shortcut_label(&self, action: Action) -> Option<String> {
        self.shortcut_labels(action).into_iter().next()
    }

    /// Every configured shortcut for an action. Prefix-only chords include
    /// the resolved prefix, while Alt chords are shown as modeless shortcuts.
    pub fn shortcut_labels(&self, action: Action) -> Vec<String> {
        self.bindings
            .iter()
            .filter(|(_, bound)| *bound == action)
            .filter_map(|(chord, _)| self.shortcut_label_for_chord(action, chord))
            .collect()
    }

    /// The first suffix key that invokes an action after the prefix. Used by
    /// the prefix help bar, which must not advertise modeless-only bindings.
    pub fn prefixed_key_label(&self, action: Action) -> Option<String> {
        self.bindings
            .iter()
            .find(|(chord, bound)| *bound == action && !self.is_modeless_binding(chord, action))
            .and_then(|(chord, _)| chord.display_label())
    }

    /// Bound actions in canonical catalog order, ready for shortcut help and
    /// future command surfaces.
    pub fn resolved_shortcuts(&self) -> Vec<(&'static ActionDefinition, Vec<String>)> {
        let mut shortcuts_by_action = HashMap::<Action, Vec<String>>::new();
        for (chord, action) in &self.bindings {
            if let Some(label) = self.shortcut_label_for_chord(*action, chord) {
                shortcuts_by_action.entry(*action).or_default().push(label);
            }
        }
        action_definitions()
            .iter()
            .copied()
            .filter_map(|definition| {
                shortcuts_by_action
                    .remove(&definition.action)
                    .filter(|shortcuts| !shortcuts.is_empty())
                    .map(|shortcuts| (definition, shortcuts))
            })
            .collect()
    }

    /// Bind one user-command chord, stealing the chord from any action or
    /// earlier command that held it. The prefix chord stays reserved.
    /// Returns whether the chord was bound.
    fn bind_user_command_chord(&mut self, id: &str, action: Action, chord: Chord) -> bool {
        if chord == self.prefix {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command binding {id:?} because it conflicts with the prefix"
            );
            return false;
        }
        self.bindings.retain(|(existing, _)| existing != &chord);
        self.bindings.push((chord, action));
        true
    }

    /// Apply config overrides: `"prefix"` rebinds the prefix; any action
    /// name rebinds that action (replacing ALL default chords for it).
    fn apply(&mut self, raw: &HashMap<String, Value>) {
        if let Some(value) = raw.get("macos_option_as_alt") {
            if let Some(value) = value.as_bool() {
                self.macos_option_as_alt = value;
            } else {
                let value = format!("{value:?}");
                crate::client_log::stderr_log!(
                    "config",
                    "{}",
                    catalog().config.invalid_macos_option_as_alt(&value)
                );
            }
        }
        if raw.get("alt_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::ALT));
        }
        if raw.get("super_shortcuts").and_then(Value::as_bool) == Some(false) {
            self.bindings.retain(|(chord, _)| !chord.mods.contains(KeyModifiers::SUPER));
        }
        if let Some(value) = raw.get("prefix") {
            if let Some(value) = value.as_str()
                && let Some(chord) = parse_chord(value)
            {
                let previous_prefix = self.prefix;
                self.prefix = chord;
                if !raw.contains_key(Action::SendPrefix.definition().config_key)
                    && let Some((send_prefix, _)) =
                        self.bindings.iter_mut().find(|(binding, action)| {
                            *action == Action::SendPrefix && *binding == previous_prefix
                        })
                {
                    *send_prefix = chord;
                }
            } else if value.as_str().is_some() {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unparseable key binding prefix = {value:?}"
                );
            } else {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring non-string prefix binding {value:?}"
                );
            }
        }
        for (name, value) in raw {
            if name == "macos_option_as_alt"
                || name == "alt_shortcuts"
                || name == "super_shortcuts"
                || name == "prefix"
            {
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
            match action_definitions().iter().find(|definition| {
                definition.config_key == normalized.as_str()
                    || (definition.action == Action::RenameTab && name == "rename-pane")
                    || (definition.action == Action::NewBrowserTab && name == "new_browser_tab")
            }) {
                Some(definition) => {
                    self.bindings.retain(|(_, action)| *action != definition.action);
                    let mut provider_menu_override_valid = definition.action
                        == Action::ProviderMenu
                        && matches!(value, Value::Array(values) if values.is_empty());
                    for raw_chord in key_values(value) {
                        if raw_chord.eq_ignore_ascii_case("none") {
                            if definition.action == Action::ProviderMenu {
                                provider_menu_override_valid = true;
                            }
                            continue;
                        }
                        let Some(chord) = parse_chord(raw_chord) else {
                            crate::client_log::stderr_log!(
                                "config",
                                "{BIN}: ignoring unparseable key binding {name} = {raw_chord:?}"
                            );
                            continue;
                        };
                        if chord == self.prefix && definition.action != Action::SendPrefix {
                            crate::client_log::stderr_log!(
                                "config",
                                "{BIN}: ignoring key binding {name} = {raw_chord:?} because it conflicts with the prefix"
                            );
                            continue;
                        }
                        if definition.action == Action::ProviderMenu {
                            provider_menu_override_valid = true;
                        }
                        self.bindings.retain(|(existing, _)| existing != &chord);
                        self.bindings.push((chord, definition.action));
                    }
                    if definition.action == Action::ProviderMenu {
                        self.provider_menu_overridden = provider_menu_override_valid;
                    }
                }
                None => crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unknown key action {name:?}"
                ),
            }
        }
        let prefix = self.prefix;
        self.bindings.retain(|(chord, action)| *action == Action::SendPrefix || *chord != prefix);
        self.rebuild_dispatch_maps();
    }

    #[cfg(test)]
    pub(crate) fn apply_for_test(&mut self, raw: &HashMap<String, Value>) {
        self.apply(raw);
    }
}

fn key_values(value: &Value) -> Vec<&str> {
    match value {
        Value::String(s) => vec![s.as_str()],
        Value::Array(values) => values.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    }
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

    let code = code?;
    // Store a shifted ASCII result so `D` and `shift+d` stay equivalent.
    // Shift stays explicit when the character itself cannot represent it.
    let (code, mods) = normalize_chord(code, mods);
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
    scrollback_limit_bytes: Option<usize>,
    pub chrome: ChromeMode,
    pub tabs: Tabs,
    pub sidebar: Sidebar,
    pub agents: Agents,
    pub machine_sidebar: MachineSidebar,
    pub machine_provider: MachineProviderConfig,
    pub machines: Vec<MachineConfig>,
    pub browser: Browser,
    pub scrollbar: Scrollbar,
    pub pane: PaneOptions,
    pub status_bar: StatusBarOptions,
    pub viewport: Viewport,
    pub server: Server,
    pub keys: Keys,
    pub commands: Vec<UserCommandConfig>,
}

/// Configuration resolved once for the process startup path.
///
/// The snapshot is consumed by the selected startup mode. Interactive reloads
/// intentionally call [`load`] again after startup and replace the app state.
#[derive(Debug)]
pub(crate) struct StartupConfigSnapshot(Config);

impl StartupConfigSnapshot {
    pub(crate) fn load() -> Self {
        Self::from_loader(load)
    }

    fn from_loader(loader: impl FnOnce() -> Config) -> Self {
        Self(loader())
    }

    pub(crate) fn into_config(self) -> Config {
        self.0
    }
}

impl Deref for StartupConfigSnapshot {
    type Target = Config;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

/// The maximum configurable pane padding, in cells per side.
pub const MAX_PANE_PADDING: u16 = 4;

/// Pane presentation options.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PaneOptions {
    /// Blank cells between the pane border and the terminal content,
    /// applied on every side, clamped to `MAX_PANE_PADDING`.
    pub padding: u16,
}

/// Bottom screens-bar options. A hidden bar gives its row back to the
/// panes; transient status messages still overlay the last row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusBarOptions {
    pub visible: bool,
    /// Renders the clickable screens strip.
    pub show_screens: bool,
    /// Renders the right-aligned session label when no message is shown.
    pub show_session: bool,
    /// Segments before the screens strip.
    pub left: Vec<StatusSegment>,
    /// Segments right-aligned before the session label.
    pub right: Vec<StatusSegment>,
    /// Powerline-style separator drawn between left segments and after the
    /// last one; its foreground takes the previous segment's background and
    /// its background the next segment's, tmux `status-left` style.
    pub left_separator: Option<String>,
    /// Mirror of `left_separator` for the right-aligned segments.
    pub right_separator: Option<String>,
    /// Cap style for the active screen chip in the screens strip.
    pub screens_style: ChipStyle,
    /// The screens strip's `+` button.
    pub screens_plus: PlusButton,
}

impl Default for StatusBarOptions {
    fn default() -> Self {
        Self {
            visible: true,
            show_screens: true,
            show_session: true,
            left: Vec::new(),
            right: Vec::new(),
            left_separator: None,
            right_separator: None,
            screens_style: ChipStyle::Block,
            screens_plus: PlusButton::default(),
        }
    }
}

impl StatusBarOptions {
    /// Command segments in draw order: left side first, then right.
    pub fn command_segments(&self) -> Vec<(usize, Vec<String>, Duration)> {
        self.left
            .iter()
            .chain(self.right.iter())
            .enumerate()
            .filter_map(|(index, segment)| match &segment.content {
                StatusSegmentContent::Command { argv, interval } => {
                    Some((index, argv.clone(), *interval))
                }
                StatusSegmentContent::Text(_) => None,
            })
            .collect()
    }
}

/// The maximum number of configured segments per status bar side.
pub const MAX_STATUS_SEGMENTS: usize = 8;

/// The maximum width of one literal status segment, in terminal cells.
pub const MAX_STATUS_SEGMENT_TEXT: usize = 256;

/// One status bar segment: literal text with `{variable}` interpolation, or
/// a command whose last stdout line becomes the segment text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusSegment {
    pub content: StatusSegmentContent,
    pub fg: Option<Color>,
    pub bg: Option<Color>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatusSegmentContent {
    Text(String),
    Command { argv: Vec<String>, interval: Duration },
}

fn resolve_status_segments(raw: Vec<RawStatusSegment>, side: &str) -> Vec<StatusSegment> {
    let mut segments = Vec::new();
    for segment in raw {
        if segments.len() >= MAX_STATUS_SEGMENTS {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring status_bar.{side} segments beyond the {MAX_STATUS_SEGMENTS}-segment limit"
            );
            break;
        }
        let content = match (segment.text, segment.run) {
            (Some(_), Some(_)) | (None, None) => {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring status_bar.{side} segment: exactly one of text or run is required"
                );
                continue;
            }
            (Some(text), None) => {
                // Bound per-draw expansion work on the render path.
                let mut bounded = String::new();
                let mut width: usize = 0;
                let mut scalar_count: usize = 0;
                for grapheme in text.graphemes(true) {
                    let grapheme_width = usize::from(grapheme.cell_width());
                    let grapheme_scalars = grapheme.chars().count();
                    if width.saturating_add(grapheme_width) > MAX_STATUS_SEGMENT_TEXT
                        || scalar_count.saturating_add(grapheme_scalars) > MAX_STATUS_SEGMENT_TEXT
                    {
                        break;
                    }
                    bounded.push_str(grapheme);
                    width += grapheme_width;
                    scalar_count += grapheme_scalars;
                }
                StatusSegmentContent::Text(bounded)
            }
            (None, Some(run)) => {
                if run.first().is_none_or(|program| program.is_empty()) {
                    crate::client_log::stderr_log!(
                        "config",
                        "{BIN}: ignoring status_bar.{side} segment without a run program"
                    );
                    continue;
                }
                let interval = segment.interval.unwrap_or(5).clamp(1, 3600);
                StatusSegmentContent::Command { argv: run, interval: Duration::from_secs(interval) }
            }
        };
        segments.push(StatusSegment {
            content,
            fg: segment.fg.as_ref().and_then(ColorValue::to_color),
            bg: segment.bg.as_ref().and_then(ColorValue::to_color),
        });
    }
    segments
}

/// One resolved user command from the top-level `commands` section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserCommandConfig {
    /// Stable config identity, unique across the list.
    pub id: String,
    /// Display name for shortcut help; defaults to the id.
    pub name: String,
    /// Argv executed directly, without a shell.
    pub run: Vec<String>,
    /// Working directory; `None` follows the target pane's current directory.
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Server {
    pub ws: Option<String>,
    pub ws_token: Option<String>,
    /// Plain interactive launches connect through a detached headless
    /// session owner so the session survives every client detaching.
    /// `false` restores hosting the session inside the first TUI process.
    pub detached_owner: bool,
    /// `true`, `false`, or `{"enabled", "allow_ports", "deny_ports"}` for
    /// browser loopback forwarding (`loopback-forward-v1`). Absent = on.
    pub loopback_forward: Option<Value>,
}

impl Default for Server {
    fn default() -> Self {
        Self { ws: None, ws_token: None, detached_owner: true, loopback_forward: None }
    }
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
    /// Effective Ghostty scrollback storage limit in bytes. Ghostty's VT
    /// surface API uses bytes, so this value must never be interpreted as a
    /// line count by callers.
    pub fn scrollback_limit_bytes(&self) -> usize {
        self.scrollback_limit_bytes
            .unwrap_or(DEFAULT_SCROLLBACK_LIMIT_BYTES)
            .min(MAX_SCROLLBACK_LIMIT_BYTES)
    }

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentPluginConfig {
    pub id: String,
    pub command: Vec<String>,
    pub cwd: Option<String>,
    pub revision: Option<String>,
}

/// Load the config: defaults, overlaid with the user's Ghostty selection
/// colors, overlaid with `cmux-tui.json` or legacy `mux.json`.
pub fn load() -> Config {
    let mut config = Config::default();

    let application_defaults = ghostty_application_defaults();
    let defaults = application_defaults.colors;
    config.terminal_defaults = defaults;
    config.scrollback_limit_bytes = application_defaults.scrollback_limit_bytes;
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
    if let Some(style) = raw.tabs.style {
        config.tabs.style = style;
    }
    if let Some(w) = raw.sidebar.width {
        config.sidebar.width = w.clamp(10, 60);
    }
    if let Some(w) = raw.sidebar.compact_width {
        config.sidebar.compact_width = w.clamp(10, 60);
    }
    config.sidebar.compact_width = config.sidebar.compact_width.min(config.sidebar.width);
    if let Some(view) = raw.sidebar.view {
        match parse_sidebar_view(&view) {
            Ok(view) => config.sidebar.view = view,
            Err(warning) => crate::client_log::stderr_log!("config", "{warning}"),
        }
    }
    if let Some(w) = raw.sidebar.max_width {
        config.sidebar.max_width = w;
    }
    if let Some(height) = raw.sidebar.row_height {
        config.sidebar.row_height = height.clamp(1, 2);
    }
    if let Some(gap) = raw.sidebar.row_gap {
        config.sidebar.row_gap = gap.min(2);
    }
    if let Some(glyph) = raw.sidebar.rail_glyph {
        if glyph.eq_ignore_ascii_case("none") {
            config.sidebar.rail_glyph = String::new();
        } else if glyph.chars().count() == 1
            && glyph.chars().all(|character| !character.is_control())
            && glyph.cell_width() == 1
        {
            // The renderer reserves exactly one cell for the glyph.
            config.sidebar.rail_glyph = glyph;
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar.rail_glyph {glyph:?}: one single-width character or \"none\""
            );
        }
    }
    if let Some(template) = raw.sidebar.workspace_label {
        let template = template.trim().to_string();
        if !template.is_empty() {
            config.sidebar.workspace_label = template;
        }
    }
    if let Some(plugin) = raw.sidebar.plugin {
        // Preserve every argument after argv[0]. Empty arguments are valid
        // process arguments, and filtering them would silently change the
        // command a user configured. Only the executable slot is required.
        let command = plugin.command.unwrap_or_default();
        if command.first().is_none_or(|arg| arg.trim().is_empty()) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring sidebar.plugin with empty command"
            );
        } else {
            config.sidebar.plugin = Some(SidebarPluginOptions {
                command,
                cwd: plugin.cwd.filter(|cwd| !cwd.trim().is_empty()),
            });
        }
    }
    // An explicit agents.plugin wins; otherwise the bundled screen detector
    // beside this daemon runs unless agents.screen_detection is false.
    config.agents.plugin = crate::agent_plugin_config::agent_plugin_for_this_daemon(raw.agents);
    if let Some(enabled) = raw.machine_sidebar.enabled {
        config.machine_sidebar.enabled = enabled;
    }
    if let Some(width) = raw.machine_sidebar.width {
        config.machine_sidebar.width = width.clamp(10, 60);
    }
    if let Some(max_width) = raw.machine_sidebar.max_width {
        config.machine_sidebar.max_width = max_width;
    }
    if let Some(sources) = raw.machine_sidebar.create_sources {
        let mut source_ids = HashSet::new();
        for source in sources {
            let id = source.id.trim().to_string();
            let name = source.name.trim().to_string();
            if id.is_empty() || name.is_empty() || !source_ids.insert(id.clone()) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring machine creation source with an empty or duplicate id/name"
                );
                continue;
            }
            let subtitle =
                source.subtitle.map(|subtitle| subtitle.trim().to_string()).unwrap_or_default();
            config.machine_sidebar.create_sources.push(MachineCreationSourceConfig {
                id,
                name,
                subtitle,
            });
        }
    }
    if let Some(columns) = raw.sidebar.columns.as_ref() {
        let mut seen = HashSet::new();
        let mut resolved = Vec::new();
        for column in columns {
            let kind = match parse_sidebar_column_kind(column.kind.trim()) {
                Ok(kind) => kind,
                Err(warning) => {
                    crate::client_log::stderr_log!("config", "{warning}");
                    continue;
                }
            };
            if !seen.insert(kind) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring duplicate sidebar column {:?}",
                    column.kind
                );
                continue;
            }
            let (default_width, default_max_width) = match kind {
                SidebarColumnKind::Machines => {
                    (config.machine_sidebar.width, config.machine_sidebar.max_width)
                }
                SidebarColumnKind::Workspaces => (config.sidebar.width, config.sidebar.max_width),
                SidebarColumnKind::Tabs => (22, 0),
            };
            resolved.push(SidebarColumn {
                kind,
                width: column.width.unwrap_or(default_width).clamp(10, 60),
                max_width: column.max_width.unwrap_or(default_max_width),
            });
        }
        if resolved.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.columns had no usable entries; keeping defaults"
            );
        } else {
            config.sidebar.columns = resolved;
            config.sidebar.columns_explicit = true;
        }
    } else {
        config.sidebar.columns = vec![
            SidebarColumn {
                kind: SidebarColumnKind::Machines,
                width: config.machine_sidebar.width,
                max_width: config.machine_sidebar.max_width,
            },
            SidebarColumn {
                kind: SidebarColumnKind::Workspaces,
                width: config.sidebar.width,
                max_width: config.sidebar.max_width,
            },
        ];
    }
    config.sidebar.views = config
        .sidebar
        .columns
        .iter()
        .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
        .collect();
    config.sidebar.views_explicit = config.sidebar.columns_explicit;
    // User commands resolve before sidebar views so pinned buttons can
    // reference them as `command:<id>`; their chords bind after `keys`.
    let (user_commands, user_command_keys) = resolve_user_command_specs(raw.commands);
    let command_ids: Vec<String> = user_commands.iter().map(|command| command.id.clone()).collect();
    if let Some(plus) = raw.tabs.plus {
        config.tabs.plus = resolve_plus_button(plus, &command_ids, "tabs");
    }
    if let Some(plus) = raw.status_bar.screens_plus {
        config.status_bar.screens_plus = resolve_plus_button(plus, &command_ids, "status_bar");
    }
    if let Some(views) = raw.sidebar.views.as_ref() {
        if raw.sidebar.columns.is_some() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.views overrides sidebar.columns"
            );
        }
        let resolved = resolve_sidebar_view_specs(
            views,
            config.machine_sidebar.width,
            config.machine_sidebar.max_width,
            config.sidebar.width,
            config.sidebar.max_width,
            "sidebar",
            &command_ids,
        );
        if resolved.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.views had no usable entries; keeping defaults"
            );
        } else {
            config.sidebar.columns = resolved
                .iter()
                .filter_map(|view| {
                    view.legacy_kind().map(|kind| SidebarColumn {
                        kind,
                        width: view.width,
                        max_width: view.max_width,
                    })
                })
                .collect();
            config.sidebar.views = resolved;
            config.sidebar.columns_explicit = false;
            config.sidebar.views_explicit = true;
        }
    }
    config.sidebar.profiles[0].views.clone_from(&config.sidebar.views);
    if let Some(raw_profiles) = raw.sidebar.profiles.as_ref() {
        if raw.sidebar.views.is_some() || raw.sidebar.columns.is_some() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.profiles overrides sidebar.views and sidebar.columns"
            );
        }
        let mut ids = HashSet::new();
        let mut profiles = Vec::new();
        for raw_profile in raw_profiles {
            let id = raw_profile.id.trim();
            if id.is_empty() || !ids.insert(id.to_string()) {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring sidebar profile with an empty or duplicate id"
                );
                continue;
            }
            let owner = format!("sidebar profile {id:?}");
            let views = resolve_sidebar_view_specs(
                &raw_profile.views,
                config.machine_sidebar.width,
                config.machine_sidebar.max_width,
                config.sidebar.width,
                config.sidebar.max_width,
                &owner,
                &command_ids,
            );
            if views.is_empty() {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring sidebar profile {id:?} with no usable views"
                );
                continue;
            }
            let name = raw_profile
                .name
                .as_deref()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .unwrap_or(id)
                .to_string();
            profiles.push(SidebarProfileSpec { id: id.to_string(), name, views });
        }
        if profiles.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: sidebar.profiles had no usable entries; keeping defaults"
            );
        } else {
            let requested =
                raw.sidebar.profile.as_deref().map(str::trim).filter(|id| !id.is_empty());
            let selected = requested
                .and_then(|id| profiles.iter().position(|profile| profile.id == id))
                .unwrap_or_else(|| {
                    if let Some(requested) = requested {
                        crate::client_log::stderr_log!("config",
                            "{BIN}: sidebar.profile {requested:?} was not found; using the first profile"
                        );
                    }
                    0
                });
            config.sidebar.active_profile = profiles[selected].id.clone();
            config.sidebar.views = profiles[selected].views.clone();
            config.sidebar.columns = config
                .sidebar
                .views
                .iter()
                .filter_map(|view| {
                    view.legacy_kind().map(|kind| SidebarColumn {
                        kind,
                        width: view.width,
                        max_width: view.max_width,
                    })
                })
                .collect();
            config.sidebar.columns_explicit = false;
            config.sidebar.views_explicit = true;
            config.sidebar.profiles = profiles;
        }
    } else if raw.sidebar.profile.is_some() {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring sidebar.profile without sidebar.profiles"
        );
    }
    match raw.machine_provider.command {
        Some(command) if command.first().is_some_and(|program| !program.trim().is_empty()) => {
            config.machine_provider.command = Some(command);
        }
        Some(_) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring machine_provider.command without a program"
            );
        }
        None => {}
    }
    let cloud = raw.machine_provider.cloud;
    if let Some(enabled) = cloud.enabled {
        config.machine_provider.cloud.enabled = enabled;
    }
    if let Some(host) = cloud.host {
        let host = host.trim();
        if host.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring empty machine_provider.cloud.host"
            );
        } else {
            config.machine_provider.cloud.host = host.to_string();
        }
    }
    config.machine_provider.cloud.user =
        cloud.user.map(|user| user.trim().to_string()).filter(|user| !user.is_empty());
    config.machine_provider.cloud.port = match cloud.port {
        Some(0) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring zero machine_provider.cloud.port"
            );
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
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring machine with an empty or duplicate id/name"
            );
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
                        .unwrap_or_else(|| "~/.local/bin/cmux-tui".to_string()),
                }
            }
            _ => {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring machine {id:?} with an empty transport target"
                );
                continue;
            }
        };
        config.machines.push(MachineConfig { id, name, subtitle: machine.subtitle, target });
    }
    config.browser.cdp_url = raw.browser.cdp_url.filter(|s| !s.trim().is_empty());
    if let Some(megapixels) = raw.browser.max_capture_megapixels {
        if megapixels.is_finite()
            && megapixels > 0.0
            && megapixels <= TRANSPORT_SAFE_CAPTURE_MEGAPIXELS
        {
            config.browser.max_capture_megapixels = megapixels;
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring browser.max_capture_megapixels={megapixels:?}; expected 0 < value <= {TRANSPORT_SAFE_CAPTURE_MEGAPIXELS}"
            );
        }
    }
    if let Some(scale) = raw.browser.capture_scale {
        if scale.is_finite() && scale > 0.0 && scale <= 1.0 {
            config.browser.capture_scale = Some(scale);
        } else {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring browser.capture_scale={scale:?}; expected 0 < scale <= 1"
            );
        }
    }
    if let Some(position) = raw.scrollbar.position {
        config.scrollbar.position = position;
    }
    if let Some(style) = raw.theme.border_style {
        config.theme.border_style = style;
    }
    if let Some(c) = raw.theme.status_bg.as_ref().and_then(ColorValue::to_color) {
        config.theme.status_bg = Some(c);
    }
    if let Some(c) = raw.theme.status_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.status_fg = Some(c);
    }
    if let Some(c) = raw.theme.sidebar_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_fg = Some(c);
    }
    if let Some(c) = raw.theme.sidebar_selected_fg.as_ref().and_then(ColorValue::to_color) {
        config.theme.sidebar_selected_fg = Some(c);
    }
    if let Some(dim) = raw.theme.dim_inactive {
        config.theme.dim_inactive = dim;
    }
    if let Some(padding) = raw.pane.padding {
        config.pane.padding = padding.min(MAX_PANE_PADDING);
    }
    if let Some(visible) = raw.status_bar.visible {
        config.status_bar.visible = visible;
    }
    if let Some(show_screens) = raw.status_bar.show_screens {
        config.status_bar.show_screens = show_screens;
    }
    if let Some(show_session) = raw.status_bar.show_session {
        config.status_bar.show_session = show_session;
    }
    if let Some(left) = raw.status_bar.left {
        config.status_bar.left = resolve_status_segments(left, "left");
    }
    if let Some(right) = raw.status_bar.right {
        config.status_bar.right = resolve_status_segments(right, "right");
    }
    config.status_bar.left_separator =
        raw.status_bar.left_separator.filter(|separator| !separator.is_empty());
    config.status_bar.right_separator =
        raw.status_bar.right_separator.filter(|separator| !separator.is_empty());
    if let Some(style) = raw.status_bar.screens_style {
        config.status_bar.screens_style = style;
    }
    if let Some(animation) = raw.viewport.animation {
        config.viewport.animation = animation;
    }
    config.server.ws = raw.server.ws.filter(|value| !value.trim().is_empty());
    config.server.ws_token = raw.server.ws_token.filter(|value| !value.trim().is_empty());
    if let Some(detached_owner) = raw.server.detached_owner {
        config.server.detached_owner = detached_owner;
    }
    config.server.loopback_forward = raw.server.loopback_forward;
    config.keys.apply(&raw.keys);
    bind_user_command_chords(&mut config.keys, &user_commands, &user_command_keys);
    config.commands = user_commands;
    config
}

/// Validate the raw `commands` section into resolved specs plus each
/// command's raw chord values. Chords bind later, after the `keys` section
/// applied its overrides, so command chords keep last-write-wins order.
fn resolve_user_command_specs(
    raw: Vec<RawUserCommand>,
) -> (Vec<UserCommandConfig>, Vec<Option<Value>>) {
    let mut commands = Vec::new();
    let mut key_values = Vec::new();
    let mut ids = HashSet::new();
    for command in raw {
        let id = command.id.as_deref().unwrap_or("").trim().to_string();
        if id.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command with a missing or empty id"
            );
            continue;
        }
        if ids.contains(&id) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command with duplicate id {id:?}"
            );
            continue;
        }
        // Empty positional arguments stay: argv executes directly, and an
        // empty argument is valid there. Only the program itself must exist.
        let run = command.run.unwrap_or_default();
        if run.first().is_none_or(|program| program.is_empty()) {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command {id:?} without a run program"
            );
            continue;
        }
        if Action::user_command(commands.len()).is_none() {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring command {id:?} beyond the {MAX_USER_COMMANDS}-command limit"
            );
            continue;
        }
        // The id is reserved only after validation, so an ignored invalid
        // entry never blocks a later valid entry with the same id.
        ids.insert(id.clone());
        let name = command
            .name
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| id.clone());
        let cwd = command.cwd.map(|cwd| cwd.trim().to_string()).filter(|cwd| !cwd.is_empty());
        commands.push(UserCommandConfig { id, name, run, cwd });
        key_values.push(command.keys);
    }
    (commands, key_values)
}

/// Bind every command's chords after `keys` overrides applied.
fn bind_user_command_chords(
    keys: &mut Keys,
    commands: &[UserCommandConfig],
    chord_values: &[Option<Value>],
) {
    for (index, (command, value)) in commands.iter().zip(chord_values).enumerate() {
        let Some(action) = Action::user_command(index) else { break };
        let Some(value) = value.as_ref() else { continue };
        let id = &command.id;
        let mut bound = 0usize;
        for raw_chord in key_values(value) {
            if raw_chord.eq_ignore_ascii_case("none") {
                continue;
            }
            if bound >= MAX_USER_COMMAND_CHORDS {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring command {id:?} chords beyond the {MAX_USER_COMMAND_CHORDS}-chord limit"
                );
                break;
            }
            let Some(chord) = parse_chord(raw_chord) else {
                crate::client_log::stderr_log!(
                    "config",
                    "{BIN}: ignoring unparseable command binding {id} = {raw_chord:?}"
                );
                continue;
            };
            // Only a successful bind consumes the limit; rejected chords
            // leave room for the valid ones after them.
            if keys.bind_user_command_chord(id, action, chord) {
                bound += 1;
            }
        }
    }
    keys.rebuild_dispatch_maps();
}

fn normalize_ssh_machine_port(id: &str, port: Option<u16>) -> Option<u16> {
    match port {
        Some(0) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: ignoring zero SSH machine port for {id:?}"
            );
            None
        }
        port => port,
    }
}

pub fn apply_browser_to_surface_options(config: &Config, options: &mut SurfaceOptions) {
    options.cdp_url = config.browser.cdp_url.clone();
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
    // A config that exists but cannot be read leaves the user's agents choice
    // unknown, so the bundled screen detector stays off (agent_plugin_config).
    let unreadable = || RawConfig {
        agents: crate::agent_plugin_config::RawAgents::invalid(),
        ..RawConfig::default()
    };
    let Some(path) = platform::config_path() else { return RawConfig::default() };
    let text = match read_config_text(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return RawConfig::default(),
        Err(_) => return unreadable(),
    };
    let value: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(e) => {
            crate::client_log::stderr_log!(
                "config",
                "{} ({})",
                config_diagnostic(&e),
                path.display(),
            );
            return unreadable();
        }
    };
    let Some(object) = value.as_object() else {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring invalid config {}: root must be an object",
            path.display()
        );
        return unreadable();
    };
    const KNOWN: &[&str] = &[
        "theme",
        "tabs",
        "sidebar",
        "agents",
        "machine_sidebar",
        "machine_provider",
        "machines",
        "commands",
        "browser",
        "scrollbar",
        "pane",
        "status_bar",
        "viewport",
        "server",
        "keys",
    ];
    if let Some(unknown) = object.keys().find(|key| !KNOWN.contains(&key.as_str())) {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring invalid config {}: unknown top-level field `{unknown}`",
            path.display()
        );
        return unreadable();
    }
    let mut raw = RawConfig::default();
    // An invalid section keeps its defaults, or `$invalid` when given.
    macro_rules! section {
        ($field:ident, $name:literal $(, $invalid:expr)?) => {
            if let Some(value) = object.get($name) {
                match serde_json::from_value(value.clone()) {
                    Ok(parsed) => raw.$field = parsed,
                    Err(error) => {
                        crate::client_log::stderr_log!(
                            "config",
                            "{BIN}: ignoring invalid `{}` section in {}: {}",
                            $name,
                            path.display(),
                            error
                        );
                        $(raw.$field = $invalid;)?
                    }
                }
            }
        };
    }
    section!(theme, "theme");
    section!(tabs, "tabs");
    section!(sidebar, "sidebar");
    // An unreadable agents section must not turn the bundled detector on.
    section!(agents, "agents", crate::agent_plugin_config::RawAgents::invalid());
    section!(machine_sidebar, "machine_sidebar");
    section!(machine_provider, "machine_provider");
    section!(machines, "machines");
    section!(commands, "commands");
    section!(browser, "browser");
    section!(scrollbar, "scrollbar");
    section!(pane, "pane");
    section!(status_bar, "status_bar");
    section!(viewport, "viewport");
    section!(server, "server");
    section!(keys, "keys");
    raw
}

fn config_diagnostic(error: &serde_json::Error) -> String {
    let text = error.to_string();
    if text.contains("unknown field") {
        return catalog().config.unknown_field("(see config file)");
    }
    if text.contains("invalid type") && text.contains("map") {
        return catalog().config.invalid_root();
    }
    catalog().config.invalid_section("(see config file)")
}

pub fn config_path() -> anyhow::Result<PathBuf> {
    platform::config_path().ok_or_else(|| anyhow::anyhow!("could not resolve mux config path"))
}

/// Read a UTF-8 file with an explicit byte bound. The extra byte distinguishes
/// an exact-size file from one that exceeds the limit without allocating an
/// unbounded buffer.
pub(crate) fn read_bounded_utf8_file(path: &Path, max_bytes: usize) -> io::Result<String> {
    let file = std::fs::File::open(path)?;
    let mut text = String::new();
    file.take(u64::try_from(max_bytes).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_string(&mut text)?;
    if text.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds {max_bytes}-byte limit"),
        ));
    }
    Ok(text)
}

pub(crate) fn read_config_text(path: &Path) -> io::Result<String> {
    read_bounded_utf8_file(path, CONFIG_FILE_MAX_BYTES)
}

/// The result of replacing the config file. A committed replacement is a
/// successful operation even when the parent directory could not be synced.
#[must_use = "inspect config durability after a committed write"]
#[derive(Debug)]
pub(crate) enum ConfigWriteOutcome {
    /// The replacement and all relevant directory entries were synced.
    Committed,
    /// The replacement committed, but this platform does not support syncing
    /// directory entries. The staged file itself was synced before rename.
    CommittedWithoutDirectorySync,
    /// The replacement committed, but a supported directory sync failed.
    CommittedButUnsynced { error: anyhow::Error },
}

impl ConfigWriteOutcome {
    /// Takes the parent-sync error, if the replacement committed without a
    /// durability confirmation.
    pub(crate) fn into_unsynced_error(self) -> Option<anyhow::Error> {
        match self {
            Self::Committed | Self::CommittedWithoutDirectorySync => None,
            Self::CommittedButUnsynced { error } => Some(error),
        }
    }
}

/// Writes the sidebar plugin selection to the configured path.
pub(crate) fn write_sidebar_plugin(
    plugin: Option<&SidebarPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let path = config_path()?;
    write_sidebar_plugin_at_path(&path, plugin)
}

/// Writes the sidebar plugin selection to an explicit path.
pub(crate) fn write_sidebar_plugin_at_path(
    path: &Path,
    plugin: Option<&SidebarPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
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

/// Writes the userland agent plugin selection to the configured path.
pub(crate) fn write_agent_plugin(
    plugin: Option<&AgentPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let path = config_path()?;
    write_agent_plugin_at_path(&path, plugin)
}

pub(crate) fn write_agent_plugin_at_path(
    path: &Path,
    plugin: Option<&AgentPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let mut root = read_config_value(path)?;
    let Some(root_object) = root.as_object_mut() else {
        anyhow::bail!("{} must contain a JSON object", path.display());
    };
    match plugin {
        Some(plugin) => {
            let agents = root_object.entry("agents").or_insert_with(|| json!({}));
            if !agents.is_object() {
                *agents = json!({});
            }
            let agents_object = agents.as_object_mut().expect("agents was just made an object");
            let mut plugin_value = json!({
                "id": &plugin.id,
                "command": &plugin.command,
            });
            if let Some(cwd) = &plugin.cwd {
                plugin_value["cwd"] = json!(cwd);
            }
            if let Some(revision) = &plugin.revision {
                plugin_value["revision"] = json!(revision);
            }
            agents_object.insert("plugin".to_string(), plugin_value);
        }
        None => {
            if let Some(agents) = root_object.get_mut("agents")
                && let Some(agents_object) = agents.as_object_mut()
            {
                agents_object.remove("plugin");
            }
        }
    }
    write_config_value_atomic(path, &root)
}

fn read_config_value(path: &Path) -> anyhow::Result<Value> {
    match read_config_text(path) {
        Ok(text) if text.trim().is_empty() => Ok(json!({})),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display())),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(anyhow::anyhow!("failed to read {}: {err}", path.display())),
    }
}

/// Serializes a config value to a private staging file before atomically
/// replacing the destination and durably syncing its parent directories. An
/// `Err` means that replacement did not commit. A
/// [`ConfigWriteOutcome::CommittedWithoutDirectorySync`] means the rename
/// committed on a platform without directory-sync support. A
/// [`ConfigWriteOutcome::CommittedButUnsynced`] value means a supported
/// directory sync failed.
fn write_config_value_atomic(path: &Path, value: &Value) -> anyhow::Result<ConfigWriteOutcome> {
    write_config_value_atomic_with_sync(path, value, &sync_config_parent_directory)
}

fn write_config_value_atomic_with_sync(
    path: &Path,
    value: &Value,
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let file_name = path.file_name().and_then(|name| name.to_str()).unwrap_or("cmux-tui.json");
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let process_id = std::process::id();
    let staging_path = move |parent: &Path, attempt: usize| {
        let suffix = if attempt == 0 {
            format!(".{file_name}.{process_id}.{stamp}.tmp")
        } else {
            format!(".{file_name}.{process_id}.{stamp}.{attempt}.tmp")
        };
        parent.join(suffix)
    };
    write_config_value_atomic_with_sync_and_staging(path, value, sync_parent, &staging_path)
}

const CONFIG_STAGING_ATTEMPTS: usize = 16;

fn write_config_value_atomic_with_sync_and_staging(
    path: &Path,
    value: &Value,
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
    staging_path: &dyn Fn(&Path, usize) -> PathBuf,
) -> anyhow::Result<ConfigWriteOutcome> {
    let parent = config_parent_directory(path);
    let created_directories = ensure_config_parent_directory(parent)?;
    let mut staged = None;
    for attempt in 0..CONFIG_STAGING_ATTEMPTS {
        let tmp_path = staging_path(parent, attempt);
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;

            // The config can contain the server authentication token. Create
            // the staging file private from the start, independent of umask,
            // and reject a pre-existing symlink if a concurrent writer races
            // with this process before open(2).
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        match options.open(&tmp_path) {
            Ok(file) => {
                staged = Some((tmp_path, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    let Some((tmp_path, mut file)) = staged else {
        anyhow::bail!("could not create a unique config staging file")
    };
    let result = (|| -> anyhow::Result<()> {
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp_path, path)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(error);
    }

    #[cfg(unix)]
    {
        Ok(match sync_config_parent_directories(parent, &created_directories, sync_parent) {
            Ok(ConfigParentSyncOutcome::Synced) => ConfigWriteOutcome::Committed,
            Ok(ConfigParentSyncOutcome::Unsupported) => {
                ConfigWriteOutcome::CommittedWithoutDirectorySync
            }
            Err(error) => ConfigWriteOutcome::CommittedButUnsynced { error },
        })
    }
    #[cfg(not(unix))]
    {
        let _ = (created_directories, sync_parent);
        Ok(ConfigWriteOutcome::CommittedWithoutDirectorySync)
    }
}

fn ensure_config_parent_directory(parent: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut created_directories = Vec::new();
    let mut current = PathBuf::new();
    for component in parent.components() {
        current.push(component.as_os_str());
        // Prefix, root, and navigation components establish path syntax;
        // only normal components identify directory entries to create.
        if !matches!(component, Component::Normal(_)) {
            continue;
        }
        match std::fs::create_dir(&current) {
            Ok(()) => created_directories.push(current.clone()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if !std::fs::metadata(&current)?.is_dir() {
                    anyhow::bail!(
                        "config parent component {} is not a directory",
                        current.display()
                    );
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(created_directories)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConfigParentSyncOutcome {
    Synced,
    Unsupported,
}

#[cfg(unix)]
fn sync_config_parent_directory(parent: &Path) -> anyhow::Result<ConfigParentSyncOutcome> {
    let result = std::fs::File::open(parent).and_then(|directory| directory.sync_all());
    #[cfg(target_os = "macos")]
    if let Err(error) = &result
        && matches!(error.raw_os_error(), Some(code) if code == libc::EINVAL || code == libc::ENOTSUP)
    {
        return Ok(ConfigParentSyncOutcome::Unsupported);
    }
    result.map(|()| ConfigParentSyncOutcome::Synced).map_err(Into::into)
}

#[cfg(not(unix))]
fn sync_config_parent_directory(_parent: &Path) -> anyhow::Result<ConfigParentSyncOutcome> {
    Ok(ConfigParentSyncOutcome::Unsupported)
}

#[cfg(unix)]
fn sync_config_parent_directories(
    parent: &Path,
    created_directories: &[PathBuf],
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
) -> anyhow::Result<ConfigParentSyncOutcome> {
    let mut unsupported = false;
    for directory in std::iter::once(parent)
        .chain(created_directories.iter().rev().map(|directory| config_parent_directory(directory)))
    {
        if matches!(sync_parent(directory)?, ConfigParentSyncOutcome::Unsupported) {
            unsupported = true;
        }
    }
    Ok(if unsupported {
        ConfigParentSyncOutcome::Unsupported
    } else {
        ConfigParentSyncOutcome::Synced
    })
}

fn config_parent_directory(path: &Path) -> &Path {
    path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."))
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

#[cfg(test)]
mod tests;
