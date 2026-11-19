//! A closed chat's log compressed in place: each plain segment `events/NNNNNN.ndjson` becomes
//! `NNNNNN.ndjson.zst`, which every read opens as the plain one (`store/segment_file.rs`).
//!
//! Lane VMs filled their disks with closed chats' logs (55 GB in `~/.acpmux/sessions`, 427 of 503
//! chats closed, the largest 14 GB). A segment compresses about 14:1 at the level used here
//! (zstd 9 with long-distance matching: 8.7 MB of a Claude chat to 630 KB in 0.09 s).
//!
//! Each segment is one zstd frame, as plain `zstd FILE` writes it (its content size and a
//! checksum in it), so the files a host's own disk cleanup makes read the same way. A segment is
//! compressed without a lock held: written beside the log under a temporary name, synced, and
//! decoded back once to check it against the plain file's bytes. Then, under the writers' lock,
//! and only when no writer holds the chat's log and the plain file is the one read (inode, length
//! and time): the compressed file is renamed into place, the folder synced, the plain file
//! removed, and the folder synced again. A crash at any point leaves a readable log:
//!
//! - before the rename: the plain segment and a temporary file no read opens, which the next pass
//!   over the chat removes;
//! - between the rename and the removal: both files, and a read takes the plain one ("plain wins",
//!   `segment_file`); the next pass compresses it again and removes it;
//! - after: the compressed segment alone.
//!
//! No state has neither file. The compressed file keeps the plain one's modified time: a closed
//! chat's age is its newest segment's time (`hub/retention.rs`). An empty segment stays plain: a
//! log with no byte in it is a purged chat's (`has_records`). The search and kind copies beside
//! the log name the plain file and are made again from the compressed one on the next read.
//!
//! The hub runs one compression at a time, on a thread of its own at the lowest CPU and IO
//! priority, and stops between two segments once the daemon shuts down or the chat is used again
//! (`hub/log_zst.rs`).

use super::segment_file;
use super::*;

/// zstd's level for a segment: with long-distance matching, about 14:1 on a chat's log in about
/// 10 ms per MB (level 19 gains a few percent at 20 times the time).
const LEVEL: i32 = 9;
/// The window long-distance matching may use; zstd keeps no more of it than the segment's size.
const WINDOW_LOG: u32 = 27;
/// What a temporary compressed segment's name holds, before the writing process's id.
const TMP_MARK: &str = ".zst.compress-";
/// What a temporary decompressed segment's name holds ([`LocalStore::thaw_log`]).
const THAW_MARK: &str = ".thaw-";

/// What one pass over a chat's log did ([`LocalStore::compress_log`]).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LogCompression {
    /// Segments compressed by this pass.
    pub segments: u64,
    /// Their plain bytes, and their compressed bytes.
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// The pass stopped before the log's end: asked to, or the log was written meanwhile.
    pub stopped: bool,
}

/// Where a test stops a segment's compression, as a crash there would.
#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CrashAt {
    /// The compressed file is written and synced, not yet renamed into place.
    BeforeRename,
    /// The compressed file is in place, the plain one not yet removed.
    BeforeRemove,
}

#[cfg(test)]
static CRASH_AT: Mutex<Vec<(String, CrashAt)>> = Mutex::new(Vec::new());

/// Tests: the next compression of a segment of chat `id` stops at `at`, once, and fails.
#[cfg(test)]
pub(crate) fn crash_once(id: &str, at: CrashAt) {
    CRASH_AT.lock().unwrap_or_else(|e| e.into_inner()).push((id.to_owned(), at));
}

#[cfg(test)]
fn crashes(id: &str, at: CrashAt) -> bool {
    let mut armed = CRASH_AT.lock().unwrap_or_else(|e| e.into_inner());
    match armed.iter().position(|(chat, when)| chat == id && *when == at) {
        Some(found) => {
            armed.remove(found);
            true
        }
        None => false,
    }
}

/// Runs a segment's commit (its renames and folder syncs), as a store wraps it: the journal
/// store counts it as a sync under way (`counted_sync`).
pub(crate) type CommitWrap<'a> = dyn FnMut(&mut dyn FnMut() -> Result<bool>) -> Result<bool> + 'a;

impl LocalStore {
    /// Compresses each plain segment of chat `id`'s log ([module docs](self)), oldest first,
    /// asking `stop` before each. A cold-archived chat's log is not brought back for it.
    pub(super) fn compress_log(&self, id: &str, stop: &dyn Fn() -> bool) -> Result<LogCompression> {
        self.compress_log_with(id, stop, &mut |commit| commit())
    }

