//! What Computer Use does while the Mac's screen is locked.
//!
//! A locked Mac shows the lock screen's password field to the system-wide
//! input queue: a key posted at the HID tap types into it, a mouse event
//! moves the real pointer over it, a display capture returns the black
//! shield, and an app asked to come forward cannot. So by default every call
//! but `status` is refused with [`CODE`] while the screen is locked, before it
//! reads or posts anything (the bridge maps the code to one typed state,
//! cmux#48175). The engine reads the lock before every call
//! ([`crate::desktop::Desktop::screen_locked`]), and a batch before each step.
//!
//! What still works on a locked Mac (measured in a macOS 26 guest, cmux#46147
//! step 78eda65e): a window's own capture by its window id returns the live
//! window, and keys posted to the app's process (`CGEventPostToPid`) land in
//! it. With the opt-in `computerUse.whileLocked` (default off) those calls go
//! on: app and window lists, window screenshots and trees, and background
//! input to a window (process-routed events and accessibility actions). Still
//! refused, setting or not: foreground delivery (the HID tap, the real
//! pointer, raising the app), a display capture, launching an app and the
//! OS permission prompt.
//!
//! Design: cmuxterm-hq `docs/design/locked-screen-computer-use.md`.

use serde_json::{Value, json};

/// The code of every call refused because the screen is locked (the Swift
/// helper's code before cmux#37003, the one the bridge maps).
pub const CODE: &str = "mac_locked";

/// The setting that lets window-scoped calls go on while locked.
pub const SETTING: &str = "computerUse.whileLocked";

/// What a call would do, as far as a locked screen is concerned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Reads the engine's own state (status, list_machines): always runs.
    Engine,
    /// App and window lists (no pixels, no input).
    Inventory,
    /// One window's pixels or tree, by its window id.
    WindowLook,
    /// Background input to one window: posted to its process, or an
    /// accessibility action on one of its elements.
    WindowInput,
    /// The system-wide input queue (foreground delivery): HID events, the
    /// real pointer, raising the window's app.
    Hid,
    /// A whole display's pixels (black while locked).
    Display,
    /// Starts or activates an app, or shows an OS prompt in front.
    Activates,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Engine => "engine",
            Kind::Inventory => "inventory",
            Kind::WindowLook => "window_look",
            Kind::WindowInput => "window_input",
            Kind::Hid => "hid",
            Kind::Display => "display",
            Kind::Activates => "activates",
        }
    }
}

fn has(args: &Value, key: &str) -> bool {
    args.get(key).and_then(Value::as_str).is_some_and(|s| !s.is_empty())
}

fn foreground(args: &Value) -> bool {
    // Anything but an explicit background (or none) counts as foreground: an
    // unknown value is refused here rather than read later.
    args.get("delivery").and_then(Value::as_str).is_some_and(|d| d != "background")
}

/// What `tool` with `args` would do. A tool this table does not know is
/// [`Kind::Activates`], so a new tool is refused while locked until it is
/// placed here.
pub fn kind_of(tool: &str, args: &Value) -> Kind {
    match tool {
        "status" | "list_machines" | "list_displays" => Kind::Engine,
        "list_apps" | "list_windows" | "list_alerts" => Kind::Inventory,
        // Without a window id a screenshot or a wait captures the display.
        "screenshot" | "wait" if has(args, "window_id") => Kind::WindowLook,
        "screenshot" | "wait" => Kind::Display,
        // Stopping a recording captures nothing (the recording ended itself
        // when the screen locked); every other record call is the display.
        "record" if args.get("action").and_then(Value::as_str) == Some("stop") => Kind::Engine,
        "record" => Kind::Display,
        "get_ui_tree" => Kind::WindowLook,
        "click" | "type_text" | "press_key" | "drag" if foreground(args) => Kind::Hid,
        "click" | "type_text" | "press_key" | "drag" | "scroll" | "set_value"
        | "perform_action" => Kind::WindowInput,
        // An accessibility press on one alert's button.
        "dismiss_alert" => Kind::WindowInput,
        // Each step is checked on its own when it runs.
        "batch" => Kind::WindowInput,
        _ => Kind::Activates,
    }
}

