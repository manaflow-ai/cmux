//! How one connection of [`super::write_parallel`] writes its small files: a few at a time,
//! sent together ([`Remote::write_batch`]), so a folder of many small files is not bound by one
//! round trip of the link per file. A file whose write needs a question first (what is at its
//! path, when the machine's writes do not refuse a symlink themselves; a folder in the way) is
//! written alone, exactly as before.

use std::path::Path;

use super::remote::{self, Remote, Whole};
use super::{Job, LinkInTheWay, open, write_on};

/// Most files one batch sends.
const BATCH_FILES: usize = 32;
/// Most bytes one batch reads into memory (one file bigger than this goes alone).
const BATCH_BYTES: u64 = 1024 * 1024;

/// The next batch of `queue`: up to [`BATCH_FILES`] jobs of up to [`BATCH_BYTES`] in all, and
/// always at least one while any is left.
pub(super) fn take(queue: &mut std::vec::IntoIter<Job>) -> Vec<Job> {
    let mut batch = Vec::new();
    let mut bytes = 0u64;
    while batch.len() < BATCH_FILES {
        let Some(next) = queue.as_slice().first() else { break };
        if !batch.is_empty() && bytes.saturating_add(next.bytes) > BATCH_BYTES {
            break;
        }
        bytes = bytes.saturating_add(next.bytes);
        batch.extend(queue.next());
    }
    batch
}

/// Writes `jobs` on `remote` (connected first when it is not yet) and answers each one's
/// outcome. The ones whose write is one whole-file overwrite go as one batch; the rest, and any
/// a dropped batch left with no answer, are written one at a time ([`write_on`]) on a new
/// connection when the batch's failed.
pub(super) fn write(
    remote: &mut Option<Remote>,
    seen: &mut std::collections::BTreeMap<String, bool>,
    socket: &Path,
    remote_root: &str,
    jobs: Vec<Job>,
) -> Vec<(Job, anyhow::Result<String>)> {
    if jobs.len() > 1
        && remote.is_none()
        && let Ok(connected) = Remote::connect_negotiated(socket)
    {
        *remote = Some(connected);
    }
    let no_follow = remote.as_ref().is_some_and(Remote::no_follow);
    let mut done = Vec::with_capacity(jobs.len());
    let mut alone = Vec::new();
    let mut batched: Vec<(Job, Vec<u8>)> = Vec::new();
    for job in jobs {
        if !(no_follow && whole_overwrite(&job)) {
            alone.push(job);
            continue;
        }
        let read = open(&job.file)
            .and_then(|mut reader| Ok(remote::read_at_most(&mut *reader, remote::PART_BYTES)?));
        match read {
            Ok(Some(bytes)) => batched.push((job, bytes)),
            // Grew past one part since it was listed: written in parts, alone.
            Ok(None) => alone.push(job),
            Err(error) => done.push((job, Err(error))),
        }
    }
    if batched.len() == 1 {
        alone.extend(batched.pop().map(|(job, _)| job));
    }
    if let Some(connection) = remote.as_mut().filter(|_| !batched.is_empty()) {
        let files: Vec<Whole<'_>> = batched
            .iter()
            .map(|(job, bytes)| Whole {
                path: &job.target,
                bytes,
                permissions: job.file.permissions,
            })
            .collect();
        let answers = connection.write_batch(&files);
        if answers.failed.is_some() {
            // Its stream may still hold answers of this batch: never read again.
            *remote = None;
        }
        for ((job, _), answer) in batched.into_iter().zip(answers.answers) {
            match answer {
                Some(Err(error))
                    if remote::refusal_code(&error) == Some(remote::SYMLINK_IN_PATH) =>
                {
                    done.push((job, Err(LinkInTheWay.into())));
                }
                Some(written) => done.push((job, written)),
                None => alone.push(job),
            }
        }
    } else {
        alone.extend(batched.into_iter().map(|(job, _)| job));
    }
    for job in alone {
        let written = write_on(remote, seen, socket, remote_root, &job);
        done.push((job, written));
    }
    done
}

/// Whether `job`'s write is one `fs.write` overwrite with no question before it: the folder's
/// listing said nothing or a file is at its path (a folder there is asked about again, a
/// symlink refused), and it fits one part.
fn whole_overwrite(job: &Job) -> bool {
    let nothing_or_file = match &job.found {
        Some(None) => true,
        Some(Some(kind)) => kind == "file",
        None => false,
    };
    nothing_or_file && job.bytes <= remote::PART_BYTES as u64
}
