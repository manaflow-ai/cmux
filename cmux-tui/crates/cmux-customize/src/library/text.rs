//! The library's words and looks: entry names from the words that asked,
//! the light thumbnail, and messages that never quote what they read.

use super::{Entry, Thumbnail};
use crate::profile::{Profile, valid_name};

const MAX_SWATCHES: usize = 6;
const MAX_THUMB_KEYS: usize = 12;

/// The colors and keys an entry sets.
pub fn thumbnail(profile: &Profile) -> Thumbnail {
    let mut swatches: Vec<String> = Vec::new();
    let mut add = |text: &str| {
        for color in colors(text) {
            if swatches.len() < MAX_SWATCHES && !swatches.contains(&color) {
                swatches.push(color);
            }
        }
    };
    for value in profile.settings.values() {
        add(&value.to_string());
    }
    for text in profile.files.values() {
        add(text);
    }
    let keys =
        profile.settings.keys().chain(profile.files.keys()).take(MAX_THUMB_KEYS).cloned().collect();
    Thumbnail { swatches, keys }
}

/// `#rgb` and `#rrggbb` colors in `text`, lowercase.
fn colors(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some((_, after)) = rest.split_once('#') {
        let run: String = after.chars().take_while(char::is_ascii_hexdigit).collect();
        let next = after.chars().nth(run.len());
        let ends = next.is_none_or(|c| !c.is_ascii_alphanumeric());
        if (run.len() == 6 || run.len() == 3) && ends {
            out.push(format!("#{}", run.to_ascii_lowercase()));
        }
        rest = after;
    }
    out
}

/// A file name from the first words: `make the sidebar compact` becomes
/// `make-the-sidebar-compact`.
pub(super) fn slug(words: &str) -> String {
    let words = words.strip_prefix("profile ").unwrap_or(words);
    let mut out = String::new();
    for c in words.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
        if out.len() >= 40 {
            break;
        }
    }
    let out = out.trim_matches('-').to_owned();
    if valid_name(&out) { out } else { "change".to_owned() }
}

pub(super) fn unique_name(entries: &[Entry], wanted: &str) -> String {
    let taken = |name: &str| entries.iter().any(|entry| entry.name() == name);
    if !taken(wanted) {
        return wanted.to_owned();
    }
    let stem: String = wanted.chars().take(56).collect();
    (2..).map(|n| format!("{stem}-{n}")).find(|name| !taken(name)).unwrap_or_default()
}

pub(super) fn one_line(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 200 {
        let mut short: String = line.chars().take(200).collect();
        short.push('…');
        return short;
    }
    line
}

/// A serde message without the value it quoted.
pub(super) fn redact_serde(message: &str) -> String {
    let unquoted = |text: &str| text.split(['`', '"']).next().unwrap_or(text).trim_end().to_owned();
    match message.split_once(" at line ") {
        Some((head, tail)) => format!("{} at line {tail}", unquoted(head)),
        None => unquoted(message),
    }
}

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;
