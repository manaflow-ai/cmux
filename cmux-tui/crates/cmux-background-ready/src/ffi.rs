//! The C ABI of the background ready copy's decisions, the owner of each one
//! (the rules and why they hold are in the crate root). Every argument and
//! answer is a uint8_t or a bool, and the one string argument is only read
//! during the call, so no memory crosses the boundary and nothing is freed.
//! An unknown value in is the safe answer out: Off for a mode, exit for a quit.

use std::ffi::{CStr, c_char};

use crate::{HiddenPlan, Mode, QuitOrigin};

/// Mode Off: the shipped default, a quit quits.
pub const CMUX_BACKGROUND_READY_MODE_OFF: u8 = 0;
/// Mode AfterQuit: a Cmd-Q hides the app.
pub const CMUX_BACKGROUND_READY_MODE_AFTER_QUIT: u8 = 1;
/// Mode AfterQuitAndLogin: as AfterQuit, and a hidden copy starts at login.
pub const CMUX_BACKGROUND_READY_MODE_AFTER_QUIT_AND_LOGIN: u8 = 2;

/// Quit origin: Cmd-Q, the app menu or the Dock.
pub const CMUX_BACKGROUND_READY_QUIT_INTERACTIVE: u8 = 0;
/// Quit origin: Quit Completely or Restart to Update.
pub const CMUX_BACKGROUND_READY_QUIT_EXPLICIT: u8 = 1;
/// Quit origin: the CLI or the control socket.
pub const CMUX_BACKGROUND_READY_QUIT_SCRIPTED: u8 = 2;
/// Quit origin: log out, restart or shut down.
pub const CMUX_BACKGROUND_READY_QUIT_POWER_OFF: u8 = 3;
/// Quit origin: a signal.
pub const CMUX_BACKGROUND_READY_QUIT_SIGNAL: u8 = 4;

/// cmux_background_ready_on_quit: exit the process.
pub const CMUX_BACKGROUND_READY_EXIT: u8 = 0;
/// cmux_background_ready_on_quit: stay running with no window.
pub const CMUX_BACKGROUND_READY_STAY_HIDDEN: u8 = 1;

/// Hidden plan: order the windows out, keep controllers and pages.
pub const CMUX_BACKGROUND_READY_PLAN_KEEP_WINDOWS: u8 = 0;
/// Hidden plan: close the windows as a user close; Chromium stays initialised.
pub const CMUX_BACKGROUND_READY_PLAN_CLOSE_WINDOWS: u8 = 1;
/// Hidden plan: no window built and no Chromium (the login-started copy).
pub const CMUX_BACKGROUND_READY_PLAN_NATIVE_ONLY: u8 = 2;

/// cmux_background_ready_at_launch: the ordinary launch.
pub const CMUX_BACKGROUND_READY_LAUNCH_NORMAL: u8 = 0;
/// cmux_background_ready_at_launch: start hidden, no window, no Chromium warm-up.
pub const CMUX_BACKGROUND_READY_LAUNCH_START_HIDDEN: u8 = 1;
/// cmux_background_ready_at_launch: a stale login registration; unregister and exit.
pub const CMUX_BACKGROUND_READY_LAUNCH_EXIT_AND_UNREGISTER: u8 = 2;

/// The bytes of a NUL-terminated string, or None for null.
///
/// # Safety
/// `utf8` is null or a NUL-terminated string readable for this call.
unsafe fn bytes<'a>(utf8: *const c_char) -> Option<&'a [u8]> {
    if utf8.is_null() {
        return None;
    }
    // SAFETY: non-null and NUL-terminated per the caller's contract.
    Some(unsafe { CStr::from_ptr(utf8) }.to_bytes())
}

