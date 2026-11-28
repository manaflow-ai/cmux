use std::{ffi::OsString, os::windows::ffi::OsStringExt};

use crossterm_winapi::ScreenBuffer;
use serial_test::serial;
use winapi::um::wincon::GetConsoleTitleW;

use super::{scroll_down, scroll_up, set_size, set_window_title, size, temp_screen_buffer};

#[test]
#[serial]
fn test_resize_winapi_20_21() {
    let _test_screen = temp_screen_buffer().unwrap();

    let (width, height) = size().unwrap();

    // The values 20 and 21 are arbitrary and different from each other
    // just to see they're not crossed over.
    set_size(20, 21).unwrap();
    assert_eq!((20, 21), size().unwrap());

    // reset to previous size
    set_size(width, height).unwrap();
    assert_eq!((width, height), size().unwrap());
}

// This is similar to test_resize_winapi_20_21() above. This verifies that
// another test of similar functionality runs independently (that a testing
// race condition has been addressed).
#[test]
#[serial]
#[ignore]
fn test_resize_winapi_30_31() {
    let _test_screen = temp_screen_buffer().unwrap();

    let (width, height) = size().unwrap();

    set_size(30, 31).unwrap();
    assert_eq!((30, 31), size().unwrap());

    // reset to previous size
    set_size(width, height).unwrap();
    assert_eq!((width, height), size().unwrap());
}

// Test is disabled, because it's failing on Travis CI
#[test]
#[ignore]
fn test_scroll_down_winapi() {
    let current_window = ScreenBuffer::current().unwrap().info().unwrap().terminal_window();

    scroll_down(2).unwrap();

    let new_window = ScreenBuffer::current().unwrap().info().unwrap().terminal_window();

    assert_eq!(new_window.top, current_window.top + 2);
    assert_eq!(new_window.bottom, current_window.bottom + 2);
}

// Test is disabled, because it's failing on Travis CI
#[test]
#[ignore]
fn test_scroll_up_winapi() {
    // move the terminal buffer down before moving it up
    test_scroll_down_winapi();

    let current_window = ScreenBuffer::current().unwrap().info().unwrap().terminal_window();

    scroll_up(2).unwrap();

    let new_window = ScreenBuffer::current().unwrap().info().unwrap().terminal_window();

    assert_eq!(new_window.top, current_window.top - 2);
    assert_eq!(new_window.bottom, current_window.bottom - 2);
}

#[test]
#[serial]
fn test_set_title_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    let test_title = "this is a crossterm test title";
    set_window_title(test_title).unwrap();

    let mut raw = [0_u16; 128];
    let length = unsafe { GetConsoleTitleW(raw.as_mut_ptr(), raw.len() as u32) } as usize;
    assert_ne!(0, length);

    let console_title = OsString::from_wide(&raw[..length]).into_string().unwrap();
    assert_eq!(test_title, &console_title[..]);
}