    /// [`Self::compress_log`], each segment's commit run through `wrap`.
    pub(super) fn compress_log_with(
        &self,
        id: &str,
        stop: &dyn Fn() -> bool,
        wrap: &mut CommitWrap<'_>,
    ) -> Result<LogCompression> {
        let mut done = LogCompression::default();
        self.remove_compress_leftovers(id);
        for (_, path) in self.segment_files(id)? {
            if segment_file::is_zst(&path) {
                continue;
            }
            if stop() {
                done.stopped = true;
                break;
            }
            match self.compress_segment(id, &path, wrap)? {
                Some((0, _)) => {}
                Some((before, after)) => {
                    done.segments += 1;
                    done.bytes_before += before;
                    done.bytes_after += after;
                }
                None => {
                    done.stopped = true;
                    break;
                }
            }
        }
        Ok(done)
    }

    /// Puts every compressed segment of chat `id` back plain, for what writes a log in place (a
    /// journal repair, `store/journal_store/repair.rs`). Each is decoded beside the log under a
    /// temporary name, synced, renamed to its plain name, the folder synced, and only then is the
    /// compressed file removed: a crash leaves both (the plain one is read) or the compressed one
    /// alone. The caller holds the log's writers off.
    pub(crate) fn thaw_log(&self, id: &str) -> Result<()> {
        self.remove_compress_leftovers(id);
        let events = self.dir(id).join("events");
        let mut thawed = false;
        for (_, path) in self.segment_files(id)? {
            if !segment_file::is_zst(&path) {
                continue;
            }
            let plain = segment_file::plain_path(&path);
            let name = plain.file_name().and_then(|n| n.to_str()).context("a segment's name")?;
            let tmp = plain.with_file_name(format!(".{name}{THAW_MARK}{}", std::process::id()));
            let _ = crate::home_fs::remove_file(&tmp);
            let written = (|| -> Result<()> {
                let source = crate::config::private_state_file(&path)?;
                let modified = source.metadata()?.modified().ok();
                let out = open_private_append(&tmp)?;
                let mut writer = std::io::BufWriter::with_capacity(256 * 1024, out);
                std::io::copy(&mut segment_file::decoder(source)?, &mut writer)?;
                let out = writer.into_inner().map_err(|e| e.into_error())?;
                if let Some(modified) = modified {
                    out.set_modified(modified)?;
                }
                out.sync_all().map_err(super::log_sync::SyncFailed)?;
                crate::home_fs::rename(&tmp, &plain)?;
                sync_directory(&events)?;
                crate::config::refuse_lost_home(&path)?;
                crate::home_fs::remove_file(&path)?;
                Ok(())
            })();
            if let Err(error) = written {
                let _ = crate::home_fs::remove_file(&tmp);
                return Err(error.context(format!("decompress {}", path.display())));
            }
            thawed = true;
        }
        if thawed {
            sync_directory(&events)?;
        }
        Ok(())
    }

    /// Removes the temporary files a compression or a thaw of chat `id` left: this process's
    /// from a pass that failed, and those of a process that is gone.
    fn remove_compress_leftovers(&self, id: &str) {
        let events = self.dir(id).join("events");
        let Ok(entries) = crate::home_fs::read_dir(&events) else { return };
        for entry in entries {
            let Some(name) = entry.name.to_str() else { continue };
            let Some(pid) = [TMP_MARK, THAW_MARK]
                .iter()
                .find_map(|mark| name.rsplit_once(mark))
                .and_then(|(_, pid)| pid.parse::<u32>().ok())
            else {
                continue;
            };
            if pid == std::process::id() || !process_alive(pid) {
                let _ = crate::home_fs::remove_file(events.join(&entry.name));
            }
        }
    }

