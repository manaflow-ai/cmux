//! The URL syntax the typed policy needs, in place of the three Foundation
//! parsers the Swift resolver called:
//!
//! - [`parse_strict`] is `URLComponents(string:)`: RFC 3986 generic syntax,
//!   nil (here `None`) for any character the grammar does not allow. The
//!   string a valid input gives back (`components.url`) is the input itself.
//! - [`parse_lenient`] is `URL(string:)` as linked on macOS 14 and later: it
//!   percent-encodes characters the grammar does not allow, then parses.
//! - [`file_url`] is `URL(filePath:)` with the path's directory hint taken
//!   from a trailing slash: `file://` and the path, percent-encoded with
//!   `CharacterSet.urlPathAllowed`.
//!
//! The outputs for ASCII input that is already valid are byte-equal to
//! Foundation's (the ported Swift corpus holds them). Non-ASCII hosts (Foundation
//! IDNA-encodes them in `URL(string:)`) are not modelled; the Swift side-by-side
//! test of the app half compares them before the Swift copy goes.

use crate::text::{push_percent_byte, split_before};

/// The parts of a parsed URL the resolver reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Parts<'a> {
    /// As written (not lowercased).
    pub scheme: &'a str,
    /// The host as written, brackets kept for an IP literal; `None` when the
    /// URL has no authority (`about:blank`, `cmux:stashed`), `Some("")` for
    /// `file:///x`.
    pub host: Option<&'a str>,
    /// The path as written (percent-encoded).
    pub path: &'a str,
}

fn is_unreserved(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_' | '~')
}

fn is_sub_delim(c: char) -> bool {
    matches!(c, '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=')
}

fn is_gen_delim(c: char) -> bool {
    matches!(c, ':' | '/' | '?' | '#' | '[' | ']' | '@')
}

/// Every character in `text` is `allowed` or starts a `%HH` escape.
fn valid_component(text: &str, allowed: impl Fn(char) -> bool) -> bool {
    let bytes = text.as_bytes();
    let mut index = 0;
    for (offset, c) in text.char_indices() {
        if offset < index {
            continue;
        }
        if c == '%' {
            let hex = |i: usize| bytes.get(i).is_some_and(u8::is_ascii_hexdigit);
            if !(hex(offset + 1) && hex(offset + 2)) {
                return false;
            }
            index = offset + 3;
        } else if !allowed(c) {
            return false;
        }
    }
    true
}

fn is_pchar(c: char) -> bool {
    is_unreserved(c) || is_sub_delim(c) || matches!(c, ':' | '@')
}

fn valid_scheme(scheme: &str) -> bool {
    let mut chars = scheme.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
}

fn valid_ip_literal(literal: &str) -> bool {
    if let Some(future) = literal.strip_prefix(['v', 'V']) {
        let Some((version, rest)) = future.split_once('.') else {
            return false;
        };
        return !version.is_empty()
            && version.bytes().all(|b| b.is_ascii_hexdigit())
            && !rest.is_empty()
            && rest.chars().all(|c| is_unreserved(c) || is_sub_delim(c) || c == ':');
    }
    literal.parse::<std::net::Ipv6Addr>().is_ok()
}

/// `host[:port]` of an authority; the host (brackets kept) when valid.
fn valid_host_port(host_port: &str) -> Option<&str> {
    let (host, port) = if let Some(after_open) = host_port.strip_prefix('[') {
        let (literal, rest) = after_open.split_once(']')?;
        if !valid_ip_literal(literal) {
            return None;
        }
        let port = match rest.strip_prefix(':') {
            Some(port) => port,
            None if rest.is_empty() => "",
            None => return None,
        };
        // The host with its brackets: `host_port` without the `rest` after `]`.
        (host_port.strip_suffix(rest)?, port)
    } else {
        let (host, port) = host_port.split_once(':').unwrap_or((host_port, ""));
        if !valid_component(host, |c| is_unreserved(c) || is_sub_delim(c)) {
            return None;
        }
        (host, port)
    };
    port.bytes().all(|b| b.is_ascii_digit()).then_some(host)
}

/// `URLComponents(string:)` for an absolute URL; `None` when the text is not
/// valid RFC 3986 (a space, `|`, a stray `%`, a non-ASCII character...).
pub(crate) fn parse_strict(text: &str) -> Option<Parts<'_>> {
    let (scheme, after) = text.split_once(':')?;
    if !valid_scheme(scheme) {
        return None;
    }
    let (host, rest) = if let Some(authority_and_rest) = after.strip_prefix("//") {
        let (authority, rest) = split_before(authority_and_rest, |c| matches!(c, '/' | '?' | '#'));
        let host_port = match authority.rsplit_once('@') {
            Some((userinfo, host_port)) => {
                if !valid_component(userinfo, |c| is_unreserved(c) || is_sub_delim(c) || c == ':') {
                    return None;
                }
                host_port
            }
            None => authority,
        };
        (Some(valid_host_port(host_port)?), rest)
    } else {
        (None, after)
    };
    let (before_fragment, fragment) = split_before(rest, |c| c == '#');
    let (path, query) = split_before(before_fragment, |c| c == '?');
    let query_or_fragment = |c: char| is_pchar(c) || matches!(c, '/' | '?');
    let valid = valid_component(path, |c| is_pchar(c) || c == '/')
        && valid_component(query.strip_prefix('?').unwrap_or(""), query_or_fragment)
        && valid_component(fragment.strip_prefix('#').unwrap_or(""), query_or_fragment);
    valid.then_some(Parts { scheme, host, path })
}

fn push_percent_encoded(out: &mut String, c: char) {
    let mut buffer = [0u8; 4];
    for byte in c.encode_utf8(&mut buffer).bytes() {
        push_percent_byte(out, byte);
    }
}

/// `URL(string:)`: the text when it is valid, else the text with every
/// character the grammar never allows (and every `%` that starts no escape)
/// percent-encoded, when that is valid. Returns the URL string.
pub(crate) fn parse_lenient(text: &str) -> Option<String> {
    if parse_strict(text).is_some() {
        return Some(text.to_string());
    }
    let bytes = text.as_bytes();
    let mut encoded = String::with_capacity(text.len() + 8);
    for (offset, c) in text.char_indices() {
        let hex = |i: usize| bytes.get(i).is_some_and(u8::is_ascii_hexdigit);
        let keep = if c == '%' {
            hex(offset + 1) && hex(offset + 2)
        } else {
            is_unreserved(c) || is_sub_delim(c) || is_gen_delim(c)
        };
        if keep {
            encoded.push(c);
        } else {
            push_percent_encoded(&mut encoded, c);
        }
    }
    parse_strict(&encoded).is_some().then_some(encoded)
}

/// `CharacterSet.urlPathAllowed`: no `;`, `?`, `#` or `%`.
fn is_path_allowed(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || matches!(
            c,
            '!' | '$'
                | '&'
                | '\''
                | '('
                | ')'
                | '*'
                | '+'
                | ','
                | '-'
                | '.'
                | '/'
                | ':'
                | '='
                | '@'
                | '_'
                | '~'
        )
}

/// `URL(filePath: path).absoluteString` for an absolute path.
pub(crate) fn file_url(path: &str) -> String {
    let mut out = String::with_capacity(path.len() + 8);
    out.push_str("file://");
    for c in path.chars() {
        if is_path_allowed(c) {
            out.push(c);
        } else {
            push_percent_encoded(&mut out, c);
        }
    }
    out
}
