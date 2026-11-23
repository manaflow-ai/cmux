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
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let high = (hex[0] as char).to_digit(16)?;
            let low = (hex[1] as char).to_digit(16)?;
            let byte = (high * 16 + low) as u8;
            if keep_slash && byte == b'/' {
                out.extend_from_slice(&bytes[i..i + 3]);
            } else {
                out.push(byte);
            }
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

impl Components {
    /// The parts of `text`.
    pub fn parse(text: &str) -> Components {
        let mut parts = Components::default();
        let mut rest = text;
        if let Some(colon) = rest.find(':') {
            let candidate = &rest[..colon];
            if !candidate.contains(['/', '?', '#']) && is_scheme(candidate) {
                parts.scheme = Some(candidate.to_owned());
                rest = &rest[colon + 1..];
            }
        }
        if let Some(hash) = rest.find('#') {
            parts.fragment = Some(percent_decode(&rest[hash + 1..], false).unwrap_or_default());
            rest = &rest[..hash];
        }
        if let Some(question) = rest.find('?') {
            parts.encoded_query = Some(rest[question + 1..].to_owned());
            rest = &rest[..question];
        }
        if let Some(after) = rest.strip_prefix("//") {
            let end = after.find('/').unwrap_or(after.len());
            parts.read_authority(&after[..end]);
            rest = &after[end..];
        }
        parts.encoded_path = rest.to_owned();
        parts
    }

    fn read_authority(&mut self, authority: &str) {
        let host_port = match authority.rfind('@') {
            Some(at) => {
                let info = &authority[..at];
                match info.find(':') {
                    Some(colon) => {
                        self.user = Some(percent_decode(&info[..colon], false).unwrap_or_default());
                        self.password =
                            Some(percent_decode(&info[colon + 1..], false).unwrap_or_default());
                    }
                    None => self.user = Some(percent_decode(info, false).unwrap_or_default()),
                }
                &authority[at + 1..]
            }
            None => authority,
        };
        let (host, port) = if host_port.starts_with('[') {
            match host_port.find(']') {
                Some(close) => {
                    (&host_port[..=close], host_port[close + 1..].strip_prefix(':').unwrap_or(""))
                }
                None => (host_port, ""),
            }
        } else {
            match host_port.rfind(':') {
                Some(colon) => (&host_port[..colon], &host_port[colon + 1..]),
                None => (host_port, ""),
            }
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
        if path.len() > 1 && path.ends_with('/') {
            path = &path[..path.len() - 1];
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