    /// Compresses the plain segment at `plain`: its plain and compressed bytes, `(0, 0)` for an
    /// empty segment (left plain), or None when the log was written meanwhile (nothing changed).
    fn compress_segment(
        &self,
        id: &str,
        plain: &Path,
        wrap: &mut CommitWrap<'_>,
    ) -> Result<Option<(u64, u64)>> {
        let source = crate::config::private_state_file(plain)?;
        let before = source.metadata()?;
        let len = before.len();
        if len == 0 {
            return Ok(Some((0, 0)));
        }
        let name = plain.file_name().and_then(|n| n.to_str()).context("a segment's name")?;
        let tmp = plain.with_file_name(format!(".{name}{TMP_MARK}{}", std::process::id()));
        let _ = crate::home_fs::remove_file(&tmp);
        let written = (|| -> Result<u64> {
            let out = open_private_append(&tmp)?;
            let mut encoder = zstd::stream::write::Encoder::new(
                std::io::BufWriter::with_capacity(256 * 1024, out),
                LEVEL,
            )?;
            encoder.include_checksum(true)?;
            encoder.include_contentsize(true)?;
            encoder.long_distance_matching(true)?;
            encoder.window_log(WINDOW_LOG)?;
            encoder.set_pledged_src_size(Some(len))?;
            let copied = std::io::copy(&mut (&source).take(len), &mut encoder)?;
            anyhow::ensure!(copied == len, "{} is shorter than it was", plain.display());
            let out = encoder.finish()?.into_inner().map_err(|e| e.into_error())?;
            if let Ok(modified) = before.modified() {
                out.set_modified(modified)?;
            }
            out.sync_all().map_err(super::log_sync::SyncFailed)?;
            super::compact::drop_cache(&out);
            let after = out.metadata()?.len();
            drop(out);
            same_bytes(&tmp, &source, len)?;
            super::compact::drop_cache(&source);
            Ok(after)
        })();
        let after = match written {
            Ok(after) => after,
            Err(error) => {
                let _ = crate::home_fs::remove_file(&tmp);
                return Err(error.context(format!("compress {}", plain.display())));
            }
        };
        let zst = segment_file::zst_path(plain);
        let events = self.dir(id).join("events");
        let committed = wrap(&mut || -> Result<bool> {
            let _open = self.writable()?;
            let writers = self.writers.lock_or_recover();
            // A writer holds the log (the chat was used again), or the segment changed since it
            // was read: left as it is.
            if writers.open.contains_key(id) || !same_file(&before, plain) {
                return Ok(false);
            }
            #[cfg(test)]
            if crashes(id, CrashAt::BeforeRename) {
                anyhow::bail!("a crash before the rename (a test)");
            }
            crate::home_fs::rename(&tmp, &zst)?;
            sync_directory(&events)?;
            #[cfg(test)]
            if crashes(id, CrashAt::BeforeRemove) {
                anyhow::bail!("a crash before the plain segment's removal (a test)");
            }
            crate::config::refuse_lost_home(plain)?;
            crate::home_fs::remove_file(plain)?;
            sync_directory(&events)?;
            drop(writers);
            Ok(true)
        });
        match committed {
            Ok(true) => Ok(Some((len, after))),
            Ok(false) => {
                let _ = crate::home_fs::remove_file(&tmp);
                Ok(None)
            }
            Err(error) => {
                // The temporary file of a crash test is left as a crash leaves it.
                #[cfg(not(test))]
                let _ = crate::home_fs::remove_file(&tmp);
                Err(error.context(format!("put {} in place", zst.display())))
            }
        }
    }
}

/// Whether the file at `path` is still the one `before` describes: inode, length and time.
fn same_file(before: &std::fs::Metadata, path: &Path) -> bool {
    let Ok(now) = crate::home_fs::symlink_metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if (now.dev(), now.ino()) != (before.dev(), before.ino()) {
            return false;
        }
    }
    now.len() == before.len() && now.modified().ok() == before.modified().ok()
}

/// Checks that the compressed file at `zst` decodes to the first `len` bytes of `plain`,
/// streamed: a buffer of each at a time.
fn same_bytes(zst: &Path, plain: &File, len: u64) -> Result<()> {
    let mut decoded = segment_file::decoder(crate::config::private_state_file(zst)?)?;
    let mut original = plain.try_clone()?;
    std::io::Seek::seek(&mut original, std::io::SeekFrom::Start(0))?;
    let mut original = original.take(len);
    let (mut a, mut b) = (vec![0u8; 64 * 1024], vec![0u8; 64 * 1024]);
    let mut checked = 0u64;
    loop {
        let n = read_full(&mut original, &mut a)?;
        let m = read_full(&mut decoded, &mut b[..n.max(1)])?;
        anyhow::ensure!(n == m && a[..n] == b[..m], "the compressed segment differs at {checked}");
        if n == 0 {
            break;
        }
        checked += n as u64;
    }
    anyhow::ensure!(checked == len, "the compressed segment holds {checked} of {len} bytes");
    Ok(())
}

/// Reads until `out` is full or the reader ends.
fn read_full(reader: &mut dyn Read, out: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while let Some(rest) = out.get_mut(filled..).filter(|rest| !rest.is_empty()) {
        let n = reader.read(rest)?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

/// Whether process `pid` runs.
#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the process exists; nothing is sent.
    let gone = unsafe { libc::kill(pid, 0) } != 0
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
    !gone
}

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    true
}

/// Runs `job` on a thread of its own at the lowest CPU and IO priority (background QoS on
/// macOS), and waits for it: the priority cannot be raised back without privilege, so it never
/// lands on a pooled thread.
pub(crate) fn in_background<T: Send + 'static>(
    job: impl FnOnce() -> T + Send + 'static,
) -> std::io::Result<T> {
    let thread = std::thread::Builder::new().name("acpmux-log-zst".into()).spawn(move || {
        lower_thread_priority();
        job()
    })?;
    thread.join().map_err(|_| std::io::Error::other("the log compression thread panicked"))
}

/// Background QoS on macOS; lowest CPU and idle IO priority for this thread on Linux.
fn lower_thread_priority() {
    #[cfg(target_vendor = "apple")]
    // SAFETY: sets the calling thread's own QoS class; no pointers.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_BACKGROUND, 0);
    }
    #[cfg(target_os = "linux")]
    // SAFETY: plain syscalls on the calling thread's own id.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, 19);
        // ioprio_set(IOPRIO_WHO_PROCESS, tid, IOPRIO_CLASS_IDLE).
        libc::syscall(libc::SYS_ioprio_set, 1, tid, 3 << 13);
    }
}

#[cfg(test)]
#[path = "log_zst_tests.rs"]
mod tests;
