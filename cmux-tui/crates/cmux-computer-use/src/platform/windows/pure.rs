//! The Windows desktop's pure pieces: message parameters, key codes, pixel
//! conversion, UI Automation roles, ids and the agent cursor's shape. No
//! Win32 calls and no crate imports, so the unit tests also run on Linux:
//! `rustc --edition 2024 --test src/platform/windows/pure.rs`.

/// Virtual-key codes we post or inject (winuser.h).
pub mod vk {
    pub const BACK: u16 = 0x08;
    pub const TAB: u16 = 0x09;
    pub const RETURN: u16 = 0x0D;
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12;
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const PRIOR: u16 = 0x21;
    pub const NEXT: u16 = 0x22;
    pub const END: u16 = 0x23;
    pub const HOME: u16 = 0x24;
    pub const LEFT: u16 = 0x25;
    pub const UP: u16 = 0x26;
    pub const RIGHT: u16 = 0x27;
    pub const DOWN: u16 = 0x28;
    pub const DELETE: u16 = 0x2E;
    pub const LWIN: u16 = 0x5B;
    pub const F1: u16 = 0x70;
}

/// The virtual key of a named (non-character) key and whether it is an
/// extended key (bit 24 of the key message's lParam, KEYEVENTF_EXTENDEDKEY).
/// Names are the snake_case names of `crate::keys::Key`; `f1`..`f24`.
pub fn named_vk(name: &str) -> Option<(u16, bool)> {
    Some(match name {
        "return" => (vk::RETURN, false),
        "tab" => (vk::TAB, false),
        "space" => (vk::SPACE, false),
        "backspace" => (vk::BACK, false),
        "delete" => (vk::DELETE, true),
        "escape" => (vk::ESCAPE, false),
        "left" => (vk::LEFT, true),
        "right" => (vk::RIGHT, true),
        "up" => (vk::UP, true),
        "down" => (vk::DOWN, true),
        "home" => (vk::HOME, true),
        "end" => (vk::END, true),
        "page_up" => (vk::PRIOR, true),
        "page_down" => (vk::NEXT, true),
        _ => {
            let n: u16 = name.strip_prefix('f')?.parse().ok()?;
            if !(1..=24).contains(&n) {
                return None;
            }
            (vk::F1 + n - 1, false)
        }
    })
}

/// lParam of WM_KEYDOWN / WM_KEYUP / WM_SYSKEYDOWN: repeat count 1, the scan
/// code, the extended bit, the context (Alt held) bit, and for key-up the
/// previous-state and transition bits.
pub fn key_lparam(scan: u32, extended: bool, alt_context: bool, up: bool) -> isize {
    let mut l: u32 = 1 | ((scan & 0xFF) << 16);
    if extended {
        l |= 1 << 24;
    }
    if alt_context {
        l |= 1 << 29;
    }
    if up {
        l |= (1 << 30) | (1 << 31);
    }
    l as i32 as isize
}

/// MAKELPARAM(x, y) for mouse messages: two signed 16-bit coordinates.
pub fn point_lparam(x: i32, y: i32) -> isize {
    let lo = (x as i16 as u16) as u32;
    let hi = (y as i16 as u16) as u32;
    (lo | (hi << 16)) as i32 as isize
}

/// wParam of WM_MOUSEWHEEL / WM_MOUSEHWHEEL: the key state in the low word,
/// the signed delta in the high word.
pub fn wheel_wparam(delta: i16, keys: u16) -> usize {
    (keys as u32 | ((delta as u16 as u32) << 16)) as usize
}

/// One wheel notch.
pub const WHEEL_DELTA: i32 = 120;

/// Wheel messages for scrolling `lines` lines (`> 0`: down or right), given
/// the person's lines-per-notch setting. Vertical wheel deltas are positive
/// upward, horizontal ones positive to the right. Each message carries at
/// most one notch, the way a real wheel reports, so apps that act per
/// message (and ignore larger deltas) still scroll the right amount; a
/// remainder below a notch goes out as one smaller delta (high-resolution
/// wheels do the same, and modern apps honor it).
pub fn wheel_deltas(lines: f64, lines_per_notch: u32, vertical: bool) -> Vec<i16> {
    if !lines.is_finite() || lines == 0.0 {
        return Vec::new();
    }
    let per_notch = f64::from(lines_per_notch.max(1));
    let total = (lines.abs() * f64::from(WHEEL_DELTA) / per_notch).round() as i64;
    let sign: i64 = match (vertical, lines > 0.0) {
        (true, true) | (false, false) => -1,
        (true, false) | (false, true) => 1,
    };
    let mut out = Vec::new();
    let mut left = total.max(1);
    while left > 0 {
        let step = left.min(i64::from(WHEEL_DELTA));
        out.push((sign * step) as i16);
        left -= step;
    }
    out
}

