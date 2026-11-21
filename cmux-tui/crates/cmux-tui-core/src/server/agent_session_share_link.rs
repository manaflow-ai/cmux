//! `agent-session-share-open-link`: a chat share link the app was handed (a click on
//! `https://<share host>/g/<id>#<secret>`, or the guest page's `<scheme>://share?link=<page>#<secret>`,
//! which it asks the operating system to open when the cmux app is installed) becomes the page the app
//! opens in its own web view, signed in as the person's cmux account so they join as themselves.
//!
//! A link made by a build other than the default a guest page opens carries `?app=<scheme>` (dropped here).
//! Only a share page of a known room is opened: the configured room's own origin, or a declared platform
//! deployment's origin or short share host (`platform::share_deployment`). The person's cmux token is
//! spent only on a page of the configured room's own deployment: one `POST /v1/chat-shares/<id>/handoff`
//! for a one-time code (cmux-platform `mintHandoff`), never with the secret. The answer is
//! `<origin>/<g|i>/<id>?in_app=1&cmux_handoff=<code>#<secret>`: the secret stays in the fragment, which
//! no browser sends, and the platform spends the code on that page's first load and redirects to it
//! without the code. `in_app=1` keeps the page from asking the app to open it again. Without a token,
//! a room that refuses, or another deployment's link, the page opens signed out (`signed_in: false`).

use std::time::Duration;

use super::*;
use crate::cloud_conversations::platform;
use zeroize::Zeroizing;

/// The share id and the secret as the daemon makes them (`token::<16>`, URL-safe), within the room's bounds.
const ID: fn(&str) -> bool = |s| {
    (16..=128).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
};
const SECRET: fn(&str) -> bool = |s| {
    (8..=128).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
};

/// One hand-off mint. timeout: a room that never answers must not hold the open; the page then opens
/// signed out, and the person can still join from it.
const HANDOFF_TIMEOUT: Duration = Duration::from_secs(10);

/// `agent-session-share-open-link`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct OpenLink {
    link: String,
    /// The person's cmux (Stack) access token, spent only on the configured room's deployment.
    #[serde(default)]
    token: Option<String>,
}

/// A share page a link names.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct ShareLink {
    /// `https://<host>` (or `http://` on loopback, local development).
    pub(super) origin: String,
    /// `g` for a link, `i` for an account invite.
    pub(super) page: &'static str,
    pub(super) share_id: String,
    /// A link's secret, from the fragment; an invite has none.
    pub(super) secret: Option<String>,
}

impl ShareLink {
    /// The page itself, with no secret: what a server may see.
    pub(super) fn page_url(&self) -> String {
        format!("{}/{}/{}", self.origin, self.page, self.share_id)
    }

    /// What the app opens: the page marked as in the app, with the hand-off code when there is one, and the
    /// secret only in the fragment.
    pub(super) fn open_url(&self, handoff: Option<&str>) -> String {
        let code = handoff.map(|code| format!("&cmux_handoff={code}")).unwrap_or_default();
        let fragment = self.secret.as_ref().map(|secret| format!("#{secret}")).unwrap_or_default();
        format!("{}?in_app=1{code}{fragment}", self.page_url())
    }
}

