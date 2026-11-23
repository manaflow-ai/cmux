//! cmux-next object links (`cmux://tab/tab_<hex>`, `cmux://agent/<harness>/<session>`, …): what a
//! URL names, how a link is written back, and the https forms the app opens as links.
//!
//! The scheme is the running build's URL scheme (`cmux` in Release, `cmux-dev` in Debug,
//! `cmux-dev-<tag>` in tagged builds). The host names the kind and the path an opaque cmux-tui
//! resource id (`ws_`, `pane_`, `tab_` plus 32 lowercase hex digits), never a numeric handle.
//! `?machine=machine_<hex>` may name the machine the target lives on; every other query
//! parameter is ignored, so a link can never carry a command. An agent link's `host`, `name` and
//! `message` parameters, and what happens to one cmux cannot use, are
//! schemas/deeplinks/agent-link.json. Nightly's `workspace/<uuid>[/pane|surface|panel/<uuid>]`
//! forms parse to the legacy targets.
//!
//! The macOS app asks through [`call`] (`cmux_deep_link_call`): a JSON request in, a JSON value
//! out, in the shapes Swift's synthesized `Codable` gives its `DeepLink` types.

mod export;
mod json;
pub mod url;
mod web;

pub use export::{ExportScheme, export_json};
pub use json::call;
pub use web::*;

use url::{Components, QueryItem};

/// Which half of a team Cloud link: a chat (`cloud/session/…`) or a workspace (`cloud/workspace/…`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CloudSessionKind {
    Chat,
    Workspace,
}

impl CloudSessionKind {
    /// The path segment (`session` or `workspace`), Swift's raw value.
    pub fn raw(self) -> &'static str {
        match self {
            CloudSessionKind::Chat => "session",
            CloudSessionKind::Workspace => "workspace",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "session" => Some(CloudSessionKind::Chat),
            "workspace" => Some(CloudSessionKind::Workspace),
            _ => None,
        }
    }
}

/// What a link opens. A UUID is kept as its uppercase string (`UUID.uuidString`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Workspace(String),
    Pane(String),
    Tab(String),
    Session {
        id: String,
        turn: Option<String>,
    },
    ChiefSession {
        home: String,
        session: String,
    },
    Agent {
        harness: String,
        session: String,
    },
    Group {
        id: String,
        workspace: Option<String>,
    },
    CloudSession {
        team: String,
        machine: String,
        session: String,
        kind: CloudSessionKind,
    },
    LegacyWorkspace {
        workspace: String,
        fallback: Option<String>,
    },
    LegacyPane {
        workspace: String,
        pane: String,
    },
    LegacySurface {
        workspace: String,
        surface: String,
        fallback_workspace: Option<String>,
        fallback_surface: Option<String>,
    },
}

impl Target {
    pub fn is_agent(&self) -> bool {
        matches!(self, Target::Agent { .. })
    }
}

/// A link to one object in cmux.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DeepLink {
    pub target: Target,
    /// The `machine_` resource id of the machine the target lives on.
    pub machine: Option<String>,
    /// An agent link's `?host=` display hint.
    pub host_hint: Option<String>,
    /// An agent link's `?name=` display hint.
    pub name_hint: Option<String>,
    /// An agent link's `?message=`.
    pub message: Option<String>,
}

/// A link and the names of the parameters it carried that cmux did not use.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parsed {
    pub link: DeepLink,
    pub ignored: Vec<String>,
}

/// The host of the sign-in callback, never a link.
pub const AUTH_CALLBACK_HOST: &str = "auth-callback";
/// The fragment that names a turn: `#turn-<turnId>`.
pub const TURN_FRAGMENT_PREFIX: &str = "turn-";
/// What the page calls the two parts of an agent link's path.
pub const AGENT_PATH_KEYS: [&str; 2] = ["harness", "session"];
pub const MACHINE_KEY: &str = "machine";
pub const HOST_HINT_KEY: &str = "host";
pub const NAME_HINT_KEY: &str = "name";
pub const MESSAGE_KEY: &str = "message";
/// The hex digits after a resource id's prefix (128 bits).
pub const RESOURCE_HEX_DIGITS: usize = 32;
/// The lengths a session or turn id may have.
pub const TOKEN_LENGTHS: (usize, usize) = (1, 200);
/// The daemon's outside-harness session id bound.
pub const AGENT_SESSION_LENGTHS: (usize, usize) = (1, 256);
/// The lengths a harness name or a display hint may have.
pub const SHORT_TOKEN_LENGTHS: (usize, usize) = (1, 64);

