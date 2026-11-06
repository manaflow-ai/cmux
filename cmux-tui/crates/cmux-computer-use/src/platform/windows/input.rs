//! Pointer and keyboard input.
//!
//! Background (the default): window messages posted to the target's own
//! child window: the one under the point for the pointer, the one with the
//! keyboard focus for keys and text. No window is activated and the
//! person's pointer and keyboard state are untouched. Limits, which we
//! refuse rather than guess around:
//! - posted messages do not change GetKeyState, so a key combo that needs a
//!   held Ctrl, Win or Shift (on a non-character key) is refused in the
//!   background; Alt combos go as WM_SYSKEYDOWN, which carries the Alt bit;
//! - apps that read raw input or pointer messages (some games, some
//!   GPU-composed UI) ignore posted mouse messages: prefer element targets;
//! - OLE drag and drop runs its own modal loop on real input: a background
//!   drag moves things within a window, not between apps.
//!
//! Foreground (asked for explicitly, allowed by policy): the window is
//! raised and SendInput synthesizes system-wide input; the pointer goes
//! back where the person left it. Each injection is recorded so the
//! person's activity tracker does not take it for theirs.

use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBD_EVENT_FLAGS, KEYBDINPUT,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, MOUSE_EVENT_FLAGS,
    MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_VIRTUALDESK, MOUSEINPUT, MapVirtualKeyW, SendInput, ToUnicode, VIRTUAL_KEY,
    VkKeyScanW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CS_DBLCLKS, CWP_SKIPINVISIBLE, CWP_SKIPTRANSPARENT, ChildWindowFromPointEx, GA_ROOT, GCL_STYLE,
    GUITHREADINFO, GetAncestor, GetClassLongW, GetCursorPos, GetForegroundWindow, GetGUIThreadInfo,
    PostMessageW, SPI_GETWHEELSCROLLCHARS, SPI_GETWHEELSCROLLLINES,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetCursorPos, SetForegroundWindow, SystemParametersInfoW,
    WM_CHAR, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP,
    WM_MBUTTONDBLCLK, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL,
    WM_RBUTTONDBLCLK, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
};

use super::capture::virtual_screen;
use super::pure::{self, vk};
use super::win::{self, Hwnd};
use crate::desktop::{ActionOutcome, Button, ClickSpec, DResult, Delivery, DesktopError, Point};
use crate::keys::{Key, KeyCombo, Modifier};

fn post(hwnd: HWND, msg: u32, w: usize, l: isize) -> DResult<()> {
    // SAFETY: posting copies the parameters; no pointers are passed.
    unsafe { PostMessageW(Some(hwnd), msg, WPARAM(w), LPARAM(l)) }
        .map_err(|e| DesktopError::Failed(format!("could not post to the window: {e}")))
}

/// The child of `top` with the keyboard focus, else `top`.
pub fn focus_of(top: Hwnd) -> Hwnd {
    let (_, tid) = win::pid_of(top.get());
    let mut info =
        GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
    // SAFETY: cbSize describes the struct.
    if unsafe { GetGUIThreadInfo(tid, &mut info) }.is_ok() && !info.hwndFocus.is_invalid() {
        // SAFETY: plain query.
        if unsafe { GetAncestor(info.hwndFocus, GA_ROOT) } == top.get() {
            return Hwnd::from(info.hwndFocus);
        }
    }
    top
}

