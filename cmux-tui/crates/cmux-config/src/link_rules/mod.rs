//! Where links open: the reads, rules and decisions behind the app's
//! `LinkRouting`, `TerminalLinkOpener` (with its rules and targets),
//! `BrowserLinkClickSetting`, `LinkPlacement` and `SSHLinkHostsSetting`, moved
//! out of CmuxNextSettings (Settings row of RFD why-swift). The app keeps the
//! URL decomposition (Foundation's `URL`: scheme, host, absolute string), the
//! sign-in page test and the AppKit side, and asks these through `app_ops`
//! `link_rules.*`.
//!
//! - `browser.enabled`, `.openLinksInCmuxBrowser` (classic's
//!   `.openTerminalLinksInCmuxBrowser` is read only without it),
//!   `.hostsToOpenInEmbeddedBrowser`, `.urlsToAlwaysOpenExternally`,
//!   `.openSignInPagesInCmux`, `.openPullRequestsInGitHubPage`: [`Routing`].
//! - `terminal.linkOpener.default` / `.rules`: [`Opener`], [`Rule`], [`Target`].
//! - `browser.links.*`: [`read_clicks`]; `layout.linkPlacement`:
//!   [`read_placement`]; `ssh.linkAllowedHosts`: [`ssh_hosts`].
//! - URL rules: [`pattern`].
//!
//! Every read is the default for a missing key with no problem, and the
//! default plus a problem (`path`, `message`, as the Swift diagnostics said)
//! for a bad value.

pub mod pattern;

use serde_json::{Map, Value, json};

use crate::schema::Schema;
use pattern::is_newline;

/// One refused value: the dotted key and what was expected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub path: String,
    pub message: String,
}

impl Problem {
    fn new(path: &str, message: impl Into<String>) -> Self {
        Self { path: path.to_owned(), message: message.into() }
    }

    pub fn json(&self) -> Value {
        json!({ "path": self.path, "message": self.message })
    }
}

const EXPECTED_BOOL: &str = "expected true or false";
const EXPECTED_STRINGS: &str = "expected an array of strings";

pub const ENABLED_KEY: &str = "browser.enabled";
pub const OPEN_KEY: &str = "browser.openLinksInCmuxBrowser";
pub const LEGACY_OPEN_KEY: &str = "browser.openTerminalLinksInCmuxBrowser";
pub const SIGN_IN_PAGES_KEY: &str = "browser.openSignInPagesInCmux";
pub const PULL_REQUESTS_KEY: &str = "browser.openPullRequestsInGitHubPage";
pub const HOSTS_KEY: &str = "browser.hostsToOpenInEmbeddedBrowser";
pub const RULES_KEY: &str = "browser.urlsToAlwaysOpenExternally";
pub const OPENER_DEFAULT_KEY: &str = "terminal.linkOpener.default";
pub const OPENER_RULES_KEY: &str = "terminal.linkOpener.rules";
pub const CLICKS_KEY: &str = "browser.links";
pub const PLACEMENT_KEY: &str = "layout.linkPlacement";
pub const SSH_HOSTS_KEY: &str = "ssh.linkAllowedHosts";

/// `layout.linkPlacement`'s choices, in the Swift enum's order.
pub const PLACEMENTS: [&str; 3] = ["split-right", "new-column", "same-pane"];
/// `browser.links.*`'s actions, in the Swift enum's order.
pub const CLICK_ACTIONS: [&str; 6] =
    ["currentTab", "backgroundTab", "foregroundTab", "linkPlacement", "newWindow", "download"];
/// The keys under `browser.links`.
pub const CLICK_KEYS: [&str; 5] =
    ["cmdClick", "cmdShiftClick", "shiftClick", "optionClick", "middleClick"];

fn schema_default(key: &str) -> Option<&'static Value> {
    Schema::embedded().row(key).and_then(|row| row.default.as_ref())
}

fn bool_default(key: &str, fallback: bool) -> bool {
    schema_default(key).and_then(Value::as_bool).unwrap_or(fallback)
}

fn strings_default(key: &str) -> Vec<String> {
    schema_default(key)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn string_default(key: &str, fallback: &'static str) -> &'static str {
    schema_default(key).and_then(Value::as_str).unwrap_or(fallback)
}

/// The value at the dotted `key` of `root`, through objects only.
fn at<'a>(root: &'a Value, key: &str) -> Option<&'a Value> {
    key.split('.').try_fold(root, |current, part| current.as_object()?.get(part))
}

