//! The links the app opens beyond its own scheme: the Chief's `cmux` scheme, the https forms of
//! cloud group and agent session links, opaque agent references and settings links.

use super::url::{Components, QueryItem};
use super::{DeepLink, Target, is_agent_session, is_group_id, is_resource_id, read_components};

/// The scheme the Chief and its documents write, whatever the build.
pub const CHIEF_SCHEME: &str = "cmux";

/// The hosts that serve a cloud group's https hand-off page (`GET /g/<id>[/w/<ws_>]`).
pub const GROUP_WEB_HOSTS: [&str; 4] =
    ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux.com", "www.cmux.com"];

/// The hosts that serve the agent session link's web page (`/deeplink/agent`).
pub const AGENT_WEB_HOSTS: [&str; 2] = ["cmux.com", "www.cmux.com"];

/// The settings link path that turns Start Agent from Any App on.
pub const START_AGENT_FROM_ANY_APP_PATH: &str = "/start-agent-from-any-app";

/// The link `url` opens in this app, in the `cmux` scheme or `link_scheme`, or a cloud group's
/// https form. A Chief subagent's chat opens only on this machine and when the app has a Chief
/// (`has_chief`); legacy UUID links never.
pub fn app_link(url: &str, link_scheme: &str, has_chief: bool) -> Option<DeepLink> {
    let components = Components::parse(url);
    let link = read_components(&components, CHIEF_SCHEME)
        .or_else(|| read_components(&components, link_scheme))
        .map(|parsed| parsed.link)
        .or_else(|| group_web(url))?;
    match link.target {
        Target::ChiefSession { .. } => (link.machine.is_none() && has_chief).then_some(link),
        Target::LegacyWorkspace { .. }
        | Target::LegacyPane { .. }
        | Target::LegacySurface { .. } => None,
        _ => Some(link),
    }
}

/// The cloud group link an https URL names (`https://cloud-api.cmux.dev/g/grp_…[/w/ws_…]`).
pub fn group_web(url: &str) -> Option<DeepLink> {
    let c = Components::parse(url);
    if c.lower_scheme().as_deref() != Some("https")
        || c.user.is_some()
        || c.password.is_some()
        || c.has_port
        || c.encoded_query.is_some()
        || c.fragment.is_some()
    {
        return None;
    }
    let host = c.lower_host()?;
    if !GROUP_WEB_HOSTS.contains(&host.as_str()) {
        return None;
    }
    let segments = c.segments();
    if segments.len() < 2 || segments[0] != "g" || !is_group_id(&segments[1]) {
        return None;
    }
    if segments.len() == 2 {
        return Some(DeepLink::new(Target::Group { id: segments[1].clone(), workspace: None }));
    }
    (segments.len() == 4 && segments[2] == "w" && is_resource_id(&segments[3], "ws_")).then(|| {
        DeepLink::new(Target::Group {
            id: segments[1].clone(),
            workspace: Some(segments[3].clone()),
        })
    })
}

/// A cmux.com locale segment (`en`, `zh-CN`): ICU's `^[a-z]{2}(-[A-Z]{2})?$`, whose `$` also
/// matches before a final line terminator.
fn is_locale(segment: &str) -> bool {
    let body = ["\r\n", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]
        .iter()
        .find_map(|end| segment.strip_suffix(end))
        .unwrap_or(segment);
    let b = body.as_bytes();
    match b.len() {
        2 => b.iter().all(u8::is_ascii_lowercase),
        5 => {
            b[..2].iter().all(u8::is_ascii_lowercase)
                && b[2] == b'-'
                && b[3..].iter().all(u8::is_ascii_uppercase)
        }
        _ => false,
    }
}

/// The query of an https agent session link's page, nil for any other URL.
fn agent_web_query(c: &Components) -> Option<Vec<QueryItem>> {
    if c.lower_scheme().as_deref() != Some("https")
        || c.user.is_some()
        || c.password.is_some()
        || c.has_port
        || c.fragment.is_some()
    {
        return None;
    }
    let host = c.lower_host()?;
    if !AGENT_WEB_HOSTS.contains(&host.as_str()) {
        return None;
    }
    let segments = c.segments();
    let path =
        if segments.len() == 3 && is_locale(&segments[0]) { &segments[1..] } else { &segments[..] };
    (path == ["deeplink", "agent"]).then(|| c.query_items().unwrap_or_default())
}

fn named<'a>(query: &'a [QueryItem], name: &str) -> Vec<&'a QueryItem> {
    query.iter().filter(|q| q.name == name).collect()
}

