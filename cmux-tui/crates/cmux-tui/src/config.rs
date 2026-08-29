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
use std::io::{Read, Write};
use std::ops::Deref;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::Child;
use std::process::Command;
use std::process::Stdio;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::BrowserMode;
use cmux_tui_core::SidebarPluginOptions;
use cmux_tui_core::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS;
use cmux_tui_core::platform;
use cmux_tui_core::{CursorShape, DefaultColors, Rgb};
use cmux_tui_core::{DEFAULT_SCROLLBACK_LIMIT_BYTES, SurfaceOptions};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Color;
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use unicode_width::UnicodeWidthStr;
use wait_timeout::ChildExt;

use crate::localization::catalog;

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
                    "cmux-tui: ignoring duplicate {owner} plus menu action {:?}",
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
            "cmux-tui: ignoring unknown sidebar.view {value:?}; expected \"files\" or \"workspaces\""
        )),
    }
}

fn parse_sidebar_column_kind(value: &str) -> Result<SidebarColumnKind, String> {
    match value {
        "machines" => Ok(SidebarColumnKind::Machines),
        "workspaces" => Ok(SidebarColumnKind::Workspaces),
        "tabs" => Ok(SidebarColumnKind::Tabs),
        _ => Err(format!(
            "cmux-tui: ignoring unknown sidebar column {value:?}; expected \"machines\", \"workspaces\", or \"tabs\""
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
            "cmux-tui: ignoring unknown sidebar resource {value:?}; expected \"machines\", \"workspaces\", \"panes\", \"tabs\", or \"agents\""
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
                format!("cmux-tui: ignoring sidebar action for unknown command {command_id:?}")
            });
    }
    action_definitions()
        .iter()
        .find(|definition| definition.config_key == value)
        .map(|definition| definition.action)
        .ok_or_else(|| format!("cmux-tui: ignoring unknown sidebar action {value:?}"))
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
                "cmux-tui: ignoring {owner} view with an empty or duplicate id"
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
                "cmux-tui: ignoring {owner} view {id:?}: {reason}"
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
                "cmux-tui: ignoring {owner} view {id:?}: a one-level view for that resource already exists"
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
                "cmux-tui: ignoring sidebar actions in {owner} machine view {id:?}; machine actions come from provider capabilities"
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
                                "cmux-tui: ignoring duplicate sidebar action {:?} in {owner} view {id:?}",
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

impl Chord {
    pub fn matches(&self, key: &KeyEvent) -> bool {
        const TRACKED: KeyModifiers = KeyModifiers::CONTROL
            .union(KeyModifiers::ALT)
            .union(KeyModifiers::SHIFT)
            .union(KeyModifiers::SUPER)
            .union(KeyModifiers::HYPER)
            .union(KeyModifiers::META);
        let (configured_code, configured_mods) = normalize_chord(self.code, self.mods);
        let (event_code, event_mods) = normalize_chord(key.code, key.modifiers);
        configured_code == event_code && configured_mods & TRACKED == event_mods & TRACKED
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
    pub(crate) provider_menu_overridden: bool,
}

impl Default for Keys {
    fn default() -> Self {
        let bind = |code, action| (Chord { code, mods: KeyModifiers::NONE }, action);
        let alt = |code, action| (Chord { code, mods: KeyModifiers::ALT }, action);
        let command = |code, action| (Chord { code, mods: KeyModifiers::SUPER }, action);
        let prefix = Chord { code: KeyCode::Char('b'), mods: KeyModifiers::CONTROL };
        Keys {
            prefix,
            macos_option_as_alt: true,
            bindings: vec![
                (prefix, Action::SendPrefix),
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
                bind(KeyCode::Char('?'), Action::ShowShortcuts),
                bind(KeyCode::Char('d'), Action::Detach),
            ],
            provider_menu_overridden: false,
        }
    }
}

impl Keys {
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
        self.bindings.iter().find(|(chord, _)| chord.matches(key)).map(|(_, a)| *a)
    }

    /// The modeless action bound to a key event. Alt- and Super-modified
    /// chords are modeless, as are Control-modified clear-history chords;
    /// other chords remain prefix-only.
    pub fn modeless_action_for(&self, key: &KeyEvent) -> Option<Action> {
        self.bindings
            .iter()
            .find(|(chord, action)| self.is_modeless_binding(chord, *action) && chord.matches(key))
            .map(|(_, a)| *a)
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
                "cmux-tui: ignoring command binding {id:?} because it conflicts with the prefix"
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
                    "cmux-tui: ignoring unparseable key binding prefix = {value:?}"
                );
            } else {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring non-string prefix binding {value:?}"
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
                                "cmux-tui: ignoring unparseable key binding {name} = {raw_chord:?}"
                            );
                            continue;
                        };
                        if chord == self.prefix && definition.action != Action::SendPrefix {
                            crate::client_log::stderr_log!(
                                "config",
                                "cmux-tui: ignoring key binding {name} = {raw_chord:?} because it conflicts with the prefix"
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
                    "cmux-tui: ignoring unknown key action {name:?}"
                ),
            }
        }
        let prefix = self.prefix;
        self.bindings.retain(|(chord, action)| *action == Action::SendPrefix || *chord != prefix);
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

/// The maximum length of one literal status segment, in characters.
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
                "cmux-tui: ignoring status_bar.{side} segments beyond the {MAX_STATUS_SEGMENTS}-segment limit"
            );
            break;
        }
        let content = match (segment.text, segment.run) {
            (Some(_), Some(_)) | (None, None) => {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring status_bar.{side} segment: exactly one of text or run is required"
                );
                continue;
            }
            (Some(text), None) => {
                // Bound per-draw expansion work on the render path.
                StatusSegmentContent::Text(text.chars().take(MAX_STATUS_SEGMENT_TEXT).collect())
            }
            (None, Some(run)) => {
                if run.first().is_none_or(|program| program.is_empty()) {
                    crate::client_log::stderr_log!(
                        "config",
                        "cmux-tui: ignoring status_bar.{side} segment without a run program"
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
}

impl Default for Server {
    fn default() -> Self {
        Self { ws: None, ws_token: None, detached_owner: true }
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
        self.scrollback_limit_bytes.unwrap_or(DEFAULT_SCROLLBACK_LIMIT_BYTES)
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
        } else if glyph.chars().count() == 1 && glyph.width() == 1 {
            // The renderer reserves exactly one cell for the glyph.
            config.sidebar.rail_glyph = glyph;
        } else {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring sidebar.rail_glyph {glyph:?}: one single-width character or \"none\""
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
        let command = plugin
            .command
            .unwrap_or_default()
            .into_iter()
            .filter(|arg| !arg.is_empty())
            .collect::<Vec<_>>();
        if command.is_empty() {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring sidebar.plugin with empty command"
            );
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
    if let Some(sources) = raw.machine_sidebar.create_sources {
        let mut source_ids = HashSet::new();
        for source in sources {
            let id = source.id.trim().to_string();
            let name = source.name.trim().to_string();
            if id.is_empty() || name.is_empty() || !source_ids.insert(id.clone()) {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring machine creation source with an empty or duplicate id/name"
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
                    "cmux-tui: ignoring duplicate sidebar column {:?}",
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
                "cmux-tui: sidebar.columns had no usable entries; keeping defaults"
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
                "cmux-tui: sidebar.views overrides sidebar.columns"
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
                "cmux-tui: sidebar.views had no usable entries; keeping defaults"
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
                "cmux-tui: sidebar.profiles overrides sidebar.views and sidebar.columns"
            );
        }
        let mut ids = HashSet::new();
        let mut profiles = Vec::new();
        for raw_profile in raw_profiles {
            let id = raw_profile.id.trim();
            if id.is_empty() || !ids.insert(id.to_string()) {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring sidebar profile with an empty or duplicate id"
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
                    "cmux-tui: ignoring sidebar profile {id:?} with no usable views"
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
                "cmux-tui: sidebar.profiles had no usable entries; keeping defaults"
            );
        } else {
            let requested =
                raw.sidebar.profile.as_deref().map(str::trim).filter(|id| !id.is_empty());
            let selected = requested
                .and_then(|id| profiles.iter().position(|profile| profile.id == id))
                .unwrap_or_else(|| {
                    if let Some(requested) = requested {
                        crate::client_log::stderr_log!("config", 
                            "cmux-tui: sidebar.profile {requested:?} was not found; using the first profile"
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
            "cmux-tui: ignoring sidebar.profile without sidebar.profiles"
        );
    }
    match raw.machine_provider.command {
        Some(command) if command.first().is_some_and(|program| !program.trim().is_empty()) => {
            config.machine_provider.command = Some(command);
        }
        Some(_) => {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring machine_provider.command without a program"
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
                "cmux-tui: ignoring empty machine_provider.cloud.host"
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
                "cmux-tui: ignoring zero machine_provider.cloud.port"
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
                "cmux-tui: ignoring machine with an empty or duplicate id/name"
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
                    "cmux-tui: ignoring machine {id:?} with an empty transport target"
                );
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
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring browser.max_capture_megapixels={megapixels:?}; expected 0 < value <= {TRANSPORT_SAFE_CAPTURE_MEGAPIXELS}"
            );
        }
    }
    if let Some(scale) = raw.browser.capture_scale {
        if scale.is_finite() && scale > 0.0 && scale <= 1.0 {
            config.browser.capture_scale = Some(scale);
        } else {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring browser.capture_scale={scale:?}; expected 0 < scale <= 1"
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
                "cmux-tui: ignoring command with a missing or empty id"
            );
            continue;
        }
        if ids.contains(&id) {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring command with duplicate id {id:?}"
            );
            continue;
        }
        // Empty positional arguments stay: argv executes directly, and an
        // empty argument is valid there. Only the program itself must exist.
        let run = command.run.unwrap_or_default();
        if run.first().is_none_or(|program| program.is_empty()) {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring command {id:?} without a run program"
            );
            continue;
        }
        if Action::user_command(commands.len()).is_none() {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring command {id:?} beyond the {MAX_USER_COMMANDS}-command limit"
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
                    "cmux-tui: ignoring command {id:?} chords beyond the {MAX_USER_COMMAND_CHORDS}-chord limit"
                );
                break;
            }
            let Some(chord) = parse_chord(raw_chord) else {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring unparseable command binding {id} = {raw_chord:?}"
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
}

fn normalize_ssh_machine_port(id: &str, port: Option<u16>) -> Option<u16> {
    match port {
        Some(0) => {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring zero SSH machine port for {id:?}"
            );
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
    let value: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(e) => {
            crate::client_log::stderr_log!(
                "config",
                "{} ({})",
                config_diagnostic(&e),
                path.display(),
            );
            return RawConfig::default();
        }
    };
    let Some(object) = value.as_object() else {
        crate::client_log::stderr_log!(
            "config",
            "cmux-tui: ignoring invalid config {}: root must be an object",
            path.display()
        );
        return RawConfig::default();
    };
    const KNOWN: &[&str] = &[
        "theme",
        "tabs",
        "sidebar",
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
            "cmux-tui: ignoring invalid config {}: unknown top-level field `{unknown}`",
            path.display()
        );
        return RawConfig::default();
    }
    let mut raw = RawConfig::default();
    macro_rules! section {
        ($field:ident, $name:literal) => {
            if let Some(value) = object.get($name) {
                match serde_json::from_value(value.clone()) {
                    Ok(parsed) => raw.$field = parsed,
                    Err(error) => crate::client_log::stderr_log!(
                        "config",
                        "cmux-tui: ignoring invalid `{}` section in {}: {}",
                        $name,
                        path.display(),
                        error
                    ),
                }
            }
        };
    }
    section!(theme, "theme");
    section!(tabs, "tabs");
    section!(sidebar, "sidebar");
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
        return catalog().config.invalid_root().to_string();
    }
    catalog().config.invalid_section("(see config file)")
}

pub fn config_path() -> anyhow::Result<PathBuf> {
    platform::config_path().ok_or_else(|| anyhow::anyhow!("could not resolve mux config path"))
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

fn read_config_value(path: &Path) -> anyhow::Result<Value> {
    match std::fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok(json!({})),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
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
    let parent = config_parent_directory(path);
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
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
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
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
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
    if let Err(error) = &result {
        if matches!(error.raw_os_error(), Some(code) if code == libc::EINVAL || code == libc::ENOTSUP)
        {
            return Ok(ConfigParentSyncOutcome::Unsupported);
        }
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

/// The user's relevant Ghostty settings with non-optional application defaults
/// resolved for values that the low-level terminal otherwise leaves unset.
fn ghostty_defaults() -> DefaultColors {
    ghostty_application_defaults().colors
}

#[derive(Default)]
struct GhosttyApplicationDefaults {
    colors: DefaultColors,
    scrollback_limit_bytes: Option<usize>,
}

fn ghostty_application_defaults() -> GhosttyApplicationDefaults {
    let config_paths = platform::ghostty_config_paths();
    let theme_dirs = platform::ghostty_theme_dirs();
    #[cfg(not(test))]
    let helper_defaults = ghostty_defaults_from_helper();
    #[cfg(test)]
    let helper_defaults = GhosttyHelperDefaults::Unavailable;
    match helper_defaults {
        GhosttyHelperDefaults::Resolved(defaults) => *defaults,
        GhosttyHelperDefaults::Unavailable => {
            parse_ghostty_application_defaults_from_paths(config_paths, theme_dirs)
                .unwrap_or_default()
        }
        GhosttyHelperDefaults::TimedOut => GhosttyApplicationDefaults::default(),
    }
}

enum GhosttyHelperDefaults {
    Resolved(Box<GhosttyApplicationDefaults>),
    Unavailable,
    TimedOut,
}

fn ghostty_defaults_from_sources(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
    helper_defaults: GhosttyHelperDefaults,
) -> DefaultColors {
    match helper_defaults {
        GhosttyHelperDefaults::Resolved(defaults) => defaults.colors,
        GhosttyHelperDefaults::Unavailable => {
            parse_ghostty_application_defaults_from_paths(config_paths, theme_dirs)
                .map(|defaults| defaults.colors)
                .unwrap_or_default()
        }
        GhosttyHelperDefaults::TimedOut => DefaultColors::default(),
    }
}

/// Read Ghostty's scrollback setting with the same bounded include traversal
/// used for the other file-based defaults. Ghostty 1.4 renamed the setting to
/// make the byte unit explicit, so both spellings are accepted.
fn ghostty_scrollback_limit_bytes() -> Option<usize> {
    let deadline_at = ghostty_config_deadline_from_now(GHOSTTY_CONFIG_PARSE_DEADLINE);
    let mut resolved = None;
    for path in platform::ghostty_config_paths() {
        if ghostty_config_deadline_expired(Some(deadline_at)) {
            // A partial traversal is not an authoritative configuration
            // result. Falling back to the shared default avoids making
            // startup timing change the selected security and memory limit.
            return None;
        }
        match parse_scrollback_limit_from_root(&path, deadline_at) {
            ScrollbackConfigOutcome::Missing => {}
            ScrollbackConfigOutcome::TimedOut => return None,
            ScrollbackConfigOutcome::Parsed(setting) => {
                // A file with no setting does not mask another candidate.
                // An explicit empty setting is represented as Some(None) and
                // intentionally resets the accumulated value to the default.
                if let Some(setting) = setting {
                    resolved = setting;
                }
            }
        }
    }
    resolved
}

#[derive(Debug, PartialEq, Eq)]
enum ScrollbackConfigOutcome {
    Missing,
    Parsed(Option<Option<usize>>),
    TimedOut,
}

fn parse_scrollback_limit_from_root(path: &Path, deadline_at: Instant) -> ScrollbackConfigOutcome {
    // Ghostty parses the complete parent file first, then loads its
    // config-file entries in declaration order. Nested entries are appended
    // after the already queued siblings. A FIFO queue preserves that
    // precedence while keeping the traversal bounded below.
    let mut queue = VecDeque::from([PendingGhosttyConfig { path: path.to_path_buf(), depth: 0 }]);
    let mut loaded = HashSet::new();
    let mut files_loaded = 0usize;
    let mut bytes_loaded = 0u64;
    let mut value = None;
    let mut loaded_root = false;

    while let Some(pending) = queue.pop_front() {
        if Instant::now() >= deadline_at {
            return ScrollbackConfigOutcome::TimedOut;
        }
        if pending.depth > GHOSTTY_CONFIG_MAX_DEPTH || files_loaded >= GHOSTTY_CONFIG_MAX_FILES {
            continue;
        }
        let identity = pending.path.canonicalize().unwrap_or_else(|_| pending.path.clone());
        if !loaded.insert(identity) {
            continue;
        }
        let remaining_bytes = GHOSTTY_CONFIG_MAX_BYTES.saturating_sub(bytes_loaded);
        let Some(text) = read_ghostty_regular_file(&pending.path, remaining_bytes) else {
            if pending.depth == 0 && files_loaded == 0 {
                return ScrollbackConfigOutcome::Missing;
            }
            continue;
        };
        bytes_loaded = bytes_loaded.saturating_add(text.len() as u64);
        files_loaded += 1;
        loaded_root |= pending.depth == 0;
        if let Some(parsed) = parse_scrollback_limit_bytes(&text) {
            value = Some(parsed);
        }

        let base_dir = pending.path.parent().unwrap_or_else(|| Path::new("."));
        let mut theme_candidates = Vec::new();
        let parsed = parse_ghostty_config_text(&text, Some(base_dir), &mut theme_candidates);
        for include in
            parsed.config_files.into_iter().filter_map(|include| include.resolve(base_dir))
        {
            queue.push_back(PendingGhosttyConfig { path: include, depth: pending.depth + 1 });
        }
        if Instant::now() >= deadline_at {
            return ScrollbackConfigOutcome::TimedOut;
        }
    }

    if loaded_root {
        ScrollbackConfigOutcome::Parsed(value)
    } else {
        ScrollbackConfigOutcome::Missing
    }
}

/// Return the last scrollback setting in a file. The outer `Option` says
/// whether a setting was present; the inner `Option` represents an explicit
/// empty reset to the shared default.
fn parse_scrollback_limit_bytes(text: &str) -> Option<Option<usize>> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.trim().split_once('=')?;
            if !matches!(key.trim(), "scrollback-limit" | "scrollback-limit-bytes") {
                return None;
            }
            // Ghostty treats comments as whole lines. Do not truncate a
            // numeric value at '#', because that would accept malformed input
            // that Ghostty rejects.
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .unwrap_or(value)
                .trim();
            if value.is_empty() {
                return Some(None);
            }
            value.replace('_', "").parse::<usize>().ok().map(Some)
        })
        .last()
}

fn resolve_ghostty_application_defaults(mut defaults: DefaultColors) -> DefaultColors {
    defaults.cursor_style.get_or_insert(CursorShape::Block);
    // `cursor-style-blink = null` is semantically different from `true` in
    // Ghostty: both start blinking, but only the unset form lets DEC mode 12
    // control the live cursor. Keep that absence intact for the terminal
    // application boundary to resolve without losing its provenance.
    defaults
}

#[cfg(test)]
fn resolved_ghostty_defaults_from_with(
    installations: &[platform::GhosttyInstallation],
    mut resolve: impl FnMut(&platform::GhosttyInstallation) -> Option<String>,
) -> Option<DefaultColors> {
    installations.iter().find_map(|installation| {
        let text = resolve(installation)?;
        let defaults = parse_resolved_ghostty_defaults(&text);
        // `+show-config` serializes Ghostty's effective application defaults,
        // including both colors. An executable that exits successfully but
        // emits no resolved config (for example a packaging stub) is not a
        // usable resolver and must not suppress later pinned candidates.
        (defaults.fg.is_some() && defaults.bg.is_some()).then_some(defaults)
    })
}

#[cfg(all(test, unix))]
fn ghostty_show_config_command(installation: &platform::GhosttyInstallation) -> Command {
    let mut command = Command::new(&installation.binary);
    command
        .args(["+show-config", "--no-pager"])
        .env_remove("GHOSTTY_RESOURCES_DIR")
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(resources_dir) = installation.resources_dir.as_deref() {
        command.env("GHOSTTY_RESOURCES_DIR", resources_dir);
    }
    command
}

/// Parse the subset of Ghostty's `key = value` config used by cmux-tui.
///
/// When the Ghostty executable is unavailable, a theme is only accepted if
/// its file can be read. This preserves Ghostty's fail-soft behavior: keep
/// looking after unreadable theme entries, then stop after the first theme
/// that resolves successfully.
#[cfg(test)]
pub(crate) fn parse_ghostty_defaults(text: &str) -> DefaultColors {
    parse_ghostty_defaults_with_theme_dirs(text, &platform::ghostty_theme_dirs())
}

pub(crate) fn is_ghostty_config_helper_invocation(args: &[String]) -> bool {
    args.first().map(String::as_str) == Some("__ghostty-config-defaults")
}

pub(crate) fn run_ghostty_config_helper() -> i32 {
    match parse_ghostty_application_defaults_from_paths(
        platform::ghostty_config_paths(),
        platform::ghostty_theme_dirs(),
    ) {
        Some(defaults) => {
            print!("{}", serialize_ghostty_application_defaults(&defaults));
            0
        }
        None => 1,
    }
}

#[cfg(not(test))]
fn ghostty_defaults_from_helper() -> GhosttyHelperDefaults {
    let Ok(exe) = std::env::current_exe() else {
        return GhosttyHelperDefaults::Unavailable;
    };
    let mut command = Command::new(exe);
    command
        .arg("__ghostty-config-defaults")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    scrub_ghostty_helper_secret_environment(&mut command);
    ghostty_defaults_from_helper_command(command, GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE)
}

#[cfg(any(not(test), all(test, unix)))]
fn ghostty_defaults_from_helper_command(
    mut command: Command,
    parent_deadline: Duration,
) -> GhosttyHelperDefaults {
    let Ok(mut child) = command.spawn() else {
        return GhosttyHelperDefaults::Unavailable;
    };
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_helper_child(child);
        return GhosttyHelperDefaults::Unavailable;
    };
    let Some(output_reader) = read_ghostty_helper_output_async(stdout) else {
        terminate_ghostty_helper_child(child);
        return GhosttyHelperDefaults::Unavailable;
    };
    let status = match child.wait_timeout(parent_deadline) {
        Ok(status) => status,
        Err(_) => {
            terminate_ghostty_helper_child(child);
            return GhosttyHelperDefaults::Unavailable;
        }
    };
    let status = match status {
        Some(status) => status,
        None => {
            terminate_ghostty_helper_child(child);
            return GhosttyHelperDefaults::TimedOut;
        }
    };
    if !status.success() {
        if status.code() == Some(2) {
            return GhosttyHelperDefaults::TimedOut;
        }
        return GhosttyHelperDefaults::Unavailable;
    }
    match output_reader.wait() {
        Some(output) => GhosttyHelperDefaults::Resolved(Box::new(GhosttyApplicationDefaults {
            colors: parse_resolved_ghostty_defaults(&output),
            scrollback_limit_bytes: parse_scrollback_limit_bytes(&output).flatten(),
        })),
        None => GhosttyHelperDefaults::Unavailable,
    }
}

