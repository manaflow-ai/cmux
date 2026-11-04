//! Viewer input as local CGEvents posted at the HID level, so the Mac handles them like its
//! own keyboard and mouse. Pointer positions are stream pixels mapped onto the captured
//! display's global points; keys arrive as USB HID usages (layout independent) and leave
//! as virtual key codes; held keys and buttons are tracked so control can end cleanly.

use super::capture::Bounds;
use super::keys::{key_code, modifier_flag};
use super::sys::{self, cf, cg, event_type, CGEventFlags, CGEventRef, CGKeyCode, CGPoint};
use crate::Res;
use cmux_rd_proto::InputEvent;
use std::collections::BTreeSet;

/// A CGEvent this code created, released on drop.
struct Event(CGEventRef);

impl Event {
    fn new(event: CGEventRef) -> Option<Self> {
        (!event.is_null()).then_some(Self(event))
    }

    /// Posts the event at the HID level with `flags`.
    fn post(&self, flags: CGEventFlags) {
        // SAFETY: a live event this value owns.
        unsafe {
            cg::CGEventSetFlags(self.0, flags.0);
            cg::CGEventPost(sys::TAP_HID, self.0);
        }
    }

    fn set_field(&self, field: u32, value: i64) {
        // SAFETY: a live event this value owns.
        unsafe { cg::CGEventSetIntegerValueField(self.0, field, value) }
    }
}

impl Drop for Event {
    fn drop(&mut self) {
        // SAFETY: the reference CGEventCreate* returned.
        unsafe { cf::CFRelease(self.0.cast_const()) }
    }
}

/// The modifier flags of the held keys (left and right of a modifier set the same flag).
fn held_flags(keys: &BTreeSet<CGKeyCode>) -> CGEventFlags {
    keys.iter().filter_map(|&code| modifier_flag(code)).fold(CGEventFlags::empty(), |a, b| a | b)
}
use std::time::{Duration, Instant};

/// Two presses of one button closer than this, and nearer than [`MULTI_CLICK_SLOP`] points,
/// count as a double (or triple) click.
const MULTI_CLICK_INTERVAL: Duration = Duration::from_millis(500);
const MULTI_CLICK_SLOP: f64 = 4.0;
/// CGEvent carries at most 20 UTF-16 units of text per event.
const TEXT_UNITS_PER_EVENT: usize = 20;

/// A wire button (1 left, 2 middle, 3 right, 8 back, 9 forward) as a CGEvent button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Button {
    Left,
    Right,
    /// CGEvent's other buttons by number: 2 middle, 3 back, 4 forward.
    Other(i64),
}

impl Button {
    fn from_wire(button: u8) -> Option<Self> {
        Some(match button {
            // 0 is what some test viewers send for the primary button.
            0 | 1 => Self::Left,
            2 => Self::Other(2),
            3 => Self::Right,
            8 => Self::Other(3),
            9 => Self::Other(4),
            _ => return None,
        })
    }

    /// Its down, up and dragged CGEventTypes and its CGMouseButton.
    fn events(self) -> (u32, u32, u32, u32) {
        match self {
            Self::Left => (
                event_type::LEFT_MOUSE_DOWN,
                event_type::LEFT_MOUSE_UP,
                event_type::LEFT_MOUSE_DRAGGED,
                sys::MOUSE_BUTTON_LEFT,
            ),
            Self::Right => (
                event_type::RIGHT_MOUSE_DOWN,
                event_type::RIGHT_MOUSE_UP,
                event_type::RIGHT_MOUSE_DRAGGED,
                sys::MOUSE_BUTTON_RIGHT,
            ),
            Self::Other(_) => (
                event_type::OTHER_MOUSE_DOWN,
                event_type::OTHER_MOUSE_UP,
                event_type::OTHER_MOUSE_DRAGGED,
                sys::MOUSE_BUTTON_CENTER,
            ),
        }
    }
}

