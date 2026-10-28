//! Interactive input to a PTY child: written as is, except mouse wheel and
//! motion reports that would not fit in the child's input queue whole.
//!
//! A program that stops reading while the wheel turns (Codex redrawing its
//! transcript) lets the reports pile up. On macOS the PTY input queue holds
//! 1022 bytes; once it is full the kernel takes what fits and cuts the next
//! report in the middle, and the program reads a short chunk. crossterm
//! takes an ESC at the end of a short chunk for the Esc key, so the rest of
//! that report (`[<65;27;20M`) is typed into the prompt
//! (https://github.com/manaflow-ai/cmux/issues/22265). Wheel and motion
//! reports are only ever written whole, while the queue keeps room for keys:
//! one that would not fit is dropped, as a terminal coalesces the wheel.

use std::io::{self, Write};
#[cfg(unix)]
use std::os::fd::RawFd;

use cmux_pty::MasterPty;

/// Writes `payload` to the PTY child of `master` through `writer`, unless
/// [`admits`] drops it. Returns false when the payload was dropped.
pub(crate) fn write_input(
    master: Option<&dyn MasterPty>,
    writer: &mut dyn Write,
    payload: &[u8],
) -> io::Result<bool> {
    if let Some(master) = master
        && !admits(master, payload)
    {
        return Ok(false);
    }
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(true)
}

/// [`write_input`] for a terminal whose input the `pty-writer` writes
/// (`crate::pty_write`): queued in the key lane, never waiting for the
/// child. A wheel or motion report is also dropped while earlier input still
/// waits in the queue: the child is not reading, and the report would only
/// grow the backlog a terminal coalesces.
#[cfg(unix)]
pub(crate) fn queue_input(
    master: Option<&dyn MasterPty>,
    queue: &crate::pty_write::PtyInputQueue,
    payload: &[u8],
) -> io::Result<bool> {
    if is_lossy_mouse_input(payload) && queue.pending() > 0 {
        return Ok(false);
    }
    if let Some(master) = master
        && !admits(master, payload)
    {
        return Ok(false);
    }
    queue.send(payload, crate::pty_write::InputLane::Key)?;
    Ok(true)
}

/// Whether `payload` goes to the PTY child of `master` now: any input but
/// wheel and motion reports, and those only while the child's input queue
/// has room for all of them. Never blocks.
pub(crate) fn admits(master: &dyn MasterPty, payload: &[u8]) -> bool {
    #[cfg(unix)]
    let master_fd = master.as_raw_fd();
    #[cfg(not(unix))]
    let master_fd = {
        let _ = master;
        None
    };
    admits_fd(master_fd, payload)
}

#[cfg(unix)]
type MasterFd = RawFd;
#[cfg(not(unix))]
type MasterFd = ();

fn admits_fd(master_fd: Option<MasterFd>, payload: &[u8]) -> bool {
    !is_lossy_mouse_input(payload) || lossy_input_fits(master_fd, payload.len())
}

/// [`write_input`] for the PTY master `master_fd`.
#[cfg(all(test, target_os = "macos"))]
pub(crate) fn write_input_fd(
    master_fd: Option<RawFd>,
    writer: &mut dyn Write,
    payload: &[u8],
) -> io::Result<bool> {
    if !admits_fd(master_fd, payload) {
        return Ok(false);
    }
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(true)
}

/// The macOS PTY input queue: TTYHOG (1024) less the two bytes the tty
/// keeps free.
#[cfg(target_os = "macos")]
const INPUT_QUEUE_BYTES: usize = 1022;

/// What wheel and motion reports leave free in the input queue, so a key,
/// a click or a paste typed behind them still goes in whole.
#[cfg(target_os = "macos")]
const KEY_ROOM_BYTES: usize = 128;

