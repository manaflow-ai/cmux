//! Host terminal notifications: when a tab the person cannot see gets a
//! notification (an agent finished or waits, OSC 9/777/99 from a program, a
//! bell), the TUI forwards it to the terminal it runs in, so the host's own
//! desktop banner (Ghostty, iTerm2, kitty, WezTerm, the cmux app) or bell
//! reaches the person even when the TUI is behind another window or the tab
//! is on another workspace.
//!
//! Config (`notifications` in `cmux-tui.json`):
//!
//! - `desktop`: `off`, `auto` (default: only a host known to show OSC
//!   notifications, outside tmux), or `always` (OSC 9 for an unknown host).
//! - `bell`: also ring the host bell (BEL). Default `false`.
//!
//! The gate ([`HostNotifyGate`]) is pure and decides from the config and what the App
//! knows: the TUI is attached and draws the whole session (not a scoped
//! `terminal attach`), the tab is not drawn while the host window has focus,
//! the notification is not for the TUI's own host terminal nor for a session
//! that already shows it (the host terminal is one of the session's tabs),
//! and the rate limit allows it (one per second, one per tab per five
//! seconds). The App writes the bytes it returns (`app/host_notify_ops.rs`).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

/// `notifications.desktop`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DesktopNotifyMode {
    Off,
    #[default]
    Auto,
    Always,
}

/// The `notifications` config section, resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NotifyConfig {
    pub desktop: DesktopNotifyMode,
    pub bell: bool,
}

/// The terminal the TUI runs in, as its environment names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostTerminal {
    /// A cmux terminal (the cmux app, or another cmux-tui session): its
    /// daemon reads OSC 9, 777 and 99.
    Cmux,
    Ghostty,
    ITerm2,
    Kitty,
    WezTerm,
    Unknown,
}

/// What the TUI knows about its host terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostTerminalInfo {
    pub terminal: HostTerminal,
    /// tmux or screen sits between the TUI and the terminal; it swallows OSC
    /// notifications without passthrough.
    pub multiplexed: bool,
    /// The public id of the cmux terminal the TUI runs in
    /// (`CMUX_TUI_TERMINAL_ID`), when it runs in one.
    pub cmux_terminal: Option<String>,
}

impl HostTerminalInfo {
    /// Read the host from environment variables (`env` looks one up).
    pub(crate) fn detect(env: impl Fn(&str) -> Option<String>) -> Self {
        let get = |name: &str| env(name).filter(|value| !value.is_empty());
        let program = get("TERM_PROGRAM").unwrap_or_default();
        let term = get("TERM").unwrap_or_default();
        let cmux_terminal = get("CMUX_TUI_TERMINAL_ID");
        let terminal = if cmux_terminal.is_some() || program == "cmux" {
            HostTerminal::Cmux
        } else if program.eq_ignore_ascii_case("ghostty") || get("GHOSTTY_RESOURCES_DIR").is_some()
        {
            HostTerminal::Ghostty
        } else if program == "iTerm.app" || get("LC_TERMINAL").as_deref() == Some("iTerm2") {
            HostTerminal::ITerm2
        } else if program.eq_ignore_ascii_case("wezterm") {
            HostTerminal::WezTerm
        } else if term == "xterm-kitty" || get("KITTY_WINDOW_ID").is_some() {
            HostTerminal::Kitty
        } else {
            HostTerminal::Unknown
        };
        let multiplexed = get("TMUX").is_some()
            || get("STY").is_some()
            || term.starts_with("tmux")
            || term.starts_with("screen");
        Self { terminal, multiplexed, cmux_terminal }
    }

