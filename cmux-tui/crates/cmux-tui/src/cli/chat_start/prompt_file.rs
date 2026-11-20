use std::fs::OpenOptions;
use std::io::Read as _;
use std::os::unix::fs::OpenOptionsExt as _;

use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Instant;

use super::UsageError;

/// Even open/stat on a regular file can block on a network mount. The worker only reads input;
/// after a timeout it cannot create a session or deliver a prompt.
pub(super) fn read_by(path: String, deadline: Option<Instant>) -> Result<String, UsageError> {
    let Some(end) = deadline else { return read(&path) };
    let expired = || {
        UsageError::new(
            "--prompt-file did not finish within the launch deadline. No chat was started.",
        )
    };
    if Instant::now() >= end {
        return Err(expired());
    }
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("chat-prompt-file".into())
        .spawn(move || {
            let _ = tx.send(read(&path));
        })
        .map_err(|e| UsageError::new(format!("--prompt-file: cannot start reader: {e}")))?;
    rx.recv_timeout(end.saturating_duration_since(Instant::now())).map_err(|e| match e {
        RecvTimeoutError::Timeout => expired(),
        RecvTimeoutError::Disconnected => {
            UsageError::new("--prompt-file reader stopped. No chat was started.")
        }
    })?
}

pub(super) fn read(path: &str) -> Result<String, UsageError> {
    const LIMIT: u64 = 8 * 1024 * 1024;
    let failure = |error| UsageError::new(format!("--prompt-file {path:?}: {error}"));
    let file =
        OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(path).map_err(failure)?;
    if !file.metadata().map_err(failure)?.is_file() {
        return Err(UsageError::new("--prompt-file needs a regular UTF-8 file"));
    }
    let mut text = String::new();
    file.take(LIMIT + 1).read_to_string(&mut text).map_err(failure)?;
    if text.len() as u64 > LIMIT || text.trim().is_empty() {
        return Err(UsageError::new("--prompt-file must contain a prompt of at most 8 MiB"));
    }
    Ok(text)
}
