//! The offline duress simulator's generator (`cmux-next-ios/design/duress-sim.md`). No agent, Mac
//! or network: a recorded Claude Code PTY session and a recorded acpmux chat are expanded, from
//! one seed, into the replay files the iPhone app's DEBUG reader (`MobileDuress`) plays while a UI
//! bench runs. Every timing and shaping decision is made here and written into the files; the
//! reader only follows them.
//!
//! - [`knobs`]: the knobs, presets and the `PRESET[,knob=value...]` spec;
//! - [`inputs`]: the recordings and their SHA-256;
//! - [`history`]: synthesized Claude Code scrollback rows;
//! - [`stream`]: the PTY stream schedule;
//! - [`chat`]: the chat records;
//! - [`link`]: the `cmux-fault` link model, as a schedule;
//! - [`scenario`]: named scenarios (`scenarios/*.toml`), their schedule transforms and verdict;
//! - `replay` (feature `paths`, on by default): a scenario run through ghostty-vt, the
//!   hybrid/lean projection and `claude::render`.
//!
//! Files written into the output folder: `duress.json` (knobs, inputs, counts), `pty-history.bin`,
//! `pty-stream.jsonl`, `chat.ndjson`. All four are written for every spec, empty where a knob is 0,
//! so the reader has one code path.

pub mod chat;
pub mod history;
pub mod inputs;
pub mod knobs;
pub mod link;
#[cfg(feature = "paths")]
pub mod replay;
pub mod scenario;
pub mod stream;

use std::io::Write;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use cmux_fault::Rng;
use cmux_fault::shaper::LinkProfile;
use serde::Serialize;

pub use inputs::Inputs;
pub use knobs::Knobs;

/// The file names in the output folder.
pub const MANIFEST: &str = "duress.json";
pub const HISTORY: &str = "pty-history.bin";
pub const STREAM: &str = "pty-stream.jsonl";
pub const CHAT: &str = "chat.ndjson";

/// Everything one spec generates, in memory.
pub struct Generated {
    pub knobs: Knobs,
    pub link: Option<LinkProfile>,
    pub history: Vec<u8>,
    /// Bytes of the recorded banner at the start of `history`, before the synthesized rows.
    pub history_prefix_bytes: usize,
    pub stream: Vec<stream::Chunk>,
    pub chat: Vec<String>,
}

/// What `duress.json` reports besides the knobs.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Counts {
    pub history_bytes: u64,
    pub history_rows: u64,
    pub history_prefix_bytes: u64,
    pub stream_chunks: u64,
    pub stream_bytes: u64,
    pub stream_ms: u64,
    pub chat_records: u64,
    pub chat_bytes: u64,
    pub chat_ms: u64,
}

#[derive(Serialize)]
struct Manifest<'a> {
    version: u32,
    generator: String,
    knobs: &'a Knobs,
    link: &'a Option<LinkProfile>,
    inputs: InputsManifest<'a>,
    counts: Counts,
    files: [&'static str; 3],
}

#[derive(Serialize)]
struct InputsManifest<'a> {
    pty: &'a inputs::Source,
    chat: &'a inputs::Source,
}

/// Expands the recordings under `knobs`. The seed's streams: 1 synthesized text, 2 the stream's
/// top-up timing, 3 the stream's link, 4 the chat's link.
pub fn generate(knobs: &Knobs, inputs: &Inputs) -> Result<Generated, String> {
    generate_with_link(knobs, knobs.link_profile()?, inputs)
}

/// [`generate`] with the link given instead of named by the knobs (a scenario's own profile).
pub fn generate_with_link(
    knobs: &Knobs,
    link: Option<LinkProfile>,
    inputs: &Inputs,
) -> Result<Generated, String> {
    let mut seed = Rng::new(knobs.seed);
    let words = inputs::printable_words(&inputs.pty);
    let mut rows = history::Rows::new(seed.split(1), &words);
    let mut filler = seed.split(2);
    let mut stream_link = link::Link::new(link.clone(), seed.split(3));
    let mut chat_link = link::Link::new(link.clone(), seed.split(4));

    let banner = inputs
        .pty
        .iter()
        .find(|chunk| chunk.bytes.len() >= 512)
        .or(inputs.pty.first())
        .ok_or("the pty recording has no chunks")?;
    let (history, history_prefix_bytes) =
        history::history(knobs.history_rows, &banner.bytes, &mut rows);
    let stream = stream::stream(
        &inputs.pty,
        knobs.stream_kbps,
        knobs.stream_seconds,
        &mut filler,
        &mut rows,
        &mut stream_link,
    );
    let chat = chat::chat(&inputs.chat, knobs.chat_records, knobs.chat_rate, &mut chat_link)?;
    Ok(Generated { knobs: knobs.clone(), link, history, history_prefix_bytes, stream, chat })
}

