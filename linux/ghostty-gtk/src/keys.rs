//! GDK keyval → ghostty_input_key_e conversion table.
//!
//! This is a port of ghostty's `src/apprt/gtk/key.zig` mapping table.

use ghostty_sys::ghostty_input_key_e::{self, *};

/// Convert a GDK keyval (u32) to a ghostty key code.
///
/// Returns `None` if the keyval has no ghostty equivalent.
pub fn gdk_keyval_to_ghostty(keyval: u32) -> Option<ghostty_input_key_e> {
    // GDK key constants (from gdk/gdkkeysyms.h)
    // We use raw u32 values to avoid API differences between gtk4-rs versions.
    let ghostty_key = match keyval {
        // Writing System Keys
        0x0060 | 0xfe50 => GHOSTTY_KEY_BACKQUOTE, // grave | dead_grave
        0x005c => GHOSTTY_KEY_BACKSLASH,
        0x005b => GHOSTTY_KEY_BRACKET_LEFT,
        0x005d => GHOSTTY_KEY_BRACKET_RIGHT,
        0x002c => GHOSTTY_KEY_COMMA,
        0x0030 => GHOSTTY_KEY_DIGIT_0,
        0x0031 => GHOSTTY_KEY_DIGIT_1,
        0x0032 => GHOSTTY_KEY_DIGIT_2,
        0x0033 => GHOSTTY_KEY_DIGIT_3,
        0x0034 => GHOSTTY_KEY_DIGIT_4,
        0x0035 => GHOSTTY_KEY_DIGIT_5,
        0x0036 => GHOSTTY_KEY_DIGIT_6,
        0x0037 => GHOSTTY_KEY_DIGIT_7,
        0x0038 => GHOSTTY_KEY_DIGIT_8,
        0x0039 => GHOSTTY_KEY_DIGIT_9,
        0x003d => GHOSTTY_KEY_EQUAL,
        0x0061 | 0x0041 => GHOSTTY_KEY_A,
        0x0062 | 0x0042 => GHOSTTY_KEY_B,
        0x0063 | 0x0043 => GHOSTTY_KEY_C,
        0x0064 | 0x0044 => GHOSTTY_KEY_D,
        0x0065 | 0x0045 => GHOSTTY_KEY_E,
        0x0066 | 0x0046 => GHOSTTY_KEY_F,
        0x0067 | 0x0047 => GHOSTTY_KEY_G,
        0x0068 | 0x0048 => GHOSTTY_KEY_H,
        0x0069 | 0x0049 => GHOSTTY_KEY_I,
        0x006a | 0x004a => GHOSTTY_KEY_J,
        0x006b | 0x004b => GHOSTTY_KEY_K,
        0x006c | 0x004c => GHOSTTY_KEY_L,
        0x006d | 0x004d => GHOSTTY_KEY_M,
        0x006e | 0x004e => GHOSTTY_KEY_N,
        0x006f | 0x004f => GHOSTTY_KEY_O,
        0x0070 | 0x0050 => GHOSTTY_KEY_P,
        0x0071 | 0x0051 => GHOSTTY_KEY_Q,
        0x0072 | 0x0052 => GHOSTTY_KEY_R,
        0x0073 | 0x0053 => GHOSTTY_KEY_S,
        0x0074 | 0x0054 => GHOSTTY_KEY_T,
        0x0075 | 0x0055 => GHOSTTY_KEY_U,
        0x0076 | 0x0056 => GHOSTTY_KEY_V,
        0x0077 | 0x0057 => GHOSTTY_KEY_W,
        0x0078 | 0x0058 => GHOSTTY_KEY_X,
        0x0079 | 0x0059 => GHOSTTY_KEY_Y,
        0x007a | 0x005a => GHOSTTY_KEY_Z,
        0x002d => GHOSTTY_KEY_MINUS,
        0x002e => GHOSTTY_KEY_PERIOD,
        0x0027 => GHOSTTY_KEY_QUOTE, // apostrophe
        0x003b => GHOSTTY_KEY_SEMICOLON,
        0x002f => GHOSTTY_KEY_SLASH,

        // Functional Keys
        0xffe9 => GHOSTTY_KEY_ALT_LEFT,            // Alt_L
        0xffea => GHOSTTY_KEY_ALT_RIGHT,           // Alt_R
        0xff08 => GHOSTTY_KEY_BACKSPACE,           // BackSpace
        0xffe5 => GHOSTTY_KEY_CAPS_LOCK,           // Caps_Lock
        0xff67 => GHOSTTY_KEY_CONTEXT_MENU,        // Menu
        0xffe3 => GHOSTTY_KEY_CONTROL_LEFT,        // Control_L
        0xffe4 => GHOSTTY_KEY_CONTROL_RIGHT,       // Control_R
        0xff0d => GHOSTTY_KEY_ENTER,               // Return
        0xffe7 | 0xffeb => GHOSTTY_KEY_META_LEFT,  // Meta_L | Super_L
        0xffe8 | 0xffec => GHOSTTY_KEY_META_RIGHT, // Meta_R | Super_R
        0xffe1 => GHOSTTY_KEY_SHIFT_LEFT,          // Shift_L
        0xffe2 => GHOSTTY_KEY_SHIFT_RIGHT,         // Shift_R
        0x0020 => GHOSTTY_KEY_SPACE,               // space
        0xff09 | 0xfe20 => GHOSTTY_KEY_TAB,        // Tab | ISO_Left_Tab

        // Control Pad Section
        0xffff => GHOSTTY_KEY_DELETE,
        0xff57 => GHOSTTY_KEY_END,
        0xff6a => GHOSTTY_KEY_HELP,
        0xff50 => GHOSTTY_KEY_HOME,
        0xff63 => GHOSTTY_KEY_INSERT,
        0xff56 => GHOSTTY_KEY_PAGE_DOWN,
        0xff55 => GHOSTTY_KEY_PAGE_UP,

        // Arrow Pad Section
        0xff54 => GHOSTTY_KEY_ARROW_DOWN,
        0xff51 => GHOSTTY_KEY_ARROW_LEFT,
        0xff53 => GHOSTTY_KEY_ARROW_RIGHT,
        0xff52 => GHOSTTY_KEY_ARROW_UP,

        // Numpad Section
        0xff7f => GHOSTTY_KEY_NUM_LOCK,
        0xffb0 => GHOSTTY_KEY_NUMPAD_0,
        0xffb1 => GHOSTTY_KEY_NUMPAD_1,
        0xffb2 => GHOSTTY_KEY_NUMPAD_2,
        0xffb3 => GHOSTTY_KEY_NUMPAD_3,
        0xffb4 => GHOSTTY_KEY_NUMPAD_4,
        0xffb5 => GHOSTTY_KEY_NUMPAD_5,
        0xffb6 => GHOSTTY_KEY_NUMPAD_6,
        0xffb7 => GHOSTTY_KEY_NUMPAD_7,
        0xffb8 => GHOSTTY_KEY_NUMPAD_8,
        0xffb9 => GHOSTTY_KEY_NUMPAD_9,
        0xffab => GHOSTTY_KEY_NUMPAD_ADD,
        0xffac => GHOSTTY_KEY_NUMPAD_COMMA, // KP_Separator
        0xffae => GHOSTTY_KEY_NUMPAD_DECIMAL,
        0xffaf => GHOSTTY_KEY_NUMPAD_DIVIDE,
        0xff8d => GHOSTTY_KEY_NUMPAD_ENTER,
        0xffbd => GHOSTTY_KEY_NUMPAD_EQUAL,
        0xffaa => GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0xffad => GHOSTTY_KEY_NUMPAD_SUBTRACT,

        // Function Keys
        0xff1b => GHOSTTY_KEY_ESCAPE,
        0xffbe => GHOSTTY_KEY_F1,
        0xffbf => GHOSTTY_KEY_F2,
        0xffc0 => GHOSTTY_KEY_F3,
        0xffc1 => GHOSTTY_KEY_F4,
        0xffc2 => GHOSTTY_KEY_F5,
        0xffc3 => GHOSTTY_KEY_F6,
        0xffc4 => GHOSTTY_KEY_F7,
        0xffc5 => GHOSTTY_KEY_F8,
        0xffc6 => GHOSTTY_KEY_F9,
        0xffc7 => GHOSTTY_KEY_F10,
        0xffc8 => GHOSTTY_KEY_F11,
        0xffc9 => GHOSTTY_KEY_F12,
        0xffca => GHOSTTY_KEY_F13,
        0xffcb => GHOSTTY_KEY_F14,
        0xffcc => GHOSTTY_KEY_F15,
        0xffcd => GHOSTTY_KEY_F16,
        0xffce => GHOSTTY_KEY_F17,
        0xffcf => GHOSTTY_KEY_F18,
        0xffd0 => GHOSTTY_KEY_F19,
        0xffd1 => GHOSTTY_KEY_F20,
        0xffd2 => GHOSTTY_KEY_F21,
        0xffd3 => GHOSTTY_KEY_F22,
        0xffd4 => GHOSTTY_KEY_F23,
        0xffd5 => GHOSTTY_KEY_F24,
        0xffd6 => GHOSTTY_KEY_F25,
        0xff61 => GHOSTTY_KEY_PRINT_SCREEN,
        0xff14 => GHOSTTY_KEY_SCROLL_LOCK,
        0xff13 => GHOSTTY_KEY_PAUSE,

        _ => return None,
    };

    Some(ghostty_key)
}