fn within(len: usize, bounds: (usize, usize)) -> bool {
    bounds.0 <= len && len <= bounds.1
}

fn is_lower_hex(b: &u8) -> bool {
    b.is_ascii_digit() || (b'a'..=b'f').contains(b)
}

fn is_lower_alnum(b: &u8) -> bool {
    b.is_ascii_digit() || b.is_ascii_lowercase()
}

/// `<prefix>` plus 32 lowercase hex digits (cmux-tui/spec/resource-api-v2.md).
pub fn is_resource_id(text: &str, prefix: &str) -> bool {
    text.strip_prefix(prefix).is_some_and(|hex| {
        hex.len() == RESOURCE_HEX_DIGITS && hex.as_bytes().iter().all(is_lower_hex)
    })
}

/// A cloud group id: `grp_` and 20 lowercase letters or digits.
pub fn is_group_id(text: &str) -> bool {
    text.strip_prefix("grp_")
        .is_some_and(|rest| rest.len() == 20 && rest.as_bytes().iter().all(is_lower_alnum))
}

/// A team id: `team_` and 20 lowercase letters or digits.
pub fn is_team_id(text: &str) -> bool {
    text.strip_prefix("team_")
        .is_some_and(|rest| rest.len() == 20 && rest.as_bytes().iter().all(is_lower_alnum))
}

/// A Chief home id: 8 lowercase hex digits.
pub fn is_chief_home(text: &str) -> bool {
    text.len() == 8 && text.as_bytes().iter().all(is_lower_hex)
}

/// An acpmux session or turn id: 1 to 200 ASCII letters, digits, `-`, `_` or `.`.
pub fn is_token(text: &str) -> bool {
    within(text.len(), TOKEN_LENGTHS)
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// An acpmux harness name: 1 to 64 lowercase ASCII letters, digits or `-`.
pub fn is_harness(text: &str) -> bool {
    within(text.len(), SHORT_TOKEN_LENGTHS)
        && text.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase() || b == b'-')
}

/// A display hint: a token of at most 64 characters, not only dots.
pub fn is_hint(text: &str) -> bool {
    within(text.len(), SHORT_TOKEN_LENGTHS) && is_token(text) && !is_only_dots(text)
}

/// An agent link's harness session id: 1 to 256 letters, digits, `-`, `_`, `.` or `:`, not only dots.
pub fn is_agent_session(text: &str) -> bool {
    within(text.len(), AGENT_SESSION_LENGTHS)
        && !is_only_dots(text)
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
}

/// An agent message id: a token, not only dots.
pub fn is_agent_message(text: &str) -> bool {
    is_token(text) && !is_only_dots(text)
}

/// Whether every byte is a dot (true for the empty text).
pub fn is_only_dots(text: &str) -> bool {
    text.bytes().all(|b| b == b'.')
}

pub use url::is_scheme;

/// A Cloud machine id: `vm_` or `vm-` and 1 to 64 ASCII letters or digits.
pub fn is_cloud_vm(text: &str) -> bool {
    let rest = text.strip_prefix("vm_").or_else(|| text.strip_prefix("vm-"));
    rest.is_some_and(|rest| {
        within(rest.len(), (1, 64)) && rest.bytes().all(|b| b.is_ascii_alphanumeric())
    })
}

