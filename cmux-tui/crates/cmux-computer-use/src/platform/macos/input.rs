//! Synthetic input as CGEvents. Background delivery posts to the target
//! process (`CGEventPostToPid`), so the window gets the event without
//! activation and the person's pointer never moves. A scroll posted to a
//! process reaches one of its windows only when it names the window (field
//! 51, the window number AppKit reads) and carries its location inside that
//! window (`CGEventSetWindowLocation`): with only the window-under-pointer
//! fields (91, 92) AppKit and WebKit drop it (macOS 26.6: TextEdit, Safari,
//! Finder and System Settings scrolled once both were set).
//!
//! Mouse buttons are not addressed that way on purpose. A press that lands
//! in an AppKit window of a background app makes the app order that window
//! front (TextEdit, Notes: the focus guard saw the window above the
//! person's and lowered it again), so a press is posted with the
//! window-under-pointer fields only, as before. Clicks on controls and list
//! rows go through accessibility instead (`actions::ax_click_at`), which
//! raises nothing. Foreground delivery posts at the HID tap, except key
//! chords while an app is denied, which go to the raised target's process
//! (so no other app's global hotkey fires).
//!
//! Events come from a private event source, so the person's held modifier
//! keys never leak into an agent's event (and the reverse).

use super::keymap;
use super::roles;
use super::sys::*;
use crate::desktop::{Button, DResult, DesktopError, Point};

const SOURCE_PRIVATE: i32 = -1;
const HID_TAP: u32 = 0;

const MOUSE_MOVED: u32 = 5;
const LEFT_DOWN: u32 = 1;
const LEFT_UP: u32 = 2;
const RIGHT_DOWN: u32 = 3;
const RIGHT_UP: u32 = 4;
const LEFT_DRAGGED: u32 = 6;
const RIGHT_DRAGGED: u32 = 7;
const OTHER_DOWN: u32 = 25;
const OTHER_UP: u32 = 26;
const OTHER_DRAGGED: u32 = 27;

const FIELD_CLICK_STATE: u32 = 1;
const FIELD_BUTTON_NUMBER: u32 = 3;
const FIELD_WINDOW_NUMBER: u32 = 51;
const FIELD_WINDOW_UNDER_POINTER: u32 = 91;
const FIELD_WINDOW_THAT_CAN_HANDLE: u32 = 92;

const SCROLL_UNIT_LINE: u32 = 1;

/// Between a pid-routed mouse-down and its up.
const PRESS_GAP: std::time::Duration = std::time::Duration::from_millis(15);
/// Between the steps of a pid-routed drag.
const DRAG_STEP: std::time::Duration = std::time::Duration::from_millis(8);

/// Where an event goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// To one process, aimed at one window (CGWindowID).
    Pid { pid: i32, window: u32 },
    /// System-wide, at the HID tap (moves the real pointer).
    Hid,
}

impl Route {
    pub fn name(&self) -> &'static str {
        match self {
            Route::Pid { .. } => "pid_event",
            Route::Hid => "hid_event",
        }
    }
}

/// The mouse event types of a button: (down, up, dragged).
pub fn button_events(button: Button) -> (u32, u32, u32) {
    match button {
        Button::Left => (LEFT_DOWN, LEFT_UP, LEFT_DRAGGED),
        Button::Right => (RIGHT_DOWN, RIGHT_UP, RIGHT_DRAGGED),
        Button::Middle => (OTHER_DOWN, OTHER_UP, OTHER_DRAGGED),
    }
}

pub fn button_number(button: Button) -> u32 {
    match button {
        Button::Left => 0,
        Button::Right => 1,
        Button::Middle => 2,
    }
}

fn source() -> DResult<Cf> {
    // SAFETY: returns a +1 event source or null.
    Cf::created(unsafe { CGEventSourceCreate(SOURCE_PRIVATE) })
        .ok_or_else(|| DesktopError::Failed("could not create an event source".into()))
}

fn post(route: Route, event: &Cf) {
    // SAFETY: event is a live CGEvent.
    unsafe {
        match route {
            Route::Pid { pid, window } => {
                if window != 0 {
                    CGEventSetIntegerValueField(
                        event.ptr(),
                        FIELD_WINDOW_UNDER_POINTER,
                        window as i64,
                    );
                    CGEventSetIntegerValueField(
                        event.ptr(),
                        FIELD_WINDOW_THAT_CAN_HANDLE,
                        window as i64,
                    );
                }
                CGEventPostToPid(pid, event.ptr());
            }
            Route::Hid => CGEventPost(HID_TAP, event.ptr()),
        }
    }
}