/// Convert GDK modifier state to ghostty modifier flags.
pub fn gdk_mods_to_ghostty(state: gdk4::ModifierType) -> u32 {
    let mut mods = 0u32;

    if state.contains(gdk4::ModifierType::SHIFT_MASK) {
        mods |= ghostty_sys::ghostty_input_mods_e::GHOSTTY_MODS_SHIFT as u32;
    }
    if state.contains(gdk4::ModifierType::CONTROL_MASK) {
        mods |= ghostty_sys::ghostty_input_mods_e::GHOSTTY_MODS_CTRL as u32;
    }
    if state.contains(gdk4::ModifierType::ALT_MASK) {
        mods |= ghostty_sys::ghostty_input_mods_e::GHOSTTY_MODS_ALT as u32;
    }
    if state.contains(gdk4::ModifierType::SUPER_MASK) {
        mods |= ghostty_sys::ghostty_input_mods_e::GHOSTTY_MODS_SUPER as u32;
    }
    if state.contains(gdk4::ModifierType::LOCK_MASK) {
        mods |= ghostty_sys::ghostty_input_mods_e::GHOSTTY_MODS_CAPS as u32;
    }

    mods
}

/// Convert a GDK mouse button number to ghostty mouse button.
pub fn gdk_button_to_ghostty(button: u32) -> ghostty_sys::ghostty_input_mouse_button_e {
    use ghostty_sys::ghostty_input_mouse_button_e::*;
    match button {
        1 => GHOSTTY_MOUSE_LEFT,
        2 => GHOSTTY_MOUSE_MIDDLE,
        3 => GHOSTTY_MOUSE_RIGHT,
        4 => GHOSTTY_MOUSE_FOUR,
        5 => GHOSTTY_MOUSE_FIVE,
        6 => GHOSTTY_MOUSE_SIX,
        7 => GHOSTTY_MOUSE_SEVEN,
        8 => GHOSTTY_MOUSE_EIGHT,
        _ => GHOSTTY_MOUSE_UNKNOWN,
    }
}