/// A Cloud session or workspace id: a letter or digit, then up to 127 letters, digits, `.`, `_`, `:` or `-`.
pub fn is_cloud_session_id(text: &str) -> bool {
    let bytes = text.as_bytes();
    let Some(first) = bytes.first() else { return false };
    within(bytes.len(), (1, 128))
        && first.is_ascii_alphanumeric()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// `UUID(uuidString:)`: 8-4-4-4-12 hex digits in either case, as its uppercase `uuidString`.
pub fn uuid(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    for (i, b) in bytes.iter().enumerate() {
        let ok = if matches!(i, 8 | 13 | 18 | 23) { *b == b'-' } else { b.is_ascii_hexdigit() };
        if !ok {
            return None;
        }
    }
    Some(text.to_ascii_uppercase())
}

impl DeepLink {
    pub fn new(target: Target) -> Self {
        DeepLink { target, machine: None, host_hint: None, name_hint: None, message: None }
    }

    /// Whether every id fits its kind's grammar, so a formatted link parses back the same.
    pub fn is_well_formed(&self) -> bool {
        if self.machine.as_deref().is_some_and(|m| !is_resource_id(m, "machine_")) {
            return false;
        }
        if self.host_hint.as_deref().is_some_and(|h| !is_hint(h))
            || self.name_hint.as_deref().is_some_and(|h| !is_hint(h))
            || self.message.as_deref().is_some_and(|m| !is_agent_message(m))
        {
            return false;
        }
        // Only an agent link carries hints; any other would not parse back the same.
        if (self.host_hint.is_some() || self.name_hint.is_some() || self.message.is_some())
            && !self.target.is_agent()
        {
            return false;
        }
        match &self.target {
            Target::Workspace(id) => is_resource_id(id, "ws_"),
            Target::Pane(id) => is_resource_id(id, "pane_"),
            Target::Tab(id) => is_resource_id(id, "tab_"),
            Target::Session { id, turn } => is_token(id) && turn.as_deref().is_none_or(is_token),
            Target::ChiefSession { home, session } => is_chief_home(home) && is_token(session),
            Target::Agent { harness, session } => is_harness(harness) && is_agent_session(session),
            Target::Group { id, workspace } => {
                is_group_id(id) && workspace.as_deref().is_none_or(|w| is_resource_id(w, "ws_"))
            }
            Target::CloudSession { team, machine, session, .. } => {
                is_team_id(team) && is_cloud_vm(machine) && is_cloud_session_id(session)
            }
            Target::LegacyWorkspace { .. }
            | Target::LegacyPane { .. }
            | Target::LegacySurface { .. } => true,
        }
    }

    /// The link as URL text in `scheme`, nil when an id does not fit its kind's grammar.
    pub fn url(&self, scheme: &str) -> Option<String> {
        if !self.is_well_formed() || !is_scheme(scheme) {
            return None;
        }
        let mut text = format!("{scheme}://");
        let mut query: Vec<String> = Vec::new();
        let mut fragment = None;
        match &self.target {
            Target::Workspace(id) => text += &format!("workspace/{id}"),
            Target::Pane(id) => text += &format!("pane/{id}"),
            Target::Tab(id) => text += &format!("tab/{id}"),
            Target::Session { id, turn } => {
                text += &format!("session/{id}");
                fragment = turn.as_ref().map(|t| format!("{TURN_FRAGMENT_PREFIX}{t}"));
            }
            Target::ChiefSession { home, session } => {
                text += &format!("chief/{home}/session/{session}");
            }
            Target::Group { id, workspace } => {
                text += &format!("group/{id}");
                if let Some(workspace) = workspace {
                    text += &format!("/workspace/{workspace}");
                }
            }
            Target::CloudSession { team, machine, session, kind } => {
                text += &format!("cloud/{}/{team}/{machine}/{session}", kind.raw());
            }
            Target::Agent { harness, session } => {
                text += &format!("agent/{harness}/{session}");
                // The order schemas/deeplinks/agent-link.json states.
                if let Some(host) = &self.host_hint {
                    query.push(format!("{HOST_HINT_KEY}={host}"));
                }
                if let Some(name) = &self.name_hint {
                    query.push(format!("{NAME_HINT_KEY}={name}"));
                }
                if let Some(message) = &self.message {
                    query.push(format!("{MESSAGE_KEY}={message}"));
                }
            }
            Target::LegacyWorkspace { workspace, fallback } => {
                text += &format!("workspace/{workspace}");
                if let Some(fallback) = fallback {
                    query.push(format!("stable_workspace_id={fallback}"));
                }
            }
            Target::LegacyPane { workspace, pane } => {
                text += &format!("workspace/{workspace}/pane/{pane}");
            }
            Target::LegacySurface { workspace, surface, fallback_workspace, fallback_surface } => {
                text += &format!("workspace/{workspace}/surface/{surface}");
                if let Some(id) = fallback_workspace {
                    query.push(format!("stable_workspace_id={id}"));
                }
                if let Some(id) = fallback_surface {
                    query.push(format!("stable_surface_id={id}"));
                }
            }
        }
        if let Some(machine) = &self.machine {
            query.push(format!("{MACHINE_KEY}={machine}"));
        }
        if !query.is_empty() {
            text += "?";
            text += &query.join("&");
        }
        if let Some(fragment) = fragment {
            text += "#";
            text += &fragment;
        }
        Some(text)
    }

    /// The names of the parameters this link carries a value for (an agent link's path names too).
    pub fn used_parameters(&self) -> Vec<&'static str> {
        let mut names = Vec::new();
        if self.target.is_agent() {
            names.extend(AGENT_PATH_KEYS);
        }
        if self.machine.is_some() {
            names.push(MACHINE_KEY);
        }
        if self.host_hint.is_some() {
            names.push(HOST_HINT_KEY);
        }
        if self.name_hint.is_some() {
            names.push(NAME_HINT_KEY);
        }
        if self.message.is_some() {
            names.push(MESSAGE_KEY);
        }
        names
    }
}

