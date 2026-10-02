//! Log segments: JSON lines, one committed record per line.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use cmux_tasks_core::{Envelope, OpResult};
use serde::{Deserialize, Serialize};

use super::OpenError;

/// One committed op. `at` is the commit time the reducer saw, so replay is
/// deterministic.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub v: u32,
    pub seq: u64,
    pub at: i64,
    #[serde(flatten)]
    pub envelope: Envelope,
    pub result: OpResult,
}

fn segment_name(first_seq: u64) -> String {
    format!("{first_seq:020}.jsonl")
}

fn segments(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut paths: Vec<PathBuf> = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    paths.sort();
    Ok(paths)
}

/// Every record in every segment, in order. A final line without its
/// newline in the last segment is a torn write that was never acknowledged:
/// it is truncated away. Any other unreadable line is corruption.
pub fn read_all(dir: &Path) -> Result<Vec<Record>, OpenError> {
    let paths = segments(dir)?;
    let mut out = Vec::new();
    for (index, path) in paths.iter().enumerate() {
        let last_segment = index + 1 == paths.len();
        let bytes = fs::read(path)?;
        let mut offset = 0usize;
        while offset < bytes.len() {
            let Some(end) = bytes[offset..].iter().position(|b| *b == b'\n').map(|n| offset + n) else {
                if last_segment {
                    truncate(path, offset as u64)?;
                    break;
                }
                return Err(OpenError::Corrupt(format!("{}: unterminated record in a sealed segment", path.display())));
            };
            let line = &bytes[offset..end];
            match serde_json::from_slice::<Record>(line) {
                Ok(record) => out.push(record),
                Err(e) => return Err(OpenError::Corrupt(format!("{} at byte {offset}: {e}", path.display()))),
            }
            offset = end + 1;
        }
    }
    Ok(out)
}

fn truncate(path: &Path, len: u64) -> io::Result<()> {
    let file = OpenOptions::new().write(true).open(path)?;
    file.set_len(len)?;
    file.sync_all()
}

pub struct Writer {
    dir: PathBuf,
    file: File,
    size: u64,
    max: u64,
    next_seq: u64,
}

impl Writer {
    /// Continue the newest segment, or start one at `next_seq`.
    pub fn open(dir: &Path, next_seq: u64, max: u64) -> io::Result<Self> {
        let newest = segments(dir)?.pop();
        let (path, created) = match newest {
            Some(path) if fs::metadata(&path)?.len() < max => (path, false),
            _ => (dir.join(segment_name(next_seq)), true),
        };
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        if created {
            super::sync_dir(dir)?;
        }
        let size = file.metadata()?.len();
        Ok(Self { dir: dir.to_owned(), file, size, max, next_seq })
    }

    /// Append records and fsync once. Rotates afterwards when the segment is full.
    pub fn append(&mut self, records: &[Record]) -> io::Result<()> {
        let mut buffer = Vec::new();
        for record in records {
            serde_json::to_writer(&mut buffer, record).map_err(io::Error::other)?;
            buffer.push(b'\n');
        }
        self.file.write_all(&buffer)?;
        self.file.sync_data()?;
        self.size += buffer.len() as u64;
        if let Some(last) = records.last() {
            self.next_seq = last.seq + 1;
        }
        if self.size >= self.max {
            let path = self.dir.join(segment_name(self.next_seq));
            self.file = OpenOptions::new().create(true).append(true).open(&path)?;
            super::sync_dir(&self.dir)?;
            self.size = 0;
        }
        Ok(())
    }
}
