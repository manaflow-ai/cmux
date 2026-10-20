//! Interactive input to a PTY child: written as is, except mouse wheel and
//! motion reports that would not fit in the child's input queue whole.

// Windows writes every input; only the tests read the report parser there.
#![cfg_attr(not(unix), allow(dead_code))]

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
    {
        write_input_fd(master.and_then(|master| master.as_raw_fd()), writer, payload)
    }
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
    if is_lossy_mouse_input(payload) && !lossy_input_fits(master_fd, payload.len()) {
        return Ok(false);
    }
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(true)
}

/// Whether `len` more bytes of wheel or motion reports fit in the child's
/// input queue.
#[cfg(unix)]
fn lossy_input_fits(master_fd: Option<RawFd>, len: usize) -> bool {
    let _ = (master_fd, len);
    true
}

/// Whether `payload` is nothing but mouse wheel and motion reports.
pub(crate) fn is_lossy_mouse_input(payload: &[u8]) -> bool {
    let _ = payload;
    false
}

#[cfg(test)]
#[path = "pty_input_room_tests.rs"]
mod tests;
