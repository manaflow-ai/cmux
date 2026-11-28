//! Text rules the compose ops share: Foundation's trims, the case- and diacritic-blind compare, the
//! contact address parser (`ContactAddress.parse`, CmuxHomeCore) and the internal-id test
//! (`String.isHomeInternalID`).

use serde::{Deserialize, Serialize};

/// `CharacterSet.whitespacesAndNewlines`.
pub fn is_space(c: char) -> bool {
    c.is_whitespace()
}

/// `CharacterSet.newlines`.
pub fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `HomeNewMessageDraft.separators`: `,` `;` and whitespace.
pub fn is_separator(c: char) -> bool {
    c == ',' || c == ';' || is_space(c)
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim_space(text: &str) -> &str {
    text.trim_matches(is_space)
}

/// `trimmingCharacters(in: HomeNewMessageDraft.separators)`.
pub fn trim_separators(text: &str) -> &str {
    text.trim_matches(is_separator)
}

/// `trimmingCharacters(in: .newlines)`.
pub fn trim_newlines(text: &str) -> &str {
    text.trim_matches(is_newline)
}

/// A combining mark `.diacriticInsensitive` drops.
fn is_combining(c: char) -> bool {
    matches!(c, '\u{300}'..='\u{36F}' | '\u{1AB0}'..='\u{1AFF}' | '\u{1DC0}'..='\u{1DFF}' | '\u{20D0}'..='\u{20FF}' | '\u{FE20}'..='\u{FE2F}')
}

/// The base letter of a precomposed Latin letter (its canonical decomposition's first scalar).
fn base(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' | 'ǎ' => 'a',
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => 'c',
        'ď' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => 'g',
        'ĥ' => 'h',
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ǐ' => 'i',
        'ĵ' => 'j',
        'ķ' => 'k',
        'ĺ' | 'ļ' | 'ľ' => 'l',
        'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ō' | 'ŏ' | 'ő' | 'ǒ' => 'o',
        'ŕ' | 'ŗ' | 'ř' => 'r',
        'ś' | 'ŝ' | 'ş' | 'š' | 'ș' => 's',
        'ţ' | 'ť' | 'ț' => 't',
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' | 'ǔ' => 'u',
        'ŵ' => 'w',
        'ý' | 'ÿ' | 'ŷ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

/// The text `[.caseInsensitive, .diacriticInsensitive]` compares: lowercased, marks dropped.
pub fn fold(text: &str) -> String {
    text.chars().flat_map(char::to_lowercase).filter(|c| !is_combining(*c)).map(base).collect()
}

/// `a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame`.
pub fn folded_equal(a: &str, b: &str) -> bool {
    fold(a) == fold(b)
}

/// `a.range(of: b, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil`.
pub fn folded_prefix(a: &str, b: &str) -> bool {
    fold(a).starts_with(&fold(b))
}

/// `a.range(of: b, options: [.caseInsensitive, .diacriticInsensitive]) != nil`.
pub fn folded_contains(a: &str, b: &str) -> bool {
    fold(a).contains(&fold(b))
}

/// `a.caseInsensitiveCompare(b) == .orderedSame` (and the localized form).
pub fn case_equal(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

/// `localizedStandardCompare`: case-blind, with runs of digits compared as numbers.
pub fn standard_order(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (a, b) = (fold(a), fold(b));
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let run = |it: &mut std::iter::Peekable<std::str::Chars<'_>>| {
                    let mut digits = String::new();
                    while let Some(d) = it.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(d);
                        it.next();
                    }
                    digits
                };
                let (m, n) = (run(&mut x), run(&mut y));
                let (m, n) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                let order = m.len().cmp(&n.len()).then_with(|| m.cmp(n));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(p), Some(q)) => {
                if p != q {
                    return p.cmp(&q);
                }
                x.next();
                y.next();
            }
        }
    }
}

/// `String.isHomeInternalID`: `addr_…`, `user_…`, `conv_…` and the other owner id shapes.
pub fn is_home_internal_id(text: &str) -> bool {
    const PREFIXES: &[&str] =
        &["addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm"];
    let Some((prefix, rest)) = text.split_once('_') else {
        return false;
    };
    PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// An email or phone number (`ContactAddress`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Address {
    pub kind: AddressKind,
    /// The normalized address (`description`): a lowercased email, or `+` and the digits.
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AddressKind {
    Email,
    Phone,
}

impl Address {
    pub fn is_email(&self) -> bool {
        self.kind == AddressKind::Email
    }
}

/// `ContactAddress.parse(_:defaultCallingCode:)`.
pub fn parse_address(input: &str, calling_code: &str) -> Option<Address> {
    let trimmed = trim_space(input);
    if trimmed.is_empty() || trimmed.chars().count() > 254 {
        return None;
    }
    if trimmed.contains('@') { parse_email(trimmed) } else { parse_phone(trimmed, calling_code) }
}

fn parse_email(text: &str) -> Option<Address> {
    let value = text.to_lowercase();
    let pieces: Vec<&str> = value.split('@').collect();
    let [local, domain] = pieces.as_slice() else {
        return None;
    };
    if local.is_empty() || local.chars().count() > 64 {
        return None;
    }
    if !domain.contains('.')
        || domain.starts_with('.')
        || domain.ends_with('.')
        || domain.contains("..")
    {
        return None;
    }
    let local_ok = local.chars().all(|c| c.is_alphanumeric() || ".!#$%&'*+/=?^_`{|}~-".contains(c));
    let domain_ok = domain.chars().all(|c| c.is_alphanumeric() || c == '.' || c == '-');
    if !local_ok
        || !domain_ok
        || local.starts_with('.')
        || local.ends_with('.')
        || local.contains("..")
    {
        return None;
    }
    let tld = domain.rsplit('.').next().unwrap_or("");
    if tld.chars().count() < 2 || !tld.chars().all(char::is_alphabetic) {
        return None;
    }
    Some(Address { kind: AddressKind::Email, value })
}

fn parse_phone(text: &str, calling_code: &str) -> Option<Address> {
    let mut has_plus = false;
    let mut digits = String::new();
    for (index, c) in text.chars().enumerate() {
        if c == '+' {
            if index != 0 {
                return None;
            }
            has_plus = true;
        } else if c.is_ascii_digit() {
            digits.push(c);
        } else if !" ()-./\u{00A0}".contains(c) {
            return None;
        }
    }
    if !has_plus {
        if let Some(rest) = digits.strip_prefix("00") {
            digits = rest.to_owned();
        } else if calling_code == "1" && digits.len() == 11 && digits.starts_with('1') {
            // Already carries the North American country code.
        } else {
            digits = format!("{calling_code}{digits}");
        }
    }
    if !(8..=15).contains(&digits.len()) || digits.starts_with('0') {
        return None;
    }
    if calling_code == "1" && digits.starts_with('1') && digits.len() != 11 {
        return None;
    }
    Some(Address { kind: AddressKind::Phone, value: format!("+{digits}") })
}

/// `ContactAddress.parse` with the default calling code, `1`.
pub fn address(input: &str) -> Option<Address> {
    parse_address(input, "1")
}