pub struct Injector {
    /// The HID-state event source (a CGEventSourceRef, released on drop).
    source: sys::CGEventSourceRef,
    bounds: Bounds,
    /// Stream pixels per display point.
    scale: (f64, f64),
    point: CGPoint,
    keys: BTreeSet<CGKeyCode>,
    buttons: BTreeSet<Button>,
    flags: CGEventFlags,
    /// The last press: when, which button, where, and its click count.
    last_press: Option<(Instant, Button, CGPoint, i64)>,
    /// Fractions of a line or point not yet posted.
    scroll_rest: (i32, i32),
}

impl Injector {
    pub fn new(bounds: Bounds, size: (u32, u32)) -> Res<Self> {
        sys::load()?;
        // SAFETY: creates an event source this injector owns (released on drop).
        let source = unsafe { cg::CGEventSourceCreate(sys::SOURCE_STATE_HID_SYSTEM) };
        if source.is_null() {
            return Err("no CGEvent source (is Accessibility allowed?)".into());
        }
        Ok(Self {
            source,
            bounds,
            scale: (
                f64::from(size.0) / bounds.width.max(1.0),
                f64::from(size.1) / bounds.height.max(1.0),
            ),
            point: CGPoint::new(bounds.x, bounds.y),
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            flags: CGEventFlags::empty(),
            last_press: None,
            scroll_rest: (0, 0),
        })
    }

    pub fn apply(&mut self, event: &InputEvent) {
        match event {
            InputEvent::Pointer { x, y } => {
                self.point = self.to_display(*x, *y);
                // A move with a button held is a drag of the first held button.
                let kind = match self.buttons.iter().next() {
                    Some(button) => button.events().2,
                    None => event_type::MOUSE_MOVED,
                };
                let button = self.buttons.iter().next().copied();
                self.mouse(kind, button, None);
            }
            InputEvent::Button { button, down } => {
                if let Some(button) = Button::from_wire(*button) {
                    self.button(button, *down);
                }
            }
            InputEvent::Scroll { dx, dy, precise } => self.scroll(*dx, *dy, *precise),
            InputEvent::Key { usage, down } => self.key(*usage, *down),
            InputEvent::Text(text) => self.text(text),
            // Desktop sessions do not offer the input.service cap.
            InputEvent::Service { .. } => {}
        }
    }

    pub fn release_all(&mut self) {
        // Each up carries the flags of the keys still held after it, so no modifier stays set.
        while let Some(code) = self.keys.pop_last() {
            self.flags = held_flags(&self.keys);
            self.post_key(code, false);
        }
        for button in std::mem::take(&mut self.buttons) {
            self.mouse(button.events().1, Some(button), None);
        }
    }

    fn to_display(&self, x: i32, y: i32) -> CGPoint {
        let b = self.bounds;
        let px = (f64::from(x) / self.scale.0).clamp(0.0, b.width - 1.0);
        let py = (f64::from(y) / self.scale.1).clamp(0.0, b.height - 1.0);
        CGPoint::new(b.x + px, b.y + py)
    }

    fn mouse(&self, kind: u32, button: Option<Button>, clicks: Option<i64>) {
        let cg_button = button.map_or(sys::MOUSE_BUTTON_LEFT, |b| b.events().3);
        // SAFETY: a live source; the event is released by `Event`.
        let created =
            unsafe { cg::CGEventCreateMouseEvent(self.source, kind, self.point, cg_button) };
        let Some(event) = Event::new(created) else { return };
        if let Some(Button::Other(number)) = button {
            event.set_field(sys::FIELD_MOUSE_EVENT_BUTTON_NUMBER, number);
        }
        if let Some(count) = clicks {
            event.set_field(sys::FIELD_MOUSE_EVENT_CLICK_STATE, count);
        }
        event.post(self.flags);
    }

