use std::sync::atomic::Ordering;

use crate::style::sys::windows::set_foreground_color;

use super::{Color, Colored, BG_INTENSITY, BG_RED, FG_INTENSITY, FG_RED, ORIGINAL_CONSOLE_COLOR};

#[test]
fn test_parse_fg_color() {
    let colored = Colored::ForegroundColor(Color::Red);
    assert_eq!(Into::<u16>::into(colored), FG_INTENSITY | FG_RED);
}

#[test]
fn test_parse_bg_color() {
    let colored = Colored::BackgroundColor(Color::Red);
    assert_eq!(Into::<u16>::into(colored), BG_INTENSITY | BG_RED);
}

#[test]
fn test_original_console_color_is_set() {
    assert_eq!(ORIGINAL_CONSOLE_COLOR.load(Ordering::Relaxed), u32::MAX);

    // will call `init_console_color`
    set_foreground_color(Color::Blue).unwrap();

    assert_ne!(ORIGINAL_CONSOLE_COLOR.load(Ordering::Relaxed), u32::MAX);
}
