//! Interactive input to a PTY child: written as is, except mouse wheel and
//! motion reports that would not fit in the child's input queue whole.

use std::io::{self, Write};
#[cfg(unix)]
use std::os::fd::RawFd;

use cmux_pty::MasterPty;

/// Writes `payload` to the PTY child of `master` through `writer`. Returns
/// false when the payload was dropped instead.
pub(crate) fn write_input(
    master: Option<&dyn MasterPty>,
    writer: &mut dyn Write,
    payload: &[u8],
) -> io::Result<bool> {
    #[cfg(unix)]
    return write_input_fd(master.and_then(|master| master.as_raw_fd()), writer, payload);
    #[cfg(not(unix))]
    {
        let _ = master;
        writer.write_all(payload)?;
        writer.flush()?;
        Ok(true)
    }
}

/// [`write_input`] for the PTY master `master_fd`.
#[cfg(unix)]
pub(crate) fn write_input_fd(
    master_fd: Option<RawFd>,
    writer: &mut dyn Write,
    payload: &[u8],
) -> io::Result<bool> {
    let _ = master_fd;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(true)
}

/// Whether `payload` is nothing but mouse wheel and motion reports.
pub(crate) fn is_lossy_mouse_input(payload: &[u8]) -> bool {
    let _ = payload;
    false
}

#[cfg(test)]
#[path = "pty_input_room_tests.rs"]
mod tests;
