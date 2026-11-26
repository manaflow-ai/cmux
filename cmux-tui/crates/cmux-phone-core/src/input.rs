//! Live input rules (Swift `PhoneKeyboard`, `PhoneGesture`,
//! `PhoneScreenMapping`): typed text as US HID usages, taps and swipes as
//! paced touches, and where a phone screen sits in its tab.
use serde::{Deserialize, Serialize};

/// One key press on the simulator's hardware keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyStroke {
    pub usage: u32,
    #[serde(default)]
    pub shift: bool,
}

const SHIFTED_DIGITS: [char; 10] = ['!', '@', '#', '$', '%', '^', '&', '*', '(', ')'];
const PUNCTUATION: [(char, char, u32); 11] = [
    ('-', '_', 0x2D),
    ('=', '+', 0x2E),
    ('[', '{', 0x2F),
    (']', '}', 0x30),
    ('\\', '|', 0x31),
    (';', ':', 0x33),
    ('\'', '"', 0x34),
    ('`', '~', 0x35),
    (',', '<', 0x36),
    ('.', '>', 0x37),
    ('/', '?', 0x38),
];
// kVK_* codes (Carbon Events.h) to HID usages.
const MAC_KEY_CODES: &[(u16, u32)] = &[
    (0, 0x04),
    (11, 0x05),
    (8, 0x06),
    (2, 0x07),
    (14, 0x08),
    (3, 0x09),
    (5, 0x0A),
    (4, 0x0B),
    (34, 0x0C),
    (38, 0x0D),
    (40, 0x0E),
    (37, 0x0F),
    (46, 0x10),
    (45, 0x11),
    (31, 0x12),
    (35, 0x13),
    (12, 0x14),
    (15, 0x15),
    (1, 0x16),
    (17, 0x17),
    (32, 0x18),
    (9, 0x19),
    (13, 0x1A),
    (7, 0x1B),
    (16, 0x1C),
    (6, 0x1D),
    (18, 0x1E),
    (19, 0x1F),
    (20, 0x20),
    (21, 0x21),
    (23, 0x22),
    (22, 0x23),
    (26, 0x24),
    (28, 0x25),
    (25, 0x26),
    (29, 0x27),
    (36, 0x28),
    (53, 0x29),
    (51, 0x2A),
    (48, 0x2B),
    (49, 0x2C),
    (27, 0x2D),
    (24, 0x2E),
    (33, 0x2F),
    (30, 0x30),
    (42, 0x31),
    (41, 0x33),
    (39, 0x34),
    (50, 0x35),
    (43, 0x36),
    (47, 0x37),
    (44, 0x38),
    (117, 0x4C),
    (124, 0x4F),
    (123, 0x50),
    (125, 0x51),
    (126, 0x52),
];

/// The key stroke of one character on a US layout; None when it has no key.
pub fn stroke(ch: char) -> Option<KeyStroke> {
    let value = ch as u32;
    let plain = |usage| Some(KeyStroke { usage, shift: false });
    let shifted = |usage| Some(KeyStroke { usage, shift: true });
    match ch {
        'a'..='z' => return plain(0x04 + value - 0x61),
        'A'..='Z' => return shifted(0x04 + value - 0x41),
        '1'..='9' => return plain(0x1E + value - 0x31),
        '0' => return plain(0x27),
        '\n' | '\r' => return plain(0x28),
        '\t' => return plain(0x2B),
        ' ' => return plain(0x2C),
        _ => {}
    }
    if let Some(index) = SHIFTED_DIGITS.iter().position(|digit| *digit == ch) {
        return shifted(if index == 9 { 0x27 } else { 0x1E + index as u32 });
    }
    PUNCTUATION.iter().find_map(|(plain_char, shifted_char, usage)| {
        if ch == *plain_char {
            plain(*usage)
        } else if ch == *shifted_char {
            shifted(*usage)
        } else {
            None
        }
    })
}

/// The key strokes that type `text` (one per Unicode scalar), or None when a
/// character has no US key (the backend then pastes the text instead).
pub fn strokes(text: &str) -> Option<Vec<KeyStroke>> {
    text.chars().map(stroke).collect()
}