/// Text for WM_CHAR: UTF-16 units, with `\n` and `\r\n` sent as the Enter
/// key's `\r` (edit controls insert a line break for it).
pub fn char_units(text: &str) -> Vec<u16> {
    let normalized = text.replace("\r\n", "\r").replace('\n', "\r");
    normalized.encode_utf16().collect()
}

/// A screen point in the 0..=65535 absolute space SendInput uses with
/// MOUSEEVENTF_VIRTUALDESK, given the virtual screen's rectangle.
pub fn absolute_input(x: f64, y: f64, vx: i32, vy: i32, vw: i32, vh: i32) -> (i32, i32) {
    let norm = |p: f64, origin: i32, len: i32| -> i32 {
        if len <= 1 {
            return 0;
        }
        let v = ((p - f64::from(origin)) * 65535.0 / f64::from(len - 1)).round();
        v.clamp(0.0, 65535.0) as i32
    };
    (norm(x, vx, vw), norm(y, vy, vh))
}

/// GDI's BGRA (top-down, `stride` bytes per row) to tight RGBA, opaque.
/// PrintWindow and BitBlt leave the alpha byte undefined, so it is set.
pub fn bgra_to_rgba(bgra: &[u8], width: usize, height: usize, stride: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(width * height * 4);
    for row in 0..height {
        let start = row * stride;
        let Some(line) = bgra.get(start..start + width * 4) else {
            break;
        };
        for px in line.chunks_exact(4) {
            out.extend_from_slice(&[px[2], px[1], px[0], 0xFF]);
        }
    }
    out
}

/// True when every pixel is black: what PrintWindow returns for a window
/// that did not render (some GPU-composed apps), so capture falls back.
pub fn all_black(rgba: &[u8]) -> bool {
    rgba.chunks_exact(4).all(|p| p[0] == 0 && p[1] == 0 && p[2] == 0)
}

/// Copies the `(x, y, w, h)` sub-rectangle of a tight RGBA image, clipped.
pub fn crop_rgba(
    rgba: &[u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
) -> (Vec<u8>, usize, usize) {
    let x = x.min(width);
    let y = y.min(height);
    let w = w.min(width - x);
    let h = h.min(height - y);
    let mut out = Vec::with_capacity(w * h * 4);
    for row in y..y + h {
        let start = (row * width + x) * 4;
        out.extend_from_slice(&rgba[start..start + w * 4]);
    }
    (out, w, h)
}

/// The role of a UI Automation control type (UIA_*ControlTypeId,
/// 50000..=50040), in the snake_case vocabulary every desktop reports.
pub fn role_for_control_type(id: i32) -> &'static str {
    match id {
        50000 => "button",
        50001 => "calendar",
        50002 => "checkbox",
        50003 => "combo_box",
        50004 => "text_field",
        50005 => "link",
        50006 => "image",
        50007 => "list_item",
        50008 => "list",
        50009 => "menu",
        50010 => "menu_bar",
        50011 => "menu_item",
        50012 => "progress_bar",
        50013 => "radio_button",
        50014 => "scroll_bar",
        50015 => "slider",
        50016 => "spinner",
        50017 => "status_bar",
        50018 => "tab_group",
        50019 => "tab",
        50020 => "text",
        50021 => "toolbar",
        50022 => "tooltip",
        50023 => "tree",
        50024 => "tree_item",
        50025 => "custom",
        50026 => "group",
        50027 => "thumb",
        50028 => "table",
        50029 => "row",
        50030 => "document",
        50031 => "split_button",
        50032 => "window",
        50033 => "pane",
        50034 => "header",
        50035 => "header_item",
        50036 => "table",
        50037 => "title_bar",
        50038 => "separator",
        50039 => "semantic_zoom",
        50040 => "app_bar",
        _ => "unknown",
    }
}

/// Element ids: `<generation>.<index>` of one window's tree walk. A new
/// walk of the window starts a new generation, so an id from an older walk
/// is reported stale instead of naming some other element.
pub fn element_id(generation: u64, index: usize) -> String {
    format!("{generation}.{index}")
}