/// Foundation's `CharacterSet.whitespaces`: whitespace that is not a newline.
fn is_space(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

fn trim_spaces(text: &str) -> &str {
    text.trim_matches(is_space)
}

/// `text` without the ASCII `prefix` (any case), or `None`.
fn strip_prefix_ignore_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let head = text.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then(|| &text[prefix.len()..])
}

/// An array of strings, or classic's one-per-line text, as lines: blank lines
/// and `#` comments dropped (Swift `LinkRouting.lines`); `None` for any other
/// value.
pub fn lines(value: &Value) -> Option<Vec<String>> {
    let texts: Vec<&str> = match value {
        Value::String(text) => vec![text],
        Value::Array(items) => items.iter().map(Value::as_str).collect::<Option<_>>()?,
        _ => return None,
    };
    Some(
        texts
            .into_iter()
            .flat_map(|text| text.split(is_newline))
            .map(trim_spaces)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(str::to_owned)
            .collect(),
    )
}

/// The `browser.*` link keys (Swift `LinkRouting`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Routing {
    pub opens_in_cmux_browser: bool,
    pub embedded_hosts: Vec<String>,
    pub external_rules: Vec<String>,
    pub browser_enabled: bool,
    pub sign_in_pages_in_cmux: bool,
    pub pull_requests_in_github_page: bool,
}

/// Where one link goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteTarget {
    /// A cmux browser tab.
    CmuxBrowser,
    /// The system: the default browser for a web link, the scheme's app otherwise.
    System,
}

impl RouteTarget {
    pub fn name(self) -> &'static str {
        match self {
            Self::CmuxBrowser => "cmuxBrowser",
            Self::System => "system",
        }
    }
}

/// One link as the app's `URL` splits it.
#[derive(Debug, Clone, Copy)]
pub struct Link<'a> {
    /// `URL.absoluteString`.
    pub url: &'a str,
    /// `URL.scheme`, "" when none.
    pub scheme: &'a str,
    /// `URL.host`, "" when none.
    pub host: &'a str,
    /// Whether the app's `SignInPage(url:)` recognizes the URL.
    pub sign_in_page: bool,
}

impl Default for Routing {
    fn default() -> Self {
        Self {
            opens_in_cmux_browser: bool_default(OPEN_KEY, true),
            embedded_hosts: strings_default(HOSTS_KEY),
            external_rules: strings_default(RULES_KEY),
            browser_enabled: bool_default(ENABLED_KEY, true),
            sign_in_pages_in_cmux: bool_default(SIGN_IN_PAGES_KEY, true),
            pull_requests_in_github_page: bool_default(PULL_REQUESTS_KEY, false),
        }
    }
}

impl Routing {
    /// Reads the keys from a settings root (Swift `LinkRouting.parse`).
    pub fn read(root: &Value) -> (Self, Vec<Problem>) {
        let mut setting = Self::default();
        let mut problems = Vec::new();
        let Some(browser) = root.get("browser").and_then(Value::as_object) else {
            return (setting, problems);
        };
        let member = |key: &str| browser.get(key.rsplit('.').next().unwrap_or(key));
        for (key, field) in [
            (ENABLED_KEY, &mut setting.browser_enabled),
            (SIGN_IN_PAGES_KEY, &mut setting.sign_in_pages_in_cmux),
            (PULL_REQUESTS_KEY, &mut setting.pull_requests_in_github_page),
        ] {
            read_bool(member(key), key, field, &mut problems);
        }
        // The new key wins; classic's is read only without it.
        let key = if member(OPEN_KEY).is_some() { OPEN_KEY } else { LEGACY_OPEN_KEY };
        read_bool(member(key), key, &mut setting.opens_in_cmux_browser, &mut problems);
        for (key, field) in
            [(HOSTS_KEY, &mut setting.embedded_hosts), (RULES_KEY, &mut setting.external_rules)]
        {
            let Some(value) = member(key) else { continue };
            // An array, as the Settings rows write; classic's line text lives only in its preferences.
            match value.is_array().then(|| lines(value)).flatten() {
                Some(read) => *field = read,
                None => problems.push(Problem::new(key, EXPECTED_STRINGS)),
            }
        }
        (setting, problems)
    }