/// The HID usage for a Mac virtual key code (`NSEvent.keyCode`); None for
/// keys the simulator has no use for.
pub fn usage_for_mac_key_code(code: u16) -> Option<u32> {
    MAC_KEY_CODES.iter().find(|(key, _)| *key == code).map(|(_, usage)| *usage)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TouchPhase {
    Began,
    Moved,
    Ended,
}

/// One touch, normalized to the screen (0...1, top-left origin), at a time
/// offset in microseconds from the gesture's start.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Touch {
    pub phase: TouchPhase,
    pub x: f64,
    pub y: f64,
    pub offset_micros: i64,
}

pub const SHORTEST_SWIPE: f64 = 0.05;
pub const DEFAULT_SWIPE: f64 = 0.3;

/// The touch error the app shows: "that point is outside the phone's screen".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutsideScreen;

fn normalized(screen: (f64, f64), point: (f64, f64)) -> Option<(f64, f64)> {
    if !(screen.0 > 0.0 && screen.1 > 0.0) {
        return None;
    }
    let (x, y) = (point.0 / screen.0, point.1 / screen.1);
    ((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y)).then_some((x, y))
}

/// Down, then up 50 ms later (shorter reads as no touch to some UIKit controls).
pub fn tap(screen: (f64, f64), point: (f64, f64)) -> Result<Vec<Touch>, OutsideScreen> {
    let (x, y) = normalized(screen, point).ok_or(OutsideScreen)?;
    Ok(vec![
        Touch { phase: TouchPhase::Began, x, y, offset_micros: 0 },
        Touch { phase: TouchPhase::Ended, x, y, offset_micros: 50_000 },
    ])
}

/// Down at `from`, one move per 16 ms frame, up at `to` after `seconds`.
pub fn swipe(
    screen: (f64, f64),
    from: (f64, f64),
    to: (f64, f64),
    seconds: f64,
) -> Result<Vec<Touch>, OutsideScreen> {
    let start = normalized(screen, from).ok_or(OutsideScreen)?;
    let end = normalized(screen, to).ok_or(OutsideScreen)?;
    // A gesture's length (input timing the caller chose), not an animation.
    let duration = SHORTEST_SWIPE.max(if seconds.is_finite() { seconds } else { DEFAULT_SWIPE });
    let steps = 2.max((duration / 0.016) as i64);
    let mut touches =
        vec![Touch { phase: TouchPhase::Began, x: start.0, y: start.1, offset_micros: 0 }];
    for step in 1..steps {
        let t = step as f64 / steps as f64;
        touches.push(Touch {
            phase: TouchPhase::Moved,
            x: start.0 + (end.0 - start.0) * t,
            y: start.1 + (end.1 - start.1) * t,
            offset_micros: (duration * 1_000_000.0 * t) as i64,
        });
    }
    touches.push(Touch {
        phase: TouchPhase::Ended,
        x: end.0,
        y: end.1,
        offset_micros: ((duration * 1000.0).round() as i64) * 1000,
    });
    Ok(touches)
}

/// A rectangle in AppKit coordinates (bottom-left origin).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };
}

/// The rectangle a `screen` (points) fills inside a `view`: aspect fit, centered.
pub fn drawn_rect(screen: (f64, f64), view: (f64, f64)) -> Rect {
    if !(screen.0 > 0.0 && screen.1 > 0.0 && view.0 > 0.0 && view.1 > 0.0) {
        return Rect::ZERO;
    }
    let scale = (view.0 / screen.0).min(view.1 / screen.1);
    let (width, height) = (screen.0 * scale, screen.1 * scale);
    Rect { x: (view.0 - width) / 2.0, y: (view.1 - height) / 2.0, width, height }
}

/// A view point as 0...1 screen coordinates with a top-left origin; None outside the screen.
pub fn normalized_view_point(
    screen: (f64, f64),
    view: (f64, f64),
    point: (f64, f64),
) -> Option<(f64, f64)> {
    let rect = drawn_rect(screen, view);
    if !(rect.width > 0.0 && rect.height > 0.0) {
        return None;
    }
    let x = (point.0 - rect.x) / rect.width;
    let y = (rect.y + rect.height - point.1) / rect.height;
    ((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y)).then_some((x, y))
}

/// A view point in phone points; None outside the screen.
pub fn device_point(screen: (f64, f64), view: (f64, f64), point: (f64, f64)) -> Option<(f64, f64)> {
    normalized_view_point(screen, view, point).map(|(x, y)| (x * screen.0, y * screen.1))
}