pub fn parse_element_id(id: &str) -> Option<(u64, usize)> {
    let (g, i) = id.split_once('.')?;
    Some((g.parse().ok()?, i.parse().ok()?))
}

/// Window ids are the HWND as a decimal number.
pub fn parse_window_id(id: &str) -> Option<usize> {
    id.parse::<usize>().ok().filter(|&h| h != 0)
}

/// What a `launch_app` id names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppId {
    /// A packaged app's AppUserModelID (`Microsoft.WindowsCalculator_8wekyb3d8bbwe!App`).
    Aumid(String),
    /// An executable: a full path (`C:\Program Files\...\app.exe`) or a
    /// program name the shell resolves through App Paths and PATH (`notepad.exe`).
    Exe(String),
}

/// Reads a `launch_app` id, refusing anything that is not an app: URIs and
/// protocol handlers (`ms-settings:`, `https://`), scripts and shortcuts
/// (`.bat`, `.cmd`, `.ps1`, `.lnk`), and ids with arguments or quotes. A
/// bare name gets `.exe`, so the shell cannot resolve it to a script
/// through PATHEXT.
pub fn parse_app_id(id: &str) -> Result<AppId, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("app_id is empty".into());
    }
    if id.contains(['"', '<', '>', '|', '*', '?', '\0']) || id.chars().any(char::is_control) {
        return Err(format!("{id:?} is not an app id or executable path"));
    }
    let drive_path = id.len() > 2
        && id.as_bytes()[0].is_ascii_alphabetic()
        && id.as_bytes()[1] == b':'
        && matches!(id.as_bytes()[2], b'\\' | b'/');
    let unc = id.starts_with("\\\\");
    if id.contains(':') && !drive_path {
        return Err(format!(
            "{id:?} is a URI or protocol, not an app; pass an exe name, a path or an AUMID"
        ));
    }
    let has_dir = id.contains(['\\', '/']);
    if id.contains('!') && !has_dir && !drive_path && !unc {
        return Ok(AppId::Aumid(id.to_string()));
    }
    let file = id.rsplit(['\\', '/']).next().unwrap_or(id);
    match file.rsplit_once('.') {
        Some((_, ext)) if ext.eq_ignore_ascii_case("exe") => Ok(AppId::Exe(id.to_string())),
        Some((_, ext)) => Err(format!(
            "{id:?} is a .{ext} file, not an app; launch_app starts only .exe programs and packaged apps"
        )),
        None if has_dir || drive_path || unc => {
            Err(format!("{id:?} is not an .exe; pass the program's full .exe path"))
        }
        None => Ok(AppId::Exe(format!("{id}.exe"))),
    }
}

/// What `launch_app(id)` would start, as policy ids: the `.exe` file name
/// (lowercased, as `list_apps` reports it) or the packaged app id.
pub fn launch_identities(id: &str) -> Result<Vec<String>, String> {
    Ok(match parse_app_id(id)? {
        AppId::Exe(path) => vec![exe_id(&path)],
        AppId::Aumid(aumid) => vec![aumid.to_ascii_lowercase()],
    })
}

/// The app id policy matches on: the executable's file name, lowercased.
pub fn exe_id(path: &str) -> String {
    path.rsplit(['\\', '/']).next().unwrap_or(path).to_ascii_lowercase()
}

/// A friendly fallback name from the executable path (`Notepad` from
/// `C:\Windows\notepad.exe`), when the file has no version description.
pub fn exe_display_name(path: &str) -> String {
    let file = path.rsplit(['\\', '/']).next().unwrap_or(path);
    let stem = match file.rsplit_once('.') {
        Some((stem, ext)) if ext.eq_ignore_ascii_case("exe") => stem,
        _ => file,
    };
    let mut chars = stem.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Milliseconds between two GetTickCount values, across the 49.7-day wrap.
pub fn ticks_since(now: u32, then: u32) -> u32 {
    now.wrapping_sub(then)
}

/// True when the session's last input came from our own SendInput: it is at
/// most `slack` ms after our last injection (Windows stamps the input when
/// it processes it, a little after SendInput returns).
pub fn input_is_ours(last_input: u32, last_injected: Option<u32>, slack: u32) -> bool {
    match last_injected {
        Some(ours) => ticks_since(last_input, ours) <= slack,
        None => false,
    }
}

/// Ease-out cubic, `t` in 0..=1.
pub fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

pub fn glide(from: (f64, f64), to: (f64, f64), t: f64) -> (f64, f64) {
    let e = ease_out(t);
    (from.0 + (to.0 - from.0) * e, from.1 + (to.1 - from.1) * e)
}

/// The agent cursor's arrow in its own units (tip at the origin), the shape
/// of the classic pointer.
const ARROW: [(f64, f64); 7] =
    [(0.0, 0.0), (0.0, 16.0), (4.0, 12.4), (6.7, 18.4), (9.1, 17.3), (6.5, 11.5), (11.5, 11.5)];
const ARROW_UNITS_W: f64 = 12.0;
const ARROW_UNITS_H: f64 = 19.0;

fn inside(poly: &[(f64, f64)], x: f64, y: f64) -> bool {
    let mut odd = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (xi, yi) = poly[i];
        let (xj, yj) = poly[j];
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            odd = !odd;
        }
        j = i;
    }
    odd
}

