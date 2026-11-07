//! Secrets out of every line this feature writes (threat model T5): the
//! daemon passes each log, trace and error text through [`redact`].

const MASK: &str = "[redacted]";

/// Keys whose values are secrets in JSON, query strings and forms.
const KEYS: [&str; 9] = [
    "access_token",
    "refresh_token",
    "id_token",
    "client_secret",
    "code_verifier",
    "code",
    "password",
    "api_key",
    "apikey",
];

fn secret_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~' | '+' | '/' | '=' | '%')
}

/// Replaces the value after `at` (up to the first non-secret character).
fn mask_from(text: &str, at: usize) -> (String, usize) {
    let rest = text.get(at..).unwrap_or("");
    let len: usize = rest.chars().take_while(|c| secret_char(*c)).map(char::len_utf8).sum();
    (MASK.to_owned(), at + len)
}

/// `text` with bearer tokens and secret-named values masked.
pub fn redact(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        let rest = lower.get(i..).unwrap_or("");
        let mut hit = None;
        if rest.starts_with("bearer ") {
            hit = Some(i + "bearer ".len());
        } else {
            let before_ok = i == 0
                || !lower
                    .get(..i)
                    .and_then(|s| s.chars().last())
                    .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
            if before_ok {
                for k in KEYS {
                    if let Some(after) = rest.strip_prefix(k) {
                        let sep = after
                            .char_indices()
                            .find(|(_, c)| !matches!(c, '"' | '\'' | ' ' | ':' | '='))
                            .map(|(n, _)| n)
                            .unwrap_or(after.len());
                        let gap = after.get(..sep).unwrap_or("");
                        if gap.contains(':') || gap.contains('=') {
                            hit = Some(i + k.len() + sep);
                            break;
                        }
                    }
                }
            }
        }
        match hit {
            Some(start) => {
                out.push_str(text.get(i..start).unwrap_or(""));
                let (mask, end) = mask_from(text, start);
                if end > start {
                    out.push_str(&mask);
                }
                i = end.max(start);
            }
            None => {
                let ch = text.get(i..).and_then(|s| s.chars().next()).unwrap_or(' ');
                out.push(ch);
                i += ch.len_utf8();
            }
        }
    }
    out
}
