//! C ABI of recording as you go (`cmux_rd_session_record_*`, ABI 7): the
//! session copies every frame of stream 0 it hands out into a fragmented
//! MP4 (`record.rs`). The one file this crate writes is the one the app
//! names here.

use std::ffi::{CStr, c_char};
use std::fs::{self, File};
use std::path::Path;

use crate::record::Recorder;
use crate::session_ffi::{CmuxRdSession, with_session};
use crate::{CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_OK};

/// The recording file could not be created or written (`CMUX_RD_ERR_IO`).
pub const CMUX_RD_ERR_IO: i32 = -11;

/// Starts recording stream 0 into a new file at `path` (UTF-8, NUL
/// terminated; missing folders are created, an existing file is replaced)
/// and asks the host for a keyframe, where the file begins. A recording
/// already running is finished first. `CMUX_RD_ERR_INVALID` for a path that
/// is not UTF-8 or empty, `CMUX_RD_ERR_IO` when the file cannot be created.
///
/// # Safety
/// `session` is valid; `path` is NULL or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_record_start(
    session: *mut CmuxRdSession,
    path: *const c_char,
) -> i32 {
    if path.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: non-NULL and NUL-terminated by this function's contract.
    let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str() else { return CMUX_RD_ERR_INVALID };
    if path.is_empty() {
        return CMUX_RD_ERR_INVALID;
    }
    let path = Path::new(path).to_owned();
    let run = |h: &mut CmuxRdSession| {
        if let Some(old) = h.recorder.take() {
            let _ = old.finish();
        }
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty())
            && fs::create_dir_all(parent).is_err()
        {
            return CMUX_RD_ERR_IO;
        }
        let Ok(file) = File::create(&path) else { return CMUX_RD_ERR_IO };
        h.recorder = Some(Recorder::new(file));
        let _ = h.inner.request_keyframe(0);
        CMUX_RD_OK
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Finishes the recording: writes the newest frame and closes the file.
/// Returns the frames in the file (0 when no keyframe arrived, or when no
/// recording was running), or `CMUX_RD_ERR_IO` when a write failed.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_record_stop(session: *mut CmuxRdSession) -> i32 {
    let run = |h: &mut CmuxRdSession| match h.recorder.take().map(Recorder::finish) {
        None => 0,
        Some(Ok((frames, _))) => i32::try_from(frames).unwrap_or(i32::MAX),
        Some(Err(_)) => CMUX_RD_ERR_IO,
    };
    // SAFETY: as in `cmux_rd_session_record_start`.
    unsafe { with_session(session, run) }
}