    /// Where `link` opens. Only an http(s) link opens in cmux. `other_target`
    /// (Shift-Command on a click) asks for the target the setting does not
    /// pick; `explicit` is a click that picked a cmux browser profile.
    pub fn target(&self, link: Link<'_>, other_target: bool, explicit: bool) -> RouteTarget {
        let scheme = link.scheme.to_lowercase();
        if !self.browser_enabled || (scheme != "http" && scheme != "https") {
            return RouteTarget::System;
        }
        let cmux = self.opens_in_cmux(link, explicit);
        if !other_target {
            return if cmux { RouteTarget::CmuxBrowser } else { RouteTarget::System };
        }
        if cmux || normalized_host(link.host).is_none() {
            RouteTarget::System
        } else {
            RouteTarget::CmuxBrowser
        }
    }

    /// Whether this http(s) link opens in a cmux browser tab.
    pub fn opens_in_cmux(&self, link: Link<'_>, explicit: bool) -> bool {
        if !self.browser_enabled {
            return false;
        }
        if !self.external_rules.is_empty() && pattern::matches(&self.external_rules, link.url) {
            return false;
        }
        let Some(host) = normalized_host(link.host) else { return false };
        if self.keeps_sign_in_page_in_cmux(link.sign_in_page) {
            return true;
        }
        if !self.opens_in_cmux_browser && !explicit {
            return false;
        }
        if self.embedded_hosts.is_empty() {
            return true;
        }
        self.embedded_hosts.iter().any(|raw| {
            let pattern = raw.trim().to_lowercase();
            if let Some(suffix) = pattern.strip_prefix("*.") {
                let Some(suffix) = normalized_host(suffix) else { return false };
                return host == suffix || host.ends_with(&format!(".{suffix}"));
            }
            normalized_host(&pattern).as_deref() == Some(host.as_str())
        })
    }

    /// Whether a sign-in page stays in a cmux browser tab.
    pub fn keeps_sign_in_page_in_cmux(&self, sign_in_page: bool) -> bool {
        self.browser_enabled && self.sign_in_pages_in_cmux && sign_in_page
    }

    pub fn json(&self) -> Value {
        json!({
            "opensInCmuxBrowser": self.opens_in_cmux_browser,
            "embeddedHosts": self.embedded_hosts,
            "externalRules": self.external_rules,
            "browserEnabled": self.browser_enabled,
            "signInPagesInCmux": self.sign_in_pages_in_cmux,
            "pullRequestsInGitHubPage": self.pull_requests_in_github_page,
        })
    }

    /// The setting from its [`Routing::json`] form; a missing member is its default.
    pub fn from_json(value: &Value) -> Option<Self> {
        let members = value.as_object()?;
        let mut setting = Self::default();
        let flag = |key: &str, field: &mut bool| -> Option<()> {
            if let Some(value) = members.get(key) {
                *field = value.as_bool()?;
            }
            Some(())
        };
        flag("opensInCmuxBrowser", &mut setting.opens_in_cmux_browser)?;
        flag("browserEnabled", &mut setting.browser_enabled)?;
        flag("signInPagesInCmux", &mut setting.sign_in_pages_in_cmux)?;
        flag("pullRequestsInGitHubPage", &mut setting.pull_requests_in_github_page)?;
        let strings = |key: &str, field: &mut Vec<String>| -> Option<()> {
            if let Some(value) = members.get(key) {
                *field = value
                    .as_array()?
                    .iter()
                    .map(|item| item.as_str().map(str::to_owned))
                    .collect::<Option<_>>()?;
            }
            Some(())
        };
        strings("embeddedHosts", &mut setting.embedded_hosts)?;
        strings("externalRules", &mut setting.external_rules)?;
        Some(setting)
    }
}

fn read_bool(value: Option<&Value>, key: &str, field: &mut bool, problems: &mut Vec<Problem>) {
    let Some(value) = value else { return };
    match value.as_bool() {
        Some(flag) => *field = flag,
        None => problems.push(Problem::new(key, EXPECTED_BOOL)),
    }
}

/// Classic's host normalizer (`RemoteLoopbackProxyAlias.normalizeHost`):
/// lowercase, no scheme, path, port, brackets or outer dots, IDN as punycode.
pub fn normalized_host(raw: &str) -> Option<String> {
    let mut value = raw.trim().to_lowercase();
    if value.is_empty() {
        return None;
    }
    // Foundation's `URL(string:).host` is set only with an authority: `scheme://` or `//`.
    let authority = if value.starts_with("//") {
        Some(format!("https:{value}"))
    } else {
        value.contains("://").then(|| value.clone())
    };
    if let Some(host) = authority.as_deref().and_then(url_host) {
        return trimmed_host(&host);
    }
    if let Some((_, rest)) = value.split_once("://") {
        value = rest.to_owned();
    }
    if let Some(cut) = value.find(['/', '?', '#']) {
        value.truncate(cut);
    }
    if let Some(rest) = value.strip_prefix('[') {
        value = match rest.find(']') {
            Some(closing) => rest[..closing].to_owned(),
            None => rest.to_owned(),
        };
    } else if let Some(colon) = value.rfind(':')
        && value[colon + 1..].chars().all(char::is_numeric)
        && value.matches(':').count() == 1
    {
        value.truncate(colon);
    }
    trimmed_host(&value)
}

