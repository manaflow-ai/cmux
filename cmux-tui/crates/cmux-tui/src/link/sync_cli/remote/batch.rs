//! Small whole-file writes sent several at a time on one connection: every request of a batch
//! goes before any answer is read, so a batch costs one round trip of the link instead of one
//! per file. The machine daemon reads a connection's lines in order and answers each in turn
//! (`server::fs_wire`), so nothing changes on its side; only the wait between two files goes.
//!
//! Over a Cloud machine's link a round trip is about 100 ms (Leo's NIGHTLY, 2026-11-15: a
//! 20,000-file folder took 290 s more than a small repository, at 8 connections), so a folder of
//! many small files was bound by round trips, not bytes: 131,000 files at 8 connections is
//! about 1,600 s of waiting alone.
//!
//! A batch stays lines (base64), not write streams: a stream is one dial and one `ready`
//! round trip per file, the very wait a batch removes, and many files on one raw stream would
//! need a new daemon op behind a capability of its own. A batch's files are small (one part at
//! most), so base64's third is a few KiB each; a large file goes alone, over a stream.

use std::io::{BufRead as _, Read as _, Write as _};
use std::time::Instant;

use anyhow::bail;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{
    Dropped, FsRefusal, MAX_ANSWER_BYTES, MAX_OTHER_ANSWERS, Remote, SEND_SLICE_BYTES,
    answer_budget, choose, name_of, revision_of, stalled, timed_out, with_bytes,
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

/// What [`Remote::call_batch`] got, as [`Batched`] does: each answer's `data`.
pub(in crate::link::sync_cli) struct Called {
    pub answers: Vec<Option<anyhow::Result<Value>>>,
    pub failed: Option<anyhow::Error>,
}

impl Remote {
    /// Writes `files`, each as one `fs.write` overwrite exactly as [`Remote::write`] sends a file
    /// of one part (zstd or deflate when the machine takes it and the bytes shrink, `no_follow` when it
    /// takes that, under a held copy's hold), all sent before the first answer is read.
    pub(in crate::link::sync_cli) fn write_batch(&mut self, files: &[Whole<'_>]) -> Batched {
        let mut requests = Vec::with_capacity(files.len());
        for file in files {
            let request = self.guarded(
                json!({ "path": file.path, "mode": "overwrite", "permissions": file.permissions }),
            );
            let kind = cmux_bytes::classify::classify(name_of(file.path), file.bytes);
            match choose(file.bytes, kind, self.zstd, self.deflate) {
                Ok(coded) => requests.push(("fs.write", with_bytes(request, file.bytes, coded))),
                Err(error) => {
                    return Batched {
                        answers: files.iter().map(|_| None).collect(),
                        failed: Some(error),
                    };
                }
            }
        }
        let called = self.call_batch(requests);
        Batched {
            answers: called
                .answers
                .into_iter()
                .map(|answer| answer.map(|data| data.and_then(|data| revision_of(&data))))
                .collect(),
            failed: called.failed,
        }
    }

    /// Sends every request of `requests` (`cmd` and its params) before reading any answer,
    /// then reads their answers: each one's `data`, or the machine's refusal of it. The machine
    /// runs a connection's requests in the order they came, so one may build on one before it
    /// (a folder made before a folder in it).
    pub(in crate::link::sync_cli) fn call_batch(
        &mut self,
        requests: Vec<(&'static str, Value)>,
    ) -> Called {
        let mut answers: Vec<Option<anyhow::Result<Value>>> =
            requests.iter().map(|_| None).collect();
        let failed = self.send_and_read(requests, &mut answers).err();
        Called { answers, failed }
    }

    fn send_and_read(
        &mut self,
        requests: Vec<(&'static str, Value)>,
        answers: &mut [Option<anyhow::Result<Value>>],
    ) -> anyhow::Result<()> {
        let mut text = String::new();
        let first_id = self.next_id;
        let count = requests.len();
        for (cmd, mut request) in requests {
            // Each request passes the held copy's fence, as one sent alone does.
            crate::link::sync_cli::fence::check(cmd)?;
            if let Some(job) = crate::link::sync_cli::fence::hold_for(cmd) {
                request.set("hold", json!(job));
            }
            request.set("id", json!(self.next_id));
            request.set("cmd", json!(cmd));
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
        let mut left = count;
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
                Ok(field("data").clone())
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
