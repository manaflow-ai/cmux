//! Who may do what to which app. One decision function, [`decide`], serves
//! every route (a local agent, the CLI, an agent on another of the person's
//! machines), so no route has its own looser copy.
//!
//! Order, first match wins:
//! 1. Computer Use off: refuse.
//! 2. Protected targets (OS authentication and security UI, cmux Remote
//!    itself): refuse in every mode. Not removable.
//! 3. The deny list (the person's, starting from [`default_denied_apps`]):
//!    refuse in every mode, including Full access.
//! 4. Remote origin: refused unless the machine allows its owner's other
//!    machines (`allow_own_machines`), and never from another account.
//! 5. Look only: observation tools only.
//! 6. Saved "never" for the app: refuse. Saved "always": allow.
//! 7. Full access: allow. Approved apps: ask once, remember.
//!    Ask every time: ask once per agent session.

use serde::{Deserialize, Serialize};

/// The Computer Use mode (setting `computerUse.mode`).
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Off,
    /// Screenshots and reading app contents; no clicks or keys.
    LookOnly,
    /// Ask in each agent session before an app is used.
    AskEveryTime,
    /// Ask the first time an app is used; remember Always allow / Never.
    ApprovedApps,
    /// Any app except the deny list, no questions (the default).
    #[default]
    FullAccess,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "off" => Mode::Off,
            "lookOnly" | "look_only" => Mode::LookOnly,
            // `ask`, `bounded`, `standard`, `unrestricted`: earlier development builds' modes.
            "askEveryTime" | "ask_every_time" | "ask" => Mode::AskEveryTime,
            "approvedApps" | "approved_apps" | "bounded" => Mode::ApprovedApps,
            "fullAccess" | "full_access" | "unrestricted" | "standard" => Mode::FullAccess,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Off => "off",
            Mode::LookOnly => "lookOnly",
            Mode::AskEveryTime => "askEveryTime",
            Mode::ApprovedApps => "approvedApps",
            Mode::FullAccess => "fullAccess",
        }
    }
}

/// How an acting call waits before it reports the window after acting.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SettleMode {
    /// A fixed floor, then a check for change, with a ceiling (cmux).
    #[default]
    Adaptive,
    /// Anthropic's computer-use reference tool: a fixed 2.0 s after every
    /// action but typing, then a screenshot; typing in groups of 50
    /// characters, 12 ms per key, then a screenshot at once.
    Anthropic,
    /// OpenAI's computer tool: the actions run, then the screenshot is taken
    /// at once.
    Openai,
}

impl SettleMode {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "adaptive" => Some(Self::Adaptive),
            "anthropic" => Some(Self::Anthropic),
            "openai" => Some(Self::Openai),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Adaptive => "adaptive",
            Self::Anthropic => "anthropic",
            Self::Openai => "openai",
        }
    }
}

/// The machine's Computer Use policy, from the cmux settings
/// (`computerUse.*`) or, on a cloud VM, from its image.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PolicyConfig {
    pub mode: Mode,
    /// App matchers no agent may use (see [`AppMatcher`]).
    pub denied_apps: Vec<String>,
    /// Agents on the person's other machines (same account) may use this one.
    pub allow_own_machines: bool,
    /// Pause acting calls while the person uses the mouse or keyboard.
    pub pause_on_takeover: bool,
    /// Allow `delivery: "foreground"` (events that take focus or move the pointer).
    pub allow_foreground: bool,
    /// Draw the agent cursor.
    pub show_cursor: bool,
    /// A disposable cloud VM: unrestricted, no default deny list.
    pub cloud_vm: bool,
    /// How acting calls wait before they report the window (a call's own
    /// `settle` argument wins).
    pub settle: SettleMode,
    /// Whether background calls may open a target app's menus
    /// (`computerUse.menus`, [`crate::menus`]).
    pub menus: crate::menus::MenuMode,
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            mode: Mode::FullAccess,
            denied_apps: default_denied_apps().iter().map(|s| (*s).to_string()).collect(),
            allow_own_machines: true,
            pause_on_takeover: true,
            allow_foreground: false,
            show_cursor: true,
            cloud_vm: false,
            settle: SettleMode::Adaptive,
            menus: crate::menus::MenuMode::Open,
        }
    }
}

