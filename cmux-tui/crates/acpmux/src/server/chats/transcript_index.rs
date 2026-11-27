//! The terminal transcript's sparse offset index. A page the reader visits leaves its byte
//! boundaries and a trigram filter in a fixed-size disk table shared by all chats. A later
//! search can jump over a known nonmatching page without reopening or parsing its JSONL.
//! Collisions evict an entry. Replacements, appends and rewrites invalidate entries.

use std::fs::{File, Metadata};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::SystemTime;

use sha2::{Digest, Sha256};

use super::transcript_preview::tool_title;
use super::transcript_raw::Part;
use crate::adopt_replay::TranscriptPage;
use crate::chats::search::Needle;

// The on-disk bound is 4,096 * 216 bytes. Only pages actually visited get a slot.
const SLOTS: u64 = 4096;
const FILTER_BYTES: usize = 128;
// At most one clipped record before and one after the ordinary turns.
const PARTS_AT: usize = 40 + FILTER_BYTES;
const RECORD_BYTES: usize = PARTS_AT + 2 * 16 + 16;

pub(super) struct Offsets {
    file: File,
    source: Sha256,
}

impl Offsets {
    pub fn open(home: &Path, path: &Path, family: &str, metadata: &Metadata) -> Option<Self> {
        let modified = metadata.modified().ok()?.duration_since(SystemTime::UNIX_EPOCH).ok()?;
        let mut source = Sha256::new();
        source.update(family.as_bytes());
        source.update(path.as_os_str().as_encoded_bytes());
        source.update(metadata.len().to_le_bytes());
        source.update(modified.as_nanos().to_le_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            source.update(metadata.dev().to_le_bytes());
            source.update(metadata.ino().to_le_bytes());
            source.update(metadata.ctime().to_le_bytes());
            source.update(metadata.ctime_nsec().to_le_bytes());
        }
        let mut options = crate::home_fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false).mode(0o600);
        let file = options.open(home.join("terminal-transcript-offsets.v2")).ok()?;
        // Best effort. A second reader can always page the transcript directly.
        file.try_lock().ok()?;
        Some(Self { file, source })
    }

    fn slot(&mut self, end: u64) -> Option<[u8; 32]> {
        let tag: [u8; 32] = self.source.clone().chain_update(end.to_le_bytes()).finalize().into();
        let slot = u64::from_le_bytes(tag.get(..8)?.try_into().ok()?) % SLOTS;
        self.file.seek(SeekFrom::Start(slot * RECORD_BYTES as u64)).ok()?;
        Some(tag)
    }

    fn validated(&mut self, end: u64) -> Option<[u8; RECORD_BYTES]> {
        let tag = self.slot(end)?;
        let mut record = [0; RECORD_BYTES];
        self.file.read_exact(&mut record).ok()?;
        let (body, check) = record.split_at(RECORD_BYTES - 16);
        if body.get(..32)? != tag || Sha256::digest(body).get(..16)? != check {
            return None;
        }
        Some(record)
    }

    pub fn contains_part(&mut self, end: u64, start: u64, stop: u64) -> bool {
        self.validated(end).is_some_and(|record| {
            record[PARTS_AT..RECORD_BYTES - 16]
                .chunks_exact(16)
                .any(|part| part[..8] == start.to_le_bytes() && part[8..] == stop.to_le_bytes())
        })
    }

    pub fn skip(&mut self, end: u64, needle: &Needle) -> Option<u64> {
        let body = self.validated(end)?;
        let older = u64::from_le_bytes(body.get(32..40)?.try_into().ok()?);
        let filter = body.get(40..)?;
        (older < end
            && needle.words().iter().any(|word| {
                word.is_ascii()
                    && word.as_bytes().windows(3).any(|tri| {
                        let bit = trigram(tri);
                        filter[bit / 8] & (1 << (bit % 8)) == 0
                    })
            }))
        .then_some(older)
    }

    pub fn record(&mut self, page: &TranscriptPage, parts: &[Part]) {
        if page.start >= page.end || (parts.is_empty() && page.last_break != Some(page.end)) {
            return;
        }
        let Some(tag) = self.slot(page.end) else { return };
        let mut record = [0; RECORD_BYTES];
        record[..32].copy_from_slice(&tag);
        record[32..40].copy_from_slice(&page.start.to_le_bytes());
        let filter = &mut record[40..40 + FILTER_BYTES];
        let mut remaining = 64 * 1024usize;
        'turns: for turn in &page.turns {
            for text in
                [&*turn.prompt, &*turn.answer].into_iter().chain(turn.tools.iter().map(tool_title))
            {
                // Unicode case folding can introduce ASCII (e.g. the Kelvin sign). Keep these
                // pages in every candidate set rather than risk a false negative.
                if text.len() > remaining || !text.is_ascii() {
                    filter.fill(0xff);
                    break 'turns;
                }
                remaining -= text.len();
                for tri in text.as_bytes().windows(3) {
                    let bit = trigram(tri);
                    filter[bit / 8] |= 1 << (bit % 8);
                }
            }
        }
        if !parts.is_empty() {
            // Raw source is searchable too. A provisional or missing prose trigram cannot skip it.
            filter.fill(0xff);
            for (dest, part) in record[PARTS_AT..RECORD_BYTES - 16].chunks_exact_mut(16).zip(parts)
            {
                dest[..8].copy_from_slice(&part.start.to_le_bytes());
                dest[8..].copy_from_slice(&part.end.to_le_bytes());
            }
        }
        let (body, check) = record.split_at_mut(RECORD_BYTES - 16);
        check.copy_from_slice(&Sha256::digest(body)[..16]);
        let _ = self.file.write_all(&record);
    }
}

fn trigram(three: &[u8]) -> usize {
    three.iter().fold(0usize, |hash, byte| hash * 31 + usize::from(byte.to_ascii_lowercase()))
        % (FILTER_BYTES * 8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adopt_replay::PastTurn;

    #[test]
    fn terminal_agent_history_sparse_index_skips_only_proven_misses_and_invalidates_on_append() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("log");
        std::fs::write(&path, b"synthetic transcript").unwrap();
        let mut index =
            Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
        let page = TranscriptPage {
            start: 4,
            end: path.metadata().unwrap().len(),
            read: 0,
            clipped_head: None,
            last_break: Some(path.metadata().unwrap().len()),
            turns: vec![PastTurn { prompt: "SHOW status".into(), ..PastTurn::default() }],
        };
        index.record(&page, &[]);
        let term = |text: &str| Needle::parse(text).unwrap();
        assert_eq!(index.skip(page.end, &term("show")), None);
        assert_eq!(index.skip(page.end, &term("xyzzy")), Some(4));
        drop(index);
        let mut reopened =
            Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
        assert_eq!(reopened.skip(page.end, &term("xyzzy")), Some(4));
        assert!(reopened.file.metadata().unwrap().len() <= SLOTS * RECORD_BYTES as u64);
        drop(reopened);
        std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"append").unwrap();
        let mut changed =
            Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
        assert_eq!(changed.skip(page.end, &term("xyzzy")), None);
    }
}
