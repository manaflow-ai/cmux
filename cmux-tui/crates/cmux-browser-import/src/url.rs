//! URLs worth importing: web pages and files, never browser-internal pages
//! (`ImportableURL` in `BrowserTime.swift`), and a template's host
//! (`ImportedSearchEngine.host`).
//!
//! A reader keeps the source's text: the app turns it into a `URL` with `URL(string:)` when it
//! decodes the result, as the Swift reader did, so the URL is Foundation's own.

const SCHEMES: [&str; 4] = ["http", "https", "file", "ftp"];

/// SQL filter for the same schemes, so `LIMIT` counts only importable rows.
pub fn sql_filter(column: &str) -> String {
    format!(
        "({column} LIKE 'http:%' OR {column} LIKE 'https:%' OR {column} LIKE 'file:%' OR {column} LIKE 'ftp:%')"
    )
}

/// The scheme of `text` (RFC 3986: a letter, then letters, digits, `+`, `-` and `.`, then `:`).
pub fn scheme(text: &str) -> Option<&str> {
    let (scheme, _) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
    .then_some(scheme)
}

/// `text` when its scheme is http, https, file or ftp (any case).
pub fn importable(text: &str) -> Option<&str> {
    let scheme = scheme(text)?.to_ascii_lowercase();
    SCHEMES.contains(&scheme.as_str()).then_some(text)
}

/// The host of an absolute URL (`URL.host()`), lowercased: the authority after `scheme://`,
/// without user info, port or IPv6 brackets. None without an authority or with an empty host.
pub fn host(text: &str) -> Option<String> {
    let scheme = scheme(text)?;
    let rest = text.get(scheme.len()..)?.strip_prefix("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        bracketed.split_once(']').map(|(inner, _)| inner)?
    } else {
        host_port.split_once(':').map_or(host_port, |(host, _)| host)
    };
    (!host.is_empty()).then(|| percent_decode(host).to_lowercase())
}

/// `%XX` decoded (`removingPercentEncoding`, lenient: a bad escape stays as it is).
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0usize;
    while let Some(&byte) = bytes.get(index) {
        let escaped = (byte == b'%')
            .then(|| bytes.get(index.saturating_add(1)..index.saturating_add(3)))
            .flatten()
            .filter(|pair| pair.iter().all(u8::is_ascii_hexdigit))
            .and_then(|pair| std::str::from_utf8(pair).ok())
            .and_then(|pair| u8::from_str_radix(pair, 16).ok());
        match escaped {
            Some(value) => {
                out.push(value);
                index = index.saturating_add(3);
            }
            None => {
                out.push(byte);
                index = index.saturating_add(1);
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