impl PolicyConfig {
    /// The cloud VM default: Full access, nothing denied but protected UI,
    /// foreground input allowed (nobody else uses the VM's desktop).
    pub fn cloud_vm() -> Self {
        Self {
            mode: Mode::FullAccess,
            denied_apps: vec![],
            allow_own_machines: true,
            pause_on_takeover: false,
            allow_foreground: true,
            show_cursor: true,
            cloud_vm: true,
            settle: SettleMode::Adaptive,
            menus: crate::menus::MenuMode::Open,
        }
    }
}

/// The deny list a new install starts with. The person can remove any entry.
pub fn default_denied_apps() -> &'static [&'static str] {
    &[
        // Password managers and keychains.
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.*",
        "com.agilebits.onepassword*",
        "com.bitwarden.*",
        "com.dashlane.*",
        "com.lastpass.*",
        "com.nordpass.*",
        "me.proton.pass",
        "org.keepassxc.keepassxc",
        "com.markmcguill.strongbox",
        "in.sinew.enpass*",
        "com.keepersecurity.*",
        "1password.exe",
        "bitwarden.exe",
        "keepass.exe",
        "keepassxc.exe",
        "org.keepassxc.KeePassXC",
        "1password",
        "bitwarden",
        // Where an agent could change OS security settings.
        "com.apple.systempreferences",
        // Terminals: typing there would run commands outside the agent's own sandbox and prompts.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "dev.warp.*",
        "windowsterminal.exe",
        "cmd.exe",
        "powershell.exe",
        "pwsh.exe",
        "org.gnome.Terminal",
        "org.gnome.Ptyxis",
        "org.kde.konsole",
        // cmux itself (an agent driving cmux could approve its own requests).
        "com.cmuxterm.app",
        "com.cmuxterm.app.*",
    ]
}

/// Never usable, in any mode, and not on the editable list.
fn protected(app_id: &str) -> bool {
    const IDS: &[&str] = &[
        "com.apple.securityagent",
        "com.apple.loginwindow",
        "com.apple.authorizationhost",
        "com.apple.coreautha",
        "com.apple.coreauthentication.agent",
        "com.apple.localauthenticationremoteservice",
        "com.apple.usernotificationcenter",
        "com.cmuxterm.remote",
        "com.cmuxterm.remote.dev",
        "cmux-remote",
        "cmux-remote.exe",
        "consent.exe",
        "credentialuibroker.exe",
        "logonui.exe",
        "polkit-gnome-authentication-agent-1",
        "org.kde.polkit-kde-authentication-agent-1",
        "gcr-prompter",
    ];
    let id = app_id.to_ascii_lowercase();
    IDS.contains(&id.as_str())
        || id.starts_with("com.apple.coreauthentication.")
        || id.starts_with("com.apple.localauthentication.")
        || id.starts_with("com.cmuxterm.remote.")
}

/// One deny-list entry: an exact app id, a `prefix*` glob, or `name:App Name`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppMatcher {
    Exact(String),
    Prefix(String),
    Name(String),
}

impl AppMatcher {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        if let Some(name) = text.strip_prefix("name:") {
            return Some(AppMatcher::Name(name.trim().to_lowercase()));
        }
        if let Some(prefix) = text.strip_suffix('*') {
            return Some(AppMatcher::Prefix(prefix.to_ascii_lowercase()));
        }
        Some(AppMatcher::Exact(text.to_ascii_lowercase()))
    }

    pub fn matches(&self, app: &TargetApp) -> bool {
        let id = app.id.to_ascii_lowercase();
        match self {
            AppMatcher::Exact(e) => id == *e,
            AppMatcher::Prefix(p) => id.starts_with(p.as_str()),
            AppMatcher::Name(n) => app.name.to_lowercase() == *n,
        }
    }
}

