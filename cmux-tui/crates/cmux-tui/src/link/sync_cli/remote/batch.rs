//! Small whole-file writes sent several at a time on one connection: every request of a batch
//! goes before any answer is read, so a batch costs one round trip of the link instead of one
//! per file. The machine daemon reads a connection's lines in order and answers each in turn
//! (`server::fs_wire`), so nothing changes on its side; only the wait between two files goes.
//!
//! Over a Cloud machine's link a round trip is about 100 ms (Leo's NIGHTLY, 2026-11-15: a
//! 20,000-file folder took 290 s more than a small repository, at 8 connections), so a folder of
//! many small files was bound by round trips, not bytes: 131,000 files at 8 connections is
//! about 1,600 s of waiting alone.

use std::io::{BufRead as _, Read as _, Write as _};
use std::time::Instant;

use anyhow::bail;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{
    Dropped, FsRefusal, MAX_ANSWER_BYTES, MAX_OTHER_ANSWERS, Remote, SEND_SLICE_BYTES,
    answer_budget, revision_of, shrinks, stalled, timed_out, with_bytes,
};

/// One file of a batch: written whole over whatever file is at `path` (never a part file).
pub(in crate::link::sync_cli) struct Whole<'a> {
    pub path: &'a str,
    pub bytes: &'a [u8],
    pub permissions: u32,
}

/// What a batch got: each file's answer in the batch's order (its revision, or the machine's
/// refusal of it), `None` for one whose answer never came; and why the connection failed, when
/// it did. A failed connection is not used again: the caller writes the files with no answer
/// on a new one, which is safe because each is a whole-file overwrite of the same bytes (the
/// rule `remote::REPLAYABLE` sends one again by).
pub(in crate::link::sync_cli) struct Batched {
    pub answers: Vec<Option<anyhow::Result<String>>>,
    pub failed: Option<anyhow::Error>,
}

impl Remote {
    /// Writes `files`, each as one `fs.write` overwrite exactly as [`Remote::write`] sends a file
    /// of one part (deflated when the machine takes it and the bytes shrink, `no_follow` when it
    /// takes that, under a held copy's hold), all sent before the first answer is read.
    pub(in crate::link::sync_cli) fn write_batch(&mut self, files: &[Whole<'_>]) -> Batched {
        let mut answers: Vec<Option<anyhow::Result<String>>> = files.iter().map(|_| None).collect();
        let failed = self.send_and_read(files, &mut answers).err();
        Batched { answers, failed }
    }

    fn send_and_read(
        &mut self,
        files: &[Whole<'_>],
        answers: &mut [Option<anyhow::Result<String>>],
    ) -> anyhow::Result<()> {
        let mut text = String::new();
        let first_id = self.next_id;
        for file in files {
            // Each request passes the held copy's fence, as one sent alone does.
            crate::link::sync_cli::fence::check("fs.write")?;
            let mut request = self.guarded(
                json!({ "path": file.path, "mode": "overwrite", "permissions": file.permissions }),
            );
            if let Some(job) = crate::link::sync_cli::fence::hold_for("fs.write") {
                request.set("hold", json!(job));
            }
            let compress = self.deflate && shrinks(file.bytes);
            let mut request = with_bytes(request, file.bytes, compress)?;
            request.set("id", json!(self.next_id));
            request.set("cmd", json!("fs.write"));
            self.next_id += 1;
            text.push_str(&request.to_string());
            text.push('\n');
        }
        for slice in text.as_bytes().chunks(SEND_SLICE_BYTES) {
            self.reader.get_mut().write_all(slice).map_err(|error| {
                if timed_out(&error) {
                    stalled(error, "the machine took no bytes of the request", self.write_timeout())
                } else {
                    Dropped(format!("the connection to the machine dropped: {error}")).into()
                }
            })?;
        }
        let silence = self.read_timeout();
        let budget = answer_budget(silence, text.len());
        let mut answer_by = Instant::now() + budget;
        let mut left = files.len();
        let mut others = 0;
        while left > 0 {
            let mut line = Vec::new();
            let mut limited = std::io::Read::take(&mut self.reader, MAX_ANSWER_BYTES + 1);
            let read = loop {
                match limited.read_until(b'\n', &mut line) {
                    Ok(_) => break line.len(),
                    // A batch waits one budget past its last answer; a machine slower than that
                    // gets the rest again, one at a time with the full patience of a call.
                    Err(error) if timed_out(&error) && Instant::now() < answer_by => {}
                    Err(error) if timed_out(&error) => {
                        return Err(stalled(error, "the machine did not answer a batch", silence));
                    }
                    Err(error) => {
                        return Err(Dropped(format!(
                            "the connection to the machine dropped: {error}"
                        ))
                        .into());
                    }
                }
            };
            if read == 0 || line.last() != Some(&b'\n') {
                if u64::try_from(read).unwrap_or(u64::MAX) > MAX_ANSWER_BYTES {
                    bail!("the machine daemon's answer is too long");
                }
                return Err(Dropped("the machine daemon closed the connection".into()).into());
            }
            let answer: Value = serde_json::from_slice(&line)?;
            let field = |key: &str| answer.get(key).unwrap_or(&Value::Null);
            let slot = field("id")
                .as_u64()
                .and_then(|id| id.checked_sub(first_id))
                .and_then(|index| usize::try_from(index).ok())
                .and_then(|index| answers.get_mut(index))
                .filter(|slot| slot.is_none());
            let Some(slot) = slot else {
                others += 1;
                if others > MAX_OTHER_ANSWERS {
                    bail!("the machine daemon kept answering other requests");
                }
                continue;
            };
            *slot = Some(if field("ok") == &json!(true) {
                revision_of(field("data"))
            } else {
                Err(FsRefusal {
                    code: field("error_code").as_str().unwrap_or("fs.unknown").to_string(),
                    message: field("error").as_str().unwrap_or_default().to_string(),
                }
                .into())
            });
            left -= 1;
            answer_by = Instant::now() + budget;
        }
        Ok(())
    }
}

/// Reads all of `reader` when it holds at most `most` bytes; `None` past that.
pub(in crate::link::sync_cli) fn read_at_most(
    reader: &mut dyn std::io::Read,
    most: usize,
) -> std::io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    reader.take(most as u64 + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() <= most).then_some(bytes))
}