/// The deepest visible child of `top` under the screen point, and the point
/// in its client coordinates. Refuses a point outside the window.
fn child_at(top: Hwnd, at: Point) -> DResult<(HWND, POINT)> {
    let frame = win::rect(win::frame_of(top.get()));
    let inside = at.x >= frame.x
        && at.y >= frame.y
        && at.x < frame.x + frame.width
        && at.y < frame.y + frame.height;
    if !inside {
        return Err(DesktopError::TargetNotFound(format!(
            "point ({:.0}, {:.0}) is outside window {}",
            at.x, at.y, top.0
        )));
    }
    let screen = POINT { x: at.x.round() as i32, y: at.y.round() as i32 };
    let mut current = top.get();
    for _ in 0..64 {
        let mut p = screen;
        // SAFETY: plain queries on live handles.
        let child = unsafe {
            let _ = ScreenToClient(current, &mut p);
            ChildWindowFromPointEx(current, p, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT)
        };
        if child.is_invalid() || child == current {
            break;
        }
        current = child;
    }
    let mut p = screen;
    // SAFETY: plain query.
    let _ = unsafe { ScreenToClient(current, &mut p) };
    Ok((current, p))
}

fn button_messages(b: Button) -> (u32, u32, u32, usize) {
    match b {
        Button::Left => (WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK, 0x0001),
        Button::Right => (WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK, 0x0002),
        Button::Middle => (WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK, 0x0010),
    }
}

/// MK_SHIFT / MK_CONTROL for mouse messages; Alt and Win have no mouse
/// message bit, so a background click cannot carry them.
fn mouse_key_bits(mods: &[Modifier]) -> DResult<usize> {
    let mut bits = 0;
    for m in mods {
        bits |= match m {
            Modifier::Shift => 0x0004,
            Modifier::Control => 0x0008,
            other => {
                return Err(DesktopError::Unsupported(format!(
                    "a background click cannot hold {other:?}; pass delivery \"foreground\" (if allowed) or use an element action"
                )));
            }
        };
    }
    Ok(bits)
}

pub fn click(top: Hwnd, at: Point, spec: &ClickSpec) -> DResult<ActionOutcome> {
    if spec.delivery == Delivery::Foreground {
        return click_foreground(top, at, spec);
    }
    let keys = mouse_key_bits(&spec.modifiers)?;
    let (target, p) = child_at(top, at)?;
    let l = pure::point_lparam(p.x, p.y);
    let (down, up, dbl, held) = button_messages(spec.button);
    // SAFETY: plain query.
    let dblclks = unsafe { GetClassLongW(target, GCL_STYLE) } & CS_DBLCLKS.0 != 0;
    post(target, WM_MOUSEMOVE, keys, l)?;
    for i in 0..spec.count.clamp(1, 3) {
        let msg = if i == 1 && dblclks { dbl } else { down };
        post(target, msg, keys | held, l)?;
        post(target, up, keys, l)?;
    }
    Ok(ActionOutcome {
        note: "posted mouse messages to the window under the point".into(),
        ..ActionOutcome::delivered("window_message").at(at)
    })
}

fn send(inputs: &[INPUT]) -> DResult<()> {
    // SAFETY: the slice and the element size describe the same array.
    let sent = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
    super::note_injected_input();
    if sent as usize != inputs.len() {
        return Err(DesktopError::Failed(
            "SendInput was blocked (a higher-integrity window has focus, or the desktop is locked)"
                .into(),
        ));
    }
    Ok(())
}

/// Raises the window for foreground input; refuses when Windows keeps
/// another window in front (its foreground lock), so input never lands in
/// the wrong app.
fn raise(top: Hwnd) -> DResult<()> {
    // SAFETY: plain calls.
    unsafe {
        if GetForegroundWindow() != top.get() {
            let _ = SetForegroundWindow(top.get());
        }
        if GetForegroundWindow() != top.get() {
            return Err(DesktopError::Unsupported(
                "Windows did not let this window come to the front (foreground lock); use background delivery or element actions".into(),
            ));
        }
    }
    Ok(())
}

