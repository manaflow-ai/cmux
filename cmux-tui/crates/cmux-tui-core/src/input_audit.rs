//! Byte-accounting audit sink for the host-input -> child-pty pipeline.
//!
//! Diagnostic instrumentation for
//! https://github.com/manaflow-ai/cmux/issues/10431: when the environment
//! variable `CMUX_TUI_INPUT_AUDIT` names a file, each tap appends one line so
//! a harness can compare, byte for byte, what crossterm delivered (`t1`),
//! what the app enqueued toward a surface (`t2`), what the PTY input worker
//! actually wrote to the child PTY (`t3`), and rare lifecycle notes.
//!
//! No caller ever blocks on the filesystem: every tap enqueues onto a channel
//! bounded by entries and by bytes, and one dedicated writer thread owns
//! opening the file and all I/O, so a slow filesystem or a FIFO cannot stall
//! the pipeline it is observing. Only the writer thread publishes the enabled
//! state, and only after its open succeeded; a failed open disables the audit
//! and reports once through the reporter installed with
//! [`set_error_reporter`]. The audit target must be a freshly creatable or
//! existing REGULAR file: it is opened non-blocking, created `0600`, and an
//! existing file with group/other permission bits is refused, because the
//! taps capture raw keystrokes. Raw payload capture also requires the separate
//! `CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE=1` opt-in, so a global audit path
//! cannot silently persist passwords or tokens. When the queue is full the event is dropped
//! and counted; the writer notes the drop count in the file
//! (`audit-dropped`). When the byte budget is exceeded a line first loses
//! its payload (recorded as `payload-bytes=N` in the detail) and is dropped
//! entirely only if even that does not fit. The environment variable is read
//! once at the first tap; when it is unset every later call is a single
//! relaxed atomic load. Lines still queued at process exit may be lost.

use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};

const QUEUE_CAPACITY: usize = 8_192;
const QUEUE_BYTE_BUDGET: usize = 8 * 1024 * 1024;
/// Per-line accounting overhead: timestamp, tag, separators, allocator slop.
const LINE_OVERHEAD: usize = 64;

const STATE_UNKNOWN: u8 = 0;
const STATE_DISABLED: u8 = 1;
const STATE_ENABLED: u8 = 2;
const STATE_STARTING: u8 = 3;
const SENSITIVE_AUDIT_OPT_IN: &str = "CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE";

static STATE: AtomicU8 = AtomicU8::new(STATE_UNKNOWN);
static SENDER: OnceLock<SyncSender<AuditLine>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);
static QUEUED_BYTES: AtomicUsize = AtomicUsize::new(0);
static ERROR_REPORTER: OnceLock<fn(&str)> = OnceLock::new();

struct AuditLine {
    micros: u128,
    tag: &'static str,
    detail: String,
    bytes: Vec<u8>,
    cost: usize,
}

/// Install the reporter used for the single "audit disabled" error (the
/// refused target itself cannot carry it). First installation wins.
pub fn set_error_reporter(reporter: fn(&str)) {
    let _ = ERROR_REPORTER.set(reporter);
}

fn report_error(message: &str) {
    if let Some(reporter) = ERROR_REPORTER.get() {
        reporter(message);
    }
}

fn sender() -> Option<&'static SyncSender<AuditLine>> {
    match STATE.load(Ordering::Acquire) {
        STATE_DISABLED => return None,
        STATE_ENABLED | STATE_STARTING => return sender_or_count_drop(),
        _ => {}
    }
    if STATE
        .compare_exchange(STATE_UNKNOWN, STATE_STARTING, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        // Another thread owns initialization; re-check its published state.
        return match STATE.load(Ordering::Acquire) {
            STATE_DISABLED => None,
            _ => sender_or_count_drop(),
        };
    }
    let path = match std::env::var_os("CMUX_TUI_INPUT_AUDIT") {
        Some(path) if !path.is_empty() => path,
        _ => {
            STATE.store(STATE_DISABLED, Ordering::Release);
            return None;
        }
    };
    if !sensitive_capture_enabled() {
        STATE.store(STATE_DISABLED, Ordering::Release);
        report_error(&format!(
            "input audit disabled: raw payload capture requires {SENSITIVE_AUDIT_OPT_IN}=1"
        ));
        return None;
    }
    let (line_sender, line_receiver) = sync_channel::<AuditLine>(QUEUE_CAPACITY);
    let sender = SENDER.get_or_init(|| line_sender);
    // Only the writer thread transitions STARTING -> ENABLED (after a
    // successful open) or STARTING -> DISABLED (after a refused target), so
    // an early failure can never be overwritten by this spawner.
    if std::thread::Builder::new()
        .name("input-audit".into())
        .spawn(move || writer(path, line_receiver))
        .is_err()
    {
        STATE.store(STATE_DISABLED, Ordering::Release);
        return None;
    }
    Some(sender)
}

/// The sender for taps racing initialization. A tap that arrives before the
/// initializer stored the channel is dropped and counted.
fn sender_or_count_drop() -> Option<&'static SyncSender<AuditLine>> {
    let sender = SENDER.get();
    if sender.is_none() {
        DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    sender
}

fn sensitive_capture_enabled() -> bool {
    sensitive_capture_enabled_value(std::env::var_os(SENSITIVE_AUDIT_OPT_IN).as_deref())
}

