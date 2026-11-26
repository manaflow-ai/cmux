//! A URL's parts as Foundation's `URLComponents` and `URL` read them, so a link reads the same
//! here as it did in the app: the scheme, the user, password and port (present or not), the
//! host and path percent-decoded, the query items split on `&` and the first `=` and decoded,
//! and the fragment decoded.

/// One `name[=value]` query item, decoded. A value is absent when the item has no `=`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueryItem {
    pub name: String,
    pub value: Option<String>,
}

/// The parts of a URL (RFC 3986 `scheme://user:password@host:port/path?query#fragment`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Components {
    /// The scheme as written, when the text starts with one.
    pub scheme: Option<String>,
    pub user: Option<String>,
    pub password: Option<String>,
    /// The host, percent-decoded; nil when there is no authority.
    pub host: Option<String>,
    /// Whether a non-empty port was written.
    pub has_port: bool,
    /// The path as written (percent-encoded).
    pub encoded_path: String,
    /// The query as written, after `?`.
    pub encoded_query: Option<String>,
    /// The fragment, percent-decoded.
    pub fragment: Option<String>,
}

/// Whether `text` is an RFC 3986 scheme: a letter, then letters, digits, `+`, `-` or `.`.
pub fn is_scheme(text: &str) -> bool {
    let bytes = text.as_bytes();
    let Some(first) = bytes.first() else { return false };
    first.is_ascii_alphabetic()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}

/// `text` percent-decoded, nil when an escape is malformed or the bytes are not UTF-8. With
/// `keep_slash`, `%2F` stays encoded (`URL.path`).
pub fn percent_decode(text: &str, keep_slash: bool) -> Option<String> {
    let mut out = Vec::with_capacity(text.len());
    let mut rest = text.as_bytes();
    while let Some((&first, after)) = rest.split_first() {
        if first != b'%' {
            out.push(first);
            rest = after;
            continue;
        }
        let [high, low, tail @ ..] = after else { return None };
        let byte = hex_value(*high)? << 4 | hex_value(*low)?;
        if keep_slash && byte == b'/' {
            out.extend_from_slice(&[b'%', *high, *low]);
        } else {
            out.push(byte);
        }
        rest = tail;
    }
    String::from_utf8(out).ok()
}

/// One hexadecimal digit's value.
fn hex_value(digit: u8) -> Option<u8> {
    match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        b'A'..=b'F' => Some(digit - b'A' + 10),
        _ => None,
    }
}

impl Components {
    /// The parts of `text`.
    pub fn parse(text: &str) -> Components {
        let mut parts = Components::default();
        let mut rest = text;
        if let Some((candidate, after)) = rest.split_once(':')
            && !candidate.contains(['/', '?', '#'])
            && is_scheme(candidate)
        {
            parts.scheme = Some(candidate.to_owned());
            rest = after;
        }
        if let Some((before, fragment)) = rest.split_once('#') {
            parts.fragment = Some(percent_decode(fragment, false).unwrap_or_default());
            rest = before;
        }
        if let Some((before, query)) = rest.split_once('?') {
            parts.encoded_query = Some(query.to_owned());
            rest = before;
        }
        if let Some(after) = rest.strip_prefix("//") {
            let end = after.find('/').unwrap_or(after.len());
            let (authority, path) = after.split_at_checked(end).unwrap_or((after, ""));
            parts.read_authority(authority);
            rest = path;
        }
        parts.encoded_path = rest.to_owned();
        parts
    }

    fn read_authority(&mut self, authority: &str) {
        let host_port = match authority.rsplit_once('@') {
            Some((info, host_port)) => {
                match info.split_once(':') {
                    Some((user, password)) => {
                        self.user = Some(percent_decode(user, false).unwrap_or_default());
                        self.password = Some(percent_decode(password, false).unwrap_or_default());
                    }
                    None => self.user = Some(percent_decode(info, false).unwrap_or_default()),
                }
                host_port
            }
            None => authority,
        };
        let (host, port) = if host_port.starts_with('[') {
            // `[v6]:port`: the host keeps its brackets; with no `]` it is the whole text.
            let host = host_port.split_inclusive(']').next().unwrap_or(host_port);
            let after = host_port.strip_prefix(host).unwrap_or("");
            (host, after.strip_prefix(':').unwrap_or(""))
        } else {
            host_port.rsplit_once(':').unwrap_or((host_port, ""))
        };
        self.host = percent_decode(host, false);
        self.has_port = !port.is_empty();
    }

    /// The path, percent-decoded (`URLComponents.path`).
    pub fn path(&self) -> String {
        percent_decode(&self.encoded_path, false).unwrap_or_default()
    }

    /// The path's segments, empty ones omitted.
    pub fn segments(&self) -> Vec<String> {
        self.path().split('/').filter(|s| !s.is_empty()).map(str::to_owned).collect()
    }

    /// `URL.path`: decoded but for `%2F`, without one trailing slash.
    pub fn url_path(&self) -> String {
        let mut path = self.encoded_path.as_str();
        if path.len() > 1 {
            path = path.strip_suffix('/').unwrap_or(path);
        }
        percent_decode(path, true).unwrap_or_default()
    }

    /// The query items (`URLComponents.queryItems`): nil with no query, empty for `?`.
    pub fn query_items(&self) -> Option<Vec<QueryItem>> {
        let query = self.encoded_query.as_deref()?;
        if query.is_empty() {
            return Some(Vec::new());
        }
        Some(
            query
                .split('&')
                .map(|item| match item.split_once('=') {
                    Some((name, value)) => QueryItem {
                        name: percent_decode(name, false).unwrap_or_default(),
                        value: Some(percent_decode(value, false).unwrap_or_default()),
                    },
                    None => QueryItem {
                        name: percent_decode(item, false).unwrap_or_default(),
                        value: None,
                    },
                })
                .collect(),
        )
    }

    /// The scheme, lowercased.
    pub fn lower_scheme(&self) -> Option<String> {
        self.scheme.as_ref().map(|s| s.to_ascii_lowercase())
    }

    /// The host, lowercased.
    pub fn lower_host(&self) -> Option<String> {
        self.host.as_ref().map(|h| h.to_lowercase())
    }
}