impl Generated {
    pub fn counts(&self) -> Counts {
        Counts {
            history_bytes: self.history.len() as u64,
            history_rows: if self.history.is_empty() { 0 } else { self.knobs.history_rows },
            history_prefix_bytes: self.history_prefix_bytes as u64,
            stream_chunks: self.stream.len() as u64,
            stream_bytes: self.stream.iter().map(|chunk| chunk.bytes.len() as u64).sum(),
            stream_ms: self.stream.last().map_or(0, |chunk| chunk.t_ms),
            chat_records: self.chat.len() as u64,
            chat_bytes: self.chat.iter().map(|line| line.len() as u64 + 1).sum(),
            chat_ms: self.chat.last().map_or(0, |line| at_of(line)),
        }
    }

    /// Writes the four files into `dir` (created if missing).
    pub fn write(&self, dir: &Path, inputs: &Inputs) -> Result<Counts, String> {
        let err = |path: &Path, error: std::io::Error| format!("{}: {error}", path.display());
        std::fs::create_dir_all(dir).map_err(|error| err(dir, error))?;

        let path = dir.join(HISTORY);
        std::fs::write(&path, &self.history).map_err(|error| err(&path, error))?;

        let path = dir.join(STREAM);
        let file = std::fs::File::create(&path).map_err(|error| err(&path, error))?;
        let mut out = std::io::BufWriter::with_capacity(1 << 20, file);
        let mut line = String::new();
        for chunk in &self.stream {
            line.clear();
            line.push_str(&format!("{{\"t_ms\":{},\"b64\":\"", chunk.t_ms));
            STANDARD.encode_string(&chunk.bytes, &mut line);
            line.push_str("\"}\n");
            out.write_all(line.as_bytes()).map_err(|error| err(&path, error))?;
        }
        out.flush().map_err(|error| err(&path, error))?;

        let path = dir.join(CHAT);
        let file = std::fs::File::create(&path).map_err(|error| err(&path, error))?;
        let mut out = std::io::BufWriter::with_capacity(1 << 20, file);
        for record in &self.chat {
            out.write_all(record.as_bytes()).map_err(|error| err(&path, error))?;
            out.write_all(b"\n").map_err(|error| err(&path, error))?;
        }
        out.flush().map_err(|error| err(&path, error))?;

        let counts = self.counts();
        let manifest = Manifest {
            version: 1,
            generator: format!("cmux-duress {}", env!("CARGO_PKG_VERSION")),
            knobs: &self.knobs,
            link: &self.link,
            inputs: InputsManifest { pty: &inputs.pty_source, chat: &inputs.chat_source },
            counts: counts.clone(),
            files: [HISTORY, STREAM, CHAT],
        };
        let path = dir.join(MANIFEST);
        let mut text =
            serde_json::to_string_pretty(&manifest).map_err(|error| error.to_string())?;
        text.push('\n');
        std::fs::write(&path, text).map_err(|error| err(&path, error))?;
        Ok(counts)
    }
}

/// A written record's `at`.
fn at_of(line: &str) -> u64 {
    #[derive(serde::Deserialize)]
    struct At {
        at: u64,
    }
    serde_json::from_str::<At>(line).map_or(0, |record| record.at)
}

/// The repository root: the nearest folder at or above `from` that holds `cmux-tui/`.
pub fn find_repo(from: &Path) -> Option<PathBuf> {
    from.ancestors().find(|dir| dir.join("cmux-tui").is_dir()).map(Path::to_owned)
}

/// One line saying what was generated.
pub fn summary(dir: &Path, knobs: &Knobs, counts: &Counts) -> String {
    format!(
        "cmux-duress: {} seed={} link={} -> {}: history {} rows {} B, stream {} chunks {} B over {} ms, chat {} records {} B over {} ms",
        knobs.preset,
        knobs.seed,
        knobs.link.as_deref().unwrap_or("none"),
        dir.display(),
        counts.history_rows,
        counts.history_bytes,
        counts.stream_chunks,
        counts.stream_bytes,
        counts.stream_ms,
        counts.chat_records,
        counts.chat_bytes,
        counts.chat_ms,
    )
}