/// Whether `len` more bytes of wheel or motion reports fit in the child's
/// input queue, keeping [`KEY_ROOM_BYTES`] free. On macOS `FIONREAD` on the
/// master counts the bytes the child has not read yet. A child in canonical
/// mode is counted by its finished lines only, so cooked input is not capped;
/// programs that ask for mouse reports read raw.
#[cfg(target_os = "macos")]
fn lossy_input_fits(master_fd: Option<MasterFd>, len: usize) -> bool {
    let Some(fd) = master_fd else {
        return true;
    };
    let mut pending: libc::c_int = 0;
    // SAFETY: `fd` is the master the caller's `MasterPty` keeps open for this
    // call; FIONREAD writes one c_int into the exclusively borrowed `pending`.
    if unsafe { libc::ioctl(fd, libc::FIONREAD, &mut pending) } != 0 {
        return true;
    }
    usize::try_from(pending).unwrap_or(0) + len <= INPUT_QUEUE_BYTES - KEY_ROOM_BYTES
}

/// Elsewhere every report is written as before: the cut has not been seen
/// or reproduced off macOS, whose queue is the smallest.
#[cfg(not(target_os = "macos"))]
fn lossy_input_fits(_master_fd: Option<MasterFd>, _len: usize) -> bool {
    true
}

/// Whether `payload` is nothing but mouse wheel and motion reports, in the
/// SGR (and SGR pixel), URXVT or X10 encoding.
pub(crate) fn is_lossy_mouse_input(payload: &[u8]) -> bool {
    let mut rest = payload;
    while !rest.is_empty() {
        let Some((button, len)) = mouse_report(rest) else {
            return false;
        };
        if !is_lossy_button(button) {
            return false;
        }
        // A report is never empty; a zero or out-of-range length would
        // loop forever or overrun, so it ends the scan.
        match rest.get(len..) {
            Some(next) if len > 0 => rest = next,
            _ => return false,
        }
    }
    !payload.is_empty()
}

/// The mouse report at the start of `bytes`: its button code and length.
fn mouse_report(bytes: &[u8]) -> Option<(u32, usize)> {
    let body = bytes.strip_prefix(b"\x1b[")?;
    // SGR: CSI < code ; x ; y M (press) or m (release).
    if let Some(sgr) = body.strip_prefix(b"<") {
        let ([code, _, _], end) = numeric_fields(sgr, b"Mm")?;
        return Some((code, 3 + end + 1));
    }
    // X10: CSI M and the code, x and y, each plus 32, as single bytes.
    if let Some(x10) = body.strip_prefix(b"M") {
        let code = *x10.get(..3)?.first()?;
        return Some((u32::from(code).checked_sub(32)?, 6));
    }
    // URXVT: CSI code ; x ; y M, the code plus 32.
    let ([code, _, _], end) = numeric_fields(body, b"M")?;
    Some((code.checked_sub(32)?, 2 + end + 1))
}

/// Three `;`-separated decimal fields ending in one of `finals`: the fields
/// and the final byte's index.
fn numeric_fields(bytes: &[u8], finals: &[u8]) -> Option<([u32; 3], usize)> {
    let end = bytes.iter().position(|byte| !(byte.is_ascii_digit() || *byte == b';'))?;
    if !finals.contains(bytes.get(end)?) {
        return None;
    }
    let mut fields = [0; 3];
    let mut parts = bytes.get(..end)?.split(|byte| *byte == b';');
    for field in &mut fields {
        let part = parts.next().filter(|part| (1..=5).contains(&part.len()))?;
        *field = std::str::from_utf8(part).ok()?.parse().ok()?;
    }
    parts.next().is_none().then_some((fields, end))
}

/// Wheel (buttons 4 to 7, bit 64) and motion (bit 32) codes, with any
/// modifier; never buttons 8 to 11 (bit 128), whose presses must arrive.
fn is_lossy_button(code: u32) -> bool {
    code & 128 == 0 && code & (64 | 32) != 0
}

#[cfg(test)]
#[path = "pty_input_room_tests.rs"]
mod tests;
