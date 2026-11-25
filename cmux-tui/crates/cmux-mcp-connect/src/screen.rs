//! Tool text that tries to steer the model (threat model T9): checked when a
//! server connects and on every new tool list. A flagged tool starts at
//! Never and the card names it; this is a screen, not a proof, so a clean
//! result still lists the tool under the person's policy.

use serde_json::Value;

/// Why a tool was flagged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Flag {
    /// Words that give the model orders ("ignore previous instructions").
    Instruction(String),
    /// A path or command that reaches for credentials.
    SecretPath(String),
    /// Invisible or direction-changing characters (zero-width, bidi, tag).
    HiddenCharacters,
    /// Text longer than a tool description needs.
    TooLong(usize),
}

/// Longer descriptions are flagged: room for a hidden payload.
pub const MAX_DESCRIPTION_CHARS: usize = 4000;

const INSTRUCTIONS: [&str; 16] = [
    "ignore previous",
    "ignore all previous",
    "ignore the above",
    "disregard previous",
    "disregard all",
    "do not tell the user",
    "don't tell the user",
    "do not mention",
    "without telling",
    "without asking",
    "system prompt",
    "<important>",
    "<system>",
    "before using any other tool",
    "you must always",
    "instead of the user",
];

const SECRET_PATHS: [&str; 12] = [
    "~/.ssh",
    "id_rsa",
    "id_ed25519",
    ".aws/credentials",
    ".netrc",
    "/etc/passwd",
    ".config/gh/hosts",
    "private key",
    "find-generic-password",
    "mcp.json",
    ".claude.json",
    "codex/config.toml",
];

fn hidden(c: char) -> bool {
    matches!(c,
        '\u{200B}'..='\u{200F}'
        | '\u{202A}'..='\u{202E}'
        | '\u{2060}'..='\u{2064}'
        | '\u{2066}'..='\u{2069}'
        | '\u{FEFF}'
        | '\u{E0000}'..='\u{E007F}')
}

/// Every text of a tool the model reads: title, description and each
/// description inside the input schema.
fn texts<'a>(value: &'a Value, out: &mut Vec<&'a str>) {
    match value {
        Value::Object(map) => {
            for (k, v) in map {
                match (k.as_str(), v) {
                    ("description" | "title", Value::String(s)) => out.push(s),
                    _ => texts(v, out),
                }
            }
        }
        Value::Array(items) => items.iter().for_each(|v| texts(v, out)),
        _ => {}
    }
}

/// The flags of one tool (empty: nothing found).
pub fn screen_tool(tool: &Value) -> Vec<Flag> {
    let mut found = Vec::new();
    let mut all = Vec::new();
    texts(tool, &mut all);
    let mut flags = Vec::new();
    let total: usize = all.iter().map(|t| t.chars().count()).sum();
    for text in &all {
        if text.chars().any(hidden) && !flags.contains(&Flag::HiddenCharacters) {
            flags.push(Flag::HiddenCharacters);
        }
        let lower = text.to_lowercase();
        for p in INSTRUCTIONS {
            if lower.contains(p) && !found.contains(&p) {
                found.push(p);
                flags.push(Flag::Instruction(p.to_owned()));
            }
        }
        for p in SECRET_PATHS {
            if lower.contains(p) && !found.contains(&p) {
                found.push(p);
                flags.push(Flag::SecretPath(p.to_owned()));
            }
        }
    }
    if total > MAX_DESCRIPTION_CHARS {
        flags.push(Flag::TooLong(total));
    }
    flags
}