/// Whether a call of `kind` runs while the screen is locked.
pub fn admits(kind: Kind, while_locked: bool) -> bool {
    match kind {
        Kind::Engine => true,
        Kind::Inventory | Kind::WindowLook | Kind::WindowInput => while_locked,
        Kind::Hid | Kind::Display | Kind::Activates => false,
    }
}

/// Why a call of `kind` cannot run on a locked screen, in words.
fn reason(kind: Kind) -> &'static str {
    match kind {
        Kind::Hid => {
            "foreground input goes through the system-wide queue, which a locked Mac sends to the lock screen's password field"
        }
        Kind::Display => "a display capture shows only the lock screen while the Mac is locked",
        Kind::Activates => "no app can be started or brought forward while the Mac is locked",
        Kind::Engine | Kind::Inventory | Kind::WindowLook | Kind::WindowInput => {
            "Computer Use does nothing on a locked Mac unless the whileLocked setting is on"
        }
    }
}

/// The error a call of `kind` gets on a locked screen.
pub fn refusal(tool: &str, kind: Kind, while_locked: bool) -> (String, Value) {
    let message = if while_locked {
        format!(
            "This Mac is locked. While it is locked only app and window lists, window screenshots (pass window_id) and background input to a window work; {tool} cannot run: {}.",
            reason(kind)
        )
    } else {
        format!(
            "This Mac is locked, so {tool} did nothing ({}). Ask the person to unlock it, or run this on another machine.",
            reason(kind)
        )
    };
    let detail = json!({
        "setting": SETTING,
        "value": if while_locked { "on" } else { "off" },
        "kind": kind.as_str(),
    });
    (message, detail)
}

/// Reads whether the session's screen is locked, on macOS: the window
/// server's `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary`.
/// A display that dimmed on idle is locked too (macOS 14 on). `false` when
/// the process has no window server session (nothing it posts reaches one).
/// Only with the `desktop` feature, as its only callers (`platform::macos`):
/// the engine-only build that acpmux and the cmux-tui daemon link must not
/// need CoreGraphics, which the Linux pool's macOS cross SDK does not have.
#[cfg(all(target_os = "macos", feature = "desktop"))]
pub fn session_screen_locked() -> bool {
    use std::ffi::c_void;
    type CFTypeRef = *const c_void;
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGSessionCopyCurrentDictionary() -> CFTypeRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFDictionaryGetValue(d: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFStringCreateWithBytes(
            alloc: CFTypeRef,
            bytes: *const u8,
            len: isize,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        fn CFRelease(cf: CFTypeRef);
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFBooleanGetValue(b: CFTypeRef) -> u8;
        fn CFNumberGetValue(n: CFTypeRef, ty: isize, out: *mut c_void) -> u8;
    }
    const UTF8: u32 = 0x0800_0100;
    const NUMBER_SINT64: isize = 4;
    let key = b"CGSSessionScreenIsLocked";
    // SAFETY: the dictionary and key are +1 and released here; the value is
    // borrowed from the dictionary, read before it is released, after its
    // type is checked.
    unsafe {
        let dict = CGSessionCopyCurrentDictionary();
        if dict.is_null() {
            return false;
        }
        let k =
            CFStringCreateWithBytes(std::ptr::null(), key.as_ptr(), key.len() as isize, UTF8, 0);
        let mut locked = false;
        if !k.is_null() {
            let v = CFDictionaryGetValue(dict, k);
            if !v.is_null() {
                let ty = CFGetTypeID(v);
                if ty == CFBooleanGetTypeID() {
                    locked = CFBooleanGetValue(v) != 0;
                } else if ty == CFNumberGetTypeID() {
                    let mut n: i64 = 0;
                    locked = CFNumberGetValue(v, NUMBER_SINT64, (&mut n as *mut i64).cast()) != 0
                        && n != 0;
                }
            }
            CFRelease(k);
        }
        CFRelease(dict);
        locked
    }
}

#[cfg(test)]
#[path = "locked_tests.rs"]
mod tests;
