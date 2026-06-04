//! Raw FFI bindings to libghostty (embedded runtime).
//!
//! These types mirror the definitions in `ghostty.h` and must be kept in sync.
//! All types here are `repr(C)` to match the C ABI.

#![allow(non_camel_case_types, non_upper_case_globals, dead_code)]

use std::os::raw::{c_char, c_double, c_int, c_void};

// -----------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------

pub const GHOSTTY_SUCCESS: c_int = 0;

pub fn bundled_resources_dir() -> Option<&'static str> {
    option_env!("GHOSTTY_BUNDLED_RESOURCES_DIR")
}

// -----------------------------------------------------------------------
// Opaque types
// -----------------------------------------------------------------------

pub type ghostty_app_t = *mut c_void;
pub type ghostty_config_t = *mut c_void;
pub type ghostty_surface_t = *mut c_void;
pub type ghostty_inspector_t = *mut c_void;

// -----------------------------------------------------------------------
// Platform
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_platform_e {
    GHOSTTY_PLATFORM_INVALID = 0,
    GHOSTTY_PLATFORM_MACOS = 1,
    GHOSTTY_PLATFORM_IOS = 2,
    GHOSTTY_PLATFORM_LINUX = 3, // Added for cmux-linux
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_platform_macos_s {
    pub nsview: *mut c_void,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_platform_ios_s {
    pub uiview: *mut c_void,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_platform_linux_s {
    pub gl_area: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ghostty_platform_u {
    pub macos: ghostty_platform_macos_s,
    pub ios: ghostty_platform_ios_s,
    pub linux: ghostty_platform_linux_s,
}

// -----------------------------------------------------------------------
// Clipboard
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_clipboard_e {
    GHOSTTY_CLIPBOARD_STANDARD = 0,
    GHOSTTY_CLIPBOARD_SELECTION = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_clipboard_content_s {
    pub mime: *const c_char,
    pub data: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_clipboard_request_e {
    GHOSTTY_CLIPBOARD_REQUEST_PASTE = 0,
    GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ = 1,
    GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE = 2,
}

// -----------------------------------------------------------------------
// Mouse input
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_mouse_state_e {
    GHOSTTY_MOUSE_RELEASE = 0,
    GHOSTTY_MOUSE_PRESS = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_mouse_button_e {
    GHOSTTY_MOUSE_UNKNOWN = 0,
    GHOSTTY_MOUSE_LEFT = 1,
    GHOSTTY_MOUSE_RIGHT = 2,
    GHOSTTY_MOUSE_MIDDLE = 3,
    GHOSTTY_MOUSE_FOUR = 4,
    GHOSTTY_MOUSE_FIVE = 5,
    GHOSTTY_MOUSE_SIX = 6,
    GHOSTTY_MOUSE_SEVEN = 7,
    GHOSTTY_MOUSE_EIGHT = 8,
    GHOSTTY_MOUSE_NINE = 9,
    GHOSTTY_MOUSE_TEN = 10,
    GHOSTTY_MOUSE_ELEVEN = 11,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_mouse_momentum_e {
    GHOSTTY_MOUSE_MOMENTUM_NONE = 0,
    GHOSTTY_MOUSE_MOMENTUM_BEGAN = 1,
    GHOSTTY_MOUSE_MOMENTUM_STATIONARY = 2,
    GHOSTTY_MOUSE_MOMENTUM_CHANGED = 3,
    GHOSTTY_MOUSE_MOMENTUM_ENDED = 4,
    GHOSTTY_MOUSE_MOMENTUM_CANCELLED = 5,
    GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN = 6,
}

pub type ghostty_input_scroll_mods_t = c_int;

// -----------------------------------------------------------------------
// Color scheme
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_color_scheme_e {
    GHOSTTY_COLOR_SCHEME_LIGHT = 0,
    GHOSTTY_COLOR_SCHEME_DARK = 1,
}

// -----------------------------------------------------------------------
// Input modifiers & actions
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_mods_e {
    GHOSTTY_MODS_NONE = 0,
    GHOSTTY_MODS_SHIFT = 1 << 0,
    GHOSTTY_MODS_CTRL = 1 << 1,
    GHOSTTY_MODS_ALT = 1 << 2,
    GHOSTTY_MODS_SUPER = 1 << 3,
    GHOSTTY_MODS_CAPS = 1 << 4,
    GHOSTTY_MODS_NUM = 1 << 5,
    GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
    GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
    GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
    GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
}

// Use a type alias for modifier flags (can combine multiple values)
pub type GhosttyMods = u32;

// Binding flags are bitflags that can be OR'd together in C,
// so we use a type alias instead of an enum to avoid UB.
pub type GhosttyBindingFlags = u32;
pub const GHOSTTY_BINDING_FLAGS_CONSUMED: GhosttyBindingFlags = 1 << 0;
pub const GHOSTTY_BINDING_FLAGS_ALL: GhosttyBindingFlags = 1 << 1;
pub const GHOSTTY_BINDING_FLAGS_GLOBAL: GhosttyBindingFlags = 1 << 2;
pub const GHOSTTY_BINDING_FLAGS_PERFORMABLE: GhosttyBindingFlags = 1 << 3;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_action_e {
    GHOSTTY_ACTION_RELEASE = 0,
    GHOSTTY_ACTION_PRESS = 1,
    GHOSTTY_ACTION_REPEAT = 2,
}

// -----------------------------------------------------------------------
// Key codes (based on W3C UIEvents)
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ghostty_input_key_e {
    GHOSTTY_KEY_UNIDENTIFIED = 0,

    // Writing System Keys § 3.1.1
    GHOSTTY_KEY_BACKQUOTE,
    GHOSTTY_KEY_BACKSLASH,
    GHOSTTY_KEY_BRACKET_LEFT,
    GHOSTTY_KEY_BRACKET_RIGHT,
    GHOSTTY_KEY_COMMA,
    GHOSTTY_KEY_DIGIT_0,
    GHOSTTY_KEY_DIGIT_1,
    GHOSTTY_KEY_DIGIT_2,
    GHOSTTY_KEY_DIGIT_3,
    GHOSTTY_KEY_DIGIT_4,
    GHOSTTY_KEY_DIGIT_5,
    GHOSTTY_KEY_DIGIT_6,
    GHOSTTY_KEY_DIGIT_7,
    GHOSTTY_KEY_DIGIT_8,
    GHOSTTY_KEY_DIGIT_9,
    GHOSTTY_KEY_EQUAL,
    GHOSTTY_KEY_INTL_BACKSLASH,
    GHOSTTY_KEY_INTL_RO,
    GHOSTTY_KEY_INTL_YEN,
    GHOSTTY_KEY_A,
    GHOSTTY_KEY_B,
    GHOSTTY_KEY_C,
    GHOSTTY_KEY_D,
    GHOSTTY_KEY_E,
    GHOSTTY_KEY_F,
    GHOSTTY_KEY_G,
    GHOSTTY_KEY_H,
    GHOSTTY_KEY_I,
    GHOSTTY_KEY_J,
    GHOSTTY_KEY_K,
    GHOSTTY_KEY_L,
    GHOSTTY_KEY_M,
    GHOSTTY_KEY_N,
    GHOSTTY_KEY_O,
    GHOSTTY_KEY_P,
    GHOSTTY_KEY_Q,
    GHOSTTY_KEY_R,
    GHOSTTY_KEY_S,
    GHOSTTY_KEY_T,
    GHOSTTY_KEY_U,
    GHOSTTY_KEY_V,
    GHOSTTY_KEY_W,
    GHOSTTY_KEY_X,
    GHOSTTY_KEY_Y,
    GHOSTTY_KEY_Z,
    GHOSTTY_KEY_MINUS,
    GHOSTTY_KEY_PERIOD,
    GHOSTTY_KEY_QUOTE,
    GHOSTTY_KEY_SEMICOLON,
    GHOSTTY_KEY_SLASH,

    // Functional Keys § 3.1.2
    GHOSTTY_KEY_ALT_LEFT,
    GHOSTTY_KEY_ALT_RIGHT,
    GHOSTTY_KEY_BACKSPACE,
    GHOSTTY_KEY_CAPS_LOCK,
    GHOSTTY_KEY_CONTEXT_MENU,
    GHOSTTY_KEY_CONTROL_LEFT,
    GHOSTTY_KEY_CONTROL_RIGHT,
    GHOSTTY_KEY_ENTER,
    GHOSTTY_KEY_META_LEFT,
    GHOSTTY_KEY_META_RIGHT,
    GHOSTTY_KEY_SHIFT_LEFT,
    GHOSTTY_KEY_SHIFT_RIGHT,
    GHOSTTY_KEY_SPACE,
    GHOSTTY_KEY_TAB,
    GHOSTTY_KEY_CONVERT,
    GHOSTTY_KEY_KANA_MODE,
    GHOSTTY_KEY_NON_CONVERT,

    // Control Pad Section § 3.2
    GHOSTTY_KEY_DELETE,
    GHOSTTY_KEY_END,
    GHOSTTY_KEY_HELP,
    GHOSTTY_KEY_HOME,
    GHOSTTY_KEY_INSERT,
    GHOSTTY_KEY_PAGE_DOWN,
    GHOSTTY_KEY_PAGE_UP,

    // Arrow Pad Section § 3.3
    GHOSTTY_KEY_ARROW_DOWN,
    GHOSTTY_KEY_ARROW_LEFT,
    GHOSTTY_KEY_ARROW_RIGHT,
    GHOSTTY_KEY_ARROW_UP,

    // Numpad Section § 3.4
    GHOSTTY_KEY_NUM_LOCK,
    GHOSTTY_KEY_NUMPAD_0,
    GHOSTTY_KEY_NUMPAD_1,
    GHOSTTY_KEY_NUMPAD_2,
    GHOSTTY_KEY_NUMPAD_3,
    GHOSTTY_KEY_NUMPAD_4,
    GHOSTTY_KEY_NUMPAD_5,
    GHOSTTY_KEY_NUMPAD_6,
    GHOSTTY_KEY_NUMPAD_7,
    GHOSTTY_KEY_NUMPAD_8,
    GHOSTTY_KEY_NUMPAD_9,
    GHOSTTY_KEY_NUMPAD_ADD,
    GHOSTTY_KEY_NUMPAD_BACKSPACE,
    GHOSTTY_KEY_NUMPAD_CLEAR,
    GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
    GHOSTTY_KEY_NUMPAD_COMMA,
    GHOSTTY_KEY_NUMPAD_DECIMAL,
    GHOSTTY_KEY_NUMPAD_DIVIDE,
    GHOSTTY_KEY_NUMPAD_ENTER,
    GHOSTTY_KEY_NUMPAD_EQUAL,
    GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
    GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
    GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
    GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
    GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
    GHOSTTY_KEY_NUMPAD_MULTIPLY,
    GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
    GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
    GHOSTTY_KEY_NUMPAD_SUBTRACT,
    GHOSTTY_KEY_NUMPAD_SEPARATOR,
    GHOSTTY_KEY_NUMPAD_UP,
    GHOSTTY_KEY_NUMPAD_DOWN,
    GHOSTTY_KEY_NUMPAD_RIGHT,
    GHOSTTY_KEY_NUMPAD_LEFT,
    GHOSTTY_KEY_NUMPAD_BEGIN,
    GHOSTTY_KEY_NUMPAD_HOME,
    GHOSTTY_KEY_NUMPAD_END,
    GHOSTTY_KEY_NUMPAD_INSERT,
    GHOSTTY_KEY_NUMPAD_DELETE,
    GHOSTTY_KEY_NUMPAD_PAGE_UP,
    GHOSTTY_KEY_NUMPAD_PAGE_DOWN,

    // Function Section § 3.5
    GHOSTTY_KEY_ESCAPE,
    GHOSTTY_KEY_F1,
    GHOSTTY_KEY_F2,
    GHOSTTY_KEY_F3,
    GHOSTTY_KEY_F4,
    GHOSTTY_KEY_F5,
    GHOSTTY_KEY_F6,
    GHOSTTY_KEY_F7,
    GHOSTTY_KEY_F8,
    GHOSTTY_KEY_F9,
    GHOSTTY_KEY_F10,
    GHOSTTY_KEY_F11,
    GHOSTTY_KEY_F12,
    GHOSTTY_KEY_F13,
    GHOSTTY_KEY_F14,
    GHOSTTY_KEY_F15,
    GHOSTTY_KEY_F16,
    GHOSTTY_KEY_F17,
    GHOSTTY_KEY_F18,
    GHOSTTY_KEY_F19,
    GHOSTTY_KEY_F20,
    GHOSTTY_KEY_F21,
    GHOSTTY_KEY_F22,
    GHOSTTY_KEY_F23,
    GHOSTTY_KEY_F24,
    GHOSTTY_KEY_F25,
    GHOSTTY_KEY_FN,
    GHOSTTY_KEY_FN_LOCK,
    GHOSTTY_KEY_PRINT_SCREEN,
    GHOSTTY_KEY_SCROLL_LOCK,
    GHOSTTY_KEY_PAUSE,

    // Media Keys § 3.6
    GHOSTTY_KEY_BROWSER_BACK,
    GHOSTTY_KEY_BROWSER_FAVORITES,
    GHOSTTY_KEY_BROWSER_FORWARD,
    GHOSTTY_KEY_BROWSER_HOME,
    GHOSTTY_KEY_BROWSER_REFRESH,
    GHOSTTY_KEY_BROWSER_SEARCH,
    GHOSTTY_KEY_BROWSER_STOP,
    GHOSTTY_KEY_EJECT,
    GHOSTTY_KEY_LAUNCH_APP_1,
    GHOSTTY_KEY_LAUNCH_APP_2,
    GHOSTTY_KEY_LAUNCH_MAIL,
    GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
    GHOSTTY_KEY_MEDIA_SELECT,
    GHOSTTY_KEY_MEDIA_STOP,
    GHOSTTY_KEY_MEDIA_TRACK_NEXT,
    GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
    GHOSTTY_KEY_POWER,
    GHOSTTY_KEY_SLEEP,
    GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
    GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
    GHOSTTY_KEY_AUDIO_VOLUME_UP,
    GHOSTTY_KEY_WAKE_UP,

    // Legacy, Non-standard § 3.7
    GHOSTTY_KEY_COPY,
    GHOSTTY_KEY_CUT,
    GHOSTTY_KEY_PASTE,
}

// -----------------------------------------------------------------------
// Key input
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_input_key_s {
    pub action: ghostty_input_action_e,
    pub mods: GhosttyMods,
    pub consumed_mods: GhosttyMods,
    pub keycode: u32,
    pub text: *const c_char,
    pub unshifted_codepoint: u32,
    pub composing: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_input_trigger_tag_e {
    GHOSTTY_TRIGGER_PHYSICAL = 0,
    GHOSTTY_TRIGGER_UNICODE = 1,
    GHOSTTY_TRIGGER_CATCH_ALL = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ghostty_input_trigger_key_u {
    pub translated: ghostty_input_key_e,
    pub physical: ghostty_input_key_e,
    pub unicode: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_input_trigger_s {
    pub tag: ghostty_input_trigger_tag_e,
    pub key: ghostty_input_trigger_key_u,
    pub mods: GhosttyMods,
}

// -----------------------------------------------------------------------
// Build info, diagnostics, strings
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_build_mode_e {
    GHOSTTY_BUILD_MODE_DEBUG = 0,
    GHOSTTY_BUILD_MODE_RELEASE_SAFE = 1,
    GHOSTTY_BUILD_MODE_RELEASE_FAST = 2,
    GHOSTTY_BUILD_MODE_RELEASE_SMALL = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_info_s {
    pub build_mode: ghostty_build_mode_e,
    pub version: *const c_char,
    pub version_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_diagnostic_s {
    pub message: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_string_s {
    pub ptr: *const c_char,
    pub len: usize,
    pub sentinel: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_text_s {
    pub tl_px_x: c_double,
    pub tl_px_y: c_double,
    pub offset_start: u32,
    pub offset_len: u32,
    pub text: *const c_char,
    pub text_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_command_s {
    pub action_key: *const c_char,
    pub action: *const c_char,
    pub title: *const c_char,
    pub description: *const c_char,
}

// -----------------------------------------------------------------------
// Points & selections
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_point_tag_e {
    GHOSTTY_POINT_ACTIVE = 0,
    GHOSTTY_POINT_VIEWPORT = 1,
    GHOSTTY_POINT_SCREEN = 2,
    GHOSTTY_POINT_SURFACE = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_point_coord_e {
    GHOSTTY_POINT_COORD_EXACT = 0,
    GHOSTTY_POINT_COORD_TOP_LEFT = 1,
    GHOSTTY_POINT_COORD_BOTTOM_RIGHT = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_point_s {
    pub tag: ghostty_point_tag_e,
    pub coord: ghostty_point_coord_e,
    pub x: u32,
    pub y: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_selection_s {
    pub top_left: ghostty_point_s,
    pub bottom_right: ghostty_point_s,
    pub rectangle: bool,
}

// -----------------------------------------------------------------------
// Environment variables
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_env_var_s {
    pub key: *const c_char,
    pub value: *const c_char,
}

// -----------------------------------------------------------------------
// Surface config
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_surface_context_e {
    GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
    GHOSTTY_SURFACE_CONTEXT_TAB = 1,
    GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_surface_config_s {
    pub platform_tag: ghostty_platform_e,
    pub platform: ghostty_platform_u,
    pub userdata: *mut c_void,
    pub scale_factor: c_double,
    pub font_size: f32,
    pub working_directory: *const c_char,
    pub command: *const c_char,
    pub env_vars: *mut ghostty_env_var_s,
    pub env_var_count: usize,
    pub initial_input: *const c_char,
    pub wait_after_command: bool,
    pub context: ghostty_surface_context_e,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_surface_size_s {
    pub columns: u16,
    pub rows: u16,
    pub width_px: u32,
    pub height_px: u32,
    pub cell_width_px: u32,
    pub cell_height_px: u32,
}

// -----------------------------------------------------------------------
// Config types
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_config_color_s {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_config_color_list_s {
    pub colors: *const ghostty_config_color_s,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_config_command_list_s {
    pub commands: *const ghostty_command_s,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_config_palette_s {
    pub colors: [ghostty_config_color_s; 256],
}

// -----------------------------------------------------------------------
// Target
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_target_tag_e {
    GHOSTTY_TARGET_APP = 0,
    GHOSTTY_TARGET_SURFACE = 1,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ghostty_target_u {
    pub surface: ghostty_surface_t,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_target_s {
    pub tag: ghostty_target_tag_e,
    pub target: ghostty_target_u,
}

// -----------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_split_direction_e {
    GHOSTTY_SPLIT_DIRECTION_RIGHT = 0,
    GHOSTTY_SPLIT_DIRECTION_DOWN = 1,
    GHOSTTY_SPLIT_DIRECTION_LEFT = 2,
    GHOSTTY_SPLIT_DIRECTION_UP = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_goto_split_e {
    GHOSTTY_GOTO_SPLIT_PREVIOUS = 0,
    GHOSTTY_GOTO_SPLIT_NEXT = 1,
    GHOSTTY_GOTO_SPLIT_UP = 2,
    GHOSTTY_GOTO_SPLIT_LEFT = 3,
    GHOSTTY_GOTO_SPLIT_DOWN = 4,
    GHOSTTY_GOTO_SPLIT_RIGHT = 5,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_goto_window_e {
    GHOSTTY_GOTO_WINDOW_PREVIOUS = 0,
    GHOSTTY_GOTO_WINDOW_NEXT = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_resize_split_direction_e {
    GHOSTTY_RESIZE_SPLIT_UP = 0,
    GHOSTTY_RESIZE_SPLIT_DOWN = 1,
    GHOSTTY_RESIZE_SPLIT_LEFT = 2,
    GHOSTTY_RESIZE_SPLIT_RIGHT = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_resize_split_s {
    pub amount: u16,
    pub direction: ghostty_action_resize_split_direction_e,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_move_tab_s {
    pub amount: isize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_goto_tab_e {
    GHOSTTY_GOTO_TAB_PREVIOUS = -1_isize,
    GHOSTTY_GOTO_TAB_NEXT = -2_isize,
    GHOSTTY_GOTO_TAB_LAST = -3_isize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_fullscreen_e {
    GHOSTTY_FULLSCREEN_NATIVE = 0,
    GHOSTTY_FULLSCREEN_NON_NATIVE = 1,
    GHOSTTY_FULLSCREEN_NON_NATIVE_VISIBLE_MENU = 2,
    GHOSTTY_FULLSCREEN_NON_NATIVE_PADDED_NOTCH = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_float_window_e {
    GHOSTTY_FLOAT_WINDOW_ON = 0,
    GHOSTTY_FLOAT_WINDOW_OFF = 1,
    GHOSTTY_FLOAT_WINDOW_TOGGLE = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_secure_input_e {
    GHOSTTY_SECURE_INPUT_ON = 0,
    GHOSTTY_SECURE_INPUT_OFF = 1,
    GHOSTTY_SECURE_INPUT_TOGGLE = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_inspector_e {
    GHOSTTY_INSPECTOR_TOGGLE = 0,
    GHOSTTY_INSPECTOR_SHOW = 1,
    GHOSTTY_INSPECTOR_HIDE = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_quit_timer_e {
    GHOSTTY_QUIT_TIMER_START = 0,
    GHOSTTY_QUIT_TIMER_STOP = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_readonly_e {
    GHOSTTY_READONLY_OFF = 0,
    GHOSTTY_READONLY_ON = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_desktop_notification_s {
    pub title: *const c_char,
    pub body: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_set_title_s {
    pub title: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_prompt_title_e {
    GHOSTTY_PROMPT_TITLE_SURFACE = 0,
    GHOSTTY_PROMPT_TITLE_TAB = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_pwd_s {
    pub pwd: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_mouse_shape_e {
    GHOSTTY_MOUSE_SHAPE_DEFAULT = 0,
    GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
    GHOSTTY_MOUSE_SHAPE_HELP,
    GHOSTTY_MOUSE_SHAPE_POINTER,
    GHOSTTY_MOUSE_SHAPE_PROGRESS,
    GHOSTTY_MOUSE_SHAPE_WAIT,
    GHOSTTY_MOUSE_SHAPE_CELL,
    GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
    GHOSTTY_MOUSE_SHAPE_TEXT,
    GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
    GHOSTTY_MOUSE_SHAPE_ALIAS,
    GHOSTTY_MOUSE_SHAPE_COPY,
    GHOSTTY_MOUSE_SHAPE_MOVE,
    GHOSTTY_MOUSE_SHAPE_NO_DROP,
    GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
    GHOSTTY_MOUSE_SHAPE_GRAB,
    GHOSTTY_MOUSE_SHAPE_GRABBING,
    GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
    GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
    GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_N_RESIZE,
    GHOSTTY_MOUSE_SHAPE_E_RESIZE,
    GHOSTTY_MOUSE_SHAPE_S_RESIZE,
    GHOSTTY_MOUSE_SHAPE_W_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
    GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
    GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
    GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_mouse_visibility_e {
    GHOSTTY_MOUSE_VISIBLE = 0,
    GHOSTTY_MOUSE_HIDDEN = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_mouse_over_link_s {
    pub url: *const c_char,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_size_limit_s {
    pub min_width: u32,
    pub min_height: u32,
    pub max_width: u32,
    pub max_height: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_initial_size_s {
    pub width: u32,
    pub height: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_cell_size_s {
    pub width: u32,
    pub height: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_renderer_health_e {
    GHOSTTY_RENDERER_HEALTH_OK = 0,
    GHOSTTY_RENDERER_HEALTH_UNHEALTHY = 1,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_action_key_sequence_s {
    pub active: bool,
    pub trigger: ghostty_input_trigger_s,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_key_table_tag_e {
    GHOSTTY_KEY_TABLE_ACTIVATE = 0,
    GHOSTTY_KEY_TABLE_DEACTIVATE = 1,
    GHOSTTY_KEY_TABLE_DEACTIVATE_ALL = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_action_key_table_activate_s {
    pub name: *const c_char,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ghostty_action_key_table_u {
    pub activate: ghostty_action_key_table_activate_s,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_action_key_table_s {
    pub tag: ghostty_action_key_table_tag_e,
    pub value: ghostty_action_key_table_u,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_color_change_s {
    pub kind: i32, // ghostty_action_color_kind_e values: -1=fg, -2=bg, -3=cursor
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_action_config_change_s {
    pub config: ghostty_config_t,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_reload_config_s {
    pub soft: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_open_url_kind_e {
    GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN = 0,
    GHOSTTY_ACTION_OPEN_URL_KIND_TEXT = 1,
    GHOSTTY_ACTION_OPEN_URL_KIND_HTML = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_open_url_s {
    pub kind: ghostty_action_open_url_kind_e,
    pub url: *const c_char,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_close_tab_mode_e {
    GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS = 0,
    GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER = 1,
    GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_surface_message_childexited_s {
    pub exit_code: u32,
    pub runtime_ms: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_progress_report_state_e {
    GHOSTTY_PROGRESS_STATE_REMOVE = 0,
    GHOSTTY_PROGRESS_STATE_SET = 1,
    GHOSTTY_PROGRESS_STATE_ERROR = 2,
    GHOSTTY_PROGRESS_STATE_INDETERMINATE = 3,
    GHOSTTY_PROGRESS_STATE_PAUSE = 4,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_progress_report_s {
    pub state: ghostty_action_progress_report_state_e,
    pub progress: i8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_command_finished_s {
    pub exit_code: i16,
    pub duration: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_start_search_s {
    pub needle: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_search_total_s {
    pub total: isize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_search_selected_s {
    pub selected: isize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ghostty_action_scrollbar_s {
    pub total: u64,
    pub offset: u64,
    pub len: u64,
}

// -----------------------------------------------------------------------
// Action tag + union
// -----------------------------------------------------------------------

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ghostty_action_tag_e {
    GHOSTTY_ACTION_QUIT = 0,
    GHOSTTY_ACTION_NEW_WINDOW,
    GHOSTTY_ACTION_NEW_TAB,
    GHOSTTY_ACTION_CLOSE_TAB,
    GHOSTTY_ACTION_NEW_SPLIT,
    GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
    GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
    GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
    GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
    GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
    GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
    GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
    GHOSTTY_ACTION_TOGGLE_VISIBILITY,
    GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
    GHOSTTY_ACTION_MOVE_TAB,
    GHOSTTY_ACTION_GOTO_TAB,
    GHOSTTY_ACTION_GOTO_SPLIT,
    GHOSTTY_ACTION_GOTO_WINDOW,
    GHOSTTY_ACTION_RESIZE_SPLIT,
    GHOSTTY_ACTION_EQUALIZE_SPLITS,
    GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
    GHOSTTY_ACTION_PRESENT_TERMINAL,
    GHOSTTY_ACTION_SIZE_LIMIT,
    GHOSTTY_ACTION_RESET_WINDOW_SIZE,
    GHOSTTY_ACTION_INITIAL_SIZE,
    GHOSTTY_ACTION_CELL_SIZE,
    GHOSTTY_ACTION_SCROLLBAR,
    GHOSTTY_ACTION_RENDER,
    GHOSTTY_ACTION_INSPECTOR,
    GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
    GHOSTTY_ACTION_RENDER_INSPECTOR,
    GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
    GHOSTTY_ACTION_SET_TITLE,
    GHOSTTY_ACTION_PROMPT_TITLE,
    GHOSTTY_ACTION_PWD,
    GHOSTTY_ACTION_MOUSE_SHAPE,
    GHOSTTY_ACTION_MOUSE_VISIBILITY,
    GHOSTTY_ACTION_MOUSE_OVER_LINK,
    GHOSTTY_ACTION_RENDERER_HEALTH,
    GHOSTTY_ACTION_OPEN_CONFIG,
    GHOSTTY_ACTION_QUIT_TIMER,
    GHOSTTY_ACTION_FLOAT_WINDOW,
    GHOSTTY_ACTION_SECURE_INPUT,
    GHOSTTY_ACTION_KEY_SEQUENCE,
    GHOSTTY_ACTION_KEY_TABLE,
    GHOSTTY_ACTION_COLOR_CHANGE,
    GHOSTTY_ACTION_RELOAD_CONFIG,
    GHOSTTY_ACTION_CONFIG_CHANGE,
    GHOSTTY_ACTION_CLOSE_WINDOW,
    GHOSTTY_ACTION_RING_BELL,
    GHOSTTY_ACTION_UNDO,
    GHOSTTY_ACTION_REDO,
    GHOSTTY_ACTION_CHECK_FOR_UPDATES,
    GHOSTTY_ACTION_OPEN_URL,
    GHOSTTY_ACTION_SHOW_CHILD_EXITED,
    GHOSTTY_ACTION_PROGRESS_REPORT,
    GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
    GHOSTTY_ACTION_COMMAND_FINISHED,
    GHOSTTY_ACTION_START_SEARCH,
    GHOSTTY_ACTION_END_SEARCH,
    GHOSTTY_ACTION_SEARCH_TOTAL,
    GHOSTTY_ACTION_SEARCH_SELECTED,
    GHOSTTY_ACTION_READONLY,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union ghostty_action_u {
    pub new_split: ghostty_action_split_direction_e,
    pub toggle_fullscreen: ghostty_action_fullscreen_e,
    pub move_tab: ghostty_action_move_tab_s,
    pub goto_tab: i32, // ghostty_action_goto_tab_e
    pub goto_split: ghostty_action_goto_split_e,
    pub goto_window: ghostty_action_goto_window_e,
    pub resize_split: ghostty_action_resize_split_s,
    pub size_limit: ghostty_action_size_limit_s,
    pub initial_size: ghostty_action_initial_size_s,
    pub cell_size: ghostty_action_cell_size_s,
    pub scrollbar: ghostty_action_scrollbar_s,
    pub inspector: ghostty_action_inspector_e,
    pub desktop_notification: ghostty_action_desktop_notification_s,
    pub set_title: ghostty_action_set_title_s,
    pub prompt_title: ghostty_action_prompt_title_e,
    pub pwd: ghostty_action_pwd_s,
    pub mouse_shape: ghostty_action_mouse_shape_e,
    pub mouse_visibility: ghostty_action_mouse_visibility_e,
    pub mouse_over_link: ghostty_action_mouse_over_link_s,
    pub renderer_health: ghostty_action_renderer_health_e,
    pub quit_timer: ghostty_action_quit_timer_e,
    pub float_window: ghostty_action_float_window_e,
    pub secure_input: ghostty_action_secure_input_e,
    pub key_sequence: ghostty_action_key_sequence_s,
    pub key_table: ghostty_action_key_table_s,
    pub color_change: ghostty_action_color_change_s,
    pub reload_config: ghostty_action_reload_config_s,
    pub config_change: ghostty_action_config_change_s,
    pub open_url: ghostty_action_open_url_s,
    pub close_tab_mode: ghostty_action_close_tab_mode_e,
    pub child_exited: ghostty_surface_message_childexited_s,
    pub progress_report: ghostty_action_progress_report_s,
    pub command_finished: ghostty_action_command_finished_s,
    pub start_search: ghostty_action_start_search_s,
    pub search_total: ghostty_action_search_total_s,
    pub search_selected: ghostty_action_search_selected_s,
    pub readonly: ghostty_action_readonly_e,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_action_s {
    pub tag: ghostty_action_tag_e,
    pub action: ghostty_action_u,
}

// -----------------------------------------------------------------------
// Runtime callbacks
// -----------------------------------------------------------------------

pub type ghostty_runtime_wakeup_cb = Option<unsafe extern "C" fn(userdata: *mut c_void)>;

pub type ghostty_runtime_read_clipboard_cb = Option<
    unsafe extern "C" fn(
        userdata: *mut c_void,
        clipboard: ghostty_clipboard_e,
        context: *mut c_void,
    ),
>;

pub type ghostty_runtime_confirm_read_clipboard_cb = Option<
    unsafe extern "C" fn(
        userdata: *mut c_void,
        content: *const c_char,
        context: *mut c_void,
        request: ghostty_clipboard_request_e,
    ),
>;

pub type ghostty_runtime_write_clipboard_cb = Option<
    unsafe extern "C" fn(
        userdata: *mut c_void,
        clipboard: ghostty_clipboard_e,
        content: *const ghostty_clipboard_content_s,
        content_len: usize,
        confirm: bool,
    ),
>;

pub type ghostty_runtime_close_surface_cb =
    Option<unsafe extern "C" fn(userdata: *mut c_void, process_alive: bool)>;

pub type ghostty_runtime_action_cb = Option<
    unsafe extern "C" fn(
        app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s,
    ) -> bool,
>;

#[repr(C)]
pub struct ghostty_runtime_config_s {
    pub userdata: *mut c_void,
    pub supports_selection_clipboard: bool,
    pub wakeup_cb: ghostty_runtime_wakeup_cb,
    pub action_cb: ghostty_runtime_action_cb,
    pub read_clipboard_cb: ghostty_runtime_read_clipboard_cb,
    pub confirm_read_clipboard_cb: ghostty_runtime_confirm_read_clipboard_cb,
    pub write_clipboard_cb: ghostty_runtime_write_clipboard_cb,
    pub close_surface_cb: ghostty_runtime_close_surface_cb,
}

// -----------------------------------------------------------------------
// Published API (extern "C" functions)
// -----------------------------------------------------------------------

// When building without libghostty (stub mode), these are declared but not linked.
// The actual linking happens when the ghostty submodule is built.
#[cfg(feature = "link-ghostty")]
extern "C" {
    pub fn ghostty_init(argc: usize, argv: *mut *mut c_char) -> c_int;
    pub fn ghostty_info() -> ghostty_info_s;
    pub fn ghostty_translate(key: *const c_char) -> *const c_char;
    pub fn ghostty_string_free(s: ghostty_string_s);

    // Config
    pub fn ghostty_config_new() -> ghostty_config_t;
    pub fn ghostty_config_free(config: ghostty_config_t);
    pub fn ghostty_config_clone(config: ghostty_config_t) -> ghostty_config_t;
    pub fn ghostty_config_load_cli_args(config: ghostty_config_t);
    pub fn ghostty_config_load_file(config: ghostty_config_t, path: *const c_char);
    pub fn ghostty_config_load_default_files(config: ghostty_config_t);
    pub fn ghostty_config_load_recursive_files(config: ghostty_config_t);
    pub fn ghostty_config_finalize(config: ghostty_config_t);
    pub fn ghostty_config_get(
        config: ghostty_config_t,
        out: *mut c_void,
        key: *const c_char,
        key_len: usize,
    ) -> bool;
    pub fn ghostty_config_trigger(
        config: ghostty_config_t,
        action: *const c_char,
        action_len: usize,
    ) -> ghostty_input_trigger_s;
    pub fn ghostty_config_diagnostics_count(config: ghostty_config_t) -> u32;
    pub fn ghostty_config_get_diagnostic(
        config: ghostty_config_t,
        index: u32,
    ) -> ghostty_diagnostic_s;

    // App
    pub fn ghostty_app_new(
        runtime_config: *const ghostty_runtime_config_s,
        config: ghostty_config_t,
    ) -> ghostty_app_t;
    pub fn ghostty_app_free(app: ghostty_app_t);
    pub fn ghostty_app_tick(app: ghostty_app_t);
    pub fn ghostty_app_userdata(app: ghostty_app_t) -> *mut c_void;
    pub fn ghostty_app_set_focus(app: ghostty_app_t, focused: bool);
    pub fn ghostty_app_key(app: ghostty_app_t, key: ghostty_input_key_s) -> bool;
    pub fn ghostty_app_key_is_binding(app: ghostty_app_t, key: ghostty_input_key_s) -> bool;
    pub fn ghostty_app_keyboard_changed(app: ghostty_app_t);
    pub fn ghostty_app_open_config(app: ghostty_app_t);
    pub fn ghostty_app_update_config(app: ghostty_app_t, config: ghostty_config_t);
    pub fn ghostty_app_needs_confirm_quit(app: ghostty_app_t) -> bool;
    pub fn ghostty_app_has_global_keybinds(app: ghostty_app_t) -> bool;
    pub fn ghostty_app_set_color_scheme(app: ghostty_app_t, scheme: ghostty_color_scheme_e);

    // Surface config
    pub fn ghostty_surface_config_new() -> ghostty_surface_config_s;

    // Surface
    pub fn ghostty_surface_new(
        app: ghostty_app_t,
        config: *const ghostty_surface_config_s,
    ) -> ghostty_surface_t;
    pub fn ghostty_surface_free(surface: ghostty_surface_t);
    pub fn ghostty_surface_userdata(surface: ghostty_surface_t) -> *mut c_void;
    pub fn ghostty_surface_app(surface: ghostty_surface_t) -> ghostty_app_t;
    pub fn ghostty_surface_inherited_config(
        surface: ghostty_surface_t,
        context: ghostty_surface_context_e,
    ) -> ghostty_surface_config_s;
    pub fn ghostty_surface_update_config(surface: ghostty_surface_t, config: ghostty_config_t);
    pub fn ghostty_surface_needs_confirm_quit(surface: ghostty_surface_t) -> bool;
    pub fn ghostty_surface_process_exited(surface: ghostty_surface_t) -> bool;
    pub fn ghostty_surface_refresh(surface: ghostty_surface_t);
    pub fn ghostty_surface_draw(surface: ghostty_surface_t);
    pub fn ghostty_surface_set_content_scale(
        surface: ghostty_surface_t,
        x_scale: c_double,
        y_scale: c_double,
    );
    pub fn ghostty_surface_set_focus(surface: ghostty_surface_t, focused: bool);
    pub fn ghostty_surface_set_occlusion(surface: ghostty_surface_t, occluded: bool);
    pub fn ghostty_surface_set_size(surface: ghostty_surface_t, width: u32, height: u32);
    pub fn ghostty_surface_size(surface: ghostty_surface_t) -> ghostty_surface_size_s;
    pub fn ghostty_surface_set_color_scheme(
        surface: ghostty_surface_t,
        scheme: ghostty_color_scheme_e,
    );
    pub fn ghostty_surface_key_translation_mods(
        surface: ghostty_surface_t,
        mods: GhosttyMods,
    ) -> GhosttyMods;
    pub fn ghostty_surface_key(surface: ghostty_surface_t, key: ghostty_input_key_s) -> bool;
    pub fn ghostty_surface_key_is_binding(
        surface: ghostty_surface_t,
        key: ghostty_input_key_s,
        flags: *mut GhosttyBindingFlags,
    ) -> bool;
    pub fn ghostty_surface_text(surface: ghostty_surface_t, text: *const c_char, len: usize);
    pub fn ghostty_surface_preedit(surface: ghostty_surface_t, text: *const c_char, len: usize);
    pub fn ghostty_surface_mouse_captured(surface: ghostty_surface_t) -> bool;
    pub fn ghostty_surface_mouse_button(
        surface: ghostty_surface_t,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: GhosttyMods,
    ) -> bool;
    pub fn ghostty_surface_mouse_pos(
        surface: ghostty_surface_t,
        x: c_double,
        y: c_double,
        mods: GhosttyMods,
    );
    pub fn ghostty_surface_mouse_scroll(
        surface: ghostty_surface_t,
        x: c_double,
        y: c_double,
        scroll_mods: ghostty_input_scroll_mods_t,
    );
    pub fn ghostty_surface_mouse_pressure(
        surface: ghostty_surface_t,
        stage: u32,
        pressure: c_double,
    );
    pub fn ghostty_surface_ime_point(
        surface: ghostty_surface_t,
        x: *mut c_double,
        y: *mut c_double,
        w: *mut c_double,
        h: *mut c_double,
    );
    pub fn ghostty_surface_request_close(surface: ghostty_surface_t);
    pub fn ghostty_surface_split(
        surface: ghostty_surface_t,
        direction: ghostty_action_split_direction_e,
    );
    pub fn ghostty_surface_split_focus(
        surface: ghostty_surface_t,
        direction: ghostty_action_goto_split_e,
    );
    pub fn ghostty_surface_split_resize(
        surface: ghostty_surface_t,
        direction: ghostty_action_resize_split_direction_e,
        amount: u16,
    );
    pub fn ghostty_surface_split_equalize(surface: ghostty_surface_t);
    pub fn ghostty_surface_binding_action(
        surface: ghostty_surface_t,
        action: *const c_char,
        len: usize,
    ) -> bool;
    pub fn ghostty_surface_complete_clipboard_request(
        surface: ghostty_surface_t,
        data: *const c_char,
        context: *mut c_void,
        confirmed: bool,
    );
    pub fn ghostty_surface_has_selection(surface: ghostty_surface_t) -> bool;
    pub fn ghostty_surface_read_selection(
        surface: ghostty_surface_t,
        out: *mut ghostty_text_s,
    ) -> bool;
    pub fn ghostty_surface_read_text(
        surface: ghostty_surface_t,
        selection: ghostty_selection_s,
        out: *mut ghostty_text_s,
    ) -> bool;
    pub fn ghostty_surface_free_text(surface: ghostty_surface_t, text: *mut ghostty_text_s);

    // Inspector
    pub fn ghostty_surface_inspector(surface: ghostty_surface_t) -> ghostty_inspector_t;
    pub fn ghostty_inspector_free(surface: ghostty_surface_t);
    pub fn ghostty_inspector_set_focus(inspector: ghostty_inspector_t, focused: bool);
    pub fn ghostty_inspector_set_content_scale(
        inspector: ghostty_inspector_t,
        x_scale: c_double,
        y_scale: c_double,
    );
    pub fn ghostty_inspector_set_size(inspector: ghostty_inspector_t, width: u32, height: u32);
    pub fn ghostty_inspector_mouse_button(
        inspector: ghostty_inspector_t,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: GhosttyMods,
    );
    pub fn ghostty_inspector_mouse_pos(inspector: ghostty_inspector_t, x: c_double, y: c_double);
    pub fn ghostty_inspector_mouse_scroll(
        inspector: ghostty_inspector_t,
        x: c_double,
        y: c_double,
        scroll_mods: ghostty_input_scroll_mods_t,
    );
    pub fn ghostty_inspector_key(
        inspector: ghostty_inspector_t,
        action: ghostty_input_action_e,
        key: ghostty_input_key_e,
        mods: GhosttyMods,
    );
    pub fn ghostty_inspector_text(inspector: ghostty_inspector_t, text: *const c_char);
}