/// The app a call touches.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TargetApp {
    pub id: String,
    pub name: String,
}

/// Whether a tool only looks or also acts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    /// Metadata only (list apps and windows, status): allowed whenever on.
    Discover,
    /// Pixels or accessibility contents of a target.
    Observe,
    /// Input, values, actions, launching.
    Act,
}

/// Saved per-app answers ("Always allow", "Never").
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SavedApprovals {
    pub always: Vec<String>,
    pub never: Vec<String>,
}

impl SavedApprovals {
    fn has(list: &[String], id: &str) -> bool {
        list.iter().any(|a| a.eq_ignore_ascii_case(id))
    }
    pub fn is_always(&self, id: &str) -> bool {
        Self::has(&self.always, id)
    }
    pub fn is_never(&self, id: &str) -> bool {
        Self::has(&self.never, id)
    }
    pub fn set_always(&mut self, id: &str) {
        self.never.retain(|a| !a.eq_ignore_ascii_case(id));
        if !self.is_always(id) {
            self.always.push(id.to_string());
        }
    }
    pub fn set_never(&mut self, id: &str) {
        self.always.retain(|a| !a.eq_ignore_ascii_case(id));
        if !self.is_never(id) {
            self.never.push(id.to_string());
        }
    }
    pub fn forget(&mut self, id: &str) {
        self.always.retain(|a| !a.eq_ignore_ascii_case(id));
        self.never.retain(|a| !a.eq_ignore_ascii_case(id));
    }
}

/// Where a call comes from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OriginKind {
    /// An agent session on this machine.
    Local,
    /// An agent on another machine. `same_account` is set by the transport
    /// from the authenticated peer, never from the request.
    Remote { machine: String, same_account: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    Off,
    Protected,
    Denied,
    LookOnly,
    NeverAllowed,
    RemoteNotAllowed,
    ForeignAccount,
    ForegroundNotAllowed,
}

impl Refusal {
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::Off => "computer_use_off",
            Refusal::Protected => "app_protected",
            Refusal::Denied => "app_denied",
            Refusal::LookOnly => "look_only",
            Refusal::NeverAllowed => "app_never_allowed",
            Refusal::RemoteNotAllowed => "remote_not_allowed",
            Refusal::ForeignAccount => "foreign_account",
            Refusal::ForegroundNotAllowed => "foreground_not_allowed",
        }
    }

    pub fn message(&self, app: Option<&TargetApp>) -> String {
        let name = app.map(|a| a.name.as_str()).filter(|n| !n.is_empty()).unwrap_or("this app");
        match self {
            Refusal::Off => {
                "Computer Use is off on this machine (Settings > Computer Use).".into()
            }
            Refusal::Protected => format!(
                "{name} is protected: no agent may use the OS sign-in, security prompts or cmux Remote."
            ),
            Refusal::Denied => format!(
                "{name} is on the Computer Use deny list (Settings > Computer Use > Denied apps)."
            ),
            Refusal::LookOnly => "Computer Use is set to Look only: screenshots and reading work, clicks and keys do not.".into(),
            Refusal::NeverAllowed => format!("The person chose Never for {name}."),
            Refusal::RemoteNotAllowed => "This machine does not accept Computer Use from your other machines (Settings > Computer Use > Allow my other machines).".into(),
            Refusal::ForeignAccount => {
                "Computer Use from another account's machine is never accepted.".into()
            }
            Refusal::ForegroundNotAllowed => "Foreground delivery is off (Settings > Computer Use > Allow foreground input); use the default background delivery.".into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Ask the person. `remember` says whether "Always allow" is offered.
    Ask {
        remember: bool,
    },
    Refuse(Refusal),
}

/// One request to decide.
pub struct Request<'a> {
    pub access: Access,
    pub target: Option<&'a TargetApp>,
    pub origin: &'a OriginKind,
    pub foreground: bool,
    /// The agent session already has a grant for this app.
    pub session_granted: bool,
}

