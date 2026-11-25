//! The recordings the load is expanded from: a Claude Code PTY session (`{"t_ms","b64"}` lines)
//! and an acpmux chat (`EventRecord` lines), found in the repository by default, each read once
//! with its SHA-256 so `duress.json` names exactly what the load came from.

use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The recorded Claude Code session, relative to the repository root.
pub const DEFAULT_PTY: &str =
    "cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl";
/// chat-sim's own recorded lane session, relative to the repository root.
pub const DEFAULT_CHAT: &str = "webviews/test/fixtures/chat-sim/replay-lane-session.ndjson";

/// One input file as `duress.json` names it.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Source {
    pub path: PathBuf,
    pub sha256: String,
    pub bytes: u64,
}

/// One PTY write, `t_ms` relative to the recording's first write.
#[derive(Clone, Debug, PartialEq)]
pub struct PtyChunk {
    pub t_ms: u64,
    pub bytes: Vec<u8>,
}

/// One chat record: the envelope's fields, `msg` kept as the recording wrote it.
#[derive(Clone, Debug)]
pub struct ChatRecord {
    pub session_id: String,
    pub at: u64,
    pub dir: String,
    pub kind: String,
    pub msg: String,
}

/// Both recordings, parsed.
#[derive(Clone, Debug)]
pub struct Inputs {
    pub pty_source: Source,
    pub chat_source: Source,
    pub pty: Vec<PtyChunk>,
    pub chat: Vec<ChatRecord>,
}

#[derive(Deserialize)]
struct PtyLine {
    t_ms: Option<u64>,
    b64: Option<String>,
}

#[derive(Deserialize)]
struct ChatLine<'a> {
    #[serde(rename = "sessionId")]
    session_id: String,
    at: u64,
    dir: String,
    kind: String,
    #[serde(borrow)]
    msg: &'a serde_json::value::RawValue,
}

impl Inputs {
    /// Reads both recordings.
    pub fn load(pty: &Path, chat: &Path) -> Result<Self, String> {
        let (pty_source, pty_text) = read(pty)?;
        let (chat_source, chat_text) = read(chat)?;
        Ok(Self {
            pty: parse_pty(&pty_text).map_err(|error| format!("{}: {error}", pty.display()))?,
            chat: parse_chat(&chat_text).map_err(|error| format!("{}: {error}", chat.display()))?,
            pty_source,
            chat_source,
        })
    }

    /// The default recordings under `repo`.
    pub fn load_repo(repo: &Path) -> Result<Self, String> {
        Self::load(&repo.join(DEFAULT_PTY), &repo.join(DEFAULT_CHAT))
    }
}

fn read(path: &Path) -> Result<(Source, String), String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let source = Source {
        path: path.to_owned(),
        sha256: hex::encode(Sha256::digest(text.as_bytes())),
        bytes: text.len() as u64,
    };
    Ok((source, text))
}

/// The recording's writes; lines without bytes (a resize) are skipped, times rebased to 0.
pub fn parse_pty(text: &str) -> Result<Vec<PtyChunk>, String> {
    let mut chunks = Vec::new();
    let mut first = None;
    for (number, line) in text.lines().enumerate().filter(|(_, line)| !line.trim().is_empty()) {
        let parsed: PtyLine =
            serde_json::from_str(line).map_err(|error| format!("line {}: {error}", number + 1))?;
        let (Some(t_ms), Some(b64)) = (parsed.t_ms, parsed.b64) else {
            continue;
        };
        let bytes =
            STANDARD.decode(b64).map_err(|error| format!("line {}: {error}", number + 1))?;
        let first = *first.get_or_insert(t_ms);
        chunks.push(PtyChunk { t_ms: t_ms.saturating_sub(first), bytes });
    }
    if chunks.is_empty() {
        return Err("no PTY writes".to_owned());
    }
    Ok(chunks)
}

/// The recording's records, in order.
pub fn parse_chat(text: &str) -> Result<Vec<ChatRecord>, String> {
    let mut records = Vec::new();
    for (number, line) in text.lines().enumerate().filter(|(_, line)| !line.trim().is_empty()) {
        let parsed: ChatLine<'_> =
            serde_json::from_str(line).map_err(|error| format!("line {}: {error}", number + 1))?;
        records.push(ChatRecord {
            session_id: parsed.session_id,
            at: parsed.at,
            dir: parsed.dir,
            kind: parsed.kind,
            msg: parsed.msg.get().to_owned(),
        });
    }
    if records.is_empty() {
        return Err("no chat records".to_owned());
    }
    Ok(records)
}

/// The recording's printable text with the escape sequences taken out (a cursor move that stands
/// for a space becomes one), split into words: the vocabulary synthesized rows are written from.
pub fn printable_words(chunks: &[PtyChunk]) -> Vec<String> {
    let mut text = String::new();
    for chunk in chunks {
        let decoded = String::from_utf8_lossy(&chunk.bytes);
        let mut iter = decoded.chars().peekable();
        while let Some(c) = iter.next() {
            match c {
                '\u{1b}' => match iter.next() {
                    Some('[') => {
                        // CSI: parameters, then a final byte in @..~.
                        let mut last = ' ';
                        for c in iter.by_ref() {
                            last = c;
                            if ('@'..='~').contains(&c) {
                                break;
                            }
                        }
                        if matches!(last, 'G' | 'C' | 'D' | 'A' | 'B' | 'H') {
                            text.push(' ');
                        }
                    }
                    Some(']') => {
                        // OSC: up to BEL or ST.
                        while let Some(c) = iter.next() {
                            if c == '\u{7}' || (c == '\u{1b}' && iter.next_if_eq(&'\\').is_some()) {
                                break;
                            }
                        }
                    }
                    _ => {}
                },
                c if c.is_control() => text.push(' '),
                c => text.push(c),
            }
        }
        text.push(' ');
    }
    let mut seen = std::collections::BTreeSet::new();
    let mut words = Vec::new();
    for word in text.split_whitespace() {
        let useful = (2..=24).contains(&word.chars().count())
            && word.chars().any(char::is_alphabetic)
            && !word.contains('\u{fffd}');
        if useful && seen.insert(word) {
            words.push(word.to_owned());
        }
    }
    words
}
