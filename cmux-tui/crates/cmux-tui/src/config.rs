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
mod browser;
mod file_io;
mod ghostty_config;
mod ghostty_helper;
mod ghostty_theme_mode;
mod keys;
mod load;
mod machines;
mod sidebar;
mod status_bar;
mod tabs;
mod theme;

pub use action::Action;
use action::*;
pub use action_catalog::action_definitions;
use action_catalog::*;
pub use browser::{Browser, apply_browser_to_surface_options};
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
#[cfg(test)]
use machines::*;
pub use machines::{
    MachineConfig, MachineCreationSourceConfig, MachineProviderConfig, MachineTargetConfig,
};
#[cfg(test)]
pub use sidebar::SidebarActionSpec;
use sidebar::*;
pub use sidebar::{
    Agents, MachineSidebar, PlusButton, Sidebar, SidebarColumn, SidebarColumnKind,
    SidebarProfileSpec, SidebarResourceKind, SidebarView, SidebarViewSpec,
};
use status_bar::*;
pub use status_bar::{StatusSegment, StatusSegmentContent};
pub use tabs::{Tabs, tab_label};
use theme::*;
pub use theme::{BorderStyle, ChipStyle, ChromeMode, ChromeTheme, Theme};

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

#[cfg(test)]
mod tests;
