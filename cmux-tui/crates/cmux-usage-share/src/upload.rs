//! The uploader: reads the spool past a per-file byte cursor, sends batches of at most
//! [`MAX_RECORDS`] records and [`MAX_BODY_BYTES`] to cmux-platform, and moves the cursor only past
//! a batch the server accepted. The server keys a record by person, install, at, src and the hash
//! of its event, so a batch sent again after a lost answer counts once.

use crate::ids::tmp_path;
use crate::record::Record;
use serde::Serialize;
use std::collections::BTreeMap;
use std::future::Future;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

/// Records per upload (cmux-platform's `USAGE_MAX_RECORDS`).
pub const MAX_RECORDS: usize = 5000;
/// The largest upload body (cmux-platform's `USAGE_MAX_BODY_BYTES`).
pub const MAX_BODY_BYTES: usize = 1024 * 1024;
/// The cursor file: spool file name -> bytes already sent.
pub const CURSOR_FILE: &str = "cursor.json";

pub type Cursor = BTreeMap<String, u64>;

/// The cursor in `dir`; empty when missing or unreadable.
pub fn read_cursor(dir: &Path) -> Cursor {
    std::fs::read(dir.join(CURSOR_FILE))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Writes the cursor atomically (a 0600 temp file renamed over it), keeping only files that exist.
pub fn write_cursor(dir: &Path, cursor: &Cursor) -> std::io::Result<()> {
    let present = crate::spool::files(dir);
    let kept: Cursor =
        cursor.iter().filter(|(k, _)| present.contains(k)).map(|(k, v)| (k.clone(), *v)).collect();
    let path = dir.join(CURSOR_FILE);
    let tmp = tmp_path(&path);
    {
        let mut file = crate::spool::open_private(&tmp, false)?;
        file.write_all(&serde_json::to_vec(&kept).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, &path)
}

/// One upload body and where the cursor goes once it is accepted.
#[derive(Debug, Clone, PartialEq)]
pub struct Batch {
    pub body: Vec<u8>,
    pub records: usize,
    /// The cursor after this batch.
    pub cursor: Cursor,
}

const HEAD_A: &[u8] = b"{\"install\":\"";
const HEAD_B: &[u8] = b"\",\"records\":[";
const TAIL: &[u8] = b"]}";

/// The next batch from `cursor`, within `max_records` and `max_bytes`; None when nothing is
/// unsent. A line that is not a whole record this crate writes (cut short, edited by hand, from a
/// newer build) is passed over, so one bad line never holds the rest back; so is a line larger
/// than a body can hold.
pub fn next_batch(
    dir: &Path,
    install: &str,
    cursor: &Cursor,
    max_records: usize,
    max_bytes: usize,
) -> Option<Batch> {
    let mut body = Vec::with_capacity(4096);
    body.extend_from_slice(HEAD_A);
    body.extend_from_slice(install.as_bytes());
    body.extend_from_slice(HEAD_B);
    let empty_len = body.len() + TAIL.len();
    let mut records = 0usize;
    let mut moved = cursor.clone();
    let mut changed = false;
    'files: for name in crate::spool::files(dir) {
        let start = cursor.get(&name).copied().unwrap_or(0);
        let Ok(mut file) = std::fs::File::open(dir.join(&name)) else { continue };
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        if len <= start || file.seek(SeekFrom::Start(start)).is_err() {
            continue;
        }
        // At most one body's worth past the cursor: what does not fit waits for the next batch.
        let cap = u64::try_from(max_bytes).unwrap_or(u64::MAX).saturating_mul(2);
        let mut rest = Vec::new();
        if file.take(cap).read_to_end(&mut rest).is_err() {
            continue;
        }
        let mut offset = start;
        for line in rest.split_inclusive(|b| *b == b'\n') {
            // A line still being written (no newline yet) waits.
            if line.last() != Some(&b'\n') {
                break;
            }
            let advance = u64::try_from(line.len()).unwrap_or(u64::MAX);
            let text = line.strip_suffix(b"\n").unwrap_or(line);
            let Some(canonical) = serde_json::from_slice::<Record>(text)
                .ok()
                .and_then(|r| serde_json::to_vec(&r).ok())
            else {
                offset = offset.saturating_add(advance);
                moved.insert(name.clone(), offset);
                changed = true;
                continue;
            };
            let comma = usize::from(records > 0);
            if empty_len.saturating_add(canonical.len()).saturating_add(1) > max_bytes {
                // Never fits: passed over.
                offset = offset.saturating_add(advance);
                moved.insert(name.clone(), offset);
                changed = true;
                continue;
            }
            if records >= max_records
                || body.len() + comma + canonical.len() + TAIL.len() > max_bytes
            {
                break 'files;
            }
            if comma == 1 {
                body.push(b',');
            }
            body.extend_from_slice(&canonical);
            records += 1;
            offset = offset.saturating_add(advance);
            moved.insert(name.clone(), offset);
            changed = true;
        }
    }
    if !changed {
        return None;
    }
    body.extend_from_slice(TAIL);
    Some(Batch { body, records, cursor: moved })
}

/// What one upload call got back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Sent {
    /// 2xx: stored (or already stored).
    Accepted { accepted: u64, duplicates: u64 },
    /// 4xx other than 401/403/404: the server refused this batch (`usage.invalid`,
    /// `usage.too_large`). Uploading stops until the next start or change.
    Refused { status: u16, code: Option<String> },
    /// 401, 403 or 404, or no sign-in: not signed in as a person, not in a sharing team, or
    /// sharing off on that server. Nothing is retried until the next round.
    Stopped { status: u16, code: Option<String> },
    /// 5xx or no answer: try again later, with backoff.
    Retry { why: String },
}

