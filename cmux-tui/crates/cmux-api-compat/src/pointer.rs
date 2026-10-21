//! RFC 6901 JSON pointers, plus one extension: the token `*` matches every
//! array element and every object member.

use crate::CompatError;

/// The wildcard token. A literal member named `*` cannot be addressed.
pub const WILDCARD: &str = "*";

/// Parses an RFC 6901 pointer (`""` is the whole document) into tokens.
pub fn parse(pointer: &str) -> Result<Vec<String>, CompatError> {
    if pointer.is_empty() {
        return Ok(Vec::new());
    }
    let Some(rest) = pointer.strip_prefix('/') else {
        return Err(CompatError::BadPointer(pointer.to_owned()));
    };
    rest.split('/').map(|token| unescape(token, pointer)).collect()
}

fn unescape(token: &str, pointer: &str) -> Result<String, CompatError> {
    if !token.contains('~') {
        return Ok(token.to_owned());
    }
    let mut out = String::with_capacity(token.len());
    let mut chars = token.chars();
    while let Some(c) = chars.next() {
        if c == '~' {
            match chars.next() {
                Some('0') => out.push('~'),
                Some('1') => out.push('/'),
                _ => return Err(CompatError::BadPointer(pointer.to_owned())),
            }
        } else {
            out.push(c);
        }
    }
    Ok(out)
}

/// Escapes one token for use in a pointer.
pub fn escape(token: &str) -> String {
    token.replace('~', "~0").replace('/', "~1")
}

/// Joins tokens back into a pointer.
pub fn join(tokens: &[String]) -> String {
    tokens.iter().map(|t| format!("/{}", escape(t))).collect()
}

#[cfg(test)]
mod api_compat_pointer_tests {
    use super::*;

    #[test]
    fn api_compat_pointer_round_trips_rfc6901_escapes() {
        assert_eq!(parse("").unwrap(), Vec::<String>::new());
        assert_eq!(parse("/a~1b/c~0d/*").unwrap(), vec!["a/b", "c~d", "*"]);
        assert_eq!(join(&parse("/a~1b/c~0d").unwrap()), "/a~1b/c~0d");
        assert!(parse("a").is_err());
        assert!(parse("/a~2").is_err());
    }
}
