//! Sharing the usage record with the team: what `cmux usage upload` sends and how far it got.
//!
//! A second opt-in on top of recording (`diagnostics.usageSharing`): the app writes the
//! `<dir>/share` switch from this Mac's own consent ([`UsageDir::set_sharing`]), and an upload
//! refuses without it. Each upload sends the records after the cursor in `<dir>/upload-cursor`,
//! in batches the team backend takes (at most [`MAX_RECORDS`] records and [`MAX_BODY_BYTES`]
//! bytes, `{"install", "records"}`), and moves the cursor only past a batch the backend
//! accepted. The backend keys a record by its content, so a batch sent twice counts once.
//!
//! The install id is the first 24 hex of `sha256("install:" ‖ salt)`: stable for one salt, new
//! after [`UsageDir::clear`] (which makes a new salt), and never the salt itself. Nothing here
//! talks to the network: the caller sends each [`Batch`] (cmux-tui `cli/usage_sharing.rs`).

use std::fs;
use std::io;

use serde::{Deserialize, Serialize};

use crate::event::Record;
use crate::store::{UPLOAD_CURSOR, UsageDir};

/// The most records one upload carries (the backend's `USAGE_MAX_RECORDS`).
pub const MAX_RECORDS: usize = 5000;
/// The largest upload body in bytes (the backend's `USAGE_MAX_BODY_BYTES`, 1 MiB).
pub const MAX_BODY_BYTES: usize = 1024 * 1024;

/// This install's id for `salt`: 24 lowercase hex characters.
pub fn install_id(salt: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut digest = Sha256::new();
    digest.update(b"install:");
    digest.update(salt);
    hex::encode(&digest.finalize()[..12])
}

/// How far an install's upload has reached: every record before `at`, and the first `n` of
/// those at `at` (records of one millisecond keep their order across reads), were accepted.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cursor {
    pub install: String,
    pub at: u64,
    pub n: usize,
}

impl Cursor {
    /// The cursor `dir` keeps for `install`; the start when there is none, it does not parse, or
    /// it belongs to another install (the salt changed).
    pub fn load(dir: &UsageDir, install: &str) -> Self {
        fs::read_to_string(dir.path().join(UPLOAD_CURSOR))
            .ok()
            .and_then(|text| serde_json::from_str::<Self>(&text).ok())
            .filter(|cursor| cursor.install == install)
            .unwrap_or_else(|| Self { install: install.to_owned(), at: 0, n: 0 })
    }

    /// Writes the cursor (a whole-file replace, so a crash leaves the old one or the new one).
    pub fn save(&self, dir: &UsageDir) -> io::Result<()> {
        let path = dir.path().join(UPLOAD_CURSOR);
        let temporary = dir.path().join(format!("{UPLOAD_CURSOR}.tmp"));
        let text = serde_json::to_string(self).map_err(io::Error::other)?;
        fs::write(&temporary, text + "\n")?;
        fs::rename(temporary, path)
    }

    /// The index of the first record of `records` (in time order) not yet uploaded.
    pub fn start(&self, records: &[Record]) -> usize {
        let before = records.partition_point(|r| r.at < self.at);
        let same = records[before..].iter().take_while(|r| r.at == self.at).count();
        before + self.n.min(same)
    }

    /// The cursor once `records[..end]` (in time order) are uploaded; this one when `end` is 0.
    pub fn after(&self, records: &[Record], end: usize) -> Self {
        let Some(last) = end.checked_sub(1).and_then(|i| records.get(i)) else {
            return self.clone();
        };
        let uploaded = &records[..end];
        let n = end - uploaded.partition_point(|r| r.at < last.at);
        Self { install: self.install.clone(), at: last.at, n }
    }
}

/// One upload body: `records[start..end]` as `{"install": ..., "records": [...]}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub body: String,
    pub start: usize,
    pub end: usize,
}

impl Batch {
    /// How many records it carries.
    pub fn len(&self) -> usize {
        self.end - self.start
    }

    pub fn is_empty(&self) -> bool {
        self.end == self.start
    }
}

/// The batch of `records[from..]` within `max_records` and `max_bytes`, or nil when none is
/// left. A record that alone passes `max_bytes` still goes as a batch of one (the backend then
/// refuses it, and the upload stops there).
pub fn next_batch(
    install: &str,
    records: &[Record],
    from: usize,
    max_records: usize,
    max_bytes: usize,
) -> Option<Batch> {
    if from >= records.len() {
        return None;
    }
    let mut body = format!("{{\"install\":\"{install}\",\"records\":[");
    let close = "]}";
    let mut end = from;
    for record in &records[from..] {
        if end - from >= max_records.max(1) {
            break;
        }
        let Ok(line) = serde_json::to_string(record) else { break };
        let comma = usize::from(end > from);
        if end > from && body.len() + comma + line.len() + close.len() > max_bytes {
            break;
        }
        if comma == 1 {
            body.push(',');
        }
        body.push_str(&line);
        end += 1;
    }
    body.push_str(close);
    Some(Batch { body, start: from, end })
}