    /// The OSC dialect `mode` sends to this host, or `None` for no desktop
    /// notification.
    fn dialect(&self, mode: DesktopNotifyMode) -> Option<OscDialect> {
        let known = match self.terminal {
            HostTerminal::Cmux | HostTerminal::Ghostty | HostTerminal::WezTerm => {
                Some(OscDialect::Osc777)
            }
            HostTerminal::ITerm2 => Some(OscDialect::Osc9),
            HostTerminal::Kitty => Some(OscDialect::Osc99),
            HostTerminal::Unknown => None,
        };
        match mode {
            DesktopNotifyMode::Off => None,
            DesktopNotifyMode::Auto if self.multiplexed => None,
            DesktopNotifyMode::Auto => known,
            DesktopNotifyMode::Always => known.or(Some(OscDialect::Osc9)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OscDialect {
    /// `OSC 9 ; text BEL` (iTerm2, and the widest fallback).
    Osc9,
    /// `OSC 777 ; notify ; title ; body BEL` (Ghostty, WezTerm, cmux).
    Osc777,
    /// `OSC 99 ; ; text ST` (kitty).
    Osc99,
}

/// One notification the daemon posted, as the gate needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostNotifyRequest<'a> {
    pub surface: SurfaceId,
    pub title: &'a str,
    pub body: &'a str,
    /// false: the poster asked for no desktop banner (`notify --desktop
    /// false`, a bell's mark). The bell option still applies.
    pub desktop: bool,
}

/// What the App knows about the person and the tab when a notification
/// arrives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct HostNotifyContext {
    /// The TUI is attached, draws the whole session, and is not quitting.
    pub attached: bool,
    /// The tab is drawn in a pane on screen now.
    pub tab_drawn: bool,
    /// The host terminal window has focus (true until it reports otherwise).
    pub host_focused: bool,
    /// The tab shows the TUI's own host terminal.
    pub own_host_terminal: bool,
    /// The host terminal is a tab of this session, whose frontends already
    /// show its notifications.
    pub session_hosts_tui: bool,
}

const GLOBAL_INTERVAL: Duration = Duration::from_secs(1);
const SURFACE_INTERVAL: Duration = Duration::from_secs(5);
/// Characters of a forwarded title and body.
const MAX_TITLE_CHARS: usize = 100;
const MAX_BODY_CHARS: usize = 240;

/// The forwarding policy for one host plus its rate-limit memory. The
/// config is passed to each decision, so a reloaded config applies at once.
#[derive(Debug)]
pub(crate) struct HostNotifyGate {
    host: HostTerminalInfo,
    /// Writes with a desktop banner.
    banners: RateLimit,
    /// Every write that rings the host bell, banner or not. A bare bell
    /// counts only here, so a bell just before a notification does not
    /// hold back that notification's banner.
    bells: RateLimit,
}

/// One per second overall, one per tab every five seconds.
#[derive(Debug, Default)]
struct RateLimit {
    last_any: Option<Instant>,
    last_by_surface: HashMap<SurfaceId, Instant>,
}

impl RateLimit {
    fn allows(&self, surface: SurfaceId, now: Instant) -> bool {
        !(self.last_any.is_some_and(|last| now.saturating_duration_since(last) < GLOBAL_INTERVAL)
            || self
                .last_by_surface
                .get(&surface)
                .is_some_and(|last| now.saturating_duration_since(*last) < SURFACE_INTERVAL))
    }

    fn record(&mut self, surface: SurfaceId, now: Instant) {
        self.last_any = Some(now);
        self.last_by_surface
            .retain(|_, last| now.saturating_duration_since(*last) < SURFACE_INTERVAL);
        self.last_by_surface.insert(surface, now);
    }
}

impl HostNotifyGate {
    pub(crate) fn new(host: HostTerminalInfo) -> Self {
        Self { host, banners: RateLimit::default(), bells: RateLimit::default() }
    }

    pub(crate) fn host(&self) -> &HostTerminalInfo {
        &self.host
    }

    /// The bytes to write to the host for `request`, or `None`. A returned
    /// write counts against the rate limit.
    pub(crate) fn decide(
        &mut self,
        config: NotifyConfig,
        request: &HostNotifyRequest<'_>,
        context: HostNotifyContext,
        now: Instant,
    ) -> Option<Vec<u8>> {
        if !context.attached
            || context.own_host_terminal
            || context.session_hosts_tui
            || (context.tab_drawn && context.host_focused)
        {
            return None;
        }
        let dialect = self.host.dialect(config.desktop).filter(|_| request.desktop);
        if dialect.is_none() && !config.bell {
            return None;
        }
        let limit = if dialect.is_some() { &self.banners } else { &self.bells };
        if !limit.allows(request.surface, now) {
            return None;
        }
        let mut bytes = Vec::new();
        if let Some(dialect) = dialect {
            bytes.extend(osc_bytes(dialect, request.title, request.body));
            self.banners.record(request.surface, now);
        }
        if config.bell {
            bytes.push(0x07);
            self.bells.record(request.surface, now);
        }
        Some(bytes)
    }
}

/// One line of printable text: control characters (C0, C1, DEL, which could
/// end the OSC or start another sequence) become spaces, runs collapse, and
/// the text is cut to `max` characters.
fn clean(text: &str, max: usize) -> String {
    let mut out = String::new();
    let mut space = false;
    for character in text.chars() {
        let character = if character.is_control() { ' ' } else { character };
        if character == ' ' {
            if !space && !out.is_empty() {
                out.push(' ');
            }
            space = true;
            continue;
        }
        space = false;
        out.push(character);
    }
    let trimmed = out.trim_end();
    match trimmed.char_indices().nth(max) {
        Some((cut, _)) => format!("{}…", trimmed.get(..cut).unwrap_or(trimmed)),
        None => trimmed.to_string(),
    }
}

fn osc_bytes(dialect: OscDialect, title: &str, body: &str) -> Vec<u8> {
    let title = clean(title, MAX_TITLE_CHARS);
    let body = clean(body, MAX_BODY_CHARS);
    let title = if title.is_empty() { "cmux".to_string() } else { title };
    let text = if body.is_empty() { title.clone() } else { format!("{title}: {body}") };
    match dialect {
        // A leading `<digits>;` would read as a ConEmu OSC 9 subcommand
        // (`9;4` is progress), so such a text is prefixed.
        OscDialect::Osc9 => {
            let ambiguous = text.split_once(';').is_some_and(|(head, _)| {
                !head.is_empty() && head.bytes().all(|byte| byte.is_ascii_digit())
            });
            let text = if ambiguous { format!("cmux: {text}") } else { text };
            format!("\x1b]9;{text}\x07").into_bytes()
        }
        // The title field ends at the first `;`.
        OscDialect::Osc777 => {
            format!("\x1b]777;notify;{};{body}\x07", title.replace(';', ",")).into_bytes()
        }
        OscDialect::Osc99 => format!("\x1b]99;;{text}\x1b\\").into_bytes(),
    }
}

#[cfg(test)]
mod attention_passthrough_tests;