/// Get the hardware keycode mapping for physical key translation.
/// This maps X11/evdev keycodes to ghostty physical keys.
pub fn hardware_keycode_to_ghostty(keycode: u32) -> Option<ghostty_input_key_e> {
    // evdev keycodes (X11 keycode = evdev + 8)
    let evdev_code = if keycode >= 8 {
        keycode - 8
    } else {
        return None;
    };

    let key = match evdev_code {
        1 => GHOSTTY_KEY_ESCAPE,
        2 => GHOSTTY_KEY_DIGIT_1,
        3 => GHOSTTY_KEY_DIGIT_2,
        4 => GHOSTTY_KEY_DIGIT_3,
        5 => GHOSTTY_KEY_DIGIT_4,
        6 => GHOSTTY_KEY_DIGIT_5,
        7 => GHOSTTY_KEY_DIGIT_6,
        8 => GHOSTTY_KEY_DIGIT_7,
        9 => GHOSTTY_KEY_DIGIT_8,
        10 => GHOSTTY_KEY_DIGIT_9,
        11 => GHOSTTY_KEY_DIGIT_0,
        12 => GHOSTTY_KEY_MINUS,
        13 => GHOSTTY_KEY_EQUAL,
        14 => GHOSTTY_KEY_BACKSPACE,
        15 => GHOSTTY_KEY_TAB,
        16 => GHOSTTY_KEY_Q,
        17 => GHOSTTY_KEY_W,
        18 => GHOSTTY_KEY_E,
        19 => GHOSTTY_KEY_R,
        20 => GHOSTTY_KEY_T,
        21 => GHOSTTY_KEY_Y,
        22 => GHOSTTY_KEY_U,
        23 => GHOSTTY_KEY_I,
        24 => GHOSTTY_KEY_O,
        25 => GHOSTTY_KEY_P,
        26 => GHOSTTY_KEY_BRACKET_LEFT,
        27 => GHOSTTY_KEY_BRACKET_RIGHT,
        28 => GHOSTTY_KEY_ENTER,
        29 => GHOSTTY_KEY_CONTROL_LEFT,
        30 => GHOSTTY_KEY_A,
        31 => GHOSTTY_KEY_S,
        32 => GHOSTTY_KEY_D,
        33 => GHOSTTY_KEY_F,
        34 => GHOSTTY_KEY_G,
        35 => GHOSTTY_KEY_H,
        36 => GHOSTTY_KEY_J,
        37 => GHOSTTY_KEY_K,
        38 => GHOSTTY_KEY_L,
        39 => GHOSTTY_KEY_SEMICOLON,
        40 => GHOSTTY_KEY_QUOTE,
        41 => GHOSTTY_KEY_BACKQUOTE,
        42 => GHOSTTY_KEY_SHIFT_LEFT,
        43 => GHOSTTY_KEY_BACKSLASH,
        44 => GHOSTTY_KEY_Z,
        45 => GHOSTTY_KEY_X,
        46 => GHOSTTY_KEY_C,
        47 => GHOSTTY_KEY_V,
        48 => GHOSTTY_KEY_B,
        49 => GHOSTTY_KEY_N,
        50 => GHOSTTY_KEY_M,
        51 => GHOSTTY_KEY_COMMA,
        52 => GHOSTTY_KEY_PERIOD,
        53 => GHOSTTY_KEY_SLASH,
        54 => GHOSTTY_KEY_SHIFT_RIGHT,
        55 => GHOSTTY_KEY_NUMPAD_MULTIPLY,
        56 => GHOSTTY_KEY_ALT_LEFT,
        57 => GHOSTTY_KEY_SPACE,
        58 => GHOSTTY_KEY_CAPS_LOCK,
        59 => GHOSTTY_KEY_F1,
        60 => GHOSTTY_KEY_F2,
        61 => GHOSTTY_KEY_F3,
        62 => GHOSTTY_KEY_F4,
        63 => GHOSTTY_KEY_F5,
        64 => GHOSTTY_KEY_F6,
        65 => GHOSTTY_KEY_F7,
        66 => GHOSTTY_KEY_F8,
        67 => GHOSTTY_KEY_F9,
        68 => GHOSTTY_KEY_F10,
        69 => GHOSTTY_KEY_NUM_LOCK,
        70 => GHOSTTY_KEY_SCROLL_LOCK,
        71 => GHOSTTY_KEY_NUMPAD_7,
        72 => GHOSTTY_KEY_NUMPAD_8,
        73 => GHOSTTY_KEY_NUMPAD_9,
        74 => GHOSTTY_KEY_NUMPAD_SUBTRACT,
        75 => GHOSTTY_KEY_NUMPAD_4,
        76 => GHOSTTY_KEY_NUMPAD_5,
        77 => GHOSTTY_KEY_NUMPAD_6,
        78 => GHOSTTY_KEY_NUMPAD_ADD,
        79 => GHOSTTY_KEY_NUMPAD_1,
        80 => GHOSTTY_KEY_NUMPAD_2,
        81 => GHOSTTY_KEY_NUMPAD_3,
        82 => GHOSTTY_KEY_NUMPAD_0,
        83 => GHOSTTY_KEY_NUMPAD_DECIMAL,
        86 => GHOSTTY_KEY_INTL_BACKSLASH,
        87 => GHOSTTY_KEY_F11,
        88 => GHOSTTY_KEY_F12,
        96 => GHOSTTY_KEY_NUMPAD_ENTER,
        97 => GHOSTTY_KEY_CONTROL_RIGHT,
        98 => GHOSTTY_KEY_NUMPAD_DIVIDE,
        99 => GHOSTTY_KEY_PRINT_SCREEN,
        100 => GHOSTTY_KEY_ALT_RIGHT,
        102 => GHOSTTY_KEY_HOME,
        103 => GHOSTTY_KEY_ARROW_UP,
        104 => GHOSTTY_KEY_PAGE_UP,
        105 => GHOSTTY_KEY_ARROW_LEFT,
        106 => GHOSTTY_KEY_ARROW_RIGHT,
        107 => GHOSTTY_KEY_END,
        108 => GHOSTTY_KEY_ARROW_DOWN,
        109 => GHOSTTY_KEY_PAGE_DOWN,
        110 => GHOSTTY_KEY_INSERT,
        111 => GHOSTTY_KEY_DELETE,
        119 => GHOSTTY_KEY_PAUSE,
        125 => GHOSTTY_KEY_META_LEFT,
        126 => GHOSTTY_KEY_META_RIGHT,
        127 => GHOSTTY_KEY_CONTEXT_MENU,
        _ => return None,
    };

    Some(key)
}