fn trimmed_host(raw: &str) -> Option<String> {
    let trimmed = raw.trim_matches('.');
    if trimmed.is_empty() {
        return None;
    }
    Some(url_host(&format!("https://{trimmed}")).unwrap_or_else(|| trimmed.to_owned()))
}

/// The host of `text` as a URL: a domain lowercased and in punycode, an IPv6
/// address without its brackets (as Foundation's `URL.host` gives it).
fn url_host(text: &str) -> Option<String> {
    let parsed = url::Url::parse(text).ok()?;
    let host = match parsed.host()? {
        url::Host::Domain(domain) => domain.to_owned(),
        url::Host::Ipv4(address) => address.to_string(),
        url::Host::Ipv6(address) => address.to_string(),
    };
    (!host.is_empty()).then_some(host)
}

/// Where a URL a terminal program opens goes (Swift `TerminalLinkOpenerTarget`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Cmux,
    System,
    App { app: String, profile: Option<String> },
    Command(String),
}

/// The app names the short presets stand for.
pub const PRESETS: [(&str, &str); 6] = [
    ("chrome", "Google Chrome"),
    ("safari", "Safari"),
    ("arc", "Arc"),
    ("firefox", "Firefox"),
    ("edge", "Microsoft Edge"),
    ("brave", "Brave Browser"),
];

impl Target {
    /// Reads a target from its settings text; `None` when it names none.
    pub fn parse(text: &str) -> Option<Self> {
        let trimmed = text.trim();
        let lower = trimmed.to_lowercase();
        match lower.as_str() {
            "cmux" => return Some(Self::Cmux),
            "system" | "default" => return Some(Self::System),
            _ => {}
        }
        if let Some(command) = strip_prefix_ignore_case(trimmed, "command:") {
            let command = trim_spaces(command);
            return (!command.is_empty()).then(|| Self::Command(command.to_owned()));
        }
        let mut body = trimmed;
        let mut profile = None;
        if let Some(at) = body.rfind('@') {
            let name = trim_spaces(&body[at + 1..]);
            profile = (!name.is_empty()).then(|| name.to_owned());
            body = &body[..at];
        }
        if let Some(app) = strip_prefix_ignore_case(body, "app:") {
            let app = trim_spaces(app);
            return (!app.is_empty()).then(|| Self::App { app: app.to_owned(), profile });
        }
        let key = trim_spaces(body).to_lowercase();
        let (_, app) = PRESETS.iter().find(|(preset, _)| *preset == key)?;
        Some(Self::App { app: (*app).to_owned(), profile })
    }

    /// The word a reply names this target by.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Cmux => "cmux",
            Self::System => "system",
            Self::App { .. } => "app",
            Self::Command(_) => "command",
        }
    }

    /// How an app target launches for `url`: `{app, arguments, newInstance}`,
    /// `None` for other targets. A profile goes only to browsers that take
    /// one on the command line, as a new instance.
    pub fn launch(&self, url: &str) -> Option<Value> {
        let Self::App { app, profile } = self else { return None };
        let name = app.to_lowercase();
        let plain = json!({ "app": app, "arguments": [], "newInstance": false });
        let Some(profile) = profile else { return Some(plain) };
        let has = |names: &[&str]| names.iter().any(|candidate| name.contains(candidate));
        if has(&["chrome", "chromium", "edge", "brave", "vivaldi", "opera"]) {
            return Some(
                json!({ "app": app, "arguments": [format!("--profile-directory={profile}"), url],
                                "newInstance": true }),
            );
        }
        if has(&["firefox", "librewolf", "zen"]) {
            return Some(
                json!({ "app": app, "arguments": ["-P", profile, "-new-tab", url], "newInstance": true }),
            );
        }
        Some(plain)
    }

    pub fn json(&self) -> Value {
        match self {
            Self::Cmux | Self::System => json!({ "kind": self.kind() }),
            Self::App { app, profile } => json!({ "kind": "app", "app": app, "profile": profile }),
            Self::Command(command) => json!({ "kind": "command", "command": command }),
        }
    }

    pub fn from_json(value: &Value) -> Option<Self> {
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(match value.get("kind")?.as_str()? {
            "cmux" => Self::Cmux,
            "system" => Self::System,
            "app" => Self::App { app: text("app")?, profile: text("profile") },
            "command" => Self::Command(text("command")?),
            _ => return None,
        })
    }
}

