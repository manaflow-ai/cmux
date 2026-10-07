//! USB HID keyboard usages (page 7) to Linux evdev key codes; X keycodes are evdev + 8.

/// HID usage `0x0007_00ii` to an evdev key code.
pub fn hid_to_evdev(usage: u32) -> Option<u16> {
    if usage >> 16 != 0x07 {
        return None;
    }
    let id = usage & 0xffff;
    const LETTERS: [u16; 26] = [
        30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17,
        45, 21, 44,
    ];
    Some(match id {
        0x04..=0x1d => LETTERS[(id - 0x04) as usize],
        0x1e..=0x26 => (id - 0x1e + 2) as u16,
        0x27 => 11,
        0x28 => 28,
        0x29 => 1,
        0x2a => 14,
        0x2b => 15,
        0x2c => 57,
        0x2d => 12,
        0x2e => 13,
        0x2f => 26,
        0x30 => 27,
        0x31 => 43,
        0x33 => 39,
        0x34 => 40,
        0x35 => 41,
        0x36 => 51,
        0x37 => 52,
        0x38 => 53,
        0x39 => 58,
        0x3a..=0x43 => (id - 0x3a + 59) as u16,
        0x44 => 87,
        0x45 => 88,
        0x49 => 110,
        0x4a => 102,
        0x4b => 104,
        0x4c => 111,
        0x4d => 107,
        0x4e => 109,
        0x4f => 106,
        0x50 => 105,
        0x51 => 108,
        0x52 => 103,
        0xe0 => 29,
        0xe1 => 42,
        0xe2 => 56,
        0xe3 => 125,
        0xe4 => 97,
        0xe5 => 54,
        0xe6 => 100,
        0xe7 => 126,
        _ => return None,
    })
}

/// HID usage to an X keycode.
pub fn hid_to_x(usage: u32) -> Option<u8> {
    hid_to_evdev(usage).and_then(|e| u8::try_from(e + 8).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_digits_and_modifiers() {
        assert_eq!(hid_to_x(0x0007_0004), Some(38)); // a
        assert_eq!(hid_to_x(0x0007_001d), Some(52)); // z
        assert_eq!(hid_to_x(0x0007_001e), Some(10)); // 1
        assert_eq!(hid_to_x(0x0007_0027), Some(19)); // 0
        assert_eq!(hid_to_x(0x0007_00e0), Some(37)); // left control
        assert_eq!(hid_to_x(0x0007_0045), Some(96)); // F12
        assert_eq!(hid_to_x(0x000c_00e9), None); // consumer page
    }
}
