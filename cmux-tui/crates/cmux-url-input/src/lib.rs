//! Normalization of user-typed browser URLs (scheme inference, loopback
//! detection, query encoding).
//!
//! A crate of its own, with no daemon dependency, so the app can link the
//! same rule (cmux-app-ffi); cmux-tui-core re-exports [`normalize_url`].

/// Turn user-entered text into a navigable URL, the same way for every
/// entrypoint (TUI omnibar, `browser-navigate` and `new-browser-tab`
/// over the control socket, direct `BrowserSurface::navigate` in cmux-tui-core):
/// explicit schemes pass through, loopback hosts and intranet addresses
/// (`go/gday`, `devbox:8080`, `nas.local`, private IPs) get `http://`,
/// dotted hosts get `https://`, and anything else becomes a web search.
/// Idempotent, so layered callers may each apply it.
pub fn normalize_url(input: &str) -> String {
    let trimmed = input.trim();
    if trimmed.contains("://") {
        return trimmed.to_string();
    }
    if is_loopback_address(trimmed) {
        return format!("http://{trimmed}");
    }
    // Before the scheme check: `devbox:8080/api` is a host and port.
    if is_intranet_address(trimmed) {
        return format!("http://{trimmed}");
    }
    if has_bare_scheme(trimmed) {
        return trimmed.to_string();
    }
    if !trimmed.chars().any(char::is_whitespace) && trimmed.contains('.') {
        return format!("https://{trimmed}");
    }
    format!("https://www.google.com/search?q={}", percent_encode_query(trimmed))
}

/// A scheme-looking prefix (`about:`, `mailto:`, `data:`, ...) that is
/// not a host:port pair: `myhost:8080` is a search, `mailto:x` is not.
fn has_bare_scheme(input: &str) -> bool {
    let Some((scheme, rest)) = input.split_once(':') else {
        return false;
    };
    if scheme.contains('.') || (!rest.is_empty() && rest.chars().all(|ch| ch.is_ascii_digit())) {
        return false;
    }
    let mut chars = scheme.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_alphabetic()
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-'))
}

/// A scheme-less address whose host is not globally unique, so it never
/// has a public certificate (Chromium's `net::IsHostnameNonUnique`, the
/// cmux-next omnibar's `BrowserURLResolver`). A single label needs a path,
/// a trailing slash or a port: `go/gday` loads, `go` alone is a search.
fn is_intranet_address(input: &str) -> bool {
    if input.chars().any(char::is_whitespace) {
        return false;
    }
    let authority_end = input.find(['/', '?', '#']).unwrap_or(input.len());
    let authority = &input[..authority_end];
    if authority.is_empty() || authority.contains('@') {
        return false;
    }
    let lower = authority.to_ascii_lowercase();
    let (host, has_port) = if let Some(rest) = lower.strip_prefix('[') {
        let Some((host, after)) = rest.split_once(']') else {
            return false;
        };
        match after.strip_prefix(':') {
            None if after.is_empty() => (host.to_string(), false),
            Some(port) if is_port(port) => (host.to_string(), true),
            _ => return false,
        }
    } else {
        match lower.split_once(':') {
            None => (lower.clone(), false),
            Some((host, port)) if is_port(port) => (host.to_string(), true),
            Some(_) => return false,
        }
    };
    if host.is_empty() || !is_non_unique_host(&host) {
        return false;
    }
    let has_path = input[authority_end..].starts_with('/');
    host.contains(['.', ':']) || has_port || has_path
}

fn is_port(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) && text.parse::<u16>().is_ok()
}

fn is_non_unique_host(host: &str) -> bool {
    if host.contains(':') {
        return ["fc", "fd", "fe8", "fe9", "fea", "feb"]
            .iter()
            .any(|prefix| host.starts_with(prefix));
    }
    let labels: Vec<&str> = host.split('.').collect();
    let octets: Vec<u8> = labels.iter().filter_map(|label| label.parse::<u8>().ok()).collect();
    if labels.len() == 4 && octets.len() == 4 {
        return matches!(
            (octets[0], octets[1]),
            (10, _) | (192, 168) | (169, 254) | (172, 16..=31) | (100, 64..=127)
        );
    }
    if labels.iter().any(|label| label.is_empty()) {
        return false;
    }
    if labels.len() == 1 {
        return !host.bytes().all(|b| b.is_ascii_digit())
            && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    }
    const SUFFIXES: [&str; 11] = [
        "local",
        "lan",
        "internal",
        "intranet",
        "corp",
        "home",
        "localdomain",
        "test",
        "example",
        "invalid",
        "home.arpa",
    ];
    SUFFIXES.iter().any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")))
}

fn is_loopback_address(input: &str) -> bool {
    let starts = ["localhost", "127.0.0.1", "[::1]"];
    starts.iter().any(|prefix| {
        let Some(rest) = input.strip_prefix(prefix) else {
            return false;
        };
        rest.is_empty() || matches!(rest.as_bytes()[0], b':' | b'/' | b'?')
    })
}

fn percent_encode_query(input: &str) -> String {
    let mut out = String::new();
    for byte in input.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            other => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.push('%');
                out.push(HEX[(other >> 4) as usize] as char);
                out.push(HEX[(other & 0x0F) as usize] as char);
            }
        }
    }
    out
}

#[cfg(test)]
mod normalize_url_corpus;