pub fn decide(config: &PolicyConfig, saved: &SavedApprovals, request: &Request<'_>) -> Decision {
    if config.mode == Mode::Off {
        return Decision::Refuse(Refusal::Off);
    }
    if let Some(app) = request.target {
        if protected(&app.id) {
            return Decision::Refuse(Refusal::Protected);
        }
        if config.denied_apps.iter().filter_map(|m| AppMatcher::parse(m)).any(|m| m.matches(app)) {
            return Decision::Refuse(Refusal::Denied);
        }
    }
    if let OriginKind::Remote { same_account, .. } = request.origin {
        if !same_account {
            return Decision::Refuse(Refusal::ForeignAccount);
        }
        if !config.allow_own_machines {
            return Decision::Refuse(Refusal::RemoteNotAllowed);
        }
    }
    if request.access == Access::Discover {
        return Decision::Allow;
    }
    if config.mode == Mode::LookOnly && request.access == Access::Act {
        return Decision::Refuse(Refusal::LookOnly);
    }
    if request.foreground && !config.allow_foreground {
        return Decision::Refuse(Refusal::ForegroundNotAllowed);
    }
    let Some(app) = request.target else {
        // A display-wide observation with no single app: the frame pipeline
        // redacts denied windows; asking modes ask once per session.
        return match config.mode {
            Mode::FullAccess | Mode::LookOnly => Decision::Allow,
            _ if request.session_granted => Decision::Allow,
            _ => Decision::Ask { remember: false },
        };
    };
    if saved.is_never(&app.id) {
        return Decision::Refuse(Refusal::NeverAllowed);
    }
    if saved.is_always(&app.id) || request.session_granted {
        return Decision::Allow;
    }
    match config.mode {
        Mode::FullAccess | Mode::LookOnly => Decision::Allow,
        Mode::ApprovedApps => Decision::Ask { remember: true },
        Mode::AskEveryTime => Decision::Ask { remember: false },
        Mode::Off => Decision::Refuse(Refusal::Off),
    }
}