fn read_ghostty_helper_output_async(
    stdout: impl Read + Send + 'static,
) -> Option<GhosttyHelperOutputReader> {
    read_ghostty_limited_output_async(
        stdout,
        GHOSTTY_HELPER_OUTPUT_MAX_BYTES,
        "cmux-tui-ghostty-helper-output",
    )
}

fn read_ghostty_limited_output_async(
    stdout: impl Read + Send + 'static,
    max_bytes: u64,
    thread_name: &'static str,
) -> Option<GhosttyHelperOutputReader> {
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || {
            let _ = sender.send(read_ghostty_limited_string(stdout, max_bytes));
        })
        .ok()?;
    Some(GhosttyHelperOutputReader { receiver })
}

struct GhosttyHelperOutputReader {
    receiver: mpsc::Receiver<Option<String>>,
}

impl GhosttyHelperOutputReader {
    fn wait(self) -> Option<String> {
        self.receiver.recv().ok().flatten()
    }

    #[cfg(not(target_os = "macos"))]
    fn recv_timeout(&self, timeout: Duration) -> Result<Option<String>, mpsc::RecvTimeoutError> {
        self.receiver.recv_timeout(timeout)
    }
}

fn terminate_ghostty_helper_child(child: Child) {
    let _ = terminate_ghostty_helper_child_with_reaped_signal(child);
}

fn terminate_ghostty_helper_child_with_reaped_signal(mut child: Child) -> mpsc::Receiver<()> {
    #[cfg(unix)]
    let descendant_groups = ghostty_helper_descendant_process_groups(child.id() as libc::pid_t);
    #[cfg(unix)]
    unsafe {
        for group in descendant_groups {
            // SAFETY: group IDs are read from the process table for descendants
            // of the helper being terminated.
            libc::killpg(group, libc::SIGKILL);
        }
        // SAFETY: killpg only sends SIGKILL to the helper-owned process group.
        libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
    }
    let _ = child.kill();
    reap_ghostty_child_after_short_wait(child, "cmux-tui-ghostty-helper-reaper")
}

#[cfg(unix)]
fn ghostty_helper_descendant_process_groups(root_pid: libc::pid_t) -> Vec<libc::pid_t> {
    let Some(text) = ghostty_helper_process_table_snapshot() else {
        return Vec::new();
    };
    ghostty_helper_descendant_process_groups_from_table(root_pid, &text)
}

#[cfg(unix)]
fn ghostty_helper_process_table_snapshot() -> Option<String> {
    let mut command = Command::new("/bin/ps");
    command
        .args(["-axo", "pid=,ppid=,pgid="])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let Ok(mut child) = command.spawn() else {
        return None;
    };
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_process_scan_child(child);
        return None;
    };
    let Some(output_reader) = read_ghostty_limited_output_async(
        stdout,
        GHOSTTY_PROCESS_SCAN_OUTPUT_MAX_BYTES,
        "cmux-tui-ghostty-process-scan-output",
    ) else {
        terminate_ghostty_process_scan_child(child);
        return None;
    };
    let status = match child.wait_timeout(GHOSTTY_PROCESS_SCAN_DEADLINE) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            terminate_ghostty_process_scan_child(child);
            return None;
        }
    };
    if !status.success() {
        return None;
    }
    output_reader.wait()
}

#[cfg(unix)]
fn terminate_ghostty_process_scan_child(child: Child) {
    let _ = terminate_ghostty_process_scan_child_with_reaped_signal(child);
}

#[cfg(unix)]
fn terminate_ghostty_process_scan_child_with_reaped_signal(mut child: Child) -> mpsc::Receiver<()> {
    unsafe {
        // SAFETY: this only targets the bounded process-scan child group.
        libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
    }
    let _ = child.kill();
    reap_ghostty_child_after_short_wait(child, "cmux-tui-ghostty-process-scan-reaper")
}

fn reap_ghostty_child_after_short_wait(
    mut child: Child,
    reaper_name: &'static str,
) -> mpsc::Receiver<()> {
    let (reaped_sender, reaped_receiver) = mpsc::sync_channel(1);
    if matches!(child.wait_timeout(Duration::from_millis(10)), Ok(Some(_))) {
        let _ = reaped_sender.send(());
        return reaped_receiver;
    }
    let _ = std::thread::Builder::new().name(reaper_name.to_string()).spawn(move || {
        let _ = child.wait();
        let _ = reaped_sender.send(());
    });
    reaped_receiver
}