/// The query parameters a link of this kind reads; every other name is ignored.
pub fn parameters(target: &Target) -> &'static [&'static str] {
    match target {
        Target::Agent { .. } => &[MACHINE_KEY, HOST_HINT_KEY, NAME_HINT_KEY, MESSAGE_KEY],
        Target::LegacyWorkspace { .. } | Target::LegacySurface { .. } => {
            &[MACHINE_KEY, "stable_workspace_id", "stable_surface_id"]
        }
        Target::CloudSession { .. } => &[],
        _ => &[MACHINE_KEY],
    }
}

/// The link `url` names in `scheme`, with the names of the parameters it ignored.
///
/// Nil for another scheme, the `auth-callback` host, an unknown host, a malformed id, extra path
/// segments, a user, password or port, and a fragment other than a session's `#turn-<turnId>`.
pub fn read(url: &str, scheme: &str) -> Option<Parsed> {
    read_components(&Components::parse(url), scheme)
}

/// The link `url` names in `scheme`.
pub fn parse(url: &str, scheme: &str) -> Option<DeepLink> {
    read(url, scheme).map(|parsed| parsed.link)
}

pub(crate) fn read_components(components: &Components, scheme: &str) -> Option<Parsed> {
    let url_scheme = components.scheme.as_deref()?;
    if !url_scheme.eq_ignore_ascii_case(scheme)
        || components.user.is_some()
        || components.password.is_some()
        || components.has_port
    {
        return None;
    }
    let host = components.lower_host().filter(|h| !h.is_empty())?;
    let segments = components.segments();
    let query = components.query_items().unwrap_or_default();
    let target = target(&host, &segments, &query, components.fragment.as_deref())?;
    let mut ignored: Vec<String> = Vec::new();
    let mut machine = None;
    let machine_items: Vec<&QueryItem> = query.iter().filter(|q| q.name == MACHINE_KEY).collect();
    if !machine_items.is_empty() {
        // `?machine` with no value names no machine; an agent link still says it carried the name.
        let machines: Vec<&String> =
            machine_items.iter().filter_map(|q| q.value.as_ref()).collect();
        if target.is_agent() {
            if machines.len() == 1
                && machine_items.len() == 1
                && is_resource_id(machines[0], "machine_")
            {
                machine = Some(machines[0].clone());
            } else {
                ignored.push(MACHINE_KEY.to_owned());
            }
        } else if let Some(first) = machines.first() {
            if !is_resource_id(first, "machine_") {
                return None;
            }
            machine = Some((*first).clone());
        }
    }
    let mut link = DeepLink { machine, ..DeepLink::new(target.clone()) };
    if target.is_agent() {
        // A hint cmux cannot use is dropped and named; a repeated one has no single value.
        let mut hint = |name: &str, fits: fn(&str) -> bool| -> Option<String> {
            let items: Vec<&QueryItem> = query.iter().filter(|q| q.name == name).collect();
            if items.is_empty() {
                return None;
            }
            match (items.len(), items[0].value.as_deref()) {
                (1, Some(value)) if fits(value) => Some(value.to_owned()),
                _ => {
                    ignored.push(name.to_owned());
                    None
                }
            }
        };
        link.host_hint = hint(HOST_HINT_KEY, is_hint);
        link.name_hint = hint(NAME_HINT_KEY, is_hint);
        link.message = hint(MESSAGE_KEY, is_agent_message);
    }
    let known = parameters(&target);
    ignored
        .extend(query.iter().filter(|q| !known.contains(&q.name.as_str())).map(|q| q.name.clone()));
    let mut seen = std::collections::HashSet::new();
    ignored.retain(|name| seen.insert(name.clone()));
    Some(Parsed { link, ignored })
}