/// Whether an app is hidden from discovery (protected or denied apps are
/// listed by name only, with `denied: true`, so agents can tell the person why).
pub fn is_blocked(config: &PolicyConfig, app: &TargetApp) -> Option<Refusal> {
    if protected(&app.id) {
        return Some(Refusal::Protected);
    }
    config
        .denied_apps
        .iter()
        .filter_map(|m| AppMatcher::parse(m))
        .any(|m| m.matches(app))
        .then_some(Refusal::Denied)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &str) -> TargetApp {
        TargetApp { id: id.into(), name: id.into() }
    }

    fn req<'a>(
        access: Access,
        target: Option<&'a TargetApp>,
        origin: &'a OriginKind,
    ) -> Request<'a> {
        Request { access, target, origin, foreground: false, session_granted: false }
    }

    #[test]
    fn full_access_is_the_default_and_allows_ordinary_apps() {
        let config = PolicyConfig::default();
        assert_eq!(config.mode, Mode::FullAccess);
        let safari = app("com.apple.Safari");
        let d = decide(
            &config,
            &SavedApprovals::default(),
            &req(Access::Act, Some(&safari), &OriginKind::Local),
        );
        assert_eq!(d, Decision::Allow);
    }

    #[test]
    fn deny_list_beats_full_access_and_always() {
        let config = PolicyConfig::default();
        let mut saved = SavedApprovals::default();
        saved.set_always("com.1password.1password");
        let one = app("com.1password.1password");
        let d = decide(&config, &saved, &req(Access::Observe, Some(&one), &OriginKind::Local));
        assert_eq!(d, Decision::Refuse(Refusal::Denied));
    }

    #[test]
    fn protected_apps_are_refused_even_with_an_empty_deny_list() {
        let config = PolicyConfig::cloud_vm();
        let agent = app("com.apple.SecurityAgent");
        let d = decide(
            &config,
            &SavedApprovals::default(),
            &req(Access::Act, Some(&agent), &OriginKind::Local),
        );
        assert_eq!(d, Decision::Refuse(Refusal::Protected));
    }

    #[test]
    fn look_only_refuses_acting_but_allows_observing() {
        let config = PolicyConfig { mode: Mode::LookOnly, ..PolicyConfig::default() };
        let s = app("com.apple.Safari");
        let saved = SavedApprovals::default();
        assert_eq!(
            decide(&config, &saved, &req(Access::Observe, Some(&s), &OriginKind::Local)),
            Decision::Allow
        );
        assert_eq!(
            decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
            Decision::Refuse(Refusal::LookOnly)
        );
    }

    #[test]
    fn approved_apps_asks_once_then_remembers() {
        let config = PolicyConfig { mode: Mode::ApprovedApps, ..PolicyConfig::default() };
        let s = app("com.apple.Safari");
        let mut saved = SavedApprovals::default();
        assert_eq!(
            decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
            Decision::Ask { remember: true }
        );
        saved.set_always(&s.id);
        assert_eq!(
            decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
            Decision::Allow
        );
        saved.set_never(&s.id);
        assert_eq!(
            decide(&config, &saved, &req(Access::Act, Some(&s), &OriginKind::Local)),
            Decision::Refuse(Refusal::NeverAllowed)
        );
    }

    #[test]
    fn remote_needs_same_account_and_the_setting() {
        let mut config = PolicyConfig::default();
        let s = app("com.apple.Safari");
        let saved = SavedApprovals::default();
        let foreign = OriginKind::Remote { machine: "m".into(), same_account: false };
        assert_eq!(
            decide(&config, &saved, &req(Access::Discover, None, &foreign)),
            Decision::Refuse(Refusal::ForeignAccount)
        );
        let mine = OriginKind::Remote { machine: "m".into(), same_account: true };
        assert_eq!(decide(&config, &saved, &req(Access::Act, Some(&s), &mine)), Decision::Allow);
        config.allow_own_machines = false;
        assert_eq!(
            decide(&config, &saved, &req(Access::Act, Some(&s), &mine)),
            Decision::Refuse(Refusal::RemoteNotAllowed)
        );
    }

    #[test]
    fn foreground_needs_its_setting() {
        let config = PolicyConfig::default();
        let s = app("com.apple.Safari");
        let r = Request {
            access: Access::Act,
            target: Some(&s),
            origin: &OriginKind::Local,
            foreground: true,
            session_granted: false,
        };
        assert_eq!(
            decide(&config, &SavedApprovals::default(), &r),
            Decision::Refuse(Refusal::ForegroundNotAllowed)
        );
        assert_eq!(
            decide(&PolicyConfig::cloud_vm(), &SavedApprovals::default(), &r),
            Decision::Allow
        );
    }

    #[test]
    fn earlier_build_modes_read_as_the_nearest_mode() {
        assert_eq!(Mode::parse("standard"), Some(Mode::FullAccess));
        assert_eq!(Mode::parse("unrestricted"), Some(Mode::FullAccess));
        assert_eq!(Mode::parse("bounded"), Some(Mode::ApprovedApps));
        assert_eq!(Mode::parse("ask"), Some(Mode::AskEveryTime));
        assert_eq!(Mode::parse("god"), None);
    }

    #[test]
    fn matchers() {
        let a = TargetApp { id: "com.agilebits.onepassword7".into(), name: "1Password 7".into() };
        assert!(AppMatcher::parse("com.agilebits.onepassword*").unwrap().matches(&a));
        assert!(AppMatcher::parse("name:1password 7").unwrap().matches(&a));
        assert!(!AppMatcher::parse("com.agilebits").unwrap().matches(&a));
    }
}
