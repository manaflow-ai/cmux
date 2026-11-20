use std::fs::OpenOptions;
use std::io::Read as _;
use std::os::unix::fs::OpenOptionsExt as _;

use super::UsageError;

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