#[cfg(unix)]
fn ghostty_helper_descendant_process_groups_from_table(
    root_pid: libc::pid_t,
    text: &str,
) -> Vec<libc::pid_t> {
    let mut children = HashMap::<libc::pid_t, Vec<(libc::pid_t, libc::pid_t)>>::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(pid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        let Some(ppid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        let Some(pgid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        children.entry(ppid).or_default().push((pid, pgid));
    }

    let mut groups = HashSet::<libc::pid_t>::new();
    let mut stack = vec![root_pid];
    while let Some(parent) = stack.pop() {
        let Some(descendants) = children.get(&parent) else {
            continue;
        };
        for &(pid, pgid) in descendants {
            stack.push(pid);
            if pgid > 0 && pgid != root_pid {
                groups.insert(pgid);
            }
        }
    }
    groups.into_iter().collect()
}

#[cfg(any(not(test), all(test, unix)))]
fn scrub_ghostty_helper_secret_environment(command: &mut Command) {
    for name in ["CMUX_MACHINE_PROVIDER_TOKEN", "CMUX_PROVIDER_WORKSPACE_AUTHORITY"] {
        command.env_remove(name);
    }
}

fn parse_ghostty_defaults_from_paths(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
) -> Option<DefaultColors> {
    match parse_ghostty_defaults_from_paths_result(config_paths, theme_dirs) {
        GhosttyConfigParseOutcome::Parsed(defaults) => Some(*defaults),
        GhosttyConfigParseOutcome::Missing | GhosttyConfigParseOutcome::TimedOut => None,
    }
}

fn parse_ghostty_application_defaults_from_paths(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
) -> Option<GhosttyApplicationDefaults> {
    let deadline_at = ghostty_config_deadline_from_now(GHOSTTY_CONFIG_PARSE_DEADLINE);
    let mut resolved = None;
    let mut scrollback_limit_bytes = None;
    for path in config_paths {
        if ghostty_config_deadline_expired(Some(deadline_at)) {
            return None;
        }
        let mut path_scrollback = None;
        match parse_ghostty_defaults_from_path_result_until_with_scrollback(
            &path,
            &theme_dirs,
            Some(deadline_at),
            Some(&mut path_scrollback),
        ) {
            GhosttyConfigParseOutcome::Missing => {}
            GhosttyConfigParseOutcome::TimedOut => return None,
            GhosttyConfigParseOutcome::Parsed(defaults) => {
                let merged = resolved.get_or_insert_with(DefaultColors::default);
                overlay_ghostty_defaults(merged, *defaults);
                if let Some(value) = path_scrollback {
                    scrollback_limit_bytes = value;
                }
            }
        }
    }
    resolved.map(|colors| GhosttyApplicationDefaults {
        colors: resolve_ghostty_application_defaults(colors),
        scrollback_limit_bytes,
    })
}

enum GhosttyConfigParseOutcome {
    Parsed(Box<DefaultColors>),
    Missing,
    TimedOut,
}

fn parse_ghostty_defaults_from_paths_result(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
) -> GhosttyConfigParseOutcome {
    let deadline_at = ghostty_config_deadline_from_now(GHOSTTY_CONFIG_PARSE_DEADLINE);
    parse_ghostty_defaults_from_paths_result_until(config_paths, theme_dirs, Some(deadline_at))
}

fn parse_ghostty_defaults_from_paths_result_until(
    config_paths: Vec<PathBuf>,
    theme_dirs: Vec<PathBuf>,
    deadline_at: Option<Instant>,
) -> GhosttyConfigParseOutcome {
    for path in config_paths {
        if ghostty_config_deadline_expired(deadline_at) {
            return GhosttyConfigParseOutcome::TimedOut;
        }
        match parse_ghostty_defaults_from_path_result_until(&path, &theme_dirs, deadline_at) {
            GhosttyConfigParseOutcome::Missing => {}
            outcome => return outcome,
        }
    }
    GhosttyConfigParseOutcome::Missing
}

#[cfg(test)]
fn parse_ghostty_defaults_with_theme_dirs(text: &str, theme_dirs: &[PathBuf]) -> DefaultColors {
    let mut theme_candidates = Vec::new();
    let parsed = parse_ghostty_config_text(text, None, &mut theme_candidates);
    resolve_parsed_ghostty_defaults(theme_candidates, theme_dirs, parsed.overrides, None)
}

#[cfg(test)]
fn parse_ghostty_defaults_from_path(path: &Path, theme_dirs: &[PathBuf]) -> Option<DefaultColors> {
    match parse_ghostty_defaults_from_path_result(path, theme_dirs) {
        GhosttyConfigParseOutcome::Parsed(defaults) => Some(*defaults),
        GhosttyConfigParseOutcome::Missing | GhosttyConfigParseOutcome::TimedOut => None,
    }
}

#[cfg(test)]
fn parse_ghostty_defaults_from_path_result(
    path: &Path,
    theme_dirs: &[PathBuf],
) -> GhosttyConfigParseOutcome {
    let deadline_at = ghostty_config_deadline_from_now(GHOSTTY_CONFIG_PARSE_DEADLINE);
    parse_ghostty_defaults_from_path_result_until(path, theme_dirs, Some(deadline_at))
}

fn parse_ghostty_defaults_from_path_result_until(
    path: &Path,
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
) -> GhosttyConfigParseOutcome {
    parse_ghostty_defaults_from_path_result_until_with_scrollback(
        path,
        theme_dirs,
        deadline_at,
        None,
    )
}

fn parse_ghostty_defaults_from_path_result_until_with_scrollback(
    path: &Path,
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
    mut scrollback_limit_bytes: Option<&mut Option<Option<usize>>>,
) -> GhosttyConfigParseOutcome {
    let mut theme_candidates = Vec::new();
    let overrides = match parse_ghostty_config_file_until_with_scrollback(
        path,
        &mut theme_candidates,
        deadline_at,
        scrollback_limit_bytes,
    ) {
        GhosttyConfigParseOutcome::Parsed(overrides) => *overrides,
        outcome => return outcome,
    };
    GhosttyConfigParseOutcome::Parsed(Box::new(resolve_parsed_ghostty_defaults(
        theme_candidates,
        theme_dirs,
        overrides,
        deadline_at,
    )))
}

const GHOSTTY_CONFIG_MAX_FILES: usize = 64;
const GHOSTTY_CONFIG_MAX_DEPTH: usize = 16;
const GHOSTTY_CONFIG_MAX_BYTES: u64 = 1024 * 1024;
const GHOSTTY_HELPER_OUTPUT_MAX_BYTES: u64 = 64 * 1024;
#[cfg(unix)]
const GHOSTTY_PROCESS_SCAN_OUTPUT_MAX_BYTES: u64 = 1024 * 1024;
const GHOSTTY_CONFIG_PARSE_DEADLINE: Duration = Duration::from_millis(250);
#[cfg(unix)]
const GHOSTTY_PROCESS_SCAN_DEADLINE: Duration = Duration::from_millis(150);
#[cfg(not(target_os = "macos"))]
const GHOSTTY_HELPER_REAP_DEADLINE: Duration = Duration::from_millis(150);
// The child owns a 250 ms parse deadline. The parent starts timing before
// spawn/exec and still needs room for setup, stdout drain, and normal exit.
const GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE: Duration = Duration::from_millis(500);
#[cfg(not(target_os = "macos"))]
const GHOSTTY_DESKTOP_APPEARANCE_DEADLINE: Duration = Duration::from_millis(75);

struct PendingGhosttyConfig {
    path: PathBuf,
    depth: usize,
}

#[cfg(test)]
fn parse_ghostty_config_file_with_deadline(
    path: &Path,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
    deadline: Duration,
) -> GhosttyConfigParseOutcome {
    parse_ghostty_config_file_until(
        path,
        theme_candidates,
        Some(ghostty_config_deadline_from_now(deadline)),
    )
}

fn parse_ghostty_config_file_until(
    path: &Path,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
    deadline_at: Option<Instant>,
) -> GhosttyConfigParseOutcome {
    parse_ghostty_config_file_until_with_scrollback(path, theme_candidates, deadline_at, None)
}

fn parse_ghostty_config_file_until_with_scrollback(
    path: &Path,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
    deadline_at: Option<Instant>,
    mut scrollback_limit_bytes: Option<&mut Option<Option<usize>>>,
) -> GhosttyConfigParseOutcome {
    let mut queue = VecDeque::from([PendingGhosttyConfig { path: path.to_path_buf(), depth: 0 }]);
    let mut loaded = HashSet::new();
    let mut files_loaded = 0usize;
    let mut bytes_loaded = 0u64;
    let mut loaded_root = false;
    let mut overrides = DefaultColors::default();
    let collect_scrollback = scrollback_limit_bytes.is_some();

    while let Some(pending) = queue.pop_front() {
        if files_loaded > 0 && ghostty_config_deadline_expired(deadline_at) {
            return GhosttyConfigParseOutcome::TimedOut;
        }
        if pending.depth > GHOSTTY_CONFIG_MAX_DEPTH || files_loaded >= GHOSTTY_CONFIG_MAX_FILES {
            continue;
        }
        let identity = pending.path.canonicalize().unwrap_or_else(|_| pending.path.clone());
        if !loaded.insert(identity) {
            continue;
        }
        let remaining_bytes = GHOSTTY_CONFIG_MAX_BYTES.saturating_sub(bytes_loaded);
        let text = match read_ghostty_regular_file(&pending.path, remaining_bytes) {
            Some(text) => text,
            None if pending.depth == 0 && files_loaded == 0 => {
                return GhosttyConfigParseOutcome::Missing;
            }
            None => continue,
        };
        bytes_loaded = bytes_loaded.saturating_add(text.len() as u64);
        files_loaded += 1;
        loaded_root |= pending.depth == 0;
        if let (Some(scrollback_limit_bytes), Some(parsed)) =
            (scrollback_limit_bytes.as_deref_mut(), parse_scrollback_limit_bytes(&text))
        {
            *scrollback_limit_bytes = Some(parsed);
        }

        let base_dir = pending.path.parent().unwrap_or_else(|| Path::new("."));
        let parsed = parse_ghostty_config_text(&text, Some(base_dir), theme_candidates);
        overlay_ghostty_defaults(&mut overrides, parsed.overrides);

        let includes =
            parsed.config_files.into_iter().filter_map(|include| include.resolve(base_dir));
        if collect_scrollback {
            for include in includes {
                queue.push_back(PendingGhosttyConfig { path: include, depth: pending.depth + 1 });
            }
        } else {
            for include in includes.rev() {
                queue.push_front(PendingGhosttyConfig { path: include, depth: pending.depth + 1 });
            }
        }
        if ghostty_config_deadline_expired(deadline_at) {
            return GhosttyConfigParseOutcome::TimedOut;
        }
    }

    if loaded_root {
        GhosttyConfigParseOutcome::Parsed(Box::new(overrides))
    } else {
        GhosttyConfigParseOutcome::Missing
    }
}

fn ghostty_config_deadline_from_now(deadline: Duration) -> Instant {
    Instant::now().checked_add(deadline).unwrap_or_else(Instant::now)
}

fn ghostty_config_deadline_expired(deadline_at: Option<Instant>) -> bool {
    deadline_at.is_some_and(|deadline_at| Instant::now() >= deadline_at)
}

#[cfg(not(target_os = "macos"))]
fn ghostty_config_deadline_remaining(deadline_at: Option<Instant>) -> Option<Duration> {
    deadline_at.map_or(Some(Duration::MAX), |deadline_at| Some(ghostty_duration_until(deadline_at)))
}

#[cfg(not(target_os = "macos"))]
fn ghostty_duration_until(deadline_at: Instant) -> Duration {
    deadline_at.checked_duration_since(Instant::now()).unwrap_or(Duration::ZERO)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn kill_ghostty_process_group(group: libc::pid_t) {
    if group <= 0 {
        return;
    }
    unsafe {
        // SAFETY: callers pass process-group IDs that were either created by
        // cmux-tui for short-lived helpers or discovered under those helpers.
        libc::killpg(group, libc::SIGKILL);
    }
}

struct ParsedGhosttyConfig {
    overrides: DefaultColors,
    config_files: Vec<GhosttyConfigFile>,
}

struct GhosttyThemeCandidate {
    value: String,
    base_dir: Option<PathBuf>,
}

struct GhosttyConfigFile {
    path: String,
}

impl GhosttyConfigFile {
    fn parse(value: &str) -> Option<Self> {
        let value = value.trim();
        let value = value.strip_prefix('?').unwrap_or(value);
        let value =
            value.strip_prefix('"').and_then(|value| value.strip_suffix('"')).unwrap_or(value);
        if value.is_empty() { None } else { Some(Self { path: value.to_owned() }) }
    }

    fn resolve(self, base_dir: &Path) -> Option<PathBuf> {
        if let Some(path) = expand_home_relative_path(&self.path) {
            return Some(path);
        }
        let path = Path::new(&self.path);
        if path.is_absolute() { Some(path.to_path_buf()) } else { Some(base_dir.join(path)) }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GhosttyThemeMode {
    Light,
    Dark,
}

impl GhosttyThemeMode {
    fn parse(value: &std::ffi::OsStr) -> Option<Self> {
        let value = value.to_string_lossy();
        match value.trim_matches('"').to_ascii_lowercase().as_str() {
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

fn system_ghostty_theme_mode(deadline_at: Option<Instant>) -> GhosttyThemeMode {
    system_ghostty_theme_mode_with_platform(|| platform_appearance_theme_mode(deadline_at))
}

fn system_ghostty_theme_mode_with_platform(
    mut platform_appearance: impl FnMut() -> Option<GhosttyThemeMode>,
) -> GhosttyThemeMode {
    if let Some(mode) =
        std::env::var_os("AppleInterfaceStyle").as_deref().and_then(GhosttyThemeMode::parse)
    {
        return mode;
    }
    if let Some(mode) = platform_appearance() {
        return mode;
    }
    GhosttyThemeMode::Light
}

#[cfg(target_os = "macos")]
fn platform_appearance_theme_mode(_deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    macos_appearance_theme_mode()
}

#[cfg(not(target_os = "macos"))]
fn platform_appearance_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    non_macos_appearance_theme_mode(deadline_at)
}

#[cfg(not(target_os = "macos"))]
fn non_macos_appearance_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    if let Some(mode) = freedesktop_portal_theme_mode(deadline_at) {
        return Some(mode);
    }
    if let Some(mode) = gnome_color_scheme_theme_mode(deadline_at) {
        return Some(mode);
    }
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    if let Some(mode) = std::env::var_os("GTK_THEME")
        .as_deref()
        .and_then(|value| gtk_theme_name_theme_mode(&value.to_string_lossy()))
    {
        return Some(mode);
    }
    gtk_settings_paths()
        .into_iter()
        .find_map(|path| {
            if ghostty_config_deadline_expired(deadline_at) {
                return None;
            }
            let text = read_ghostty_regular_file(&path, 64 * 1024)?;
            gtk_settings_theme_mode(&text)
        })
        .or_else(|| kde_globals_theme_mode(deadline_at))
}

#[cfg(not(target_os = "macos"))]
fn freedesktop_portal_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    let output = desktop_theme_command_output(
        "gdbus",
        &[
            "call",
            "--session",
            "--dest",
            "org.freedesktop.portal.Desktop",
            "--object-path",
            "/org/freedesktop/portal/desktop",
            "--method",
            "org.freedesktop.portal.Settings.Read",
            "org.freedesktop.appearance",
            "color-scheme",
        ],
        deadline_at,
    )?;
    freedesktop_portal_color_scheme_theme_mode(&output)
}

#[cfg(not(target_os = "macos"))]
fn gnome_color_scheme_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    let output = desktop_theme_command_output(
        "gsettings",
        &["get", "org.gnome.desktop.interface", "color-scheme"],
        deadline_at,
    )?;
    gnome_color_scheme_output_theme_mode(&output)
}

#[cfg(not(target_os = "macos"))]
fn desktop_theme_command_output(
    program: &str,
    args: &[&str],
    deadline_at: Option<Instant>,
) -> Option<String> {
    desktop_theme_command_output_with_lifecycle_signals(program, args, deadline_at, None, None)
}

#[cfg(not(target_os = "macos"))]
fn desktop_theme_command_output_with_lifecycle_signals(
    program: &str,
    args: &[&str],
    deadline_at: Option<Instant>,
    started_sender: Option<&mpsc::SyncSender<u32>>,
    reaped_sender: Option<&mpsc::SyncSender<()>>,
) -> Option<String> {
    let timeout =
        ghostty_config_deadline_remaining(deadline_at)?.min(GHOSTTY_DESKTOP_APPEARANCE_DEADLINE);
    if timeout.is_zero() {
        return None;
    }
    let command_deadline = Instant::now() + timeout;
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn().ok()?;
    if let Some(started_sender) = started_sender {
        let _ = started_sender.send(child.id());
    }
    #[cfg(unix)]
    let child_group = child.id() as libc::pid_t;
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_helper_child(child);
        return None;
    };
    let Some(output_reader) = read_ghostty_helper_output_async(stdout) else {
        terminate_ghostty_helper_child(child);
        return None;
    };
    let status = match child.wait_timeout(timeout) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            terminate_ghostty_helper_child(child);
            return None;
        }
    };
    if !status.success() {
        return None;
    }
    match output_reader.recv_timeout(ghostty_duration_until(command_deadline)) {
        Ok(output) => output,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            #[cfg(unix)]
            kill_ghostty_process_group(child_group);
            let reap_timeout =
                ghostty_config_deadline_remaining(deadline_at)?.min(GHOSTTY_HELPER_REAP_DEADLINE);
            if !reap_timeout.is_zero()
                && output_reader.recv_timeout(reap_timeout).is_ok()
                && let Some(reaped_sender) = reaped_sender
            {
                let _ = reaped_sender.send(());
            }
            None
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => None,
    }
}

#[cfg(any(test, not(target_os = "macos")))]
fn freedesktop_portal_color_scheme_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    if text.contains("uint32 1") || text.contains("<1>") {
        return Some(GhosttyThemeMode::Dark);
    }
    if text.contains("uint32 2") || text.contains("<2>") {
        return Some(GhosttyThemeMode::Light);
    }
    None
}

#[cfg(any(test, not(target_os = "macos")))]
fn gnome_color_scheme_output_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    let text = text.trim().trim_matches('\'').trim_matches('"');
    match text {
        "prefer-dark" => Some(GhosttyThemeMode::Dark),
        "prefer-light" => Some(GhosttyThemeMode::Light),
        _ => None,
    }
}

#[cfg(not(target_os = "macos"))]
fn kde_globals_theme_mode(deadline_at: Option<Instant>) -> Option<GhosttyThemeMode> {
    kde_globals_paths().into_iter().find_map(|path| {
        if ghostty_config_deadline_expired(deadline_at) {
            return None;
        }
        let text = read_ghostty_regular_file(&path, 64 * 1024)?;
        kde_globals_text_theme_mode(&text)
    })
}

#[cfg(not(target_os = "macos"))]
fn kde_globals_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(config_home) = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from) {
        paths.push(config_home.join("kdeglobals"));
    }
    if let Some(home) = platform::home_dir() {
        let path = home.join(".config").join("kdeglobals");
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    paths
}

#[cfg(any(test, not(target_os = "macos")))]
fn kde_globals_text_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() == "ColorScheme" {
            return gtk_theme_name_theme_mode(value.trim());
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn gtk_settings_paths() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(config_home) = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from) {
        roots.push(config_home);
    }
    if let Some(home) = platform::home_dir() {
        roots.push(home.join(".config"));
    }

    let mut paths = Vec::new();
    for root in roots {
        for version in ["gtk-4.0", "gtk-3.0"] {
            let path = root.join(version).join("settings.ini");
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    paths
}

#[cfg(any(test, not(target_os = "macos")))]
fn gtk_settings_theme_mode(text: &str) -> Option<GhosttyThemeMode> {
    let mut theme_name = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let key = key.trim();
        let value = value.trim().trim_matches('"');
        match key {
            "gtk-application-prefer-dark-theme" => match value.to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" => return Some(GhosttyThemeMode::Dark),
                "0" | "false" | "no" => {}
                _ => {}
            },
            "gtk-theme-name" => theme_name = gtk_theme_name_theme_mode(value),
            _ => {}
        }
    }
    theme_name
}

#[cfg(any(test, not(target_os = "macos")))]
fn gtk_theme_name_theme_mode(value: &str) -> Option<GhosttyThemeMode> {
    let value = value.to_ascii_lowercase();
    if value.ends_with("dark") || value.split([':', '-', '_']).any(|part| part == "dark") {
        return Some(GhosttyThemeMode::Dark);
    }
    if value.ends_with("light") || value.split([':', '-', '_']).any(|part| part == "light") {
        return Some(GhosttyThemeMode::Light);
    }
    None
}

#[cfg(test)]
fn ghostty_background_is_light(background: Rgb) -> bool {
    let luminance = (0.299 * f64::from(background.r)
        + 0.587 * f64::from(background.g)
        + 0.114 * f64::from(background.b))
        / 255.0;
    luminance > 0.5
}

#[cfg(target_os = "macos")]
fn macos_appearance_theme_mode() -> Option<GhosttyThemeMode> {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_void};
    use std::ptr;

    type CfTypeRef = *const c_void;
    type CfStringRef = *const c_void;
    type Boolean = u8;

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFPreferencesAnyApplication: CfStringRef;
        static kCFPreferencesCurrentUser: CfStringRef;
        static kCFPreferencesAnyHost: CfStringRef;

        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const c_char,
            encoding: u32,
        ) -> CfStringRef;
        fn CFPreferencesCopyValue(
            key: CfStringRef,
            application_id: CfStringRef,
            user_name: CfStringRef,
            host_name: CfStringRef,
        ) -> CfTypeRef;
        fn CFEqual(cf1: CfTypeRef, cf2: CfTypeRef) -> Boolean;
        fn CFRelease(cf: CfTypeRef);
    }

    let key = CString::new("AppleInterfaceStyle").ok()?;
    let dark = CString::new("Dark").ok()?;
    unsafe {
        let key_ref =
            CFStringCreateWithCString(ptr::null(), key.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        if key_ref.is_null() {
            return None;
        }
        let dark_ref =
            CFStringCreateWithCString(ptr::null(), dark.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        if dark_ref.is_null() {
            CFRelease(key_ref);
            return None;
        }
        let value = CFPreferencesCopyValue(
            key_ref,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        );
        let mode = if !value.is_null() && CFEqual(value, dark_ref) != 0 {
            GhosttyThemeMode::Dark
        } else {
            GhosttyThemeMode::Light
        };
        if !value.is_null() {
            CFRelease(value);
        }
        CFRelease(dark_ref);
        CFRelease(key_ref);
        Some(mode)
    }
}

fn parse_ghostty_config_text(
    text: &str,
    base_dir: Option<&Path>,
    theme_candidates: &mut Vec<GhosttyThemeCandidate>,
) -> ParsedGhosttyConfig {
    let mut overrides = DefaultColors::default();
    let mut config_files = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else { continue };
        match key.trim() {
            "theme" => {
                theme_candidates.push(GhosttyThemeCandidate {
                    value: value.trim().to_owned(),
                    base_dir: base_dir.map(Path::to_path_buf),
                });
            }
            "window-theme" => {}
            "config-file" => {
                if let Some(include) = GhosttyConfigFile::parse(value) {
                    config_files.push(include);
                }
            }
            key => apply_ghostty_default(&mut overrides, key, value.trim()),
        }
    }

    ParsedGhosttyConfig { overrides, config_files }
}

fn resolve_ghostty_theme_defaults(
    theme_candidates: &[GhosttyThemeCandidate],
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
) -> DefaultColors {
    if theme_candidates.is_empty() {
        return DefaultColors::default();
    }
    if ghostty_config_deadline_expired(deadline_at) {
        return DefaultColors::default();
    }
    let mut theme_mode = None;
    for candidate in theme_candidates {
        if ghostty_config_deadline_expired(deadline_at) {
            return DefaultColors::default();
        }
        if let Some(defaults) =
            load_ghostty_theme(candidate, theme_dirs, deadline_at, &mut theme_mode)
        {
            return defaults;
        }
    }
    DefaultColors::default()
}