/// Reads a share link in either form; nil for anything else (another path, a query other than `app=`, credentials
/// in the URL, a scheme that is not cmux's).
pub(super) fn parse(raw: &str) -> Option<ShareLink> {
    let url = url::Url::parse(raw).ok()?;
    let (page, secret) = match url.scheme() {
        "https" | "http" => (url.clone(), url.fragment().map(str::to_owned)),
        scheme if is_cmux_scheme(scheme) => {
            if url.host_str() != Some("share") {
                return None;
            }
            let mut links = url.query_pairs().filter(|(key, _)| key == "link");
            let link = links.next()?.1.into_owned();
            if links.next().is_some() {
                return None;
            }
            let page = url::Url::parse(&link).ok()?;
            // The secret rides only in the app URL's own fragment, never inside the page address.
            if page.fragment().is_some() {
                return None;
            }
            (page, url.fragment().map(str::to_owned))
        }
        _ => return None,
    };
    let loopback = matches!(page.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if !(page.scheme() == "https" || (page.scheme() == "http" && loopback))
        || !page.username().is_empty()
        || page.password().is_some()
        || !page.query().is_none_or(names_only_an_app)
    {
        return None;
    }
    let mut segments = page.path_segments()?;
    let kind = match segments.next()? {
        "g" => "g",
        "i" => "i",
        _ => return None,
    };
    let share_id = segments.next()?.to_owned();
    if !ID(&share_id) || segments.any(|rest| !rest.is_empty()) {
        return None;
    }
    let secret = match kind {
        "g" => secret.filter(|s| SECRET(s)),
        _ => None,
    };
    Some(ShareLink { origin: page.origin().ascii_serialization(), page: kind, share_id, secret })
}

/// A page's only query a link may carry: `app=<scheme>`, the build that made it (room `set_link_share_app_scheme`).
fn names_only_an_app(query: &str) -> bool {
    query.strip_prefix("app=").is_some_and(is_cmux_scheme)
}

/// `cmux`, `cmux-dev`, `cmux-nightly`, `cmux-dev-<tag>` or a bundle's `cmux.<name>`: a cmux build's own scheme,
/// `cmux` then `-` or `.` separated runs of `[a-z0-9]` (the guest page's `CMUX_SCHEME`, appLink.ts).
pub(super) fn is_cmux_scheme(scheme: &str) -> bool {
    let Some(rest) = scheme.strip_prefix("cmux") else { return false };
    let mut run = 0usize;
    for (index, byte) in rest.bytes().enumerate() {
        match byte {
            b'-' | b'.' if index == 0 || run > 0 => run = 0,
            b'a'..=b'z' | b'0'..=b'9' if index > 0 => run += 1,
            _ => return false,
        }
    }
    rest.is_empty() || run > 0
}

/// Whether a link's page belongs to a room this daemon knows: the configured room, or a declared deployment.
pub(super) fn known(link: &ShareLink, room: Option<&str>) -> bool {
    room == Some(link.origin.as_str()) || platform::share_deployment(&link.origin).is_some()
}

/// Whether the person's token may go to the link's room: only the configured room's own deployment (its
/// origin, or the same deployment's other host), so a token never reaches another environment or host.
pub(super) fn takes_token(link: &ShareLink, room: Option<&str>) -> bool {
    let Some(room) = room else { return false };
    room == link.origin
        || platform::share_deployment(room)
            .is_some_and(|deployment| platform::share_deployment(&link.origin) == Some(deployment))
}

pub(super) fn open(shares: &LinkShares, p: OpenLink) -> Result<Value, &'static str> {
    let token = p.token.map(Zeroizing::new);
    let link = parse(&p.link).ok_or("share.not_a_link")?;
    let room = shares.bridge.room();
    let room = room.as_ref().map(|room| room.url());
    if !known(&link, room) {
        return Err("share.not_a_link");
    }
    let handoff = match (token, shares.bridge.runtime()) {
        (Some(token), Some(runtime)) if !token.is_empty() && takes_token(&link, room) => {
            runtime.block_on(mint(&link, &token))
        }
        _ => None,
    };
    Ok(json!({"url": link.open_url(handoff.as_deref()), "signed_in": handoff.is_some()}))
}

/// The room's one-time code for this page and the token's account; nil when it refuses or does not answer.
async fn mint(link: &ShareLink, token: &str) -> Option<String> {
    let url = format!("{}/v1/chat-shares/{}/handoff", link.origin, link.share_id);
    let body = json!({"page": link.page});
    let (status, reply) =
        room::call(reqwest::Method::POST, &url, token, Some(&body), HANDOFF_TIMEOUT).await?;
    let code = reply.get("handoff").and_then(Value::as_str)?;
    ((200..300).contains(&status) && ID(code)).then(|| code.to_owned())
}

#[cfg(test)]
#[path = "agent_session_share_link_tests.rs"]
mod tests;
