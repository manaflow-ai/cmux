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

mod action;
mod action_catalog;
#[cfg(test)]
mod action_metadata;
mod file_io;
mod ghostty_config;
mod ghostty_helper;
mod ghostty_theme_mode;
mod keys;
mod load;
mod status_bar;

pub use action::Action;
use action::*;
pub use action_catalog::action_definitions;
use action_catalog::*;
pub use file_io::config_path;
#[cfg(test)]
use file_io::*;
pub(crate) use file_io::{
    read_bounded_utf8_file, read_config_text, write_agent_plugin, write_sidebar_plugin,
};
use ghostty_config::*;
use ghostty_helper::*;
pub(crate) use ghostty_helper::{is_ghostty_config_helper_invocation, run_ghostty_config_helper};
use ghostty_theme_mode::*;
use keys::*;
pub use keys::{Chord, Keys};
pub use load::load;
#[cfg(test)]
use load::*;
use status_bar::*;
pub use status_bar::{StatusSegment, StatusSegmentContent};

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