/// The owner of parsing `app.backgroundReady`: "off", "afterQuit" or
/// "afterQuitAndLogin" give 0, 1 or 2; null or any other string gives 0 (Off),
/// so an unreadable setting never keeps a process the user did not ask for.
///
/// # Safety
/// `utf8` is null or a NUL-terminated string readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_background_ready_mode_parse(utf8: *const c_char) -> u8 {
    // SAFETY: the caller's contract.
    Mode::parse(unsafe { bytes(utf8) }) as u8
}

/// The owner of what a quit does: 1 stays hidden, 0 exits. It stays only when
/// the mode is on, the quit is a plain Cmd-Q, menu or Dock quit (origin 0), no
/// update installs on this quit (the installer needs the process gone) and the
/// user did not choose Quit Completely. Every other origin asks for this
/// process to end: Quit Completely and Restart to Update by name, a script
/// that quits expects it gone, the system cannot log out or shut down past an
/// app that stays, and a signal is the end. An unknown mode or origin exits.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_background_ready_on_quit(
    mode: u8,
    origin: u8,
    update_installs_on_quit: bool,
    quit_completely: bool,
) -> u8 {
    crate::on_quit(
        Mode::from_u8(mode),
        QuitOrigin::from_u8(origin),
        update_installs_on_quit,
        quit_completely,
    ) as u8
}

/// The owner of how the hidden copy holds its windows. A login-started copy
/// (started_at_login) has none, so it is 2 (NativeOnly) whatever else is
/// passed. Otherwise the measurement override from CMUX_NEXT_BACKGROUND_READY_PLAN
/// (Swift reads the environment and passes it, or null): "keep" gives 0,
/// "close" gives 1, so one build can measure both. With no override it is 0
/// (KeepWindows): showing is ordering the windows in, with no page to rebuild.
/// CloseWindows keeps Chromium initialised but idle, since CEF cannot
/// initialise twice in one process.
///
/// # Safety
/// `override_or_null` is null or a NUL-terminated string readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_background_ready_hidden_plan(
    mode: u8,
    started_at_login: bool,
    override_or_null: *const c_char,
) -> u8 {
    // SAFETY: the caller's contract.
    let plan_override = crate::parse_plan_override(unsafe { bytes(override_or_null) });
    crate::hidden_plan(Mode::from_u8(mode), started_at_login, plan_override) as u8
}

/// The owner of the login item: registered only for mode 2
/// (AfterQuitAndLogin), the one mode that starts a copy at login; every other
/// mode unregisters it, so lowering the setting removes the item.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_background_ready_registers_login_item(mode: u8) -> bool {
    crate::registers_login_item(Mode::from_u8(mode))
}

/// The owner of what a launch does. A launch the user made is 0 (Normal)
/// whatever the mode: the setting changes quits and logins, never an open. A
/// login launch with mode 2 is 1 (start hidden: no window and no Chromium
/// warm-up, so login pays for the native process only). A login launch with
/// any other mode is 2: the registration is stale (the setting changed while
/// the app was not running to unregister it), so unregister and exit at once.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_background_ready_at_launch(mode: u8, launched_as_login_item: bool) -> u8 {
    crate::at_launch(Mode::from_u8(mode), launched_as_login_item) as u8
}

/// The owner of the update exit: true when the copy is hidden and an update
/// is staged, so the hidden process quits, the installer runs and the next
/// open is the new version (a hidden copy would keep the old one running
/// indefinitely). A shown copy waits for the user's own quit, as before.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_background_ready_exits_for_update(
    mode: u8,
    hidden: bool,
    update_staged: bool,
) -> bool {
    crate::exits_for_update(Mode::from_u8(mode), hidden, update_staged)
}

/// The owner of the Chromium warm-up: false only for plan 2 (NativeOnly, the
/// login-started copy) not yet shown, so login pays for no browser; it warms
/// up when first shown. Every other plan already has Chromium initialised,
/// and a shown copy needs it, so true.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_background_ready_starts_chromium_warmup(plan: u8, shown: bool) -> bool {
    crate::starts_chromium_warmup(HiddenPlan::from_u8(plan), shown)
}