/// The agent link an https agent session link names (`https://cmux.com/deeplink/agent?harness=
/// claude&session=…&host=…`), read as its `cmux://agent/<harness>/<session>` form. Nil for any
/// other URL and for the opaque `?id=` form.
pub fn agent_web(url: &str) -> Option<DeepLink> {
    let query = agent_web_query(&Components::parse(url))?;
    let one = |name: &str| {
        let items = named(&query, name);
        if items.len() == 1 { items[0].value.clone() } else { None }
    };
    let harness = one("harness")?;
    let session = one("session")?;
    // The native form, read as the parser reads it: the two values are its path, the hints its
    // query, every value as written.
    let native = Components {
        scheme: Some(CHIEF_SCHEME.to_owned()),
        host: Some("agent".to_owned()),
        encoded_path: format!("/{}/{}", encode_path_part(&harness), encode_path_part(&session)),
        encoded_query: {
            let hints: Vec<String> = query
                .iter()
                .filter(|q| ["host", "name", "message"].contains(&q.name.as_str()))
                .map(|q| match &q.value {
                    Some(value) => {
                        format!("{}={}", encode_query_part(&q.name), encode_query_part(value))
                    }
                    None => encode_query_part(&q.name),
                })
                .collect();
            (!hints.is_empty()).then(|| hints.join("&"))
        },
        ..Components::default()
    };
    let link = read_components(&native, CHIEF_SCHEME)?.link;
    link.target.is_agent().then_some(link)
}

fn encode(text: &str, keep: impl Fn(u8) -> bool) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if keep(b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A path segment: everything but unreserved characters is escaped, so it decodes to itself.
fn encode_path_part(text: &str) -> String {
    encode(text, |b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~'))
}

fn encode_query_part(text: &str) -> String {
    encode_path_part(text)
}

/// The harness session id an https agent link names when it names no harness (`?session=&host=`).
pub fn agent_web_session(url: &str) -> Option<String> {
    let query = agent_web_query(&Components::parse(url))?;
    if query.iter().any(|q| q.name == "harness") {
        return None;
    }
    let sessions = named(&query, "session");
    let session = (sessions.len() == 1).then(|| sessions[0].value.clone()).flatten()?;
    is_agent_session(&session).then_some(session)
}

/// The opaque agent reference (`aid-` and 20 lowercase hex digits) a link names in place of a
/// session: `cmux://agent?id=aid-…` (in `cmux` or `link_scheme`) or
/// `https://cmux.com/deeplink/agent?id=aid-…`. Nil for any other URL, for one that also names a
/// harness or session, and for an `id` written twice.
pub fn agent_reference(url: &str, link_scheme: &str) -> Option<String> {
    let c = Components::parse(url);
    let query = match agent_web_query(&c) {
        Some(web) => web,
        None => {
            let scheme = c.lower_scheme()?;
            let path = c.path();
            if !(scheme == CHIEF_SCHEME || scheme == link_scheme.to_lowercase())
                || c.lower_host().as_deref() != Some("agent")
                || !(path.is_empty() || path == "/")
                || c.user.is_some()
                || c.has_port
                || c.fragment.is_some()
            {
                return None;
            }
            c.query_items().unwrap_or_default()
        }
    };
    if query.iter().any(|q| q.name == "harness" || q.name == "session") {
        return None;
    }
    let ids = named(&query, "id");
    let id = (ids.len() == 1).then(|| ids[0].value.clone()).flatten()?;
    is_agent_reference(&id).then_some(id)
}

/// Whether `url` opens an agent's chat: an agent link in `link_scheme` or an opaque reference.
pub fn opens_agent_chat(url: &str, link_scheme: &str) -> bool {
    agent_reference(url, link_scheme).is_some()
        || super::read(url, link_scheme).is_some_and(|parsed| parsed.link.target.is_agent())
}

/// `aid-` and 20 lowercase hex digits.
pub fn is_agent_reference(text: &str) -> bool {
    text.len() == 24
        && text.strip_prefix("aid-").is_some_and(|hex| {
            hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// A settings link's path (`URL.path`, lowercased) when `url` is one in `cmux` or `link_scheme`.
pub fn settings_path(url: &str, link_scheme: &str) -> Option<String> {
    let c = Components::parse(url);
    let scheme = c.lower_scheme()?;
    ((scheme == CHIEF_SCHEME || scheme == link_scheme.to_lowercase())
        && c.lower_host().as_deref() == Some("settings"))
    .then(|| c.url_path().to_lowercase())
}

/// The Settings page place a settings link opens (`cmux://settings/models` is `#/settings/models`).
pub fn settings_route(url: &str, link_scheme: &str) -> Option<String> {
    let path = settings_path(url, link_scheme)?;
    let route = match path.as_str() {
        "/models" | "/models/" => "#/settings/models".to_owned(),
        "/models/add" | "/models/add/" => "#/settings/models?focus=models.add".to_owned(),
        "/cloud" | "/cloud/" => cloud_route(None),
        "/cloud/claude" | "/cloud/claude/" => cloud_route(Some("claude")),
        "/cloud/chatgpt" | "/cloud/chatgpt/" => cloud_route(Some("chatgpt")),
        "/cloud/api-key" | "/cloud/api-key/" => cloud_route(Some("apiKey")),
        _ => return None,
    };
    Some(route)
}

/// Settings > Cloud, opened on a row of its Models for Cloud card when one is named.
pub fn cloud_route(row: Option<&str>) -> String {
    match row {
        Some(row) => format!("#/settings/cloud?focus=cloud.{row}"),
        None => "#/settings/cloud".to_owned(),
    }
}