/// One `terminal.linkOpener.rules` entry, `<match> -> <target>` (Swift `TerminalLinkOpenerRule`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// The rule as written.
    pub text: String,
    /// Caller globs, lowercased; empty matches any caller.
    pub callers: Vec<String>,
    /// The URL pattern; `None` matches any URL.
    pub url_pattern: Option<String>,
    pub target: Target,
}

impl Rule {
    /// Reads one rule; `None` when it has no `->` or names no target.
    pub fn parse(text: &str) -> Option<Self> {
        let (lhs, rhs) = text.split_once("->")?;
        let target = Target::parse(rhs)?;
        let mut callers = Vec::new();
        let mut pattern: Vec<&str> = Vec::new();
        for token in trim_spaces(lhs).split(' ').filter(|token| !token.is_empty()) {
            if let Some(globs) = strip_prefix_ignore_case(token, "caller:") {
                callers.extend(
                    globs.split(',').filter(|glob| !glob.is_empty()).map(str::to_lowercase),
                );
            } else {
                pattern.push(token);
            }
        }
        let joined = pattern.join(" ");
        Some(Self {
            text: trim_spaces(text).to_owned(),
            callers,
            url_pattern: (!joined.is_empty() && joined != "*").then_some(joined),
            target,
        })
    }

    /// Whether `url`, opened by a process chain named `callers`, matches.
    pub fn matches<S: AsRef<str>>(&self, url: &str, callers: &[S]) -> bool {
        if !self.callers.is_empty() {
            let lowered: Vec<String> =
                callers.iter().map(|name| name.as_ref().to_lowercase()).collect();
            if !self.callers.iter().any(|glob| lowered.iter().any(|name| glob_matches(glob, name)))
            {
                return false;
            }
        }
        match &self.url_pattern {
            None => true,
            Some(pattern) => pattern::matches(std::slice::from_ref(pattern), url),
        }
    }

    pub fn json(&self) -> Value {
        json!({ "text": self.text, "callers": self.callers, "urlPattern": self.url_pattern,
                "target": self.target.json() })
    }
}

/// `*` and `?` over the whole name.
fn glob_matches(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    let (mut pi, mut ni, mut star, mut mark) = (0usize, 0usize, None::<usize>, 0usize);
    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ni;
            pi += 1;
        } else if let Some(star) = star {
            pi = star + 1;
            mark += 1;
            ni = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// `terminal.linkOpener` (Swift `TerminalLinkOpener`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opener {
    pub default_target: Target,
    pub rules: Vec<Rule>,
}

impl Default for Opener {
    fn default() -> Self {
        Self {
            default_target: Target::parse(string_default(OPENER_DEFAULT_KEY, "cmux"))
                .unwrap_or(Target::Cmux),
            rules: Vec::new(),
        }
    }
}

impl Opener {
    pub fn read(root: &Value) -> (Self, Vec<Problem>) {
        let mut setting = Self::default();
        let mut problems = Vec::new();
        if let Some(value) = at(root, OPENER_DEFAULT_KEY) {
            match value.as_str().and_then(Target::parse) {
                Some(target) => setting.default_target = target,
                None => problems.push(Problem::new(
                    OPENER_DEFAULT_KEY,
                    "expected cmux, system, a browser (chrome, safari, arc, firefox, edge, brave), app:<name> or command:<command>",
                )),
            }
        }
        if let Some(value) = at(root, OPENER_RULES_KEY) {
            match value.is_array().then(|| lines(value)).flatten() {
                Some(read) => {
                    for line in read {
                        match Rule::parse(&line) {
                            Some(rule) => setting.rules.push(rule),
                            None => problems.push(Problem::new(
                                OPENER_RULES_KEY,
                                "expected <match> -> <target>, such as caller:aws -> chrome",
                            )),
                        }
                    }
                }
                None => problems.push(Problem::new(OPENER_RULES_KEY, EXPECTED_STRINGS)),
            }
        }
        (setting, problems)
    }