/// Where a gesture's pid-routed mouse events point: the window and its
/// top-left corner (global points), read once per gesture.
#[derive(Clone, Copy)]
struct Aim {
    window: u32,
    origin: Option<Point>,
}

impl Aim {
    fn of(route: Route) -> Option<Aim> {
        match route {
            Route::Pid { window, .. } if window != 0 => Some(Aim {
                window,
                origin: super::cgwindows::by_id(window)
                    .map(|w| Point { x: w.frame.x, y: w.frame.y }),
            }),
            _ => None,
        }
    }
}

/// `CGEventSetWindowLocation` (CoreGraphics, not in its headers).
type SetWindowLocation = unsafe extern "C" fn(CFTypeRef, CGPoint);

fn set_window_location() -> Option<SetWindowLocation> {
    static F: std::sync::OnceLock<Option<SetWindowLocation>> = std::sync::OnceLock::new();
    *F.get_or_init(|| {
        // SAFETY: the symbol has this signature (void (CGEventRef, CGPoint)).
        symbol(c"CGEventSetWindowLocation")
            .map(|p| unsafe { std::mem::transmute::<*mut std::ffi::c_void, SetWindowLocation>(p) })
    })
}

/// Posts a mouse event at `at` (global points): on a pid route it names the
/// window and its point inside it ([`roles::pid_mouse_stamp`]), which AppKit
/// needs to deliver it to that window.
fn post_mouse(route: Route, aim: Option<Aim>, event: &Cf, at: Point) {
    if let Some(aim) = aim {
        let stamp = roles::pid_mouse_stamp(aim.window, at, aim.origin);
        // SAFETY: event is a live CGEvent; the location setter takes it and a point.
        unsafe {
            CGEventSetIntegerValueField(event.ptr(), FIELD_WINDOW_NUMBER, stamp.window_number);
            if let (Some(local), Some(set)) = (stamp.local, set_window_location()) {
                set(event.ptr(), CGPoint { x: local.x, y: local.y });
            }
        }
    }
    post(route, event);
}

fn mouse_event(src: &Cf, ty: u32, at: Point, button: Button, flags: u64) -> DResult<Cf> {
    let p = CGPoint { x: at.x, y: at.y };
    // SAFETY: src is live; the event is +1.
    let e =
        Cf::created(unsafe { CGEventCreateMouseEvent(src.ptr(), ty, p, button_number(button)) })
            .ok_or_else(|| DesktopError::Failed("could not create a mouse event".into()))?;
    // SAFETY: e is a live mouse event.
    unsafe {
        CGEventSetIntegerValueField(e.ptr(), FIELD_BUTTON_NUMBER, button_number(button) as i64);
        CGEventSetFlags(e.ptr(), flags);
    }
    Ok(e)
}

/// `count` clicks (1: single, 2: double, ...) of `button` at `at`.
pub fn click(
    route: Route,
    at: Point,
    button: Button,
    count: u8,
    flags: u64,
    gap: std::time::Duration,
) -> DResult<()> {
    let src = source()?;
    // Presses are not window-addressed (see the module notes).
    let aim = None;
    let paced = matches!(route, Route::Pid { .. });
    let (down, up, _) = button_events(button);
    post_mouse(route, aim, &mouse_event(&src, MOUSE_MOVED, at, Button::Left, flags)?, at);
    for n in 1..=count.max(1) {
        if n > 1 && !gap.is_zero() {
            std::thread::sleep(gap);
        }
        for ty in [down, up] {
            let e = mouse_event(&src, ty, at, button, flags)?;
            // SAFETY: e is a live mouse event.
            unsafe { CGEventSetIntegerValueField(e.ptr(), FIELD_CLICK_STATE, n as i64) };
            post_mouse(route, aim, &e, at);
            // A control's mouse-down starts a tracking loop that waits for
            // the up; one posted in the same instant can be missed.
            if ty == down && paced {
                std::thread::sleep(PRESS_GAP);
            }
        }
    }
    Ok(())
}

