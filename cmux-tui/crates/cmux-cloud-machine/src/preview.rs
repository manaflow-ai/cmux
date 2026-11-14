//! A live preview's browser URL: the platform's short-lived authentication bootstrap URL, asked
//! to open a path on the preview. The bootstrap credential stays intact; the preview's server
//! validates `return_to` as a relative path before redirecting.

/// The URL to open for `path` on the preview whose bootstrap URL is `url`: only an `https` URL
/// with a host and no user or password; any other path than `/` replaces `return_to`. None for a
/// URL that is not one (`machine.preview_invalid_url`).
pub fn browser_url(url: &str, path: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    if authority.contains('@') {
        return None;
    }
    let (host, port) = match authority.strip_prefix('[') {
        Some(bracketed) => bracketed
            .split_once(']')
            .map_or(("", ""), |(host, port)| (host, port.trim_start_matches(':'))),
        None => authority.split_once(':').unwrap_or((authority, "")),
    };
    if !port.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    if host.is_empty() {
        return None;
    }
    if path == "/" {
        return Some(url.to_owned());
    }
    let (before_fragment, fragment) = match url.split_once('#') {
        Some((before, fragment)) => (before, Some(fragment)),
        None => (url, None),
    };
    let (base, query) = before_fragment
        .split_once('?')
        .map_or((before_fragment, None), |(base, query)| (base, Some(query)));
    let mut items: Vec<&str> = query
        .into_iter()
        .flat_map(|query| query.split('&'))
        .filter(|item| !item.is_empty() && item.split('=').next() != Some("return_to"))
        .collect();
    let return_to = format!("return_to={}", encode(path));
    items.push(&return_to);
    let mut opened = format!("{base}?{}", items.join("&"));
    if let Some(fragment) = fragment {
        opened.push('#');
        opened.push_str(fragment);
    }
    Some(opened)
}

/// `value` percent-encoded for a query value: unreserved characters and `/` `:` `@` stay.
fn encode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~/:@!$'()*,;".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests;