/// The platform's refusal code, kept only when it is a plain dotted token.
pub fn refusal_code(body: &[u8]) -> Option<String> {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()?
        .get("code")?
        .as_str()
        .filter(|c| {
            c.len() <= 64 && c.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_')
        })
        .map(str::to_owned)
}

/// [`Sent`] for an HTTP answer.
pub fn classify(status: u16, body: &[u8]) -> Sent {
    match status {
        200..=299 => {
            let answer = serde_json::from_slice::<serde_json::Value>(body).unwrap_or_default();
            let n = |k: &str| answer.get(k).and_then(serde_json::Value::as_u64).unwrap_or(0);
            Sent::Accepted { accepted: n("accepted"), duplicates: n("duplicates") }
        }
        401 | 403 | 404 => Sent::Stopped { status, code: refusal_code(body) },
        400..=499 => Sent::Refused { status, code: refusal_code(body) },
        _ => Sent::Retry { why: format!("HTTP {status}") },
    }
}

/// Sends one upload body; the acpmux daemon's posts it with the person's cmux sign-in.
pub trait Sender {
    fn send(&self, body: Vec<u8>) -> impl Future<Output = Sent> + Send;
}

/// How an upload round ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Round {
    pub batches: u32,
    pub records: u64,
    pub accepted: u64,
    pub duplicates: u64,
    /// The answer that ended the round early (None: everything unsent went).
    pub ended: Option<Sent>,
}

/// Sends every unsent batch in `dir`, oldest first, moving the cursor past each accepted one and
/// stopping at the first that is not.
pub async fn upload<S: Sender>(dir: &Path, install: &str, sender: &S) -> Round {
    upload_with(dir, install, sender, MAX_RECORDS, MAX_BODY_BYTES).await
}

/// [`upload`] with its limits (tests).
pub async fn upload_with<S: Sender>(
    dir: &Path,
    install: &str,
    sender: &S,
    max_records: usize,
    max_bytes: usize,
) -> Round {
    let mut round = Round { batches: 0, records: 0, accepted: 0, duplicates: 0, ended: None };
    let mut cursor = read_cursor(dir);
    // Bounded: each batch moves the cursor forward, and a round stops after this many.
    for _ in 0..10_000 {
        let Some(batch) = next_batch(dir, install, &cursor, max_records, max_bytes) else { break };
        if batch.records == 0 {
            // Only lines passed over: move past them without a call.
            cursor = batch.cursor;
            let _ = write_cursor(dir, &cursor);
            continue;
        }
        match sender.send(batch.body).await {
            Sent::Accepted { accepted, duplicates } => {
                cursor = batch.cursor;
                if let Err(e) = write_cursor(dir, &cursor) {
                    round.ended = Some(Sent::Retry { why: format!("cursor not written: {e}") });
                    return round;
                }
                round.batches += 1;
                round.records += u64::try_from(batch.records).unwrap_or(u64::MAX);
                round.accepted += accepted;
                round.duplicates += duplicates;
            }
            other => {
                round.ended = Some(other);
                return round;
            }
        }
    }
    round
}