fn mouse(dx: i32, dy: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn move_to(at: Point) -> INPUT {
    let v = virtual_screen();
    let (x, y) =
        pure::absolute_input(at.x, at.y, v.x as i32, v.y as i32, v.width as i32, v.height as i32);
    mouse(x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)
}

fn button_flags(b: Button) -> (MOUSE_EVENT_FLAGS, MOUSE_EVENT_FLAGS) {
    match b {
        Button::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        Button::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        Button::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
    }
}

fn key(vk: u16, extended: bool, up: bool) -> INPUT {
    // SAFETY: plain query.
    let scan = unsafe { MapVirtualKeyW(u32::from(vk), MAPVK_VK_TO_VSC) } as u16;
    let mut flags = KEYBD_EVENT_FLAGS(0);
    if extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: scan,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn unicode(unit: u16, up: bool) -> INPUT {
    let mut flags = KEYEVENTF_UNICODE;
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn modifier_vk(m: Modifier) -> DResult<u16> {
    Ok(match m {
        Modifier::Shift => vk::SHIFT,
        Modifier::Control => vk::CONTROL,
        Modifier::Alt => vk::MENU,
        Modifier::Meta => vk::LWIN,
        Modifier::Fn => {
            return Err(DesktopError::Unsupported("Windows has no Fn key event".into()));
        }
    })
}

/// Runs `body` with the pointer restored afterwards.
fn keep_pointer(body: impl FnOnce() -> DResult<()>) -> DResult<()> {
    let mut saved = POINT::default();
    // SAFETY: an out pointer to a local.
    let had = unsafe { GetCursorPos(&mut saved) }.is_ok();
    let result = body();
    if had {
        // SAFETY: plain call.
        let _ = unsafe { SetCursorPos(saved.x, saved.y) };
        super::note_injected_input();
    }
    result
}

fn click_foreground(top: Hwnd, at: Point, spec: &ClickSpec) -> DResult<ActionOutcome> {
    child_at(top, at)?;
    raise(top)?;
    let mods: Vec<u16> = spec.modifiers.iter().map(|m| modifier_vk(*m)).collect::<DResult<_>>()?;
    let (down, up) = button_flags(spec.button);
    let mut inputs: Vec<INPUT> = mods.iter().map(|&v| key(v, false, false)).collect();
    inputs.push(move_to(at));
    for _ in 0..spec.count.clamp(1, 3) {
        inputs.push(mouse(0, 0, down));
        inputs.push(mouse(0, 0, up));
    }
    inputs.extend(mods.iter().rev().map(|&v| key(v, false, true)));
    keep_pointer(|| send(&inputs))?;
    Ok(ActionOutcome::delivered("send_input").at(at))
}

pub fn type_background(target: Hwnd, text: &str) -> DResult<ActionOutcome> {
    for unit in pure::char_units(text) {
        post(target.get(), WM_CHAR, usize::from(unit), 1)?;
    }
    Ok(ActionOutcome {
        note: "posted WM_CHAR to the focused control".into(),
        ..ActionOutcome::delivered("window_message")
    })
}

pub fn type_foreground(top: Hwnd, text: &str) -> DResult<ActionOutcome> {
    raise(top)?;
    let mut inputs = Vec::new();
    for unit in pure::char_units(text) {
        if unit == 13 {
            inputs.push(key(vk::RETURN, false, false));
            inputs.push(key(vk::RETURN, false, true));
        } else {
            inputs.push(unicode(unit, false));
            inputs.push(unicode(unit, true));
        }
    }
    send(&inputs)?;
    Ok(ActionOutcome::delivered("send_input"))
}

fn key_name(k: &Key) -> Option<String> {
    Some(match k {
        Key::Char(_) => return None,
        Key::F(n) => format!("f{n}"),
        other => serde_json::to_value(other).ok()?.as_str()?.to_string(),
    })
}

/// The virtual key for a character on this keyboard layout, when it needs
/// no modifier (VkKeyScanW's high byte is the shift state it needs).
fn plain_vk(c: char) -> Option<u16> {
    let mut units = [0u16; 2];
    if c.encode_utf16(&mut units).len() != 1 {
        return None;
    }
    // SAFETY: plain query.
    let scan = unsafe { VkKeyScanW(units[0]) };
    if scan == -1 || (scan as u16) >> 8 != 0 {
        return None;
    }
    Some((scan as u16) & 0xFF)
}

/// The character Shift+`c` types on this layout (`!` for `1` on US).
fn shifted(c: char) -> Option<char> {
    if c.is_alphabetic() {
        return c.to_uppercase().next();
    }
    let v = plain_vk(c)?;
    let mut state = [0u8; 256];
    state[usize::from(vk::SHIFT)] = 0x80;
    let mut out = [0u16; 4];
    // SAFETY: plain call; flag 0x4 leaves the thread's dead-key state alone.
    let n = unsafe { ToUnicode(u32::from(v), 0, Some(&state), &mut out, 0x4) };
    if n != 1 {
        return None;
    }
    char::from_u32(u32::from(out[0]))
}

fn post_key(target: HWND, vk_code: u16, extended: bool, alt: bool) -> DResult<()> {
    // SAFETY: plain query.
    let scan = unsafe { MapVirtualKeyW(u32::from(vk_code), MAPVK_VK_TO_VSC) };
    let (down, up) = if alt { (WM_SYSKEYDOWN, WM_SYSKEYUP) } else { (WM_KEYDOWN, WM_KEYUP) };
    post(target, down, usize::from(vk_code), pure::key_lparam(scan, extended, alt, false))?;
    post(target, up, usize::from(vk_code), pure::key_lparam(scan, extended, alt, true))
}

fn resolve_key(k: &Key) -> DResult<(u16, bool)> {
    if let Key::Char(c) = k {
        return plain_vk(c.to_ascii_lowercase()).map(|v| (v, false)).ok_or_else(|| {
            DesktopError::Unsupported(format!(
                "{c:?} has no key on this keyboard layout; use type_text"
            ))
        });
    }
    let name = key_name(k).unwrap_or_default();
    pure::named_vk(&name)
        .ok_or_else(|| DesktopError::Unsupported(format!("no Windows key for {name:?}")))
}

pub fn press_keys(top: Hwnd, combo: &KeyCombo, delivery: Delivery) -> DResult<ActionOutcome> {
    if delivery == Delivery::Foreground {
        raise(top)?;
        let mods: Vec<u16> =
            combo.modifiers.iter().map(|m| modifier_vk(*m)).collect::<DResult<_>>()?;
        let (v, extended) = resolve_key(&combo.key)?;
        let mut inputs: Vec<INPUT> = mods.iter().map(|&m| key(m, false, false)).collect();
        inputs.push(key(v, extended, false));
        inputs.push(key(v, extended, true));
        inputs.extend(mods.iter().rev().map(|&m| key(m, false, true)));
        send(&inputs)?;
        return Ok(ActionOutcome::delivered("send_input"));
    }
    let target = focus_of(top).get();
    let shift = combo.modifiers.contains(&Modifier::Shift);
    let alt = combo.modifiers.contains(&Modifier::Alt);
    if let Some(m) = combo
        .modifiers
        .iter()
        .find(|m| matches!(m, Modifier::Control | Modifier::Meta | Modifier::Fn))
    {
        return Err(DesktopError::Unsupported(format!(
            "{m:?} combos need the real key state, which posted messages cannot set; pass delivery \"foreground\" (if allowed), or use an element action or set_value"
        )));
    }
    let note = "posted key messages to the focused control";
    match &combo.key {
        Key::Char(c) if !alt => {
            let c = if shift {
                shifted(*c).ok_or_else(|| {
                    DesktopError::Unsupported(format!(
                        "shift+{c:?} has no character on this layout"
                    ))
                })?
            } else {
                *c
            };
            match plain_vk(c) {
                // TranslateMessage in the app turns the key into its WM_CHAR.
                Some(v) => post_key(target, v, false, false)?,
                None => type_background(Hwnd::from(target), &c.to_string()).map(|_| ())?,
            }
        }
        k => {
            if shift {
                return Err(DesktopError::Unsupported(
                    "shift with a non-character key needs the real Shift state; pass delivery \"foreground\" (if allowed)".into(),
                ));
            }
            let (v, extended) = resolve_key(k)?;
            if alt {
                // SAFETY: plain query.
                let scan = unsafe { MapVirtualKeyW(u32::from(vk::MENU), MAPVK_VK_TO_VSC) };
                post(
                    target,
                    WM_SYSKEYDOWN,
                    usize::from(vk::MENU),
                    pure::key_lparam(scan, false, true, false),
                )?;
                post_key(target, v, extended, true)?;
                post(
                    target,
                    WM_KEYUP,
                    usize::from(vk::MENU),
                    pure::key_lparam(scan, false, false, true),
                )?;
            } else {
                post_key(target, v, extended, false)?;
            }
        }
    }
    Ok(ActionOutcome { note: note.into(), ..ActionOutcome::delivered("window_message") })
}

fn wheel_lines(
    action: windows::Win32::UI::WindowsAndMessaging::SYSTEM_PARAMETERS_INFO_ACTION,
) -> u32 {
    let mut lines = 3u32;
    // SAFETY: a u32 out buffer.
    let _ = unsafe {
        SystemParametersInfoW(
            action,
            0,
            Some((&mut lines as *mut u32).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    // WHEEL_PAGESCROLL (u32::MAX) means a page per notch; count it as 3 lines.
    if lines == 0 || lines == u32::MAX { 3 } else { lines }
}

pub fn scroll(top: Hwnd, at: Point, dx: f64, dy: f64) -> DResult<ActionOutcome> {
    let (target, _) = child_at(top, at)?;
    let l = pure::point_lparam(at.x.round() as i32, at.y.round() as i32);
    for d in pure::wheel_deltas(dy, wheel_lines(SPI_GETWHEELSCROLLLINES), true) {
        post(target, WM_MOUSEWHEEL, pure::wheel_wparam(d, 0), l)?;
    }
    for d in pure::wheel_deltas(dx, wheel_lines(SPI_GETWHEELSCROLLCHARS), false) {
        post(target, WM_MOUSEHWHEEL, pure::wheel_wparam(d, 0), l)?;
    }
    Ok(ActionOutcome {
        note: "posted wheel messages to the window under the point".into(),
        ..ActionOutcome::delivered("window_message").at(at)
    })
}

const DRAG_STEPS: usize = 12;

pub fn drag(
    top: Hwnd,
    from: Point,
    to: Point,
    button: Button,
    delivery: Delivery,
) -> DResult<ActionOutcome> {
    child_at(top, to)?;
    let steps = (1..=DRAG_STEPS).map(|i| {
        let t = i as f64 / DRAG_STEPS as f64;
        Point { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t }
    });
    if delivery == Delivery::Foreground {
        child_at(top, from)?;
        raise(top)?;
        let (down, up) = button_flags(button);
        let mut inputs = vec![move_to(from), mouse(0, 0, down)];
        inputs.extend(steps.map(move_to));
        inputs.push(mouse(0, 0, up));
        keep_pointer(|| send(&inputs))?;
        return Ok(ActionOutcome::delivered("send_input").at(to));
    }
    // Every message goes to the window the drag started in, as a real drag
    // with capture would deliver them; points outside it are negative or
    // past its size in its client coordinates.
    let (target, start) = child_at(top, from)?;
    let (down, up, _, held) = button_messages(button);
    let client = |p: Point| {
        let dx = (p.x - from.x).round() as i32;
        let dy = (p.y - from.y).round() as i32;
        pure::point_lparam(start.x + dx, start.y + dy)
    };
    post(target, WM_MOUSEMOVE, 0, client(from))?;
    post(target, down, held, client(from))?;
    for p in steps {
        post(target, WM_MOUSEMOVE, held, client(p))?;
    }
    post(target, up, 0, client(to))?;
    Ok(ActionOutcome {
        note: "posted a mouse drag to the window under the start point (in-window drags; OLE drag and drop needs foreground)".into(),
        ..ActionOutcome::delivered("window_message").at(to)
    })
}