fn sensitive_capture_enabled_value(value: Option<&OsStr>) -> bool {
    value == Some(OsStr::new("1"))
}

/// Open the audit target without ever blocking (a writer-less FIFO blocks
/// `open(2)` forever) and refuse anything that is not a private regular
/// file: create with mode `0600`, and reject an existing file readable by
/// group or other, because audit lines carry raw keystrokes.
fn open_audit_file(path: &OsStr) -> Result<File, &'static str> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK).mode(0o600);
    }
    let file = options.open(path).map_err(|_| "target is not openable")?;
    let metadata = file.metadata().map_err(|_| "target metadata is unreadable")?;
    if !metadata.is_file() {
        return Err("target is not a regular file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err("target is not owned by the current user");
        }
        if metadata.permissions().mode() & 0o7777 != 0o600 {
            return Err("target must have private mode 0600");
        }
        if metadata.nlink() != 1 {
            return Err("target must not have hard links");
        }
    }
    Ok(file)
}

fn writer(path: OsString, lines: Receiver<AuditLine>) {
    let mut file = match open_audit_file(&path) {
        Ok(file) => file,
        Err(reason) => {
            STATE.store(STATE_DISABLED, Ordering::Release);
            report_error(&format!("input audit disabled: CMUX_TUI_INPUT_AUDIT {reason}"));
            return;
        }
    };
    STATE.store(STATE_ENABLED, Ordering::Release);
    while let Ok(line) = lines.recv() {
        QUEUED_BYTES.fetch_sub(line.cost, Ordering::Relaxed);
        let dropped = DROPPED.swap(0, Ordering::Relaxed);
        if dropped > 0 {
            let _ = writeln!(file, "{} audit-dropped {dropped} -", line.micros);
        }
        let mut rendered = String::with_capacity(64 + line.detail.len() + line.bytes.len() * 2);
        use std::fmt::Write as _;
        let _ = write!(rendered, "{} {} {} ", line.micros, line.tag, line.detail);
        for byte in &line.bytes {
            let _ = write!(rendered, "{byte:02x}");
        }
        rendered.push('\n');
        let _ = file.write_all(rendered.as_bytes());
        let _ = file.flush();
    }
}

pub fn enabled() -> bool {
    sender().is_some()
}

fn timestamp_micros() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_micros())
        .unwrap_or(0)
}

/// Reserve `cost` bytes of queue budget. Returns false when over budget.
fn reserve_budget(cost: usize) -> bool {
    let queued = QUEUED_BYTES.fetch_add(cost, Ordering::Relaxed);
    if queued.saturating_add(cost) > QUEUE_BYTE_BUDGET {
        QUEUED_BYTES.fetch_sub(cost, Ordering::Relaxed);
        return false;
    }
    true
}

/// Enqueue `tag detail hex(bytes)` with a wall-clock microsecond timestamp.
/// Never blocks and never touches the filesystem; a full queue or an
/// exhausted byte budget drops the payload or the line, counted in the file.
pub fn record(tag: &'static str, detail: &str, bytes: &[u8]) {
    let Some(sender) = sender() else { return };
    let mut detail = detail.to_string();
    let mut payload = bytes;
    let mut cost = LINE_OVERHEAD + detail.len() + payload.len();
    if !reserve_budget(cost) {
        if payload.is_empty() {
            DROPPED.fetch_add(1, Ordering::Relaxed);
            return;
        }
        // Keep the accounting-relevant fact (how many bytes moved) and shed
        // the payload itself.
        use std::fmt::Write as _;
        let _ = write!(detail, " payload-bytes={}", payload.len());
        payload = &[];
        cost = LINE_OVERHEAD + detail.len();
        if !reserve_budget(cost) {
            DROPPED.fetch_add(1, Ordering::Relaxed);
            return;
        }
    }
    let line = AuditLine { micros: timestamp_micros(), tag, detail, bytes: payload.to_vec(), cost };
    match sender.try_send(line) {
        Ok(()) => {}
        Err(TrySendError::Full(line)) | Err(TrySendError::Disconnected(line)) => {
            QUEUED_BYTES.fetch_sub(line.cost, Ordering::Relaxed);
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Enqueue a bytes-free note (event names, enqueue failures, drop sites).
pub fn note(tag: &'static str, detail: &str) {
    record(tag, detail, &[]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_capture_requires_an_explicit_exact_opt_in() {
        assert!(!sensitive_capture_enabled_value(None));
        assert!(!sensitive_capture_enabled_value(Some(OsStr::new("true"))));
        assert!(!sensitive_capture_enabled_value(Some(OsStr::new("1 "))));
        assert!(sensitive_capture_enabled_value(Some(OsStr::new("1"))));
    }

    #[cfg(unix)]
    #[test]
    fn audit_file_rejects_symlinks_and_non_private_modes() {
        use std::os::unix::fs::PermissionsExt as _;

        let root = std::env::temp_dir().join(format!(
            "cmux-input-audit-file-{}-{}",
            std::process::id(),
            timestamp_micros()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let target = root.join("audit.log");
        std::fs::write(&target, b"").unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(open_audit_file(target.as_os_str()).is_ok());

        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o640)).unwrap();
        assert!(open_audit_file(target.as_os_str()).is_err());

        let link = root.join("audit-link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(open_audit_file(link.as_os_str()).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