pub fn drag(route: Route, from: Point, to: Point, button: Button) -> DResult<()> {
    let src = source()?;
    // Presses are not window-addressed (see the module notes).
    let aim = None;
    let (down, up, dragged) = button_events(button);
    post_mouse(route, aim, &mouse_event(&src, MOUSE_MOVED, from, Button::Left, 0)?, from);
    let press = |ty, at| -> DResult<Cf> {
        let e = mouse_event(&src, ty, at, button, 0)?;
        // SAFETY: e is a live mouse event.
        unsafe { CGEventSetIntegerValueField(e.ptr(), FIELD_CLICK_STATE, 1) };
        Ok(e)
    };
    post_mouse(route, aim, &press(down, from)?, from);
    // Pacing: AppKit and WebKit coalesce a burst of drag events into one
    // jump, and a slider or a text selection then sees no movement.
    let paced = matches!(route, Route::Pid { .. });
    if paced {
        std::thread::sleep(PRESS_GAP);
    }
    for p in roles::drag_path(from, to) {
        post_mouse(route, aim, &press(dragged, p)?, p);
        if paced {
            std::thread::sleep(DRAG_STEP);
        }
    }
    post_mouse(route, aim, &press(up, to)?, to);
    Ok(())
}

/// Scrolls by lines at `at` (`dy > 0` down, `dx > 0` right).
pub fn scroll(route: Route, at: Point, dx: f64, dy: f64) -> DResult<()> {
    let (wheel_y, wheel_x) = roles::wheel_deltas(dx, dy);
    if wheel_x == 0 && wheel_y == 0 {
        return Ok(());
    }
    let src = source()?;
    let aim = Aim::of(route);
    post_mouse(route, aim, &mouse_event(&src, MOUSE_MOVED, at, Button::Left, 0)?, at);
    // SAFETY: src is live; the event is +1.
    let e = Cf::created(unsafe {
        CGEventCreateScrollWheelEvent2(src.ptr(), SCROLL_UNIT_LINE, 2, wheel_y, wheel_x, 0)
    })
    .ok_or_else(|| DesktopError::Failed("could not create a scroll event".into()))?;
    // SAFETY: e is a live scroll event.
    unsafe {
        CGEventSetLocation(e.ptr(), CGPoint { x: at.x, y: at.y });
        CGEventSetFlags(e.ptr(), 0);
    }
    post_mouse(route, aim, &e, at);
    Ok(())
}

fn key_event(src: &Cf, code: u16, down: bool, flags: u64, text: Option<&[u16]>) -> DResult<Cf> {
    // SAFETY: src is live; the event is +1.
    let e = Cf::created(unsafe { CGEventCreateKeyboardEvent(src.ptr(), code, down) })
        .ok_or_else(|| DesktopError::Failed("could not create a key event".into()))?;
    // SAFETY: e is a live key event; text outlives the call.
    unsafe {
        CGEventSetFlags(e.ptr(), flags);
        if let Some(units) = text {
            CGEventKeyboardSetUnicodeString(e.ptr(), units.len(), units.as_ptr());
        }
    }
    Ok(e)
}

/// One key press (down and up) with modifier flags.
pub fn key(route: Route, code: u16, flags: u64, text: Option<char>) -> DResult<()> {
    let src = source()?;
    let mut buf = [0u16; 2];
    let len = text.map(|c| c.encode_utf16(&mut buf).len());
    let units = len.map(|n| &buf[..n]);
    post(route, &key_event(&src, code, true, flags, units)?);
    post(route, &key_event(&src, code, false, flags, units)?);
    Ok(())
}

/// Types text one character at a time as Unicode key events. Characters on
/// the ANSI layout use their own key code (apps that read codes, such as
/// terminals, see the real key); newlines and tabs press Return and Tab.
pub fn type_text(route: Route, text: &str) -> DResult<()> {
    let src = source()?;
    let mut buf = [0u16; 2];
    for c in text.chars() {
        let (code, shift) = keymap::char_key(c).unwrap_or((0, false));
        let flags = if shift { keymap::FLAG_SHIFT } else { 0 };
        let typed = match c {
            '\n' | '\r' => '\r',
            other => other,
        };
        let units: &[u16] = typed.encode_utf16(&mut buf);
        post(route, &key_event(&src, code, true, flags, Some(units))?);
        post(route, &key_event(&src, code, false, flags, Some(units))?);
    }
    Ok(())
}