fn target(
    host: &str,
    segments: &[String],
    query: &[QueryItem],
    fragment: Option<&str>,
) -> Option<Target> {
    let first = segments.first()?;
    match host {
        "workspace" => {
            if let Some(workspace) = uuid(first) {
                if fragment.is_some() {
                    return None;
                }
                return legacy(workspace, segments, query);
            }
            (segments.len() == 1 && fragment.is_none() && is_resource_id(first, "ws_"))
                .then(|| Target::Workspace(first.clone()))
        }
        "pane" => (segments.len() == 1 && fragment.is_none() && is_resource_id(first, "pane_"))
            .then(|| Target::Pane(first.clone())),
        "tab" => (segments.len() == 1 && fragment.is_none() && is_resource_id(first, "tab_"))
            .then(|| Target::Tab(first.clone())),
        "chief" => (segments.len() == 3
            && segments[1] == "session"
            && fragment.is_none()
            && is_chief_home(first)
            && is_token(&segments[2]))
        .then(|| Target::ChiefSession { home: first.clone(), session: segments[2].clone() }),
        "group" => {
            if fragment.is_some() || !is_group_id(first) {
                return None;
            }
            if segments.len() == 1 {
                return Some(Target::Group { id: first.clone(), workspace: None });
            }
            (segments.len() == 3
                && segments[1] == "workspace"
                && is_resource_id(&segments[2], "ws_"))
            .then(|| Target::Group { id: first.clone(), workspace: Some(segments[2].clone()) })
        }
        "cloud" => cloud_target(segments, fragment),
        "agent" => (segments.len() == 2
            && fragment.is_none()
            && is_harness(first)
            && is_agent_session(&segments[1]))
        .then(|| Target::Agent { harness: first.clone(), session: segments[1].clone() }),
        "session" => {
            if segments.len() != 1 || !is_token(first) {
                return None;
            }
            let Some(fragment) = fragment else {
                return Some(Target::Session { id: first.clone(), turn: None });
            };
            let turn = fragment.strip_prefix(TURN_FRAGMENT_PREFIX)?;
            is_token(turn)
                .then(|| Target::Session { id: first.clone(), turn: Some(turn.to_owned()) })
        }
        // Includes `auth-callback`, the sign-in callback.
        _ => None,
    }
}

/// `cloud/<session|workspace>/<team>/<vm>/<id>`'s target.
fn cloud_target(segments: &[String], fragment: Option<&str>) -> Option<Target> {
    if fragment.is_some() || segments.len() != 4 {
        return None;
    }
    let kind = CloudSessionKind::from_raw(&segments[0])?;
    (is_team_id(&segments[1]) && is_cloud_vm(&segments[2]) && is_cloud_session_id(&segments[3]))
        .then(|| Target::CloudSession {
            team: segments[1].clone(),
            machine: segments[2].clone(),
            session: segments[3].clone(),
            kind,
        })
}

