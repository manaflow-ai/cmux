//! The C ABI the app's stage-0 window calls (include/cmux_launch_shell.h): one disposition per
//! input event while it is up, whether each held one is replayed at the swap, and with no launch
//! record whether this is a first launch ever.
use std::ffi::{CStr, OsStr, c_char};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::{InputKind, PriorState, Reason, input_disposition};

/// The plan's reason for a launch with no launch record: 1 (`Reason::FreshInstall`, the bare
/// launch at the default frame) only when `session` has no registry folder in `state_dir` (NULL:
/// `CMUX_TUI_STATE_DIR`, else `~/Library/Application Support/cmux-tui/sessions`), no
/// `launch-times.jsonl` at `launch_times_path`, and `snapshot_path_recorded` is false; else 10
/// (`Reason::Upgrade`, no stage-0 window). A NULL or non-UTF-8 `session`, or a NULL
/// `launch_times_path`, is 10. Blocking (two stats, no listing): call it off the main
/// thread.
///
/// # Safety
/// Each pointer is NULL or a NUL-terminated string valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_shell_no_record_reason(
    session: *const c_char,
    state_dir: *const c_char,
    launch_times_path: *const c_char,
    snapshot_path_recorded: bool,
) -> u8 {
    // SAFETY: the caller passes NULL or a NUL-terminated string valid for the call.
    let text = |p: *const c_char| (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) });
    let path = |p| text(p).map(|s| Path::new(OsStr::from_bytes(s.to_bytes())));
    let prior = match (text(session).and_then(|s| s.to_str().ok()), path(launch_times_path)) {
        (Some(session), Some(launch_times)) => {
            PriorState::gather(session, path(state_dir), snapshot_path_recorded, launch_times)
        }
        _ => PriorState::UNKNOWN,
    };
    if prior.is_fresh() { Reason::FreshInstall as u8 } else { Reason::Upgrade as u8 }
}

/// What the stage-0 window does with an event of `kind` (`InputKind`) when `held` events are held:
/// 0 pass to AppKit, 1 hold, 2 hold and swap now.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_shell_input_disposition(kind: u8, held: usize) -> u8 {
    input_disposition(InputKind::from_u8(kind), held) as u8
}

/// Whether a held event of `kind` is replayed to the real window at the swap: keys always;
/// buttons, drags and scrolls only over the saved image (`showed_image`) when the real window drew
/// the same place (`mismatch` false).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_shell_replays(kind: u8, showed_image: bool, mismatch: bool) -> bool {
    crate::replays(InputKind::from_u8(kind), showed_image, mismatch)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::ptr::null;

    #[test]
    fn no_record_reason_is_fresh_only_on_evidence() {
        let dir =
            std::env::temp_dir().join(format!("cmux-launch-shell-ffi-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sessions")).unwrap();
        let c = |p: &Path| CString::new(p.as_os_str().as_bytes()).unwrap();
        let (sessions, times) = (c(&dir.join("sessions")), c(&dir.join("launch-times.jsonl")));
        let session = CString::new("cmux-app-a").unwrap();
        let reason = |session: *const c_char, times: *const c_char, recorded| unsafe {
            cmux_launch_shell_no_record_reason(session, sessions.as_ptr(), times, recorded)
        };
        assert_eq!(reason(session.as_ptr(), times.as_ptr(), false), 1);
        assert_eq!(reason(session.as_ptr(), times.as_ptr(), true), 10);
        assert_eq!(reason(null(), times.as_ptr(), false), 10);
        assert_eq!(reason(session.as_ptr(), null(), false), 10);
        std::fs::create_dir(
            dir.join("sessions").join(crate::prior::storage_component("cmux-app-a")),
        )
        .unwrap();
        assert_eq!(reason(session.as_ptr(), times.as_ptr(), false), 10);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
