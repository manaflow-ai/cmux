//! "Import from this .env": the names and values a `.env` file sets, read without running anything.
//!
//! Accepted lines: `NAME=value`, `export NAME=value`, single-quoted (literal), double-quoted (with `\n`, `\t`, `\"`,
//! `\\` escapes, and a value that spans lines), unquoted (a ` #` comment ends it, surrounding spaces trimmed).
//! Blank lines and `#` comments are skipped. A line that is none of these is reported by its line number only, never
//! its text, since it may hold a value. `${OTHER}` is kept literally: nothing is expanded.

use zeroize::Zeroizing;

/// One entry of the file. `value` is wiped when dropped and never printed.
pub struct Entry {
    pub name: String,
    pub value: Zeroizing<String>,
    /// The 1-based line the entry starts on.
    pub line: usize,
}

impl std::fmt::Debug for Entry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Entry({} line {} {})", self.name, self.line, crate::mask(&self.value))
    }
}

/// What a read found: the entries in file order (a name set twice keeps its last value, at its first place), and
/// the lines it could not read.
#[derive(Debug, Default)]
pub struct Parsed {
    pub entries: Vec<Entry>,
    pub skipped_lines: Vec<usize>,
}

fn is_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
        && name.len() <= 128
}

pub fn parse(text: &str) -> Parsed {
    let mut out = Parsed::default();
    let lines: Vec<&str> = text.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let number = i + 1;
        let raw = lines.get(i).copied().unwrap_or_default();
        i += 1;
        let line = raw.trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").map(str::trim_start).unwrap_or(line);
        let Some((name, rest)) = line.split_once('=') else {
            out.skipped_lines.push(number);
            continue;
        };
        let name = name.trim_end();
        if !is_name(name) {
            out.skipped_lines.push(number);
            continue;
        }
        let rest = rest.trim_start();
        let value = if let Some(body) = rest.strip_prefix('\'') {
            match body.find('\'') {
                Some(end) => Zeroizing::new(body.get(..end).unwrap_or_default().to_owned()),
                None => {
                    out.skipped_lines.push(number);
                    continue;
                }
            }
        } else if let Some(body) = rest.strip_prefix('"') {
            // A double-quoted value may span lines until its closing quote.
            let mut joined = Zeroizing::new(body.to_owned());
            let mut closed = closing_quote(&joined);
            while closed.is_none() && i < lines.len() {
                joined.push('\n');
                joined.push_str(lines.get(i).copied().unwrap_or_default());
                i += 1;
                closed = closing_quote(&joined);
            }
            match closed {
                Some(end) => unescape(joined.get(..end).unwrap_or_default()),
                None => {
                    out.skipped_lines.push(number);
                    continue;
                }
            }
        } else {
            let end = rest.find(" #").unwrap_or(rest.len());
            Zeroizing::new(rest.get(..end).unwrap_or_default().trim_end().to_owned())
        };
        if let Some(existing) = out.entries.iter_mut().find(|e| e.name == name) {
            existing.value = value;
        } else {
            out.entries.push(Entry { name: name.to_owned(), value, line: number });
        }
    }
    out
}

/// The byte index of the first unescaped `"`.
fn closing_quote(s: &str) -> Option<usize> {
    let mut escaped = false;
    for (index, c) in s.char_indices() {
        match c {
            '\\' if !escaped => escaped = true,
            '"' if !escaped => return Some(index),
            _ => escaped = false,
        }
    }
    None
}

fn unescape(s: &str) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::with_capacity(s.len()));
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}