fn resolve_parsed_ghostty_defaults(
    theme_candidates: Vec<GhosttyThemeCandidate>,
    theme_dirs: &[PathBuf],
    overrides: DefaultColors,
    deadline_at: Option<Instant>,
) -> DefaultColors {
    let mut defaults = resolve_ghostty_theme_defaults(&theme_candidates, theme_dirs, deadline_at);
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

fn serialize_ghostty_defaults(defaults: DefaultColors) -> String {
    let mut out = String::new();
    if let Some(color) = defaults.fg {
        out.push_str(&format!("foreground = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.bg {
        out.push_str(&format!("background = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.cursor {
        out.push_str(&format!("cursor-color = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.selection_bg {
        out.push_str(&format!("selection-background = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(color) = defaults.selection_fg {
        out.push_str(&format!("selection-foreground = {}\n", format_ghostty_rgb(color)));
    }
    if let Some(style) = defaults.cursor_style {
        let style = match style {
            CursorShape::Block => Some("block"),
            CursorShape::Underline => Some("underline"),
            CursorShape::Bar => Some("bar"),
            CursorShape::BlockHollow => Some("block_hollow"),
        };
        if let Some(style) = style {
            out.push_str(&format!("cursor-style = {style}\n"));
        }
    }
    if let Some(blink) = defaults.cursor_blink {
        out.push_str(&format!("cursor-style-blink = {blink}\n"));
    }
    for (index, color) in defaults.palette.into_iter().enumerate() {
        if let Some(color) = color {
            out.push_str(&format!("palette = {index}={}\n", format_ghostty_rgb(color)));
        }
    }
    out
}

fn serialize_ghostty_application_defaults(defaults: &GhosttyApplicationDefaults) -> String {
    let mut out = serialize_ghostty_defaults(defaults.colors);
    if let Some(limit) = defaults.scrollback_limit_bytes {
        out.push_str(&format!("scrollback-limit-bytes = {limit}\n"));
    }
    out
}

fn format_ghostty_rgb(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
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
                "block_hollow" => Some(CursorShape::BlockHollow),
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

fn load_ghostty_theme(
    candidate: &GhosttyThemeCandidate,
    theme_dirs: &[PathBuf],
    deadline_at: Option<Instant>,
    theme_mode: &mut Option<GhosttyThemeMode>,
) -> Option<DefaultColors> {
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    let value = candidate.value.trim_matches('"');
    let theme = selected_ghostty_theme(value, deadline_at, theme_mode);
    if ghostty_config_deadline_expired(deadline_at) {
        return None;
    }
    let path = resolve_ghostty_theme_path(theme, candidate.base_dir.as_deref(), theme_dirs)?;
    let text = read_ghostty_regular_file(&path, GHOSTTY_CONFIG_MAX_BYTES)?;
    Some(parse_resolved_ghostty_defaults(&text))
}

fn read_ghostty_regular_file(path: &Path, max_bytes: u64) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() > max_bytes {
        return None;
    }
    read_ghostty_limited_string(file, max_bytes)
}

fn read_ghostty_limited_string(reader: impl Read, max_bytes: u64) -> Option<String> {
    let mut text = String::new();
    reader.take(max_bytes.saturating_add(1)).read_to_string(&mut text).ok()?;
    if text.len() as u64 > max_bytes {
        return None;
    }
    Some(text)
}

fn resolve_ghostty_theme_path(
    theme: &str,
    base_dir: Option<&Path>,
    theme_dirs: &[PathBuf],
) -> Option<PathBuf> {
    if let Some(path) = expand_home_relative_path(theme) {
        return Some(path);
    }
    let path = Path::new(theme);
    if path.is_absolute() {
        return Some(path.to_path_buf());
    }
    if path.file_name().is_some_and(|name| name == theme) {
        return theme_dirs.iter().map(|dir| dir.join(theme)).find(|path| path.is_file());
    }
    base_dir.map(|base_dir| base_dir.join(path))
}

fn expand_home_relative_path(value: &str) -> Option<PathBuf> {
    let home = platform::home_dir()?;
    match value {
        "~" => Some(home),
        value => value.strip_prefix("~/").map(|rest| home.join(rest)),
    }
}

fn selected_ghostty_theme<'a>(
    value: &'a str,
    deadline_at: Option<Instant>,
    theme_mode: &mut Option<GhosttyThemeMode>,
) -> &'a str {
    let Some((light, dark)) = conditional_ghostty_themes(value) else {
        return value;
    };
    let mode = *theme_mode.get_or_insert_with(|| system_ghostty_theme_mode(deadline_at));
    match mode {
        GhosttyThemeMode::Light => light,
        GhosttyThemeMode::Dark => dark,
    }
}

fn conditional_ghostty_themes(value: &str) -> Option<(&str, &str)> {
    let mut light = None;
    let mut dark = None;
    for part in value.split(',') {
        let (key, theme) = part.split_once(':').or_else(|| part.split_once('='))?;
        let theme = theme.trim();
        match key.trim() {
            "light" if !theme.is_empty() => light = Some(theme),
            "dark" if !theme.is_empty() => dark = Some(theme),
            _ => return None,
        }
    }
    Some((light?, dark?))
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
    use std::cell::{Cell, RefCell};

    #[test]
    fn config_diagnostics_do_not_echo_parser_details() {
        let error = serde_json::from_str::<RawConfig>(r#"{"typo":true}"#).unwrap_err();
        let diagnostic = config_diagnostic(&error);
        assert!(diagnostic.contains("unknown config field"));
        assert!(!diagnostic.contains("typo"));
    }
    use std::ffi::OsString;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// Config env vars are process-global state; tests that set them must not
    /// run concurrently with each other.
    static CONFIG_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn startup_snapshot_invokes_loader_once() {
        let loads = Cell::new(0);
        let snapshot = StartupConfigSnapshot::from_loader(|| {
            loads.set(loads.get() + 1);
            Config::default()
        });

        assert!(snapshot.server.detached_owner);
        assert!(snapshot.server.detached_owner);
        let _config = snapshot.into_config();
        assert_eq!(loads.get(), 1);
    }
    static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new(label: &str) -> Self {
            loop {
                let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
                let path = std::env::temp_dir()
                    .join(format!("cmux-tui-config-{label}-{}-{sequence}", std::process::id()));
                match std::fs::create_dir(&path) {
                    Ok(()) => return Self { path },
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => panic!("create config test directory failed: {error}"),
                }
            }
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn restore_env_var(key: &str, value: Option<OsString>) {
        match value {
            // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
            Some(value) => unsafe { std::env::set_var(key, value) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    fn assert_committed(outcome: ConfigWriteOutcome) {
        assert!(matches!(
            outcome,
            ConfigWriteOutcome::Committed
                | ConfigWriteOutcome::CommittedWithoutDirectorySync
                | ConfigWriteOutcome::CommittedButUnsynced { .. }
        ));
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

        assert_eq!(
            parse_scrollback_limit_bytes(
                "scrollback-limit-lines = 12\n\
                 scrollback-limit = invalid\n\
                 scrollback-limit-bytes = 8_000_000\n"
            ),
            Some(Some(8_000_000))
        );
        assert_eq!(parse_scrollback_limit_bytes("scrollback-limit = \"\"\n"), Some(None));
        assert_eq!(parse_scrollback_limit_bytes("scrollback-limit-lines = 12\n"), None);
        assert_eq!(parse_scrollback_limit_bytes("scrollback-limit = 4096#note\n"), None);

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

        let hollow = parse_ghostty_defaults("cursor-style = block_hollow\n");
        assert_eq!(hollow.cursor_style, Some(CursorShape::BlockHollow));
    }

    #[test]
    fn scrollback_config_outcomes_preserve_precedence_and_timeout() {
        let dir = TestDirectory::new("scrollback-outcomes");
        let value_path = dir.path.join("value.conf");
        let empty_path = dir.path.join("empty.conf");
        let absent_path = dir.path.join("absent.conf");
        std::fs::write(&value_path, "scrollback-limit = 123_456\n").unwrap();
        std::fs::write(&empty_path, "scrollback-limit = \"\"\n").unwrap();
        std::fs::write(&absent_path, "foreground = #010203\n").unwrap();

        assert_eq!(
            parse_scrollback_limit_from_root(&value_path, Instant::now() + Duration::from_secs(1)),
            ScrollbackConfigOutcome::Parsed(Some(Some(123_456)))
        );
        assert_eq!(
            parse_scrollback_limit_from_root(&absent_path, Instant::now() + Duration::from_secs(1)),
            ScrollbackConfigOutcome::Parsed(None)
        );
        assert_eq!(
            parse_scrollback_limit_from_root(&empty_path, Instant::now() + Duration::from_secs(1)),
            ScrollbackConfigOutcome::Parsed(Some(None))
        );
        assert_eq!(
            parse_scrollback_limit_from_root(&value_path, Instant::now() - Duration::from_secs(1)),
            ScrollbackConfigOutcome::TimedOut
        );
    }

    #[test]
    fn scrollback_include_order_matches_ghostty_recursive_loading() {
        let dir = TestDirectory::new("scrollback-include-order");
        let root = dir.path.join("config");
        let first = dir.path.join("first.conf");
        let second = dir.path.join("second.conf");
        let nested = dir.path.join("nested.conf");
        std::fs::write(
            &root,
            "config-file = first.conf\n\
             scrollback-limit = 1\n\
             config-file = second.conf\n",
        )
        .unwrap();
        std::fs::write(&first, "scrollback-limit = 2\nconfig-file = nested.conf\n").unwrap();
        std::fs::write(&second, "scrollback-limit = 3\n").unwrap();
        std::fs::write(&nested, "scrollback-limit = 4\n").unwrap();

        assert_eq!(
            parse_scrollback_limit_from_root(&root, Instant::now() + Duration::from_secs(1)),
            ScrollbackConfigOutcome::Parsed(Some(Some(4)))
        );
    }

    #[test]
    fn application_defaults_snapshot_resolves_colors_and_scrollback_together() {
        let dir = TestDirectory::new("application-defaults-snapshot");
        let root = dir.path.join("config");
        let include = dir.path.join("scrollback.conf");
        std::fs::write(&root, "foreground = #010203\nconfig-file = scrollback.conf\n").unwrap();
        std::fs::write(&include, "scrollback-limit-bytes = 654321\n").unwrap();

        let mut scrollback = None;
        let outcome = parse_ghostty_defaults_from_path_result_until_with_scrollback(
            &root,
            &[],
            Some(Instant::now() + Duration::from_secs(1)),
            Some(&mut scrollback),
        );
        let GhosttyConfigParseOutcome::Parsed(colors) = outcome else {
            panic!("snapshot should parse");
        };
        assert_eq!(colors.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(scrollback, Some(Some(654321)));
    }

    #[test]
    fn application_defaults_overlay_later_config_and_resolve_fallbacks() {
        let dir = TestDirectory::new("application-defaults-overlay");
        let legacy = dir.path.join("config");
        let current = dir.path.join("config.ghostty");
        std::fs::write(&legacy, "foreground = #010203\n").unwrap();
        std::fs::write(&current, "foreground = #070809\nbackground = #040506\n").unwrap();

        let defaults =
            parse_ghostty_application_defaults_from_paths(vec![legacy, current], Vec::new())
                .expect("config files should parse");
        assert_eq!(defaults.colors.fg, Some(Rgb { r: 7, g: 8, b: 9 }));
        assert_eq!(defaults.colors.bg, Some(Rgb { r: 4, g: 5, b: 6 }));
        assert_eq!(defaults.colors.cursor_style, Some(CursorShape::Block));
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

        let output = ghostty_show_config_command(&platform::GhosttyInstallation {
            binary,
            resources_dir: Some(resources.clone()),
        })
        .output()
        .unwrap();
        assert!(output.status.success());
        let output = String::from_utf8(output.stdout).unwrap();
        assert!(output.contains(&format!("resource-path = {}", resources.display())));
        let defaults = parse_resolved_ghostty_defaults(&output);
        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn ghostty_resolver_drains_output_while_the_child_is_running() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-large-output-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let binary = root.join("ghostty-config-helper");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            &binary,
            "#!/bin/sh\n\
             i=0\n\
             while [ \"$i\" -lt 2048 ]; do\n\
               printf 'palette = 1=#010203\\n'\n\
               i=$((i + 1))\n\
             done\n\
             printf 'background = #272822\\nforeground = #fdfff1\\n'\n",
        )
        .unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();

        let mut command = Command::new(&binary);
        command.stdout(Stdio::piped()).stderr(Stdio::null());
        let defaults = match ghostty_defaults_from_helper_command(command, Duration::from_secs(2)) {
            GhosttyHelperDefaults::Resolved(defaults) => defaults.colors,
            GhosttyHelperDefaults::Unavailable => panic!("helper output was not parsed"),
            GhosttyHelperDefaults::TimedOut => panic!("helper output timed out"),
        };
        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn unusable_packaged_ghostty_resolver_falls_through() {
        let broken = PathBuf::from("/cmux-test/copied-app-binary");
        let working = PathBuf::from("/cmux-test/standalone-cli-helper");
        let installations = [
            platform::GhosttyInstallation { binary: broken.clone(), resources_dir: None },
            platform::GhosttyInstallation { binary: working.clone(), resources_dir: None },
        ];
        let mut visited = Vec::new();
        let defaults = resolved_ghostty_defaults_from_with(&installations, |installation| {
            visited.push(installation.binary.clone());
            if installation.binary == broken {
                Some(String::new())
            } else {
                Some("background = #272822\nforeground = #fdfff1\n".to_owned())
            }
        })
        .unwrap();

        assert_eq!(visited, vec![broken, working]);
        assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
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
        surface
            .try_with_terminal(|term| {
                term.vt_write(b"\x1b[31mR");
                term.vt_write(b"\x1b_Ga=T,t=d,f=32,i=75,p=1,s=1,v=1,c=1,r=1,q=2;/wAAfw==\x1b\\");
            })
            .unwrap();
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
        assert_eq!(state["graphics"]["images"][0]["id"], 75);
        assert_eq!(state["graphics"]["images"][0]["format"], "rgba");
        assert_eq!(state["graphics"]["images"][0]["data"], "/wAAfw==");
        assert_eq!(state["graphics"]["placements"][0]["image_id"], 75);

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

    #[cfg(unix)]
    #[test]
    fn load_uses_file_ghostty_defaults_without_invoking_external_resolver() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
        let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
        let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir()
            .join(format!("mux-ghostty-startup-file-only-{}", std::process::id()));
        let ghostty_dir = dir.join("ghostty");
        let marker = dir.join("resolver-ran");
        let resolver = dir.join("ghostty-resolver");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::write(ghostty_dir.join("config"), "foreground = #010203\n").unwrap();
        std::fs::write(
            &resolver,
            format!(
                "#!/bin/sh\n\
                 printf marker > '{}'\n\
                 printf 'foreground = #aabbcc\\nbackground = #ddeeff\\n'\n",
                marker.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&resolver, std::fs::Permissions::from_mode(0o700)).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("GHOSTTY_RESOURCES_DIR") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

        let config = load();

        restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
        restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
        restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let resolver_ran = marker.exists();
        let _ = std::fs::remove_dir_all(&dir);

        assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
        assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(config.terminal_defaults.bg, None);
    }

    #[cfg(unix)]
    #[test]
    fn load_resolves_ghostty_resource_theme_without_invoking_external_resolver() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
        let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
        let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir()
            .join(format!("mux-ghostty-startup-resource-theme-{}", std::process::id()));
        let ghostty_dir = dir.join("ghostty");
        let resources = dir.join("resources");
        let themes = resources.join("themes");
        let marker = dir.join("resolver-ran");
        let resolver = dir.join("ghostty-resolver");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&themes).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "window-theme = light\n\
             theme = dark:Dark Resource Theme, light:Light Resource Theme\n\
             background = #444444\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Light Resource Theme"),
            "foreground = #111111\nbackground = #222222\npalette = 1=#333333\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Dark Resource Theme"),
            "foreground = #aaaaaa\nbackground = #bbbbbb\npalette = 1=#cccccc\n",
        )
        .unwrap();
        std::fs::write(
            &resolver,
            format!(
                "#!/bin/sh\n\
                 printf marker > '{}'\n\
                 printf 'foreground = #ddeeff\\nbackground = #000000\\n'\n",
                marker.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&resolver, std::fs::Permissions::from_mode(0o700)).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("GHOSTTY_RESOURCES_DIR", &resources) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };
        let theme_dirs = platform::ghostty_theme_dirs();
        assert!(theme_dirs.contains(&themes), "{theme_dirs:?}");

        let config = load();

        restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
        restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
        restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let resolver_ran = marker.exists();
        let _ = std::fs::remove_dir_all(&dir);

        assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
        assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 0x11, g: 0x11, b: 0x11 }));
        assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x44, g: 0x44, b: 0x44 }));
        assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0x33, g: 0x33, b: 0x33 }));
    }

    #[cfg(unix)]
    #[test]
    fn load_applies_ghostty_config_file_after_root_and_respects_dark_theme_mode() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_ghostty_bin = std::env::var_os("GHOSTTY_BIN");
        let old_ghostty_resources = std::env::var_os("GHOSTTY_RESOURCES_DIR");
        let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir()
            .join(format!("mux-ghostty-startup-include-theme-{}", std::process::id()));
        let ghostty_dir = dir.join("ghostty");
        let resources = dir.join("resources");
        let themes = resources.join("themes");
        let marker = dir.join("resolver-ran");
        let resolver = dir.join("ghostty-resolver");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&themes).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "foreground = #010101\n\
             config-file = colors.conf\n\
             background = #020202\n",
        )
        .unwrap();
        std::fs::write(
            ghostty_dir.join("colors.conf"),
            "window-theme = dark\n\
             theme = light:Light Include Theme,dark:Dark Include Theme\n\
             background = #444444\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Light Include Theme"),
            "foreground = #111111\nbackground = #222222\npalette = 1=#333333\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Dark Include Theme"),
            "foreground = #aaaaaa\nbackground = #bbbbbb\npalette = 1=#cccccc\n",
        )
        .unwrap();
        std::fs::write(
            &resolver,
            format!(
                "#!/bin/sh\n\
                 printf marker > '{}'\n\
                 printf 'foreground = #ddeeff\\nbackground = #000000\\n'\n",
                marker.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&resolver, std::fs::Permissions::from_mode(0o700)).unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("GHOSTTY_BIN", &resolver) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("GHOSTTY_RESOURCES_DIR", &resources) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_TUI_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

        let config = load();

        restore_env_var("GHOSTTY_BIN", old_ghostty_bin);
        restore_env_var("GHOSTTY_RESOURCES_DIR", old_ghostty_resources);
        restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        restore_env_var("XDG_CONFIG_HOME", old_xdg_config_home);
        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let resolver_ran = marker.exists();
        let _ = std::fs::remove_dir_all(&dir);

        assert!(!resolver_ran, "config load must not run ghostty +show-config at startup");
        assert_eq!(config.terminal_defaults.fg, Some(Rgb { r: 0x01, g: 0x01, b: 0x01 }));
        assert_eq!(config.terminal_defaults.bg, Some(Rgb { r: 0x44, g: 0x44, b: 0x44 }));
        assert_eq!(config.terminal_defaults.palette[1], Some(Rgb { r: 0xcc, g: 0xcc, b: 0xcc }));
    }

    #[test]
    fn ghostty_fallback_theme_selection_skips_unreadable_themes() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-missing-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Readable Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_with_theme_dirs(
            "theme = Missing Theme\n\
             theme = Readable Theme\n",
            std::slice::from_ref(&dir),
        );

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
    }

    #[test]
    fn ghostty_included_config_cannot_replace_successful_root_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-include-first-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        let themes = dir.join("themes");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&themes).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "window-theme = light\n\
             theme = Root Theme\n\
             config-file = colors.conf\n",
        )
        .unwrap();
        std::fs::write(
            ghostty_dir.join("colors.conf"),
            "theme = Include Theme\n\
             foreground = #303132\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Root Theme"),
            "background = #202122\nforeground = #232425\npalette = 1=#262728\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Include Theme"),
            "background = #909192\nforeground = #939495\npalette = 1=#969798\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0x20, g: 0x21, b: 0x22 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0x30, g: 0x31, b: 0x32 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x26, g: 0x27, b: 0x28 }));
    }

    #[test]
    fn ghostty_parent_explicit_color_wins_over_theme_loaded_by_include() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-include-overrides-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        let themes = dir.join("themes");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&themes).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "window-theme = dark\n\
             foreground = #010203\n\
             config-file = colors.conf\n",
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("colors.conf"), "theme = Include Theme\n").unwrap();
        std::fs::write(
            themes.join("Include Theme"),
            "background = #202122\nforeground = #a0a1a2\npalette = 1=#232425\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x20, g: 0x21, b: 0x22 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x23, g: 0x24, b: 0x25 }));
    }

    #[test]
    fn ghostty_included_window_theme_does_not_control_parent_conditional_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-include-window-theme-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        let themes = dir.join("themes");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&themes).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "theme = light:Root Light Theme,dark:Root Dark Theme\n\
             config-file = colors.conf\n",
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("colors.conf"), "window-theme = dark\n").unwrap();
        std::fs::write(
            themes.join("Root Light Theme"),
            "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Root Dark Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[themes])
            .expect("config parses");

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0xf0, g: 0xf1, b: 0xf2 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf6, g: 0xf7, b: 0xf8 }));
    }

    #[test]
    fn ghostty_window_theme_does_not_control_conditional_terminal_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-invalid-window-theme-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Light Theme"),
            "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("Dark Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

        let defaults = parse_ghostty_defaults_with_theme_dirs(
            "window-theme = dark\n\
             window-theme = drak\n\
             theme = light:Light Theme,dark:Dark Theme\n",
            std::slice::from_ref(&dir),
        );

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0xf0, g: 0xf1, b: 0xf2 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0xf6, g: 0xf7, b: 0xf8 }));
    }

    #[test]
    fn ghostty_config_file_expands_required_and_optional_home_relative_paths() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_home = std::env::var_os("HOME");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-home-include-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let home = dir.join("home");
        let ghostty_dir = dir.join("ghostty");
        let include_dir = home.join(".config").join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::create_dir_all(&include_dir).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "config-file = ~/.config/ghostty/colors.conf\n\
             config-file = ?~/.config/ghostty/missing.conf\n",
        )
        .unwrap();
        std::fs::write(
            include_dir.join("colors.conf"),
            "foreground = #010203\nbackground = #040506\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("HOME", &home) };

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses");

        restore_env_var("HOME", old_home);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    }

    #[test]
    fn ghostty_relative_theme_path_uses_declaring_config_directory() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-relative-theme-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        let nested_dir = ghostty_dir.join("nested");
        let nested_themes = nested_dir.join("themes");
        std::fs::create_dir_all(&nested_themes).unwrap();
        std::fs::write(ghostty_dir.join("config"), "config-file = nested/colors.conf\n").unwrap();
        std::fs::write(nested_dir.join("colors.conf"), "theme = ./themes/custom\n").unwrap();
        std::fs::write(
            nested_themes.join("custom"),
            "foreground = #111213\nbackground = #141516\npalette = 1=#171819\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x11, g: 0x12, b: 0x13 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x14, g: 0x15, b: 0x16 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x17, g: 0x18, b: 0x19 }));
    }

    #[test]
    fn ghostty_config_file_skips_non_regular_includes() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-nonregular-include-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(ghostty_dir.join("not-a-file")).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "config-file = not-a-file\n\
             config-file = colors.conf\n",
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("colors.conf"), "foreground = #010203\n").unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    }

    #[test]
    fn ghostty_config_file_depth_limit_bounds_include_chain() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-depth-limit-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        for index in 0..=(GHOSTTY_CONFIG_MAX_DEPTH + 2) {
            let color = 0x10 + index as u8;
            let include = if index < GHOSTTY_CONFIG_MAX_DEPTH + 2 {
                format!("config-file = file{}.conf\n", index + 1)
            } else {
                String::new()
            };
            std::fs::write(
                ghostty_dir.join(format!("file{index}.conf")),
                format!("foreground = #{color:02x}{color:02x}{color:02x}\n{include}"),
            )
            .unwrap();
        }

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("file0.conf"), &[])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);
        let color = 0x10 + GHOSTTY_CONFIG_MAX_DEPTH as u8;

        assert_eq!(defaults.fg, Some(Rgb { r: color, g: color, b: color }));
    }

    #[test]
    fn ghostty_config_file_count_limit_bounds_broad_include_graph() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-file-count-limit-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        let include_count = GHOSTTY_CONFIG_MAX_FILES + 2;
        let mut root = String::new();
        for index in 0..include_count {
            root.push_str(&format!("config-file = colors{index}.conf\n"));
            let color = 0x10 + index as u8;
            std::fs::write(
                ghostty_dir.join(format!("colors{index}.conf")),
                format!("foreground = #{color:02x}{color:02x}{color:02x}\n"),
            )
            .unwrap();
        }
        std::fs::write(ghostty_dir.join("config"), root).unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);
        let expected_index = GHOSTTY_CONFIG_MAX_FILES - 2;
        let color = 0x10 + expected_index as u8;

        assert_eq!(defaults.fg, Some(Rgb { r: color, g: color, b: color }));
    }

    #[test]
    fn ghostty_config_file_size_limit_skips_oversized_includes() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-size-limit-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "config-file = small.conf\n\
             config-file = large.conf\n\
             config-file = later.conf\n",
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("small.conf"), "foreground = #010203\n").unwrap();
        std::fs::write(
            ghostty_dir.join("large.conf"),
            "background = #a0a1a2\n".repeat((GHOSTTY_CONFIG_MAX_BYTES as usize / 20) + 1),
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("later.conf"), "background = #040506\n").unwrap();

        let defaults = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    }

    #[test]
    fn ghostty_config_parse_deadline_discards_partial_defaults() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-deadline-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        std::fs::create_dir_all(&ghostty_dir).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "background = #010203\nconfig-file = colors.conf\n",
        )
        .unwrap();
        std::fs::write(ghostty_dir.join("colors.conf"), "foreground = #040506\n").unwrap();

        let mut theme_candidates = Vec::new();
        let outcome = parse_ghostty_config_file_with_deadline(
            &ghostty_dir.join("config"),
            &mut theme_candidates,
            Duration::ZERO,
        );
        let full = parse_ghostty_defaults_from_path(&ghostty_dir.join("config"), &[])
            .expect("config parses without deadline pressure");

        let _ = std::fs::remove_dir_all(dir);

        assert!(matches!(outcome, GhosttyConfigParseOutcome::TimedOut));
        assert_eq!(full.bg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(full.fg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    }

    #[test]
    fn ghostty_theme_deadline_keeps_parsed_overrides() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-deadline-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Dark Budget Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();
        let overrides = DefaultColors {
            fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
            bg: Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }),
            ..Default::default()
        };

        let loaded = resolve_parsed_ghostty_defaults(
            vec![GhosttyThemeCandidate { value: "Dark Budget Theme".to_string(), base_dir: None }],
            std::slice::from_ref(&dir),
            overrides,
            None,
        );
        let expired = resolve_parsed_ghostty_defaults(
            vec![GhosttyThemeCandidate { value: "Dark Budget Theme".to_string(), base_dir: None }],
            std::slice::from_ref(&dir),
            overrides,
            Some(Instant::now().checked_sub(Duration::from_millis(1)).unwrap()),
        );

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(loaded.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
        assert_eq!(expired.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(expired.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
        assert_eq!(expired.palette[1], None);
    }

    #[test]
    fn ghostty_file_reader_enforces_byte_limit_during_read() {
        let text = "foreground = #010203\n";
        assert_eq!(
            read_ghostty_limited_string(text.as_bytes(), text.len() as u64),
            Some(text.to_string())
        );
        assert_eq!(read_ghostty_limited_string(text.as_bytes(), text.len() as u64 - 1), None);
    }

    #[test]
    fn ghostty_theme_loader_skips_non_regular_and_oversized_candidates() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-size-limit-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        let ghostty_dir = dir.join("ghostty");
        let themes = ghostty_dir.join("themes");
        std::fs::create_dir_all(themes.join("Theme Directory")).unwrap();
        std::fs::write(
            ghostty_dir.join("config"),
            "theme = Theme Directory\n\
             theme = Huge Theme\n\
             theme = Readable Theme\n",
        )
        .unwrap();
        std::fs::write(
            themes.join("Huge Theme"),
            "foreground = #a0a1a2\n".repeat((GHOSTTY_CONFIG_MAX_BYTES as usize / 20) + 1),
        )
        .unwrap();
        std::fs::write(
            themes.join("Readable Theme"),
            "foreground = #010203\nbackground = #040506\n",
        )
        .unwrap();

        let defaults = parse_ghostty_defaults_from_path(
            &ghostty_dir.join("config"),
            std::slice::from_ref(&themes),
        )
        .expect("config parses");

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    }

    #[cfg(unix)]
    #[test]
    fn ghostty_config_helper_scrubs_provider_secret_environment() {
        let output = {
            let mut command = Command::new("/usr/bin/env");
            command
                .env("CMUX_MACHINE_PROVIDER_TOKEN", "edge-test-bearer")
                .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-workspace-authority-test")
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            scrub_ghostty_helper_secret_environment(&mut command);
            command.output().unwrap()
        };
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(!stdout.contains("CMUX_MACHINE_PROVIDER_TOKEN="), "{stdout}");
        assert!(!stdout.contains("CMUX_PROVIDER_WORKSPACE_AUTHORITY="), "{stdout}");
    }

    #[cfg(unix)]
    fn wait_for_helper_ready_pid(
        stdout: std::process::ChildStdout,
        marker: &'static str,
    ) -> libc::pid_t {
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("cmux-tui-ghostty-test-ready-reader".to_string())
            .spawn(move || {
                use std::io::{BufRead, BufReader};

                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    let Some(pid) = line.strip_prefix(marker) else {
                        continue;
                    };
                    if let Ok(pid) = pid.trim().parse::<libc::pid_t>() {
                        let _ = ready_sender.send(pid);
                        return;
                    }
                }
            })
            .unwrap();
        ready_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("helper did not publish its ready pid")
    }

    #[cfg(unix)]
    fn wait_for_helper_reaped(reaped_receiver: mpsc::Receiver<()>) {
        reaped_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("helper reaper did not publish completion");
    }

    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    struct TestProcessExit {
        descriptor: std::os::fd::OwnedFd,
    }

    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    impl TestProcessExit {
        fn observe(pid: libc::pid_t) -> Option<Self> {
            use std::os::fd::FromRawFd;

            #[cfg(target_os = "linux")]
            // SAFETY: pidfd_open observes the supplied live test child and
            // returns a new descriptor without modifying process state.
            let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
            #[cfg(target_vendor = "apple")]
            // SAFETY: kqueue returns a new descriptor without external state.
            let descriptor = unsafe { libc::kqueue() };
            #[cfg(target_os = "linux")]
            if descriptor < 0 {
                let error = std::io::Error::last_os_error();
                if matches!(error.raw_os_error(), Some(libc::ENOSYS) | Some(libc::EPERM)) {
                    return None;
                }
                panic!("observe helper child {pid}: {error}");
            }
            #[cfg(target_vendor = "apple")]
            assert!(
                descriptor >= 0,
                "observe helper child {pid}: {}",
                std::io::Error::last_os_error()
            );
            // SAFETY: pidfd_open and kqueue return a new owned descriptor.
            let descriptor =
                unsafe { std::os::fd::OwnedFd::from_raw_fd(descriptor as libc::c_int) };

            #[cfg(target_vendor = "apple")]
            {
                use std::os::fd::AsRawFd;

                let change = libc::kevent {
                    ident: pid as libc::uintptr_t,
                    filter: libc::EVFILT_PROC,
                    flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                    fflags: libc::NOTE_EXIT,
                    data: 0,
                    udata: std::ptr::null_mut(),
                };
                let registered = unsafe {
                    libc::kevent(
                        descriptor.as_raw_fd(),
                        &raw const change,
                        1,
                        std::ptr::null_mut(),
                        0,
                        std::ptr::null(),
                    )
                };
                assert!(
                    registered >= 0,
                    "register helper child {pid} exit: {}",
                    std::io::Error::last_os_error()
                );
            }

            Some(Self { descriptor })
        }

        fn wait(self, timeout: Duration) {
            use std::os::fd::AsRawFd;

            #[cfg(target_os = "linux")]
            let ready = {
                let mut descriptor = libc::pollfd {
                    fd: self.descriptor.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let timeout_ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
                unsafe { libc::poll(&raw mut descriptor, 1, timeout_ms) }
            };
            #[cfg(target_vendor = "apple")]
            let ready = {
                // SAFETY: kevent fully initializes the event before it is read.
                let mut event = unsafe { std::mem::zeroed::<libc::kevent>() };
                let timeout = libc::timespec {
                    tv_sec: timeout.as_secs().try_into().unwrap_or(libc::time_t::MAX),
                    tv_nsec: timeout.subsec_nanos().into(),
                };
                unsafe {
                    libc::kevent(
                        self.descriptor.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        &raw mut event,
                        1,
                        &raw const timeout,
                    )
                }
            };
            assert!(ready > 0, "helper child did not exit before the final deadline");
        }
    }

    #[cfg(unix)]
    #[test]
    fn ghostty_config_helper_cleanup_reaps_killed_child() {
        let child = Command::new("/bin/sleep").arg("5").spawn().unwrap();
        let pid = child.id() as libc::pid_t;

        let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
        wait_for_helper_reaped(reaped_receiver);

        assert!(!unix_process_exists(pid), "helper child {pid} was not reaped");
    }

    #[cfg(unix)]
    #[test]
    fn ghostty_process_scan_cleanup_reaps_killed_child() {
        let mut command = Command::new("/bin/sleep");
        command.arg("5").process_group(0);
        let child = command.spawn().unwrap();
        let pid = child.id() as libc::pid_t;

        let reaped_receiver = terminate_ghostty_process_scan_child_with_reaped_signal(child);
        wait_for_helper_reaped(reaped_receiver);

        assert!(!unix_process_exists(pid), "process scan child {pid} was not reaped");
    }

    #[cfg(unix)]
    #[test]
    fn ghostty_config_helper_parent_deadline_allows_startup_margin() {
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "sleep 0.32; printf 'foreground=#010203\nbackground=#040506\n'"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0);

        let defaults =
            ghostty_defaults_from_helper_command(command, GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE);

        let GhosttyHelperDefaults::Resolved(defaults) = defaults else {
            panic!("helper should resolve within parent startup margin");
        };
        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn ghostty_desktop_probe_cleanup_kills_stdout_inheriting_child() {
        let (started_sender, started_receiver) = mpsc::sync_channel(1);
        let (reaped_sender, reaped_receiver) = mpsc::sync_channel(1);

        let started_at = Instant::now();
        let output = desktop_theme_command_output_with_lifecycle_signals(
            "/bin/sh",
            &["-c", "sleep 5 & printf \"'prefer-dark'\\n\"; exit 0"],
            Some(Instant::now() + Duration::from_secs(1)),
            Some(&started_sender),
            Some(&reaped_sender),
        );
        let child_group = started_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("desktop probe did not publish its process group")
            as libc::pid_t;
        wait_for_helper_reaped(reaped_receiver);

        assert_eq!(output, None);
        assert!(
            started_at.elapsed() < Duration::from_secs(1),
            "desktop probe output drain was not bounded"
        );

        assert!(
            !unix_process_group_is_live(child_group),
            "stdout-inheriting desktop probe group {child_group} was not killed"
        );
    }

    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    #[test]
    fn ghostty_config_helper_cleanup_reaps_process_group_children() {
        const READY_MARKER: &str = "CMUX_HELPER_READY:";
        let script = format!("sleep 5 & echo {READY_MARKER}$!; wait");
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).stdout(Stdio::piped()).process_group(0);
        let mut child = command.spawn().unwrap();
        let parent_pid = child.id() as libc::pid_t;
        let child_pid = wait_for_helper_ready_pid(child.stdout.take().unwrap(), READY_MARKER);
        let child_exit = TestProcessExit::observe(child_pid);

        let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
        wait_for_helper_reaped(reaped_receiver);
        if let Some(child_exit) = child_exit {
            child_exit.wait(Duration::from_secs(2));
            assert!(!unix_process_is_live(child_pid), "helper child {child_pid} was not killed");
        } else {
            crate::client_log::stderr_log!(
                "config",
                "skipped helper child {child_pid} exit postcondition: pidfd_open is unsupported"
            );
        }

        assert!(!unix_process_exists(parent_pid), "helper parent {parent_pid} was not reaped");
    }

    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    #[test]
    fn ghostty_config_helper_cleanup_kills_descendant_process_groups() {
        const CHILD_MARKER: &str = "CMUX_TEST_GHOSTTY_HELPER_DESCENDANT_GROUP";
        const READY_MARKER: &str = "CMUX_DESCENDANT_READY:";
        if std::env::var_os(CHILD_MARKER).is_some() {
            let mut command = Command::new("/bin/sleep");
            command.arg("5").process_group(0);
            let mut child = command.spawn().unwrap();
            println!("{READY_MARKER}{}", child.id());
            std::io::stdout().flush().unwrap();
            let _ = child.wait();
            return;
        }

        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "config::tests::ghostty_config_helper_cleanup_kills_descendant_process_groups",
                "--nocapture",
            ])
            .env(CHILD_MARKER, "1")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0);
        let mut child = command.spawn().unwrap();
        let parent_pid = child.id() as libc::pid_t;
        let child_pid = wait_for_helper_ready_pid(child.stdout.take().unwrap(), READY_MARKER);
        let child_exit = TestProcessExit::observe(child_pid);

        let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
        wait_for_helper_reaped(reaped_receiver);
        if let Some(child_exit) = child_exit {
            child_exit.wait(Duration::from_secs(2));
            assert!(
                !unix_process_is_live(child_pid),
                "descendant process-group child {child_pid} was not killed"
            );
        } else {
            crate::client_log::stderr_log!(
                "config",
                "skipped descendant process-group child {child_pid} exit postcondition: \
                 pidfd_open is unsupported"
            );
        }

        assert!(!unix_process_exists(parent_pid), "helper parent {parent_pid} was not reaped");
    }

    #[cfg(unix)]
    fn unix_process_is_live(pid: libc::pid_t) -> bool {
        if !unix_process_exists(pid) {
            return false;
        }
        let Ok(output) =
            Command::new("/bin/ps").args(["-o", "stat=", "-p", &pid.to_string()]).output()
        else {
            return true;
        };
        if !output.status.success() {
            return unix_process_exists(pid);
        }
        let stat = String::from_utf8_lossy(&output.stdout);
        !stat.trim_start().starts_with('Z')
    }

    #[cfg(unix)]
    fn unix_process_exists(pid: libc::pid_t) -> bool {
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    fn unix_process_group_is_live(group: libc::pid_t) -> bool {
        let Ok(output) = Command::new("/bin/ps").args(["-axo", "pgid=,stat="]).output() else {
            return unsafe { libc::killpg(group, 0) } == 0;
        };
        if !output.status.success() {
            return unsafe { libc::killpg(group, 0) } == 0;
        }
        String::from_utf8_lossy(&output.stdout).lines().any(|line| {
            let mut parts = line.split_whitespace();
            parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) == Some(group)
                && parts.next().is_some_and(|status| !status.starts_with('Z'))
        })
    }

    #[test]
    fn ghostty_config_helper_output_reader_drains_large_palette() {
        let mut output = String::new();
        for index in 0..256 {
            output.push_str(&format!("palette.{index}=#010203\n"));
        }
        assert!(output.len() > 4 * 1024);

        let reader =
            read_ghostty_helper_output_async(std::io::Cursor::new(output.clone())).unwrap();

        assert_eq!(reader.wait(), Some(output));
    }

    #[test]
    fn ghostty_config_helper_output_reader_enforces_byte_limit() {
        let output = "x".repeat(GHOSTTY_HELPER_OUTPUT_MAX_BYTES as usize + 1);

        let reader = read_ghostty_helper_output_async(std::io::Cursor::new(output)).unwrap();

        assert_eq!(reader.wait(), None);
    }

    #[test]
    fn ghostty_defaults_falls_back_to_files_when_helper_is_unavailable() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-helper-fallback-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config");
        std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();

        let defaults = ghostty_defaults_from_sources(
            vec![config],
            Vec::new(),
            GhosttyHelperDefaults::Unavailable,
        );

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
        assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
    }

    #[test]
    fn ghostty_defaults_use_helper_result_before_file_fallback() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-helper-result-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config");
        std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();
        let helper = DefaultColors {
            fg: Some(Rgb { r: 0xa0, g: 0xa1, b: 0xa2 }),
            bg: Some(Rgb { r: 0xb0, g: 0xb1, b: 0xb2 }),
            ..Default::default()
        };

        let defaults = ghostty_defaults_from_sources(
            vec![config],
            Vec::new(),
            GhosttyHelperDefaults::Resolved(Box::new(GhosttyApplicationDefaults {
                colors: helper,
                scrollback_limit_bytes: None,
            })),
        );

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, Some(Rgb { r: 0xa0, g: 0xa1, b: 0xa2 }));
        assert_eq!(defaults.bg, Some(Rgb { r: 0xb0, g: 0xb1, b: 0xb2 }));
        assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
    }

    #[test]
    fn ghostty_defaults_do_not_retry_files_after_helper_timeout() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-helper-timeout-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("config");
        std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();

        let defaults = ghostty_defaults_from_sources(
            vec![config],
            Vec::new(),
            GhosttyHelperDefaults::TimedOut,
        );

        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.fg, None);
        assert_eq!(defaults.bg, None);
        assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
    }

    #[test]
    fn ghostty_automatic_window_theme_uses_detected_dark_mode_for_conditional_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-auto-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Light Auto Theme"),
            "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("Dark Auto Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

        let defaults = parse_ghostty_defaults_with_theme_dirs(
            "window-theme = auto\n\
             theme = light:Light Auto Theme,dark:Dark Auto Theme\n",
            std::slice::from_ref(&dir),
        );

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
    }

    #[test]
    fn ghostty_conditional_terminal_theme_ignores_ghostty_window_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-window-ghostty-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Light Window Theme"),
            "background = #f0f1f2\nforeground = #f3f4f5\npalette = 1=#f6f7f8\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("Dark Window Theme"),
            "background = #101112\nforeground = #131415\npalette = 1=#161718\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

        let defaults = parse_ghostty_defaults_with_theme_dirs(
            "window-theme = ghostty\n\
             theme = light:Light Window Theme,dark:Dark Window Theme\n",
            std::slice::from_ref(&dir),
        );

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(defaults.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
        assert_eq!(defaults.fg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
        assert_eq!(defaults.palette[1], Some(Rgb { r: 0x16, g: 0x17, b: 0x18 }));
    }

    #[test]
    fn ghostty_fixed_theme_selection_does_not_require_appearance_budget() {
        let expired = Instant::now().checked_sub(Duration::from_millis(1)).unwrap();
        let mut theme_mode = None;

        let selected = selected_ghostty_theme("Monokai", Some(expired), &mut theme_mode);

        assert_eq!(selected, "Monokai");
        assert_eq!(theme_mode, None);
    }

    #[test]
    fn ghostty_conditional_theme_selection_reuses_cached_appearance_mode() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let mut theme_mode = None;
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

        let missing = selected_ghostty_theme(
            "light:Missing Light Theme,dark:Missing Dark Theme",
            None,
            &mut theme_mode,
        );
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };
        let fallback = selected_ghostty_theme(
            "light:Light Fallback Theme,dark:Dark Fallback Theme",
            None,
            &mut theme_mode,
        );

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

        assert_eq!(missing, "Missing Dark Theme");
        assert_eq!(fallback, "Dark Fallback Theme");
        assert_eq!(theme_mode, Some(GhosttyThemeMode::Dark));
    }

    #[test]
    fn ghostty_system_theme_uses_platform_appearance() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::remove_var("AppleInterfaceStyle") };

        let mode = system_ghostty_theme_mode_with_platform(|| Some(GhosttyThemeMode::Light));

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

        assert_eq!(mode, GhosttyThemeMode::Light);
    }

    #[test]
    fn ghostty_system_theme_uses_environment_before_platform_probe() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let mut platform_calls = 0;
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Dark") };

        let mode = system_ghostty_theme_mode_with_platform(|| {
            platform_calls += 1;
            Some(GhosttyThemeMode::Light)
        });

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);

        assert_eq!(mode, GhosttyThemeMode::Dark);
        assert_eq!(platform_calls, 0);
    }

    #[test]
    fn ghostty_background_luminance_matches_ghostty_threshold() {
        assert!(ghostty_background_is_light(Rgb { r: 255, g: 255, b: 255 }));
        assert!(!ghostty_background_is_light(Rgb { r: 0, g: 0, b: 0 }));
        assert!(!ghostty_background_is_light(Rgb { r: 0x28, g: 0x2c, b: 0x34 }));
    }

    #[test]
    fn ghostty_non_macos_desktop_sources_detect_system_theme_mode() {
        assert_eq!(
            freedesktop_portal_color_scheme_theme_mode("(<'uint32 1'>,)"),
            Some(GhosttyThemeMode::Dark)
        );
        assert_eq!(
            freedesktop_portal_color_scheme_theme_mode("(<uint32 2>,)"),
            Some(GhosttyThemeMode::Light)
        );
        assert_eq!(
            gnome_color_scheme_output_theme_mode("'prefer-dark'\n"),
            Some(GhosttyThemeMode::Dark)
        );
        assert_eq!(gnome_color_scheme_output_theme_mode("'default'\n"), None);
        assert_eq!(
            gtk_settings_theme_mode("[Settings]\ngtk-application-prefer-dark-theme=1\n"),
            Some(GhosttyThemeMode::Dark)
        );
        assert_eq!(
            gtk_settings_theme_mode(
                "[Settings]\ngtk-application-prefer-dark-theme=false\ngtk-theme-name=Adwaita-dark\n"
            ),
            Some(GhosttyThemeMode::Dark)
        );
        assert_eq!(
            gtk_settings_theme_mode("[Settings]\ngtk-application-prefer-dark-theme=0\n"),
            None
        );
        assert_eq!(
            gtk_settings_theme_mode("[Settings]\ngtk-theme-name=Adwaita-dark\n"),
            Some(GhosttyThemeMode::Dark)
        );
        assert_eq!(gtk_theme_name_theme_mode("Adwaita:dark"), Some(GhosttyThemeMode::Dark));
        assert_eq!(gtk_theme_name_theme_mode("Yaru-light"), Some(GhosttyThemeMode::Light));
        assert_eq!(
            kde_globals_text_theme_mode("[General]\nColorScheme=BreezeDark\n"),
            Some(GhosttyThemeMode::Dark)
        );
    }

    #[test]
    fn ghostty_window_theme_does_not_use_resolved_background_for_terminal_theme() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_apple_interface_style = std::env::var_os("AppleInterfaceStyle");
        let dir = std::env::temp_dir().join(format!(
            "cmux-tui-ghostty-theme-source-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Light Source Theme"),
            "background = #f0f1f2\nforeground = #f3f4f5\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("Dark Source Theme"),
            "background = #101112\nforeground = #131415\n",
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("AppleInterfaceStyle", "Light") };

        let system = parse_ghostty_defaults_with_theme_dirs(
            "window-theme = system\n\
             background = #101112\n\
             theme = light:Light Source Theme,dark:Dark Source Theme\n",
            std::slice::from_ref(&dir),
        );
        let ghostty = parse_ghostty_defaults_with_theme_dirs(
            "window-theme = ghostty\n\
             background = #101112\n\
             theme = light:Light Source Theme,dark:Dark Source Theme\n",
            std::slice::from_ref(&dir),
        );

        restore_env_var("AppleInterfaceStyle", old_apple_interface_style);
        let _ = std::fs::remove_dir_all(dir);

        assert_eq!(system.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
        assert_eq!(system.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
        assert_eq!(ghostty.bg, Some(Rgb { r: 0x10, g: 0x11, b: 0x12 }));
        assert_eq!(ghostty.fg, Some(Rgb { r: 0xf3, g: 0xf4, b: 0xf5 }));
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
    fn machine_provider_command_parses_and_requires_a_program() {
        let raw: RawConfig = serde_json::from_str(
            r#"{"machine_provider":{"command":["/opt/provider/run.sh","--profile","prod"]}}"#,
        )
        .unwrap();
        assert_eq!(
            raw.machine_provider.command.as_deref(),
            Some(
                ["/opt/provider/run.sh".to_string(), "--profile".into(), "prod".into()].as_slice()
            )
        );

        // An empty argv or blank program is ignored at apply time.
        let raw: RawConfig =
            serde_json::from_str(r#"{"machine_provider":{"command":[]}}"#).unwrap();
        assert!(raw.machine_provider.command.as_deref().is_some_and(|c| c.is_empty()));
        let raw: RawConfig =
            serde_json::from_str(r#"{"machine_provider":{"command":["  "]}}"#).unwrap();
        assert!(raw.machine_provider.command.as_deref().is_some_and(|c| c[0].trim().is_empty()));
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
        assert_eq!(Action::select_tab(0).unwrap().tab_index(), Some(0));
        assert_eq!(Action::select_tab(9).unwrap().tab_index(), Some(9));
        assert!(Action::select_tab(10).is_none());
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
                    "tab_bg": 44,
                    "border_style": "rounded"
                },
                "tabs": {"min_width": 9, "solid_background": false},
                "sidebar": {
                    "view": "workspaces",
                    "width": 30,
                    "compact_width": 12,
                    "max_width": 38,
                    "columns": [
                        {"kind": "machines", "width": 18},
                        {"kind": "workspaces", "width": 24},
                        {"kind": "tabs", "width": 26, "max_width": 40}
                    ],
                    "plugin": {
                        "command": ["/tmp/sidebar-plugin", "--mode", "test"],
                        "cwd": "/tmp"
                    }
                },
                "machine_sidebar": {
                    "enabled": true,
                    "width": 26,
                    "max_width": 34,
                    "create_sources": [
                        {"id": "docker", "name": "Docker", "subtitle": "container prototype"},
                        {"id": "e2b", "name": "E2B"}
                    ]
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
                "pane": {"padding": 9},
                "status_bar": {"visible": false},
                "viewport": {"animation": false},
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
        assert_eq!(config.sidebar.compact_width, 12);
        assert_eq!(config.sidebar.max_width, 38);
        assert_eq!(config.sidebar.view, SidebarView::Workspaces);
        assert!(config.sidebar.columns_explicit);
        assert_eq!(
            config.sidebar.columns,
            vec![
                SidebarColumn { kind: SidebarColumnKind::Machines, width: 18, max_width: 34 },
                SidebarColumn { kind: SidebarColumnKind::Workspaces, width: 24, max_width: 38 },
                SidebarColumn { kind: SidebarColumnKind::Tabs, width: 26, max_width: 40 },
            ]
        );
        assert!(config.sidebar.views_explicit);
        assert_eq!(
            config.sidebar.views,
            vec![
                SidebarViewSpec::legacy(SidebarColumnKind::Machines, 18, 34),
                SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 24, 38),
                SidebarViewSpec::legacy(SidebarColumnKind::Tabs, 26, 40),
            ]
        );
        assert_eq!(
            config.machine_sidebar,
            MachineSidebar {
                enabled: true,
                width: 26,
                max_width: 34,
                create_sources: vec![
                    MachineCreationSourceConfig {
                        id: "docker".into(),
                        name: "Docker".into(),
                        subtitle: "container prototype".into(),
                    },
                    MachineCreationSourceConfig {
                        id: "e2b".into(),
                        name: "E2B".into(),
                        subtitle: String::new(),
                    },
                ],
            }
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
            MachineTargetConfig::Ssh { host, user: Some(user), session, binary, .. }
                if host == "mini.local"
                    && user == "lawrence"
                    && session == "main"
                    && binary == "~/.local/bin/cmux-tui"
        ));
        let plugin = config.sidebar.plugin.as_ref().expect("sidebar plugin config");
        assert_eq!(plugin.command, vec!["/tmp/sidebar-plugin", "--mode", "test"]);
        assert_eq!(plugin.cwd.as_deref(), Some("/tmp"));
        assert_eq!(config.scrollbar.position, ScrollbarPosition::Border);
        assert_eq!(config.theme.border_style, BorderStyle::Rounded);
        assert_eq!(config.pane.padding, MAX_PANE_PADDING, "padding clamps to the maximum");
        assert!(!config.status_bar.visible);
        assert!(!config.viewport.animation);
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)),
            Some(Action::RenameTab)
        );
        assert_eq!(config.keys.action_for(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)), None);
        assert_eq!(
            config.keys.action_for(&KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
            Action::select_tab(0)
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
    fn sidebar_views_parse_flat_columns_and_nested_resource_trees() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let dir =
            std::env::temp_dir().join(format!("cmux-sidebar-views-config-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmux-tui.json");
        std::fs::write(
            &path,
            r#"{
                "sidebar": {
                    "views": [
                        {
                            "id": "hosts",
                            "levels": ["machines"],
                            "width": 18,
                            "collapse_priority": 7
                        },
                        {
                            "id": "workspace-agents",
                            "levels": ["workspaces", "agents"],
                            "actions": ["new-workspace", "new-tab"],
                            "width": 28
                        },
                        {
                            "id": "workspace-pane-tabs",
                            "levels": ["workspaces", "panes", "tabs"],
                            "actions": [],
                            "width": 32,
                            "max_width": 44
                        }
                    ]
                }
            }"#,
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

        let config = load();

        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(config.sidebar.views_explicit);
        assert!(!config.sidebar.columns_explicit);
        assert_eq!(config.sidebar.views.len(), 3);
        assert_eq!(config.sidebar.views[0].id, "hosts");
        assert_eq!(config.sidebar.views[0].levels, vec![SidebarResourceKind::Machines]);
        assert_eq!(config.sidebar.views[0].width, 18);
        assert_eq!(config.sidebar.views[0].collapse_priority, 7);
        assert_eq!(
            config.sidebar.views[1].levels,
            vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents]
        );
        assert_eq!(config.sidebar.views[1].collapse_priority, 20);
        assert_eq!(
            config.sidebar.views[1].actions,
            vec![
                SidebarActionSpec::plain(Action::NewWorkspace),
                SidebarActionSpec::plain(Action::NewTab)
            ]
        );
        assert_eq!(
            config.sidebar.views[2].levels,
            vec![
                SidebarResourceKind::Workspaces,
                SidebarResourceKind::Panes,
                SidebarResourceKind::Tabs,
            ]
        );
        assert_eq!(config.sidebar.views[2].max_width, 44);
        assert!(config.sidebar.views[2].actions.is_empty());
        assert_eq!(
            config.sidebar.columns,
            vec![SidebarColumn { kind: SidebarColumnKind::Machines, width: 18, max_width: 0 }]
        );
    }

    #[test]
    fn sidebar_profiles_select_one_named_native_layout() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
        let dir = std::env::temp_dir()
            .join(format!("cmux-sidebar-profiles-config-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmux-tui.json");
        std::fs::write(
            &path,
            r#"{
                "sidebar": {
                    "profile": "focused",
                    "profiles": [
                        {
                            "id": "full",
                            "name": "Full",
                            "views": [
                                {"id": "machines", "levels": ["machines"]},
                                {"id": "workspaces", "levels": ["workspaces"]},
                                {"id": "tabs", "levels": ["tabs"]}
                            ]
                        },
                        {
                            "id": "focused",
                            "name": "Focused",
                            "views": [
                                {"id": "machines", "levels": ["machines"]},
                                {
                                    "id": "workspace-tree",
                                    "levels": ["workspaces", "agents"]
                                }
                            ]
                        }
                    ]
                }
            }"#,
        )
        .unwrap();
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

        let config = load();

        restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(
            config.sidebar.views.iter().map(|view| view.id.as_str()).collect::<Vec<_>>(),
            vec!["machines", "workspace-tree"]
        );
        assert!(config.sidebar.views.iter().all(|view| !view.includes(SidebarResourceKind::Tabs)));
    }

    #[test]
    fn sidebar_resources_are_hidden_when_their_view_is_omitted() {
        let sidebar = Sidebar::default();
        assert!(sidebar.views.iter().all(|view| !view.includes(SidebarResourceKind::Agents)));
        assert_eq!(sidebar.views[1].actions, vec![SidebarActionSpec::plain(Action::NewWorkspace)]);
    }

    #[test]
    fn sidebar_view_paths_reject_ambiguous_hierarchies() {
        assert!(validate_sidebar_levels(&[]).is_err());
        assert!(
            validate_sidebar_levels(&[
                SidebarResourceKind::Machines,
                SidebarResourceKind::Workspaces,
            ])
            .is_err()
        );
        assert!(
            validate_sidebar_levels(&[SidebarResourceKind::Tabs, SidebarResourceKind::Workspaces,])
                .is_err()
        );
        assert!(
            validate_sidebar_levels(&[
                SidebarResourceKind::Workspaces,
                SidebarResourceKind::Tabs,
                SidebarResourceKind::Panes,
            ])
            .is_err()
        );
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
    fn invalid_section_does_not_discard_valid_sections() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir = TestDirectory::new("section-recovery");
        let path = dir.path.join("cmux-tui.json");
        std::fs::write(&path, r##"{"theme":{"sidebar_rail":42},"browser":{"mode":"stealth"}}"##)
            .unwrap();
        let old = std::env::var_os("CMUX_TUI_CONFIG");
        unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
        let config = load();
        restore_env_var("CMUX_TUI_CONFIG", old);
        assert_eq!(config.theme.sidebar_rail, Color::Indexed(42));
        assert_eq!(config.browser.mode, BrowserMode::Headful);
    }

    #[test]
    fn unknown_top_level_field_keeps_strict_rejection() {
        let _guard = CONFIG_ENV_LOCK.lock().unwrap();
        let dir =
            std::env::temp_dir().join(format!("cmux-tui-top-level-strict-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmux-tui.json");
        std::fs::write(&path, r##"{"theme":{"sidebar_rail":42},"future":true}"##).unwrap();
        let old = std::env::var_os("CMUX_TUI_CONFIG");
        unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
        let config = load();
        restore_env_var("CMUX_TUI_CONFIG", old);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(config.theme.sidebar_rail, Theme::default().sidebar_rail);
    }

    #[test]
    fn viewport_animation_defaults_on_and_can_be_disabled() {
        let raw: RawConfig = serde_json::from_str(r#"{}"#).unwrap();
        assert!(raw.viewport.animation.is_none());
        assert!(Config::default().viewport.animation);

        let raw: RawConfig = serde_json::from_str(r#"{"viewport":{"animation":false}}"#).unwrap();
        assert_eq!(raw.viewport.animation, Some(false));

        let error = serde_json::from_str::<RawConfig>(r#"{"viewport":{"animation":"slow"}}"#)
            .unwrap_err()
            .to_string();
        assert!(error.contains("invalid type"), "{error}");
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
    fn macos_option_as_alt_is_an_explicit_input_mode() {
        let mut keys = Keys::default();
        assert!(keys.macos_option_as_alt);

        keys.apply(&HashMap::from([("macos_option_as_alt".to_string(), Value::Bool(false))]));
        assert!(!keys.macos_option_as_alt);

        keys.apply(&HashMap::from([(
            "macos_option_as_alt".to_string(),
            Value::String("guess".to_string()),
        )]));
        assert!(!keys.macos_option_as_alt);
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
        assert_eq!(
            keys.bindings
                .iter()
                .filter(|(chord, action)| chord == &keys.prefix && *action == Action::SendPrefix)
                .count(),
            1,
            "the prefix chord must resolve only to the send-prefix action"
        );
        for c in ['b', 'f', 'd', '.'] {
            assert_eq!(
                keys.modeless_action_for(&KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)),
                None
            );
        }
    }

    #[test]
    fn default_terminal_clear_shortcuts_keep_ctrl_l_child_owned() {
        let keys = Keys::default();
        let action = |code, modifiers| keys.modeless_action_for(&KeyEvent::new(code, modifiers));
        assert_eq!(action(KeyCode::Char('k'), KeyModifiers::SUPER), Some(Action::ClearHistory));
        assert_eq!(action(KeyCode::Char('l'), KeyModifiers::CONTROL), None);
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
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('l'), KeyModifiers::CONTROL)),
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
    fn ordinary_binding_collision_preserves_doubled_prefix_passthrough() {
        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert(
            "new-tab".to_string(),
            Value::Array(vec![Value::String("ctrl+b".to_string()), Value::String("f".to_string())]),
        );

        keys.apply(&raw);

        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)),
            Some(Action::SendPrefix)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
            Some(Action::NewTab)
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
    fn shift_is_preserved_without_a_shifted_ascii_character() {
        for (raw, character) in [("shift+space", ' '), ("shift+é", 'é')] {
            let chord = parse_chord(raw).unwrap();
            assert_eq!(chord, Chord { code: KeyCode::Char(character), mods: KeyModifiers::SHIFT });
            assert!(chord.matches(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::SHIFT,)));
            assert!(!chord.matches(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE,)));
        }
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
    fn close_tab_uses_the_primary_lowercase_binding() {
        let keys = Keys::default();
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            Some(Action::CloseTab)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)),
            Some(Action::ClosePane)
        );
    }

    #[test]
    fn close_tab_and_pane_bindings_are_configurable_independently() {
        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert("close-tab".to_string(), Value::String("q".to_string()));
        raw.insert("close-pane".to_string(), Value::String("Q".to_string()));
        keys.apply(&raw);

        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
            Some(Action::CloseTab)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('Q'), KeyModifiers::SHIFT)),
            Some(Action::ClosePane)
        );
        assert_eq!(keys.action_for(&KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)), None);
        assert_eq!(keys.action_for(&KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)), None);
    }

    #[test]
    fn workspace_defaults_cover_previous_next_create_and_close() {
        let keys = Keys::default();
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('('), KeyModifiers::SHIFT)),
            Some(Action::PrevWorkspace)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char(')'), KeyModifiers::SHIFT)),
            Some(Action::NextWorkspace)
        );
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(
                KeyCode::Char('{'),
                KeyModifiers::ALT | KeyModifiers::SHIFT,
            )),
            Some(Action::PrevWorkspace)
        );
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(
                KeyCode::Char('}'),
                KeyModifiers::ALT | KeyModifiers::SHIFT,
            )),
            Some(Action::NextWorkspace)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('W'), KeyModifiers::SHIFT)),
            Some(Action::NewWorkspace)
        );
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('D'), KeyModifiers::SHIFT)),
            Some(Action::CloseWorkspace)
        );
    }

    #[test]
    fn layout_undo_has_a_default_prefix_binding() {
        let keys = Keys::default();
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('U'), KeyModifiers::SHIFT)),
            Some(Action::UndoLayout)
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
            ("toggle-sidebar-compact", Action::ToggleSidebarCompact),
            ("provider-menu", Action::ProviderMenu),
            ("toggle-sidebar-view", Action::ToggleSidebarView),
            ("new-pane-right", Action::NewPaneRight),
            ("undo-layout", Action::UndoLayout),
            ("show-shortcuts", Action::ShowShortcuts),
            ("send-prefix", Action::SendPrefix),
            ("prev-workspace", Action::PrevWorkspace),
            ("close-workspace", Action::CloseWorkspace),
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
    fn provider_menu_override_requires_a_valid_chord_or_none() {
        let cases = [
            (Value::String("not a chord".to_string()), false),
            (Value::String("ctrl+b".to_string()), false),
            (Value::String("none".to_string()), true),
            (Value::Array(vec![]), true),
            (Value::String("x".to_string()), true),
            (Value::Bool(true), false),
        ];
        for (value, expected) in cases {
            let mut keys = Keys::default();
            keys.apply(&HashMap::from([("provider-menu".to_string(), value)]));
            assert_eq!(keys.provider_menu_overridden, expected);
        }
    }

    #[test]
    fn select_screen_action_names_round_trip_and_parse() {
        for number in 0..=9 {
            let action = Action::select_screen(number).unwrap();
            let name = format!("select-screen-{number}");
            assert_eq!(action.definition().config_key, name);
            assert!(action_definitions().iter().any(|definition| definition.action == action));

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

        assert_eq!(Action::select_screen(0).unwrap().screen_index(), Some(0));
        assert_eq!(Action::select_screen(1).unwrap().screen_index(), Some(1));
        assert_eq!(Action::select_screen(9).unwrap().screen_index(), Some(9));
        assert!(Action::select_screen(10).is_none());
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
    fn shortcut_labels_follow_resolved_bindings_and_prefix() {
        let mut keys = Keys::default();
        assert_eq!(keys.shortcut_label(Action::SendPrefix).as_deref(), Some("Ctrl-b Ctrl-b"));
        assert_eq!(keys.shortcut_label(Action::ZoomPane).as_deref(), Some("Ctrl-b z"));
        assert_eq!(keys.shortcut_label(Action::NewPaneSmart).as_deref(), Some("Alt-n"));
        assert_eq!(keys.shortcut_label(Action::ClearHistory).as_deref(), Some("Super-k"));
        assert_eq!(keys.prefixed_key_label(Action::ClearHistory), None);
        assert_eq!(keys.prefixed_key_label(Action::ShowShortcuts).as_deref(), Some("?"));
        assert_eq!(
            keys.shortcut_labels(Action::FocusLeft),
            ["Ctrl-b h", "Ctrl-b Left", "Alt-h", "Alt-Left"]
        );

        let mut raw = HashMap::new();
        raw.insert("prefix".to_string(), Value::String("ctrl+a".to_string()));
        raw.insert("zoom-pane".to_string(), Value::String("f".to_string()));
        raw.insert("toggle-sidebar".to_string(), Value::String("none".to_string()));
        keys.apply(&raw);

        assert_eq!(keys.shortcut_label(Action::SendPrefix).as_deref(), Some("Ctrl-a Ctrl-a"));
        assert_eq!(keys.shortcut_label(Action::ZoomPane).as_deref(), Some("Ctrl-a f"));
        assert_eq!(keys.shortcut_label(Action::ToggleSidebar), None);
        assert!(
            keys.resolved_shortcuts()
                .iter()
                .all(|(definition, shortcuts)| definition.action != Action::ToggleSidebar
                    && !shortcuts.is_empty())
        );

        let mut collision = Keys::default();
        let mut raw = HashMap::new();
        raw.insert("prefix".to_string(), Value::String("alt+n".to_string()));
        collision.apply(&raw);
        assert_eq!(
            collision.shortcut_labels(Action::NewPaneSmart),
            Vec::<String>::new(),
            "the prefix chord must not remain advertised as a modeless action"
        );
        assert_eq!(collision.shortcut_label(Action::SendPrefix).as_deref(), Some("Alt-n Alt-n"));
    }

    #[test]
    fn border_style_parses_every_name_and_defaults_to_single() {
        assert_eq!(Theme::default().border_style, BorderStyle::Single);
        for (name, style) in [
            ("single", BorderStyle::Single),
            ("rounded", BorderStyle::Rounded),
            ("thick", BorderStyle::Thick),
            ("double", BorderStyle::Double),
            ("none", BorderStyle::None),
        ] {
            let raw: RawConfig =
                serde_json::from_str(&format!(r#"{{"theme":{{"border_style":"{name}"}}}}"#))
                    .unwrap();
            assert_eq!(raw.theme.border_style, Some(style), "{name} did not parse");
        }
        let hidden = BorderStyle::None.glyphs();
        for glyph in [
            hidden.horizontal,
            hidden.vertical,
            hidden.top_left,
            hidden.top_right,
            hidden.bottom_left,
            hidden.bottom_right,
        ] {
            assert_eq!(glyph, " ");
        }
    }

    #[test]
    fn status_bar_segments_parse_validate_and_cap() {
        let raw: RawConfig = serde_json::from_value(json!({
            "status_bar": {
                "show_screens": false,
                "show_session": false,
                "left": [
                    {"text": " {session} ", "fg": "#87d787", "bg": 236},
                    {"text": "x", "run": ["true"]},
                    {"run": []},
                    {}
                ],
                "right": [
                    {"run": ["date", "+%H:%M"], "interval": 0},
                    {"text": "{workspace}"}
                ]
            }
        }))
        .unwrap();
        let left = resolve_status_segments(raw.status_bar.left.unwrap(), "left");
        assert_eq!(left.len(), 1, "text+run, empty run, and empty segments are rejected");
        assert_eq!(left[0].content, StatusSegmentContent::Text(" {session} ".to_string()));
        assert!(left[0].fg.is_some() && left[0].bg.is_some());
        let right = resolve_status_segments(raw.status_bar.right.unwrap(), "right");
        assert_eq!(right.len(), 2);
        assert_eq!(
            right[0].content,
            StatusSegmentContent::Command {
                argv: vec!["date".to_string(), "+%H:%M".to_string()],
                interval: Duration::from_secs(1),
            },
            "interval clamps to at least one second"
        );

        let options = StatusBarOptions { left, right, ..StatusBarOptions::default() };
        let commands = options.command_segments();
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].0, 1, "command index counts left segments first");

        let overflow: Vec<RawStatusSegment> = (0..MAX_STATUS_SEGMENTS + 3)
            .map(|index| RawStatusSegment {
                text: Some(format!("{index}")),
                ..RawStatusSegment::default()
            })
            .collect();
        assert_eq!(resolve_status_segments(overflow, "left").len(), MAX_STATUS_SEGMENTS);
    }

    #[test]
    fn chip_styles_and_separators_parse() {
        let raw: RawConfig = serde_json::from_value(json!({
            "tabs": {"style": "pill"},
            "status_bar": {
                "left_separator": "\u{e0b0}",
                "right_separator": "\u{e0b2}",
                "screens_style": "slant"
            }
        }))
        .unwrap();
        assert_eq!(raw.tabs.style, Some(ChipStyle::Pill));
        assert_eq!(raw.status_bar.screens_style, Some(ChipStyle::Slant));
        assert_eq!(raw.status_bar.left_separator.as_deref(), Some("\u{e0b0}"));
        assert!(ChipStyle::Block.caps().is_none());
        let (left, right) = ChipStyle::Pill.caps().unwrap();
        assert!(!left.is_empty() && !right.is_empty());
    }

    #[test]
    fn sidebar_buttons_accept_labels_positions_and_command_references() {
        let views = vec![RawSidebarView {
            id: "ws".to_string(),
            levels: vec!["workspaces".to_string()],
            actions: Some(vec![
                RawSidebarAction::Detailed {
                    action: "new-workspace".to_string(),
                    label: Some("new".to_string()),
                },
                RawSidebarAction::Name("command:lazygit".to_string()),
                RawSidebarAction::Name("command:unknown".to_string()),
                RawSidebarAction::Name("new-tab".to_string()),
            ]),
            actions_position: Some(ActionsPosition::Top),
            width: None,
            max_width: None,
            collapse_priority: None,
        }];
        let command_ids = vec!["lazygit".to_string()];
        let resolved = resolve_sidebar_view_specs(&views, 22, 0, 22, 0, "sidebar", &command_ids);
        assert_eq!(resolved.len(), 1);
        assert_eq!(resolved[0].actions_position, ActionsPosition::Top);
        assert_eq!(
            resolved[0].actions,
            vec![
                SidebarActionSpec { action: Action::NewWorkspace, label: Some("new".to_string()) },
                SidebarActionSpec::plain(Action::user_command(0).unwrap()),
                SidebarActionSpec::plain(Action::NewTab),
            ],
            "unknown command references drop, known ones bind by id"
        );
    }

    #[test]
    fn sidebar_row_metrics_glyph_and_label_template_parse() {
        let raw: RawConfig = serde_json::from_value(json!({
            "sidebar": {
                "row_height": 1,
                "row_gap": 0,
                "rail_glyph": "none",
                "workspace_label": "{index} · {name}"
            }
        }))
        .unwrap();
        assert_eq!(raw.sidebar.row_height, Some(1));
        assert_eq!(raw.sidebar.row_gap, Some(0));
        assert_eq!(raw.sidebar.rail_glyph.as_deref(), Some("none"));
        assert_eq!(raw.sidebar.workspace_label.as_deref(), Some("{index} · {name}"));
    }

    #[test]
    fn plus_buttons_parse_labels_actions_and_menus() {
        let raw: RawConfig = serde_json::from_value(json!({
            "tabs": {"plus": {
                "label": " new ",
                "action": "command:top",
                "menu": [
                    "new-tab",
                    {"action": "new-browser-tab", "label": "browser"},
                    "command:top",
                    "command:unknown"
                ]
            }},
            "status_bar": {"screens_plus": {"label": " ⊕ "}}
        }))
        .unwrap();
        let command_ids = vec!["top".to_string()];
        let plus = resolve_plus_button(raw.tabs.plus.unwrap(), &command_ids, "tabs");
        assert_eq!(plus.label, " new ");
        assert_eq!(plus.action, Action::user_command(0));
        assert_eq!(
            plus.menu,
            vec![
                SidebarActionSpec::plain(Action::NewTab),
                SidebarActionSpec {
                    action: Action::NewBrowserTab,
                    label: Some("browser".to_string()),
                },
                SidebarActionSpec::plain(Action::user_command(0).unwrap()),
            ],
            "unknown command references drop from plus menus"
        );
        let screens =
            resolve_plus_button(raw.status_bar.screens_plus.unwrap(), &command_ids, "status_bar");
        assert_eq!(screens.label, " ⊕ ");
        assert_eq!(screens.action, None);
        assert!(screens.menu.is_empty());
        // A blank label keeps the clickable default.
        let blank = resolve_plus_button(
            RawPlusButton { label: Some("   ".to_string()), action: None, menu: None },
            &command_ids,
            "tabs",
        );
        assert_eq!(blank.label, " + ");
    }

    #[test]
    fn raw_config_accepts_commands_section() {
        let raw: RawConfig = serde_json::from_value(json!({
            "commands": [
                {"id": "lazygit", "name": "LazyGit", "keys": "g", "run": ["lazygit"]},
                {"id": "scratch", "keys": ["alt+s"], "run": ["nvim", "/tmp/scratch.md"], "cwd": "/tmp"}
            ]
        }))
        .unwrap();
        assert_eq!(raw.commands.len(), 2);
    }

    #[test]
    fn user_commands_bind_chords_and_resolve() {
        let mut keys = Keys::default();
        let raw = vec![
            RawUserCommand {
                id: Some("lazygit".to_string()),
                name: Some("LazyGit".to_string()),
                keys: Some(Value::String("g".to_string())),
                run: Some(vec!["lazygit".to_string()]),
                cwd: None,
            },
            RawUserCommand {
                id: Some("scratch".to_string()),
                name: None,
                // The prefix chord is reserved, so only alt+s binds.
                keys: Some(json!(["alt+s", "ctrl+b"])),
                run: Some(vec!["nvim".to_string(), "/tmp/scratch.md".to_string()]),
                cwd: Some("/tmp".to_string()),
            },
            RawUserCommand {
                id: Some("lazygit".to_string()),
                name: None,
                keys: Some(Value::String("y".to_string())),
                run: Some(vec!["true".to_string()]),
                cwd: None,
            },
            RawUserCommand {
                id: Some("empty-run".to_string()),
                name: None,
                keys: Some(Value::String("e".to_string())),
                run: Some(Vec::new()),
                cwd: None,
            },
            RawUserCommand {
                id: None,
                name: None,
                keys: Some(Value::String("i".to_string())),
                run: Some(vec!["true".to_string()]),
                cwd: None,
            },
        ];
        let (commands, key_values) = resolve_user_command_specs(raw);
        bind_user_command_chords(&mut keys, &commands, &key_values);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].id, "lazygit");
        // An ignored invalid entry does not reserve its id: a later valid
        // entry with the same id is accepted.
        let mut keys_retry = Keys::default();
        let retry = vec![
            RawUserCommand {
                id: Some("retry".to_string()),
                name: None,
                keys: None,
                run: Some(Vec::new()),
                cwd: None,
            },
            RawUserCommand {
                id: Some("retry".to_string()),
                name: None,
                keys: None,
                run: Some(vec!["true".to_string()]),
                cwd: Some("   ".to_string()),
            },
        ];
        let (retried, retried_keys) = resolve_user_command_specs(retry);
        bind_user_command_chords(&mut keys_retry, &retried, &retried_keys);
        assert_eq!(retried.len(), 1);
        assert_eq!(retried[0].id, "retry");
        assert_eq!(retried[0].cwd, None, "blank cwd is treated as absent");
        assert_eq!(commands[0].name, "LazyGit");
        assert_eq!(commands[0].run, ["lazygit"]);
        assert_eq!(commands[1].name, "scratch");
        assert_eq!(commands[1].cwd.as_deref(), Some("/tmp"));

        let lazygit = Action::user_command(0).unwrap();
        let scratch = Action::user_command(1).unwrap();
        // An explicit command chord steals the default chord it collides with.
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
            Some(lazygit)
        );
        assert_eq!(keys.shortcut_labels(Action::NewPaneRight), Vec::<String>::new());
        // Alt chords are modeless, exactly like built-in Alt bindings.
        assert_eq!(
            keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('s'), KeyModifiers::ALT)),
            Some(scratch)
        );
        // The prefix chord stays reserved for send-prefix.
        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)),
            Some(Action::SendPrefix)
        );
        // Rejected chords do not bind: `y`, `e`, and `i` keep their defaults.
        assert_ne!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
            Some(Action::user_command(2).unwrap())
        );
        assert_eq!(keys.shortcut_labels(lazygit), ["Ctrl-b g"]);
        assert_eq!(keys.shortcut_labels(scratch), ["Alt-s"]);
    }

    #[test]
    fn user_commands_stop_at_the_command_limit() {
        let mut keys = Keys::default();
        let raw = (0..MAX_USER_COMMANDS + 2)
            .map(|index| RawUserCommand {
                id: Some(format!("command-{index}")),
                name: None,
                keys: None,
                run: Some(vec!["true".to_string()]),
                cwd: None,
            })
            .collect();
        let (commands, key_values) = resolve_user_command_specs(raw);
        bind_user_command_chords(&mut keys, &commands, &key_values);
        assert_eq!(commands.len(), MAX_USER_COMMANDS);
        assert!(Action::user_command(MAX_USER_COMMANDS).is_none());
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
    fn action_catalog_has_unique_actions_keys_and_complete_localized_labels() {
        let mut actions = HashSet::new();
        let mut keys = HashSet::new();
        for &definition in action_definitions() {
            assert!(actions.insert(definition.action), "duplicate action: {:?}", definition.action);
            assert!(keys.insert(definition.config_key), "duplicate key: {}", definition.config_key);
            assert!(!definition.label_en.is_empty());
            assert!(!definition.label_ja.is_empty());
            assert_eq!(definition.action.definition(), definition);
            let metadata = definition.action.metadata();
            let metadata_key = metadata.key;
            let _execution = metadata.execution();
            let resolved_metadata_key = match definition.action {
                Action::SelectTab(index) | Action::SelectScreen(index) => {
                    metadata_key.replace("{number}", &index.get().to_string())
                }
                _ => metadata_key.to_string(),
            };
            assert_eq!(
                resolved_metadata_key, definition.config_key,
                "action catalog and programmability metadata disagree for {:?}",
                definition.action
            );
        }
        for (_, action) in Keys::default().bindings {
            assert!(actions.contains(&action), "default binding is not registered: {action:?}");
        }
        assert!(actions.contains(&Action::NewPaneSmart));
        assert!(actions.contains(&Action::ShowShortcuts));
    }

    #[test]
    fn every_catalog_action_can_be_rebound() {
        for &definition in action_definitions() {
            let mut keys = Keys::default();
            let mut raw = HashMap::new();
            raw.insert(definition.config_key.to_string(), Value::String("f".to_string()));
            keys.apply(&raw);

            assert_eq!(
                keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
                Some(definition.action),
                "{} did not rebind through the central action catalog",
                definition.config_key
            );
        }
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

        assert_committed(
            write_sidebar_plugin_at_path(
                &path,
                Some(&SidebarPluginConfig {
                    command: vec![
                        "/tmp/plugin".to_string(),
                        "--mode".to_string(),
                        "test".to_string(),
                    ],
                    cwd: Some("/tmp".to_string()),
                }),
            )
            .unwrap(),
        );
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["theme"]["sidebar_rail"], json!(42));
        assert_eq!(value["sidebar"]["width"], json!(31));
        assert_eq!(value["future"]["unknown"], json!(true));
        assert_eq!(value["sidebar"]["plugin"]["command"][0], json!("/tmp/plugin"));
        assert_eq!(value["sidebar"]["plugin"]["cwd"], json!("/tmp"));

        assert_committed(write_sidebar_plugin_at_path(&path, None).unwrap());
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["sidebar"]["width"], json!(31));
        assert!(value["sidebar"].get("plugin").is_none());
        assert_eq!(value["future"]["unknown"], json!(true));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn sidebar_plugin_write_replaces_config_with_private_permissions() {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        let dir = TestDirectory::new("private-permissions");
        let path = dir.path.join("cmux-tui.json");
        let mut options = OpenOptions::new();
        options.write(true).create_new(true).mode(0o644);
        let file = options.open(&path).unwrap();
        drop(file);

        assert_committed(
            write_sidebar_plugin_at_path(
                &path,
                Some(&SidebarPluginConfig { command: vec!["/tmp/plugin".to_string()], cwd: None }),
            )
            .unwrap(),
        );

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "config permissions must not expose server.ws_token");
    }

    #[test]
    fn config_write_failure_cleans_staging_file() {
        let dir = TestDirectory::new("failure-cleanup");
        let path = dir.path.join("cmux-tui.json");
        std::fs::create_dir(&path).unwrap();

        let error = write_config_value_atomic(&path, &json!({"server": {"ws_token": "secret"}}))
            .expect_err("replacing a directory must fail");
        assert!(!error.to_string().is_empty());

        let entries = std::fs::read_dir(&dir.path).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
        assert_eq!(entries.len(), 1, "failed writes must remove their staging file");
        assert_eq!(entries[0].path(), path);
    }

    #[test]
    fn config_write_collision_preserves_existing_staging_file() {
        let dir = TestDirectory::new("staging-collision");
        let path = dir.path.join("cmux-tui.json");
        let collision = dir.path.join("collision.tmp");
        let replacement = dir.path.join("replacement.tmp");
        std::fs::write(&collision, b"owned by another writer").unwrap();
        let staging_paths = [collision.clone(), replacement.clone()];
        let staging_path = |_: &Path, attempt: usize| staging_paths[attempt].clone();
        let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
            Ok(ConfigParentSyncOutcome::Synced)
        };

        assert_committed(
            write_config_value_atomic_with_sync_and_staging(
                &path,
                &json!({"server": {"ws_token": "secret"}}),
                &sync_parent,
                &staging_path,
            )
            .expect("a colliding staging path should be retried"),
        );
        assert_eq!(std::fs::read(&collision).unwrap(), b"owned by another writer");
        assert!(!replacement.exists(), "the successful staging file must be renamed");
    }

    #[test]
    fn config_parent_creation_handles_absolute_path_syntax() {
        let dir = TestDirectory::new("absolute-parent");
        let parent = dir.path.join("nested").join("config");

        let created = ensure_config_parent_directory(&parent).unwrap();

        assert!(parent.is_dir());
        assert!(created.iter().any(|directory| directory == &parent));
    }

    #[test]
    fn config_parent_directory_normalizes_relative_path() {
        assert_eq!(config_parent_directory(Path::new("cmux-tui.json")), Path::new("."));
        assert_eq!(config_parent_directory(Path::new("nested/cmux-tui.json")), Path::new("nested"));
    }

    #[test]
    fn config_write_succeeds_after_parent_directory_sync() {
        let dir = TestDirectory::new("parent-sync");
        let path = dir.path.join("cmux-tui.json");
        assert_committed(
            write_config_value_atomic(&path, &json!({"server": {"ws_token": "secret"}})).unwrap(),
        );

        let value: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(value["server"]["ws_token"], json!("secret"));
    }

    #[cfg(unix)]
    #[test]
    fn config_write_does_not_report_failure_after_parent_sync_error() {
        let dir = TestDirectory::new("parent-sync-failure");
        let path = dir.path.join("cmux-tui.json");
        let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
            Err(anyhow::anyhow!("injected parent directory sync failure"))
        };

        let result = write_config_value_atomic_with_sync(
            &path,
            &json!({"server": {"ws_token": "secret"}}),
            &sync_parent,
        );

        assert!(matches!(
            result.expect("a committed rename must not be reported as a write failure"),
            ConfigWriteOutcome::CommittedButUnsynced { .. }
        ));
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["server"]["ws_token"], json!("secret"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn config_write_does_not_warn_for_unsupported_parent_sync() {
        let dir = TestDirectory::new("unsupported-parent-sync");
        let path = dir.path.join("cmux-tui.json");
        let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
            Ok(ConfigParentSyncOutcome::Unsupported)
        };

        let outcome = write_config_value_atomic_with_sync(
            &path,
            &json!({"server": {"ws_token": "secret"}}),
            &sync_parent,
        )
        .expect("a committed rename must not be reported as a write failure");
        assert!(matches!(&outcome, ConfigWriteOutcome::CommittedWithoutDirectorySync));
        assert!(outcome.into_unsynced_error().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn config_write_syncs_parents_of_new_directories() {
        let dir = TestDirectory::new("created-parent-sync");
        let parent = dir.path.join("new").join("nested");
        let path = parent.join("cmux-tui.json");
        let synced = RefCell::new(Vec::new());
        let sync_parent = |directory: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
            synced.borrow_mut().push(directory.to_path_buf());
            Ok(ConfigParentSyncOutcome::Synced)
        };

        assert_committed(
            write_config_value_atomic_with_sync(
                &path,
                &json!({"server": {"ws_token": "secret"}}),
                &sync_parent,
            )
            .unwrap(),
        );

        let synced = synced.into_inner();
        assert!(synced.iter().any(|directory| directory == &parent));
        assert!(synced.iter().any(|directory| directory == &dir.path));
    }
}