/// What one upload would send, read from the folder.
#[derive(Debug)]
pub struct Pending {
    pub install: String,
    /// Every record in time order; those from `start` on are not uploaded yet.
    pub records: Vec<Record>,
    pub start: usize,
    cursor: Cursor,
}

/// Why an upload stopped before its end.
#[derive(Debug)]
pub enum Stop<E> {
    /// The sender's error for a batch (the backend's refusal, no answer); nothing moved.
    Send(E),
    /// The backend took a batch but the cursor could not be written; the next upload sends it
    /// again and the backend counts it once.
    Cursor(io::Error),
}

/// What an upload did.
#[derive(Debug)]
pub struct Sent<E> {
    pub batches: usize,
    pub records: usize,
    pub stopped: Option<Stop<E>>,
}

impl Pending {
    /// The records `dir` has not uploaded yet; nil before anything was recorded (no salt). Only
    /// records made while sharing is on count: what was recorded before this Mac's consent to
    /// share, or while sharing was off, never goes (none while it is off).
    pub fn read(dir: &UsageDir) -> Option<Self> {
        let install = install_id(&dir.existing_salt()?);
        let cursor = Cursor::load(dir, &install);
        let records = dir.sharing_since().map_or_else(Vec::new, |since| dir.read(since));
        let start = cursor.start(&records);
        Some(Self { install, records, start, cursor })
    }

    /// How many records would go.
    pub fn count(&self) -> usize {
        self.records.len() - self.start
    }

    /// The first record that would go, as its upload line.
    pub fn sample(&self) -> Option<String> {
        self.records.get(self.start).and_then(|r| serde_json::to_string(r).ok())
    }