    /// The target for `url` opened by the process chain `callers`, and the
    /// index of the rule that decided (`None`: the default). With no rule
    /// matching, a sign-in page `routing` keeps in cmux opens in cmux.
    pub fn decide<S: AsRef<str>>(
        &self,
        url: &str,
        callers: &[S],
        keeps_sign_in_page: bool,
    ) -> (Target, Option<usize>) {
        if let Some(index) = self.rules.iter().position(|rule| rule.matches(url, callers)) {
            return (self.rules[index].target.clone(), Some(index));
        }
        if keeps_sign_in_page {
            return (Target::Cmux, None);
        }
        (self.default_target.clone(), None)
    }

    pub fn json(&self) -> Value {
        json!({ "default": self.default_target.json(),
                "rules": self.rules.iter().map(Rule::json).collect::<Vec<_>>() })
    }

    /// From [`Opener::json`]'s form, or `{default, rules}` with rule texts.
    pub fn from_json(value: &Value) -> Option<Self> {
        let mut setting = Self::default();
        if let Some(target) = value.get("default") {
            setting.default_target = match target {
                Value::String(text) => Target::parse(text)?,
                other => Target::from_json(other)?,
            };
        }
        if let Some(rules) = value.get("rules") {
            for rule in rules.as_array()? {
                let text = rule.as_str().or_else(|| rule.get("text")?.as_str())?;
                setting.rules.push(Rule::parse(text)?);
            }
        }
        Some(setting)
    }
}

/// `browser.links.*` (Swift `BrowserLinkClickSetting.parse`): every key's
/// action, its default when missing or bad.
pub fn read_clicks(root: &Value) -> (Map<String, Value>, Vec<Problem>) {
    let mut setting: Map<String, Value> = CLICK_KEYS
        .iter()
        .map(|key| {
            let default = string_default(&format!("{CLICKS_KEY}.{key}"), "currentTab");
            ((*key).to_owned(), Value::String(default.to_owned()))
        })
        .collect();
    let Some(links) = at(root, CLICKS_KEY) else { return (setting, Vec::new()) };
    let Some(members) = links.as_object() else {
        return (setting, vec![Problem::new(CLICKS_KEY, "expected an object")]);
    };
    let mut problems = Vec::new();
    for key in CLICK_KEYS {
        let Some(value) = members.get(key) else { continue };
        match value.as_str().filter(|text| CLICK_ACTIONS.contains(text)) {
            Some(action) => {
                setting.insert(key.to_owned(), Value::String(action.to_owned()));
            }
            None => problems.push(Problem::new(
                &format!("{CLICKS_KEY}.{key}"),
                format!("expected one of {}", choices(&CLICK_ACTIONS)),
            )),
        }
    }
    (setting, problems)
}

/// `layout.linkPlacement`: one of [`PLACEMENTS`].
pub fn read_placement(root: &Value) -> (&'static str, Option<Problem>) {
    let fallback = string_default(PLACEMENT_KEY, "split-right");
    let Some(value) = at(root, PLACEMENT_KEY) else { return (fallback, None) };
    match value.as_str().and_then(|text| PLACEMENTS.iter().find(|choice| **choice == text)) {
        Some(choice) => (choice, None),
        None => (
            fallback,
            Some(Problem::new(PLACEMENT_KEY, format!("expected one of {}", choices(&PLACEMENTS)))),
        ),
    }
}

fn choices(values: &[&str]) -> String {
    values.iter().map(|value| format!("\"{value}\"")).collect::<Vec<_>>().join(", ")
}

/// `ssh.linkAllowedHosts` as written; a value that is not an array is the
/// default, and entries that are not strings are skipped.
pub fn ssh_hosts(root: &Value) -> Vec<String> {
    match at(root, SSH_HOSTS_KEY).and_then(Value::as_array) {
        Some(entries) => entries.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
        None => strings_default(SSH_HOSTS_KEY),
    }
}

/// `ssh.linkAllowedHosts` after allowing `host`: `None` when nothing changes
/// (an empty host, or one already listed).
pub fn ssh_hosts_allowing(root: &Value, host: &str) -> Option<Vec<String>> {
    let mut hosts = ssh_hosts(root);
    if host.is_empty() || hosts.iter().any(|entry| entry == host) {
        return None;
    }
    hosts.push(host.to_owned());
    Some(hosts)
}

#[cfg(test)]
#[path = "pattern_tests.rs"]
mod pattern_tests;

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