fn edge_distance(poly: &[(f64, f64)], x: f64, y: f64) -> f64 {
    let mut best = f64::MAX;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (ax, ay) = poly[j];
        let (bx, by) = poly[i];
        let (dx, dy) = (bx - ax, by - ay);
        let len2 = dx * dx + dy * dy;
        let t = if len2 == 0.0 {
            0.0
        } else {
            (((x - ax) * dx + (y - ay) * dy) / len2).clamp(0.0, 1.0)
        };
        let (px, py) = (ax + t * dx, ay + t * dy);
        best = best.min(((x - px).powi(2) + (y - py).powi(2)).sqrt());
        j = i;
    }
    best
}

/// The cursor as premultiplied BGRA (what UpdateLayeredWindow takes): a
/// `fill` arrow with an `outline` border, anti-aliased by 4x4 supersampling.
/// `scale` is pixels per arrow unit; the tip sits at `(pad, pad)`.
pub struct ArrowBitmap {
    pub width: usize,
    pub height: usize,
    /// Where the arrow's tip is inside the bitmap.
    pub tip: (usize, usize),
    pub bgra: Vec<u8>,
}

pub fn arrow_bitmap(scale: f64, fill: [u8; 3], outline: [u8; 3]) -> ArrowBitmap {
    let scale = scale.max(0.5);
    let border = 1.3;
    let pad = (border * scale).ceil() as usize + 1;
    let width = (ARROW_UNITS_W * scale).ceil() as usize + 2 * pad;
    let height = (ARROW_UNITS_H * scale).ceil() as usize + 2 * pad;
    let mut bgra = vec![0u8; width * height * 4];
    const SS: usize = 4;
    for py in 0..height {
        for px in 0..width {
            let (mut fill_n, mut line_n) = (0u32, 0u32);
            for sy in 0..SS {
                for sx in 0..SS {
                    let x = (px as f64 + (sx as f64 + 0.5) / SS as f64 - pad as f64) / scale;
                    let y = (py as f64 + (sy as f64 + 0.5) / SS as f64 - pad as f64) / scale;
                    let d = edge_distance(&ARROW, x, y);
                    if inside(&ARROW, x, y) && d > border * 0.5 {
                        fill_n += 1;
                    } else if inside(&ARROW, x, y) || d <= border {
                        line_n += 1;
                    }
                }
            }
            let total = (SS * SS) as u32;
            let a = (fill_n + line_n) * 255 / total;
            if a == 0 {
                continue;
            }
            // Premultiplied: each channel is its coverage-weighted sum.
            let mix = |c: usize| -> u8 {
                ((u32::from(fill[c]) * fill_n + u32::from(outline[c]) * line_n) / total) as u8
            };
            let i = (py * width + px) * 4;
            bgra[i] = mix(2);
            bgra[i + 1] = mix(1);
            bgra[i + 2] = mix(0);
            bgra[i + 3] = a as u8;
        }
    }
    ArrowBitmap { width, height, tip: (pad, pad), bgra }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_keys_map_to_virtual_keys() {
        assert_eq!(named_vk("return"), Some((0x0D, false)));
        assert_eq!(named_vk("left"), Some((0x25, true)));
        assert_eq!(named_vk("delete"), Some((0x2E, true)));
        assert_eq!(named_vk("page_down"), Some((0x22, true)));
        assert_eq!(named_vk("f1"), Some((0x70, false)));
        assert_eq!(named_vk("f24"), Some((0x87, false)));
        assert_eq!(named_vk("f25"), None);
        assert_eq!(named_vk("f0"), None);
        assert_eq!(named_vk("hyper"), None);
    }

    #[test]
    fn key_lparams_match_real_keyboard_messages() {
        // 'A' down: repeat 1, scan 0x1E.
        assert_eq!(key_lparam(0x1E, false, false, false), 0x001E_0001);
        // 'A' up: previous state and transition bits.
        assert_eq!(key_lparam(0x1E, false, false, true) as u32, 0xC01E_0001);
        // Left arrow (scan 0x4B) is extended.
        assert_eq!(key_lparam(0x4B, true, false, false), 0x014B_0001);
        // Alt context bit.
        assert_eq!(key_lparam(0x21, false, true, false), 0x2021_0001);
    }

    #[test]
    fn point_lparam_packs_signed_words() {
        assert_eq!(point_lparam(10, 20), (20 << 16) | 10);
        let l = point_lparam(-5, 7) as u32;
        assert_eq!(l & 0xFFFF, 0xFFFB);
        assert_eq!(l >> 16, 7);
    }

    #[test]
    fn wheel_params_and_deltas() {
        assert_eq!(wheel_wparam(-120, 0) as u32, 0xFF88_0000);
        assert_eq!(wheel_wparam(120, 0x0008) as u32, 0x0078_0008);
        // 3 lines per notch: 6 lines down is two notches of -120.
        assert_eq!(wheel_deltas(6.0, 3, true), vec![-120, -120]);
        // Up is positive.
        assert_eq!(wheel_deltas(-3.0, 3, true), vec![120]);
        // A partial notch is one smaller delta.
        assert_eq!(wheel_deltas(4.0, 3, true), vec![-120, -40]);
        // Horizontal: right is positive.
        assert_eq!(wheel_deltas(3.0, 3, false), vec![120]);
        assert_eq!(wheel_deltas(0.0, 3, true), Vec::<i16>::new());
        assert_eq!(wheel_deltas(f64::NAN, 3, true), Vec::<i16>::new());
        // A tiny scroll still sends something.
        assert_eq!(wheel_deltas(0.001, 3, true), vec![-1]);
    }

    #[test]
    fn line_breaks_become_enter() {
        assert_eq!(char_units("a\nb"), vec![97, 13, 98]);
        assert_eq!(char_units("a\r\nb"), vec![97, 13, 98]);
        // Astral characters are two UTF-16 units.
        assert_eq!(char_units("\u{1F600}").len(), 2);
    }

    #[test]
    fn absolute_input_spans_the_virtual_screen() {
        assert_eq!(absolute_input(0.0, 0.0, 0, 0, 1920, 1080), (0, 0));
        assert_eq!(absolute_input(1919.0, 1079.0, 0, 0, 1920, 1080), (65535, 65535));
        // A monitor left of the primary has negative coordinates.
        assert_eq!(absolute_input(-1920.0, 0.0, -1920, 0, 3840, 1080), (0, 0));
        assert_eq!(absolute_input(-5000.0, 0.0, -1920, 0, 3840, 1080).0, 0);
    }

    #[test]
    fn bgra_rows_with_padding_become_opaque_rgba() {
        // 1x2 image, stride 8 (4 bytes of padding per row).
        let bgra = [1, 2, 3, 0, 9, 9, 9, 9, 4, 5, 6, 0, 9, 9, 9, 9];
        assert_eq!(bgra_to_rgba(&bgra, 1, 2, 8), vec![3, 2, 1, 255, 6, 5, 4, 255]);
        assert!(all_black(&[0, 0, 0, 255, 0, 0, 0, 255]));
        assert!(!all_black(&[0, 0, 1, 255]));
    }

    #[test]
    fn crop_clips_to_the_image() {
        // 3x2 image; pixel value = index.
        let img: Vec<u8> = (0..6u8).flat_map(|i| [i, i, i, 255]).collect();
        let (out, w, h) = crop_rgba(&img, 3, 2, 1, 1, 5, 5);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out, vec![4, 4, 4, 255, 5, 5, 5, 255]);
        let (_, w, h) = crop_rgba(&img, 3, 2, 9, 9, 1, 1);
        assert_eq!((w, h), (0, 0));
    }

    #[test]
    fn roles_and_ids() {
        assert_eq!(role_for_control_type(50000), "button");
        assert_eq!(role_for_control_type(50004), "text_field");
        assert_eq!(role_for_control_type(50032), "window");
        assert_eq!(role_for_control_type(1), "unknown");
        assert_eq!(parse_element_id(&element_id(7, 42)), Some((7, 42)));
        assert_eq!(parse_element_id("7"), None);
        assert_eq!(parse_element_id("a.b"), None);
        assert_eq!(parse_window_id("132456"), Some(132456));
        assert_eq!(parse_window_id("0"), None);
        assert_eq!(parse_window_id("0x10"), None);
    }

    #[test]
    fn app_ids() {
        let aumid = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App";
        assert_eq!(parse_app_id(aumid), Ok(AppId::Aumid(aumid.into())));
        assert_eq!(
            parse_app_id(r"C:\Windows\notepad.exe"),
            Ok(AppId::Exe(r"C:\Windows\notepad.exe".into()))
        );
        assert_eq!(parse_app_id("notepad.exe"), Ok(AppId::Exe("notepad.exe".into())));
        assert_eq!(parse_app_id("notepad"), Ok(AppId::Exe("notepad.exe".into())));
        assert!(parse_app_id("ms-settings:privacy").is_err());
        assert!(parse_app_id("https://example.com").is_err());
        assert!(parse_app_id("evil.bat").is_err());
        assert!(parse_app_id(r"C:\x\run.ps1").is_err());
        assert!(parse_app_id(r"C:\Users\a\Desktop\App.lnk").is_err());
        assert!(parse_app_id("notepad.exe\" C:\\x").is_err());
        assert!(parse_app_id("").is_err());
        assert_eq!(exe_id(r"C:\Program Files\App\MyApp.EXE"), "myapp.exe");
        assert_eq!(exe_id("notepad.exe"), "notepad.exe");
        assert_eq!(exe_display_name(r"C:\Windows\notepad.exe"), "Notepad");
        assert_eq!(exe_display_name("tool"), "Tool");
    }

    #[test]
    fn own_input_is_told_apart_across_the_tick_wrap() {
        assert!(input_is_ours(1010, Some(1000), 50));
        assert!(!input_is_ours(1100, Some(1000), 50));
        assert!(!input_is_ours(1010, None, 50));
        // The person typed before our injection: theirs.
        assert!(!input_is_ours(990, Some(1000), 50));
        // Across the wrap.
        assert!(input_is_ours(5, Some(u32::MAX - 5), 50));
        assert_eq!(ticks_since(5, u32::MAX - 5), 11);
    }

    #[test]
    fn glide_eases_out_and_lands() {
        assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 0.0), (0.0, 0.0));
        assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 1.0), (100.0, 50.0));
        assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 7.0), (100.0, 50.0));
        // Ease-out: past halfway at half time.
        assert!(glide((0.0, 0.0), (100.0, 0.0), 0.5).0 > 80.0);
    }

    #[test]
    fn arrow_is_blue_inside_white_at_the_edge_and_clear_outside() {
        let blue = [0x0A, 0x84, 0xFF];
        let white = [0xFF, 0xFF, 0xFF];
        let a = arrow_bitmap(2.0, blue, white);
        let px = |x: usize, y: usize| {
            let i = (y * a.width + x) * 4;
            [a.bgra[i], a.bgra[i + 1], a.bgra[i + 2], a.bgra[i + 3]]
        };
        // Inside the body (units (3, 10)): opaque cmux blue, as BGRA.
        let (bx, by) = (a.tip.0 + 6, a.tip.1 + 20);
        assert_eq!(px(bx, by), [0xFF, 0x84, 0x0A, 0xFF]);
        // The tip is covered by the white outline.
        let tip = px(a.tip.0, a.tip.1);
        assert!(tip[3] > 0 && tip[0] > 0xC0 && tip[1] > 0xC0 && tip[2] > 0xC0);
        // Far right of the top rows is clear.
        assert_eq!(px(a.width - 1, 0)[3], 0);
        // Premultiplied: no channel exceeds alpha.
        assert!(a.bgra.chunks_exact(4).all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]));
    }
}

#[cfg(test)]
mod launch_identity_tests {
    use super::launch_identities;

    #[test]
    fn every_spelling_of_a_program_is_one_identity() {
        for id in ["cmd", "CMD.EXE", "C:\\Windows\\System32\\cmd.exe", "\\\\host\\share\\Cmd.exe"] {
            assert_eq!(launch_identities(id).unwrap(), vec!["cmd.exe".to_string()], "{id}");
        }
        assert!(launch_identities("ms-settings:privacy").is_err());
    }
}