    /// Sends every pending record with `send`, one [`Batch`] at a time within the backend's
    /// limits, saving the cursor in `dir` after each batch `send` accepted. Stops at the first
    /// batch `send` refuses.
    pub fn send<E>(
        self,
        dir: &UsageDir,
        limits: (usize, usize),
        mut send: impl FnMut(&Batch) -> Result<(), E>,
    ) -> Sent<E> {
        let mut sent = Sent { batches: 0, records: 0, stopped: None };
        let mut cursor = self.cursor;
        let mut from = self.start;
        while let Some(batch) = next_batch(&self.install, &self.records, from, limits.0, limits.1) {
            if let Err(error) = send(&batch) {
                sent.stopped = Some(Stop::Send(error));
                break;
            }
            cursor = cursor.after(&self.records, batch.end);
            sent.batches += 1;
            sent.records += batch.len();
            from = batch.end;
            if let Err(error) = cursor.save(dir) {
                sent.stopped = Some(Stop::Cursor(error));
                break;
            }
        }
        sent
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{Event, Source};
    use crate::store::Recorder;
    use crate::store::tests::temp_dir;

    fn record(at: u64, on: bool) -> Record {
        Record { at, src: Source::App, ev: Event::Active { on } }
    }

    #[test]
    fn install_id_is_stable_per_salt_and_differs_across_salts() {
        let a = install_id(&[1u8; 32]);
        assert_eq!(a, install_id(&[1u8; 32]));
        assert_eq!(a.len(), 24);
        assert!(a.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
        assert_ne!(a, install_id(&[2u8; 32]));
        assert!(!a.contains(&hex::encode([1u8; 12])));
    }

    #[test]
    fn the_cursor_is_exact_across_records_of_one_millisecond() {
        let records = vec![
            record(1, true),
            record(5, true),
            record(5, false),
            record(5, true),
            record(9, true),
        ];
        let start = Cursor { install: "i".into(), ..Cursor::default() };
        assert_eq!(start.start(&records), 0);
        // Two of the three records at 5 went: the third is next.
        let mid = start.after(&records, 3);
        assert_eq!(mid, Cursor { install: "i".into(), at: 5, n: 2 });
        assert_eq!(mid.start(&records), 3);
        // A batch boundary after all three at 5.
        let all_five = mid.after(&records, 4);
        assert_eq!((all_five.at, all_five.n), (5, 3));
        assert_eq!(all_five.start(&records), 4);
        // A record of the same millisecond recorded later is still sent.
        let mut more = records.clone();
        more.insert(4, record(5, false));
        assert_eq!(all_five.start(&more), 4);
        // Nothing uploaded keeps the cursor.
        assert_eq!(mid.after(&records, 0), mid);
        // Past the end.
        let end = start.after(&records, records.len());
        assert_eq!(end.start(&records), records.len());
    }

    #[test]
    fn batches_keep_the_record_and_byte_limits() {
        let records: Vec<Record> = (0..12).map(|i| record(i, i % 2 == 0)).collect();
        let by_count = next_batch("abc", &records, 0, 5, MAX_BODY_BYTES).expect("batch");
        assert_eq!((by_count.start, by_count.end), (0, 5));
        let body: serde_json::Value = serde_json::from_str(&by_count.body).expect("json");
        assert_eq!(body["install"], "abc");
        assert_eq!(body["records"].as_array().map(Vec::len), Some(5));
        assert_eq!(
            body["records"][0],
            serde_json::json!({"at":0,"src":"app","ev":{"t":"active","on":true}})
        );

        let lines: usize =
            records[2..5].iter().map(|r| serde_json::to_string(r).expect("line").len()).sum();
        let overhead = r#"{"install":"abc","records":[]}"#.len();
        let max_bytes = overhead + lines + 2;
        let by_bytes = next_batch("abc", &records, 2, MAX_RECORDS, max_bytes).expect("batch");
        assert_eq!((by_bytes.start, by_bytes.end), (2, 5));
        assert!(by_bytes.body.len() <= max_bytes);
        // One record bigger than the limit still goes alone.
        let alone = next_batch("abc", &records, 0, MAX_RECORDS, 10).expect("batch");
        assert_eq!(alone.len(), 1);
        assert_eq!(next_batch("abc", &records, 12, 5, MAX_BODY_BYTES), None);
    }

    fn shared_dir(name: &str, records: usize) -> UsageDir {
        let dir = temp_dir(name);
        dir.set_enabled(true).expect("on");
        dir.set_sharing(true).expect("share");
        let since = dir.sharing_since().expect("sharing since");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        rec.append((0..records as u64).map(|i| (since + i / 3, Event::Active { on: i % 2 == 0 })))
            .expect("append");
        dir
    }

    /// The second opt-in covers what is recorded from then on: what this Mac recorded before it
    /// agreed to share, or while sharing was off, never goes.
    #[test]
    fn only_records_made_while_sharing_is_on_go() {
        let dir = temp_dir("share-since");
        dir.set_enabled(true).expect("on");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        rec.append([(1, Event::Active { on: true })]).expect("append");
        assert_eq!(Pending::read(&dir).expect("pending").count(), 0);
        dir.set_sharing(true).expect("share");
        let since = dir.sharing_since().expect("since");
        rec.append([(since, Event::Active { on: false })]).expect("append");
        let pending = Pending::read(&dir).expect("pending");
        assert_eq!(pending.count(), 1);
        assert_eq!(pending.records[pending.start].at, since);
        dir.set_sharing(false).expect("unshare");
        assert_eq!(Pending::read(&dir).expect("pending").count(), 0);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn the_cursor_moves_only_past_accepted_batches() {
        let dir = shared_dir("upload", 10);
        let pending = Pending::read(&dir).expect("pending");
        assert_eq!(pending.count(), 10);
        let since = dir.sharing_since().expect("since");
        let sample = pending.sample().expect("sample");
        assert!(sample.starts_with(&format!(r#"{{"at":{since},"src":"app""#)), "{sample}");
        // The second batch is refused: only the first moves the cursor.
        let mut calls = 0;
        let sent = pending.send(&dir, (4, MAX_BODY_BYTES), |_| {
            calls += 1;
            if calls == 2 { Err("usage.unavailable") } else { Ok(()) }
        });
        assert_eq!((sent.batches, sent.records), (1, 4));
        assert!(matches!(sent.stopped, Some(Stop::Send("usage.unavailable"))));
        let pending = Pending::read(&dir).expect("pending");
        assert_eq!(pending.count(), 6);
        let mut seen = Vec::new();
        let sent = pending.send(&dir, (4, MAX_BODY_BYTES), |batch| {
            seen.push(batch.len());
            Ok::<(), ()>(())
        });
        assert_eq!(seen, vec![4, 2]);
        assert!(sent.stopped.is_none());
        assert_eq!(Pending::read(&dir).expect("pending").count(), 0);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn a_new_salt_starts_over_and_nothing_recorded_has_nothing_pending() {
        let dir = shared_dir("salt", 3);
        let pending = Pending::read(&dir).expect("pending");
        let first = pending.install.clone();
        pending.send(&dir, (MAX_RECORDS, MAX_BODY_BYTES), |_| Ok::<(), ()>(()));
        assert_eq!(Pending::read(&dir).expect("pending").count(), 0);
        dir.clear().expect("clear");
        assert!(Pending::read(&dir).is_none());
        assert!(!dir.path().join(UPLOAD_CURSOR).exists());
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        rec.record_now([Event::Active { on: true }]).expect("append");
        let pending = Pending::read(&dir).expect("pending");
        assert_ne!(pending.install, first);
        assert_eq!(pending.count(), 1);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn sharing_needs_recording() {
        let dir = temp_dir("share-switch");
        assert!(!dir.is_sharing());
        dir.set_enabled(true).expect("on");
        dir.set_sharing(true).expect("share");
        assert!(dir.is_sharing());
        assert!(dir.sharing_since().is_some());
        dir.set_enabled(false).expect("off");
        assert!(!dir.is_sharing());
        dir.set_sharing(false).expect("off again");
        let _ = fs::remove_dir_all(dir.path());
    }
}
