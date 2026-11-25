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
    assert_eq!(detect(&[("TERM_PROGRAM", "cmux")]).terminal, HostTerminal::Cmux);
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
    assert!(gate.decide(&request(1), away(), now).is_some());
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
    // A terminal bell reaches the TUI as the daemon's `Bell` notification
    // with `desktop: false`: with `bell` on it rings the host, no banner.
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
