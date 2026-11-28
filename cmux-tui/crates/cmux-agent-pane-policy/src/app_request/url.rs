//! The address checks of the page's requests (`isAgentPanePreview`): a strict hand parse of the
//! few shapes the host accepts.

/// The scheme, authority and rest of an absolute `http`/`https` address.
fn split(text: &str) -> Option<(&str, &str)> {
    let (scheme, rest) = text.split_once("://")?;
    if scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https") {
        let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        Some((rest.get(..end)?, rest.get(end..)?))
    } else {
        None
    }
}

/// Whether `text` is an http or https address with no user or password, on localhost or 127.0.0.1.
pub fn is_preview_url(text: &str) -> bool {
    if text.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    let Some((authority, _)) = split(text) else { return false };
    if authority.contains('@') {
        return false;
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    if port.is_some_and(|port| port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit())) {
        return false;
    }
    host.eq_ignore_ascii_case("localhost") || host == "127.0.0.1"
}

/// Whether `text` is an absolute http or https address with a host (`AgentPaneReplyRequest.webURL`).
pub fn is_web_url(text: &str) -> bool {
    if text.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    split(text).is_some_and(|(authority, _)| {
        let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
        !host.is_empty() && !host.starts_with(':')
    })
}