    fn button(&mut self, button: Button, down: bool) {
        let (press, release, _, _) = button.events();
        if down {
            let now = Instant::now();
            let count = match self.last_press {
                Some((at, last, point, count))
                    if last == button
                        && now.duration_since(at) < MULTI_CLICK_INTERVAL
                        && (point.x - self.point.x).abs() <= MULTI_CLICK_SLOP
                        && (point.y - self.point.y).abs() <= MULTI_CLICK_SLOP =>
                {
                    count + 1
                }
                _ => 1,
            };
            self.last_press = Some((now, button, self.point, count));
            self.buttons.insert(button);
            self.mouse(press, Some(button), Some(count));
        } else if self.buttons.remove(&button) {
            let count = self.last_press.map_or(1, |(_, _, _, count)| count);
            self.mouse(release, Some(button), Some(count));
        }
    }

    /// Hundredths of a line, or of a point when `precise`, in AppKit's sign; fractions carry
    /// to the next event.
    fn scroll(&mut self, dx: i32, dy: i32, precise: bool) {
        let x = self.scroll_rest.0.saturating_add(dx);
        let y = self.scroll_rest.1.saturating_add(dy);
        self.scroll_rest = (x % 100, y % 100);
        let (whole_x, whole_y) = (x / 100, y / 100);
        if whole_x == 0 && whole_y == 0 {
            return;
        }
        let unit = if precise { sys::SCROLL_UNIT_PIXEL } else { sys::SCROLL_UNIT_LINE };
        // SAFETY: a live source; the event is released by `Event`.
        let created = unsafe {
            cg::CGEventCreateScrollWheelEvent2(self.source, unit, 2, whole_y, whole_x, 0)
        };
        if let Some(event) = Event::new(created) {
            event.post(self.flags);
        }
    }

    fn key(&mut self, usage: u32, down: bool) {
        let Some(code) = key_code(usage) else { return };
        if down {
            self.keys.insert(code);
        } else if !self.keys.remove(&code) {
            // An up for a key this session never pressed (released already).
            return;
        }
        // From the held keys, so releasing one Shift keeps the other's flag.
        self.flags = held_flags(&self.keys);
        self.post_key(code, down);
    }

    fn post_key(&self, code: CGKeyCode, down: bool) {
        // SAFETY: a live source; the event is released by `Event`.
        let created = unsafe { cg::CGEventCreateKeyboardEvent(self.source, code, down) };
        if let Some(event) = Event::new(created) {
            event.post(self.flags);
        }
    }

    /// Committed IME text, typed as Unicode strings (never split inside a character).
    fn text(&self, text: &str) {
        let mut units: Vec<u16> = Vec::with_capacity(TEXT_UNITS_PER_EVENT);
        let mut buf = [0u16; 2];
        for ch in text.chars() {
            let encoded = ch.encode_utf16(&mut buf);
            if units.len() + encoded.len() > TEXT_UNITS_PER_EVENT {
                self.post_text(&units);
                units.clear();
            }
            units.extend_from_slice(encoded);
        }
        if !units.is_empty() {
            self.post_text(&units);
        }
    }

    fn post_text(&self, units: &[u16]) {
        for down in [true, false] {
            // SAFETY: a live source; the event is released by `Event`, and `units` outlives
            // the call that copies them.
            unsafe {
                let Some(event) = Event::new(cg::CGEventCreateKeyboardEvent(self.source, 0, down))
                else {
                    continue;
                };
                cg::CGEventKeyboardSetUnicodeString(event.0, units.len(), units.as_ptr());
                event.post(CGEventFlags::empty());
            }
        }
    }
}

impl Drop for Injector {
    fn drop(&mut self) {
        // SAFETY: the source CGEventSourceCreate returned.
        unsafe { cf::CFRelease(self.source.cast_const()) }
    }
}

// SAFETY: the event source is only used from the session's thread that owns the injector.
unsafe impl Send for Injector {}
