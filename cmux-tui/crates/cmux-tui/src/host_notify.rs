//! Host terminal notifications: when a tab the person cannot see gets a
//! notification (an agent finished or waits, `cmux notify`, a bell), the TUI
//! forwards it to the terminal it runs in, so the host's own desktop banner
//! (Ghostty, iTerm2, kitty, WezTerm, the cmux app) or bell reaches the person
//! even when the TUI is behind another window or the tab is on another
//! workspace.
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
//! A terminal bell (`MuxEvent::Bell`) goes through the same gate with no
//! banner, so it rings the host bell only when `bell` is on.

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
    /// A terminal of a cmux-tui session (`CMUX_TUI_TERMINAL_ID` is set).
    /// That daemon turns no OSC 9, 777 or 99 into a notification (OSC 9 is
    /// progress metadata there), so nothing is passed to it.
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
        let terminal = if cmux_terminal.is_some() {
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
            HostTerminal::Cmux => return None,
            HostTerminal::Ghostty | HostTerminal::WezTerm => Some(OscDialect::Osc777),
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
    /// false: no desktop banner, only the bell option applies (a terminal
    /// bell, `MuxEvent::Bell`).
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
mod attention_passthrough_tests {
    use super::*;

    fn host(terminal: HostTerminal) -> HostTerminalInfo {
        HostTerminalInfo { terminal, multiplexed: false, cmux_terminal: None }
    }

    fn away() -> HostNotifyContext {
        HostNotifyContext {
            attached: true,
            tab_drawn: false,
            host_focused: true,
            own_host_terminal: false,
            session_hosts_tui: false,
        }
    }

    fn request(surface: SurfaceId) -> HostNotifyRequest<'static> {
        HostNotifyRequest { surface, title: "Claude finished", body: "bench done", desktop: true }
    }

    /// A gate with its config, as the App holds the two.
    struct Gate(HostNotifyGate, NotifyConfig);

    impl Gate {
        fn decide(
            &mut self,
            request: &HostNotifyRequest<'_>,
            context: HostNotifyContext,
            now: Instant,
        ) -> Option<Vec<u8>> {
            self.0.decide(self.1, request, context, now)
        }
    }

    fn gate(desktop: DesktopNotifyMode, bell: bool, terminal: HostTerminal) -> Gate {
        Gate(HostNotifyGate::new(host(terminal)), NotifyConfig { desktop, bell })
    }

    fn text(bytes: Option<Vec<u8>>) -> Option<String> {
        bytes.map(|bytes| String::from_utf8(bytes).unwrap())
    }

    #[test]
    fn host_notify_detects_the_terminal_from_its_environment() {
        let detect = |pairs: &[(&str, &str)]| {
            let pairs: Vec<(String, String)> =
                pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
            HostTerminalInfo::detect(move |name| {
                pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
            })
        };
        assert_eq!(detect(&[("TERM_PROGRAM", "ghostty")]).terminal, HostTerminal::Ghostty);
        assert_eq!(detect(&[("TERM_PROGRAM", "iTerm.app")]).terminal, HostTerminal::ITerm2);
        assert_eq!(detect(&[("LC_TERMINAL", "iTerm2")]).terminal, HostTerminal::ITerm2);
        assert_eq!(detect(&[("TERM_PROGRAM", "WezTerm")]).terminal, HostTerminal::WezTerm);
        assert_eq!(detect(&[("TERM", "xterm-kitty")]).terminal, HostTerminal::Kitty);
        assert_eq!(detect(&[("TERM", "xterm-256color")]).terminal, HostTerminal::Unknown);
        let cmux = detect(&[("TERM_PROGRAM", "ghostty"), ("CMUX_TUI_TERMINAL_ID", "term_1")]);
        assert_eq!(cmux.terminal, HostTerminal::Cmux);
        assert_eq!(cmux.cmux_terminal.as_deref(), Some("term_1"));
        assert!(detect(&[("TERM_PROGRAM", "ghostty"), ("TMUX", "/tmp/x,1,0")]).multiplexed);
        assert!(detect(&[("TERM", "screen-256color")]).multiplexed);
    }

    #[test]
    fn host_notify_sends_each_hosts_dialect_in_auto() {
        let now = Instant::now();
        let mut ghostty = gate(DesktopNotifyMode::Auto, false, HostTerminal::Ghostty);
        assert_eq!(
            text(ghostty.decide(&request(1), away(), now)).as_deref(),
            Some("\x1b]777;notify;Claude finished;bench done\x07")
        );
        let mut iterm = gate(DesktopNotifyMode::Auto, false, HostTerminal::ITerm2);
        assert_eq!(
            text(iterm.decide(&request(1), away(), now)).as_deref(),
            Some("\x1b]9;Claude finished: bench done\x07")
        );
        let mut kitty = gate(DesktopNotifyMode::Auto, false, HostTerminal::Kitty);
        assert_eq!(
            text(kitty.decide(&request(1), away(), now)).as_deref(),
            Some("\x1b]99;;Claude finished: bench done\x1b\\")
        );
        let mut unknown = gate(DesktopNotifyMode::Auto, false, HostTerminal::Unknown);
        assert_eq!(unknown.decide(&request(1), away(), now), None, "auto skips an unknown host");
        let mut always = gate(DesktopNotifyMode::Always, false, HostTerminal::Unknown);
        assert_eq!(
            text(always.decide(&request(1), away(), now)).as_deref(),
            Some("\x1b]9;Claude finished: bench done\x07")
        );
        let mut off = gate(DesktopNotifyMode::Off, false, HostTerminal::Ghostty);
        assert_eq!(off.decide(&request(1), away(), now), None);
        let mut tmux = Gate(
            HostNotifyGate::new(HostTerminalInfo {
                terminal: HostTerminal::Ghostty,
                multiplexed: true,
                cmux_terminal: None,
            }),
            NotifyConfig { desktop: DesktopNotifyMode::Auto, bell: false },
        );
        assert_eq!(tmux.decide(&request(1), away(), now), None, "auto skips a host behind tmux");
    }

    #[test]
    fn host_notify_never_forwards_a_tab_the_person_is_looking_at() {
        let now = Instant::now();
        let mut gate = gate(DesktopNotifyMode::Always, true, HostTerminal::Ghostty);
        let looking = HostNotifyContext { tab_drawn: true, ..away() };
        assert_eq!(gate.decide(&request(1), looking, now), None);
        let behind = HostNotifyContext { tab_drawn: true, host_focused: false, ..away() };
        assert!(gate.decide(&request(1), behind, now).is_some(), "an unfocused host window");
    }

    #[test]
    fn host_notify_never_forwards_when_detached_or_for_its_own_host() {
        let now = Instant::now();
        let mut gate = gate(DesktopNotifyMode::Always, true, HostTerminal::Cmux);
        let detached = HostNotifyContext { attached: false, ..away() };
        assert_eq!(gate.decide(&request(1), detached, now), None);
        let own = HostNotifyContext { own_host_terminal: true, ..away() };
        assert_eq!(gate.decide(&request(1), own, now), None, "no echo loop through the host");
        let same = HostNotifyContext { session_hosts_tui: true, ..away() };
        assert_eq!(gate.decide(&request(1), same, now), None, "the session already shows it");
        assert_eq!(gate.decide(&request(1), away(), now), Some(vec![0x07]), "the bell only");
        for desktop in [DesktopNotifyMode::Auto, DesktopNotifyMode::Always] {
            let mut cmux = self::gate(desktop, false, HostTerminal::Cmux);
            assert_eq!(cmux.decide(&request(2), away(), now), None, "a cmux-tui tab shows no OSC");
        }
    }

    #[test]
    fn host_notify_rate_limits_globally_and_per_tab() {
        let start = Instant::now();
        let mut gate = gate(DesktopNotifyMode::Auto, false, HostTerminal::Ghostty);
        assert!(gate.decide(&request(1), away(), start).is_some());
        assert!(gate.decide(&request(2), away(), start + Duration::from_millis(500)).is_none());
        assert!(gate.decide(&request(2), away(), start + Duration::from_millis(1100)).is_some());
        assert!(gate.decide(&request(1), away(), start + Duration::from_secs(3)).is_none());
        assert!(gate.decide(&request(1), away(), start + Duration::from_secs(6)).is_some());
    }

    #[test]
    fn host_notify_rings_the_bell_without_a_banner_when_asked() {
        let now = Instant::now();
        let mut bell_only = gate(DesktopNotifyMode::Off, true, HostTerminal::Unknown);
        assert_eq!(bell_only.decide(&request(1), away(), now), Some(vec![0x07]));
        let mut quiet_mark = gate(DesktopNotifyMode::Auto, false, HostTerminal::Ghostty);
        let mark = HostNotifyRequest { desktop: false, ..request(2) };
        assert_eq!(quiet_mark.decide(&mark, away(), now), None, "desktop:false posts no banner");
        // A terminal bell reaches the TUI as `MuxEvent::Bell`, a request with
        // `desktop: false`: with `bell` on it rings the host, no banner.
        let mut bell_mark = gate(DesktopNotifyMode::Auto, true, HostTerminal::Ghostty);
        let bell = HostNotifyRequest { title: "Bell", body: "", desktop: false, ..request(4) };
        assert_eq!(bell_mark.decide(&bell, away(), now), Some(vec![0x07]));
        let mut both = gate(DesktopNotifyMode::Auto, true, HostTerminal::Ghostty);
        let bytes = both.decide(&request(3), away(), now).unwrap();
        assert_eq!(bytes.last(), Some(&0x07));
        assert!(bytes.starts_with(b"\x1b]777;notify;"));
    }

    #[test]
    fn host_notify_strips_control_characters_and_ambiguous_osc9_prefixes() {
        let now = Instant::now();
        let mut gate = gate(DesktopNotifyMode::Always, false, HostTerminal::ITerm2);
        let hostile = HostNotifyRequest {
            surface: 1,
            title: "4;3",
            body: "evil\x1b]52;c;AAAA\x07\nnext",
            desktop: true,
        };
        let text = text(gate.decide(&hostile, away(), now)).unwrap();
        assert_eq!(text, "\x1b]9;cmux: 4;3: evil ]52;c;AAAA next\x07");
        assert_eq!(text.matches('\x1b').count(), 1);
        assert_eq!(text.matches('\x07').count(), 1);
        let mut ghostty =
            Gate(HostNotifyGate::new(host(HostTerminal::Ghostty)), NotifyConfig::default());
        let semicolon = HostNotifyRequest { title: "a;b", ..request(5) };
        assert_eq!(
            String::from_utf8(ghostty.decide(&semicolon, away(), now).unwrap()).unwrap(),
            "\x1b]777;notify;a,b;bench done\x07"
        );
    }

    /// A bare bell (`notifications.bell`) right before a tab's notification
    /// does not use up that notification's banner.
    #[test]
    fn host_notify_a_bell_before_a_notification_keeps_its_banner() {
        let mut gate = gate(DesktopNotifyMode::Auto, true, HostTerminal::Ghostty);
        let now = Instant::now();
        let bell = HostNotifyRequest { surface: 1, title: "Bell", body: "", desktop: false };
        assert_eq!(text(gate.decide(&bell, away(), now)).as_deref(), Some("\x07"));
        let soon = now + Duration::from_millis(200);
        assert_eq!(
            text(gate.decide(&request(1), away(), soon)).as_deref(),
            Some("\x1b]777;notify;Claude finished;bench done\x07\x07")
        );
        // The banner and its bell count: another bell or banner for tab 1
        // waits out the five seconds.
        let later = now + Duration::from_secs(2);
        assert_eq!(gate.decide(&bell, away(), later), None);
        assert_eq!(gate.decide(&request(1), away(), later), None);
    }
}
