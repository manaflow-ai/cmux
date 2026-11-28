use std::{io::stdout, thread, time};

use crate::execute;

use super::*;

// Test is disabled, because it's failing on Travis CI
#[test]
#[ignore]
fn test_resize_ansi() {
    let (width, height) = size().unwrap();

    execute!(stdout(), SetSize(35, 35)).unwrap();

    // see issue: https://github.com/eminence/terminal-size/issues/11
    thread::sleep(time::Duration::from_millis(30));

    assert_eq!((35, 35), size().unwrap());

    // reset to previous size
    execute!(stdout(), SetSize(width, height)).unwrap();

    // see issue: https://github.com/eminence/terminal-size/issues/11
    thread::sleep(time::Duration::from_millis(30));

    assert_eq!((width, height), size().unwrap());
}

#[test]
fn test_raw_mode() {
    // check we start from normal mode (may fail on some test harnesses)
    assert!(!is_raw_mode_enabled().unwrap());

    // enable the raw mode
    if enable_raw_mode().is_err() {
        // Enabling raw mode doesn't work on the ci
        // So we just ignore it
        return;
    }

    // check it worked (on unix it doesn't really check the underlying
    // tty but rather check that the code is consistent)
    assert!(is_raw_mode_enabled().unwrap());

    // enable it again, this should not change anything
    enable_raw_mode().unwrap();

    // check we're still in raw mode
    assert!(is_raw_mode_enabled().unwrap());

    // now let's disable it
    disable_raw_mode().unwrap();

    // check we're back to normal mode
    assert!(!is_raw_mode_enabled().unwrap());
}
