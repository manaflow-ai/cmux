//! Which secret may go to which host, and the header rewrite. No I/O.

use base64::Engine as _;
use zeroize::Zeroizing;

/// What an agent holds in place of a value: `cmux-secret://NAME`.
pub const PLACEHOLDER_PREFIX: &str = "cmux-secret://";

/// The placeholder agents get for `name`.
pub fn placeholder(name: &str) -> String {
    format!("{PLACEHOLDER_PREFIX}{name}")
}

const DEFAULT_PORT: u16 = 443;

/// One allowed host, as the hub writes it: a lowercase DNS name, optionally
/// `*.`-prefixed (its subdomains, never the apex), optionally `:port`
/// (default 443). No scheme, path, IP literal, userinfo or trailing dot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostPattern {
    /// The name without `*.`.
    host: String,
    wildcard: bool,
    port: u16,
}

impl HostPattern {
    /// The contract's rule; `None` for anything else.
    pub fn parse(text: &str) -> Option<HostPattern> {
        let (rest, wildcard) = match text.strip_prefix("*.") {
            Some(rest) => (rest, true),
            None => (text, false),
        };
        let (host, port) = match rest.split_once(':') {
            Some((host, port)) => {
                let valid = !port.is_empty()
                    && port.len() <= 5
                    && !port.starts_with('0')
                    && port.bytes().all(|b| b.is_ascii_digit());
                let port: u32 = if valid { port.parse().ok()? } else { return None };
                (host, u16::try_from(port).ok().filter(|p| *p != 0)?)
            }
            None => (rest, DEFAULT_PORT),
        };
        dns_name(host).then(|| HostPattern { host: host.to_owned(), wildcard, port })
    }

    /// Whether a connection to `host:port` (host lowercased) is allowed.
    pub fn matches(&self, host: &str, port: u16) -> bool {
        if port != self.port {
            return false;
        }
        if self.wildcard {
            // At least one label, then the dot, before the pattern's host.
            host.strip_suffix(self.host.as_str())
                .and_then(|label| label.strip_suffix('.'))
                .is_some_and(|label| !label.is_empty())
        } else {
            host == self.host
        }
    }
}

impl std::fmt::Display for HostPattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.wildcard {
            f.write_str("*.")?;
        }
        f.write_str(&self.host)?;
        if self.port != DEFAULT_PORT {
            write!(f, ":{}", self.port)?;
        }
        Ok(())
    }
}

/// A lowercase DNS name of at least two labels whose last label starts with a
/// letter (never an IP literal): labels of 1-63 `[a-z0-9-]`, no leading or
/// trailing hyphen, 253 bytes at most.
pub(crate) fn dns_name(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    let label_ok = |l: &str| {
        !l.is_empty()
            && l.len() <= 63
            && l.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && !l.starts_with('-')
            && !l.ends_with('-')
    };
    labels.iter().all(|l| label_ok(l))
        && labels.last().is_some_and(|l| l.bytes().next().is_some_and(|b| b.is_ascii_lowercase()))
}

/// One vault entry the proxy may put into requests.
pub struct Secret {
    name: String,
    value: Zeroizing<String>,
    hosts: Vec<HostPattern>,
}

impl Secret {
    pub fn new(name: impl Into<String>, value: Zeroizing<String>, hosts: Vec<HostPattern>) -> Self {
        Secret { name: name.into(), value, hosts }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn hosts(&self) -> &[HostPattern] {
        &self.hosts
    }

    fn allows(&self, host: &str, port: u16) -> bool {
        self.hosts.iter().any(|p| p.matches(host, port))
    }
}

impl std::fmt::Debug for Secret {
    /// Never the value.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Secret").field("name", &self.name).field("hosts", &self.hosts).finish()
    }
}

/// The secrets the proxy serves now. Read once per request, so a revoked or
/// narrowed entry takes effect on the next request.
#[derive(Debug, Default)]
pub struct Policy {
    secrets: Vec<Secret>,
}

impl Policy {
    pub fn new(secrets: Vec<Secret>) -> Self {
        Policy { secrets }
    }

    pub fn is_empty(&self) -> bool {
        self.secrets.is_empty()
    }

    pub fn secrets(&self) -> &[Secret] {
        &self.secrets
    }

    /// Whether a connection to `host:port` is intercepted: some secret allows it.
    pub fn intercepts(&self, host: &str, port: u16) -> bool {
        self.secrets.iter().any(|s| s.allows(host, port))
    }

    fn allowed(&self, name: &str, host: &str, port: u16) -> Option<&Secret> {
        self.secrets.iter().find(|s| s.name == name && s.allows(host, port))
    }

    /// `text` with each `cmux-secret://NAME` whose NAME allows `host:port`
    /// replaced by its value, and the names replaced (in order, repeats
    /// once). `None` when nothing was replaced. Other placeholders stay.
    pub fn substitute_text(
        &self,
        text: &str,
        host: &str,
        port: u16,
    ) -> Option<(Zeroizing<String>, Vec<String>)> {
        if !text.contains(PLACEHOLDER_PREFIX) {
            return None;
        }
        let mut out = Zeroizing::new(String::with_capacity(text.len()));
        let mut names: Vec<String> = Vec::new();
        let mut rest = text;
        while let Some((before, after)) = rest.split_once(PLACEHOLDER_PREFIX) {
            out.push_str(before);
            // The name ends at the first byte outside [A-Za-z0-9_], an ASCII
            // byte, so the split is on a char boundary.
            let len = after
                .bytes()
                .position(|b| !(b.is_ascii_alphanumeric() || b == b'_'))
                .unwrap_or(after.len());
            let (name, tail) = after.split_at_checked(len).unwrap_or((after, ""));
            let len = name.len();
            match (len > 0).then(|| self.allowed(name, host, port)).flatten() {
                Some(secret) => {
                    out.push_str(&secret.value);
                    if !names.iter().any(|n| n == name) {
                        names.push(name.to_owned());
                    }
                }
                None => {
                    out.push_str(PLACEHOLDER_PREFIX);
                    out.push_str(name);
                }
            }
            rest = tail;
        }
        out.push_str(rest);
        (!names.is_empty()).then_some((out, names))
    }

    /// One header value rewritten for `host:port`: placeholders in the text,
    /// and in the decoded credentials of `Basic` (git's form for a token).
    pub fn substitute_header(
        &self,
        value: &str,
        host: &str,
        port: u16,
    ) -> Option<(Zeroizing<String>, Vec<String>)> {
        if let Some((scheme, encoded)) = basic_credentials(value) {
            let engine = base64::engine::general_purpose::STANDARD;
            let decoded = Zeroizing::new(engine.decode(encoded.trim()).ok()?);
            let text = std::str::from_utf8(&decoded).ok()?;
            let (plain, names) = self.substitute_text(text, host, port)?;
            let mut out = Zeroizing::new(String::from(scheme));
            out.push(' ');
            out.push_str(&engine.encode(plain.as_bytes()));
            return Some((out, names));
        }
        self.substitute_text(value, host, port)
    }
}

/// The base64 part of `Basic <credentials>` (scheme case-insensitive).
fn basic_credentials(value: &str) -> Option<(&str, &str)> {
    let (scheme, rest) = value.split_once(' ')?;
    scheme.eq_ignore_ascii_case("basic").then_some((scheme, rest))
}

#[cfg(test)]
mod tests;