/// Nightly's grammar: `workspace/<uuid>`, optionally `pane/<uuid>`, `surface/<uuid>` or `panel/<uuid>`.
fn legacy(workspace: String, segments: &[String], query: &[QueryItem]) -> Option<Target> {
    let fallback_workspace = stable_id("stable_workspace_id", query)?;
    let fallback_surface = stable_id("stable_surface_id", query)?;
    if segments.len() == 1 {
        return Some(Target::LegacyWorkspace { workspace, fallback: fallback_workspace });
    }
    if segments.len() != 3 {
        return None;
    }
    let child = uuid(&segments[2])?;
    match segments[1].to_lowercase().as_str() {
        "pane" => Some(Target::LegacyPane { workspace, pane: child }),
        "surface" | "panel" => Some(Target::LegacySurface {
            workspace,
            surface: child,
            fallback_workspace,
            fallback_surface,
        }),
        _ => None,
    }
}

/// The UUID of the first query item `name`: `Some(None)` when absent, nil when not a UUID.
fn stable_id(name: &str, query: &[QueryItem]) -> Option<Option<String>> {
    let Some(item) = query.iter().find(|q| q.name == name) else { return Some(None) };
    item.value.as_deref().and_then(uuid).map(Some)
}

/// The `cloud:<team>/<vm>/<session>` key or a `cmux…://cloud/…` link as a link. The key names no
/// kind; it reads as a chat.
pub fn cloud_session(text: &str) -> Option<DeepLink> {
    let trimmed = text.trim();
    if let Some(key) = trimmed.strip_prefix("cloud:") {
        let parts: Vec<&str> = key.split('/').collect();
        if parts.len() == 3
            && is_team_id(parts[0])
            && is_cloud_vm(parts[1])
            && is_cloud_session_id(parts[2])
        {
            return Some(DeepLink::new(Target::CloudSession {
                team: parts[0].to_owned(),
                machine: parts[1].to_owned(),
                session: parts[2].to_owned(),
                kind: CloudSessionKind::Chat,
            }));
        }
        return None;
    }
    let components = Components::parse(trimmed);
    let scheme = components.scheme.clone()?;
    if !scheme.starts_with("cmux") {
        return None;
    }
    let link = read_components(&components, &scheme)?.link;
    matches!(link.target, Target::CloudSession { .. }).then_some(link)
}

/// The tabs an `agent/<harness>/<session>` link may open, best first: the chat tab that adopted
/// the session, then the terminals whose agent reported it under the link's harness, then those
/// whose agent names no harness we know. A terminal of another harness is skipped.
pub fn agent_tabs(
    harness: &str,
    session: &str,
    adopted: Option<&str>,
    terminals: &[AgentCandidate],
) -> Vec<String> {
    let running: Vec<&AgentCandidate> =
        terminals.iter().filter(|t| t.session.as_deref() == Some(session)).collect();
    let mut tabs: Vec<String> = adopted.map(str::to_owned).into_iter().collect();
    tabs.extend(
        running
            .iter()
            .filter(|t| known_harness(t.harness.as_deref()).as_deref() == Some(harness))
            .map(|t| t.tab.clone()),
    );
    tabs.extend(
        running
            .iter()
            .filter(|t| known_harness(t.harness.as_deref()).is_none())
            .map(|t| t.tab.clone()),
    );
    tabs
}

/// A terminal tab that may run an outside agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentCandidate {
    pub tab: String,
    pub harness: Option<String>,
    pub session: Option<String>,
}

/// The harnesses a terminal's reported agent can name.
pub const KNOWN_HARNESSES: [&str; 5] = ["claude", "codex", "opencode", "gemini", "muse"];

/// The harness a reported agent names (`claude-code` is `claude`), nil for none we know.
pub fn known_harness(agent: Option<&str>) -> Option<String> {
    let agent = agent?.to_lowercase();
    if agent == "claude-code" {
        return Some("claude".to_owned());
    }
    KNOWN_HARNESSES.contains(&agent.as_str()).then_some(agent)
}
