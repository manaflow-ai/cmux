//! Discovery records this build cannot adopt (R41, plans/cmux-next/durable-sessions.md
//! section 7): their hosts may still run their shells, so the terminal stays
//! visible, is watched until its host proves it ended, and is ended only with
//! proof that the recorded PID is its host.

use super::*;

/// A discovery record this build cannot adopt: it does not decode or does
/// not validate, for example a newer `record_version` left by a host of a
/// later build after a rollback. Its host may still run its shell, so the
/// terminal must stay visible instead of being reported ended (R41).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnadoptableTerminalHostRecord {
    pub terminal_id: String,
    pub record_path: PathBuf,
    /// `record_version` when the file is JSON with that field.
    pub record_version: Option<u64>,
    /// `host_pid` when the file is JSON with that field.
    pub host_pid: Option<u32>,
    /// `incarnation` and `host_start_nonce` when both are canonical
    /// lowercase hex: they name the host's live marker, the only proof
    /// this build accepts that `host_pid` is that host.
    pub marker: Option<PathBuf>,
    pub reason: String,
}

/// Every `<terminal id>.json` record under `root` that
/// [`load_terminal_host_records`] skips because it cannot be read,
/// decoded or validated.
pub fn load_unadoptable_terminal_host_records(
    root: &Path,
) -> anyhow::Result<Vec<UnadoptableTerminalHostRecord>> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut records = Vec::new();
    for entry in entries {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Some(terminal_id) = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .filter(|stem| TerminalId::from_hex(stem).is_some())
            .map(str::to_owned)
        else {
            continue;
        };
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                records.push(UnadoptableTerminalHostRecord {
                    terminal_id,
                    record_path: path,
                    record_version: None,
                    host_pid: None,
                    marker: None,
                    reason: format!("unreadable: {error}"),
                });
                continue;
            }
        };
        let reason = match serde_json::from_slice::<TerminalHostRecord>(&bytes) {
            Ok(record) => match validate_terminal_host_record(&path, &record) {
                Ok(_) => continue,
                Err(error) => format!("invalid: {error:#}"),
            },
            Err(error) => format!("undecodable: {error}"),
        };
        let loose = serde_json::from_slice::<serde_json::Value>(&bytes).ok();
        let number = |name: &str| loose.as_ref().and_then(|value| value.get(name)?.as_u64());
        let hex = |name: &str| {
            loose
                .as_ref()
                .and_then(|value| value.get(name)?.as_str())
                .filter(|text| {
                    !text.is_empty()
                        && text.len() <= 128
                        && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
                .map(str::to_owned)
        };
        let marker = hex("incarnation")
            .zip(hex("host_start_nonce"))
            .map(|(incarnation, nonce)| path.with_extension(format!("{incarnation}-{nonce}.live")));
        records.push(UnadoptableTerminalHostRecord {
            terminal_id,
            record_path: path,
            record_version: number("record_version"),
            host_pid: number("host_pid").and_then(|pid| u32::try_from(pid).ok()),
            marker,
            reason,
        });
    }
    records.sort_by(|left, right| left.record_path.cmp(&right.record_path));
    Ok(records)
}

/// Open an unadoptable host's live marker when a live process holds it.
fn held_unadoptable_marker(record: &UnadoptableTerminalHostRecord) -> Option<File> {
    let marker = record.marker.as_ref()?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(marker)
        .ok()?;
    // SAFETY: flock only probes the advisory lock of this owned fd.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        // SAFETY: same descriptor; release the probe lock at once.
        let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        return None;
    }
    Some(file)
}

/// Block until an unadoptable host exits, then remove its record, marker
/// and socket. Death needs proof: the exact marker's lock was held and is
/// now acquired, or the marker is gone and `host_pid` no longer exists.
/// Without proof (no marker name, an unreadable marker) this returns an
/// error at once and removes nothing: the terminal stays pending. Runs on
/// a watcher thread: the lock is the death proof, not a delay.
pub fn wait_for_unadoptable_terminal_host_exit(
    record: &UnadoptableTerminalHostRecord,
) -> anyhow::Result<()> {
    let marker = record
        .marker
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("record names no live marker; host state unknown"))?;
    match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(marker)
    {
        Ok(file) => loop {
            // SAFETY: a blocking exclusive lock on an owned descriptor.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error.into());
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let gone = record.host_pid.is_some_and(process_definitely_absent);
            anyhow::ensure!(
                gone,
                "live marker missing and host {:?} not proven gone",
                record.host_pid
            );
        }
        Err(error) => return Err(error.into()),
    }
    let Some(parent) = record.record_path.parent() else { return Ok(()) };
    let endpoint = PathBuf::from("/tmp")
        .join(format!("cmux-th-{}", fs::metadata(parent)?.uid()))
        .join(format!("{}.sock", record.terminal_id));
    let _ = fs::remove_file(&record.record_path);
    let _ = fs::remove_file(marker);
    if fs::symlink_metadata(&endpoint).is_ok_and(|metadata| metadata.file_type().is_socket()) {
        let _ = fs::remove_file(endpoint);
    }
    Ok(())
}

/// Signal an unadoptable host to end without speaking its protocol.
/// Signals only with proof that `host_pid` is this terminal's live host:
/// the exact marker its record names (`<id>.<incarnation>-<nonce>.live`)
/// is held, and the PID exists. Returns whether a signal was sent; the
/// host's exit is observed by [`wait_for_unadoptable_terminal_host_exit`].
pub fn terminate_unadoptable_terminal_host(
    record: &UnadoptableTerminalHostRecord,
) -> anyhow::Result<bool> {
    let (Some(_held), Some(pid)) = (held_unadoptable_marker(record), record.host_pid) else {
        return Ok(false);
    };
    let pid = libc::pid_t::try_from(pid)?;
    // SAFETY: the host is a session leader (`setsid` at spawn), so its
    // process group is its PID, and its held marker proves it runs.
    if unsafe { libc::killpg(pid, libc::SIGKILL) } != 0 {
        return Ok(false);
    }
    Ok(true)
}

/// Positive proof that no process has `pid` (ESRCH). Permission errors and
/// live processes are not proof.
pub(super) fn process_definitely_absent(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
    // SAFETY: signal zero performs a liveness/permission probe and does not
    // deliver a signal to the target process.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return false;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}
