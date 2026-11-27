//! Every input of every C ABI function: the full truth tables, plus null and
//! garbage strings and out-of-range values.

use std::ffi::{CString, c_char};
use std::ptr;

use cmux_background_ready::ffi::*;

const MODES: [u8; 3] = [0, 1, 2];
const ORIGINS: [u8; 5] = [0, 1, 2, 3, 4];
const BOOLS: [bool; 2] = [false, true];
/// Values no caller sends: each must give the safe answer.
const UNKNOWN: [u8; 4] = [3, 7, 128, 255];

fn parse(s: &str) -> u8 {
    let c = CString::new(s).unwrap();
    unsafe { cmux_background_ready_mode_parse(c.as_ptr()) }
}

fn plan(mode: u8, at_login: bool, over: Option<&str>) -> u8 {
    let c = over.map(|s| CString::new(s).unwrap());
    let p: *const c_char = c.as_ref().map_or(ptr::null(), |c| c.as_ptr());
    unsafe { cmux_background_ready_hidden_plan(mode, at_login, p) }
}

#[test]
fn mode_parse_known_values() {
    assert_eq!(parse("off"), CMUX_BACKGROUND_READY_MODE_OFF);
    assert_eq!(parse("afterQuit"), CMUX_BACKGROUND_READY_MODE_AFTER_QUIT);
    assert_eq!(parse("afterQuitAndLogin"), CMUX_BACKGROUND_READY_MODE_AFTER_QUIT_AND_LOGIN);
}

#[test]
fn mode_parse_null_and_garbage_are_off() {
    assert_eq!(unsafe { cmux_background_ready_mode_parse(ptr::null()) }, 0);
    for s in [
        "",
        "Off",
        "OFF",
        "afterquit",
        "AfterQuit",
        "afterQuit ",
        " afterQuit",
        "afterQuitAndLogin\n",
        "afterQuitAndLoginX",
        "after_quit",
        "1",
        "2",
        "true",
        "null",
        "\"afterQuit\"",
        "\u{00e9}",
    ] {
        assert_eq!(parse(s), 0, "{s:?}");
    }
    // Invalid UTF-8 bytes.
    let bad = [0xffu8, 0xfe, b'a', 0];
    assert_eq!(unsafe { cmux_background_ready_mode_parse(bad.as_ptr().cast()) }, 0);
}

#[test]
fn on_quit_full_truth_table() {
    for mode in MODES {
        for origin in ORIGINS {
            for update in BOOLS {
                for completely in BOOLS {
                    let want = if mode != 0 && origin == 0 && !update && !completely {
                        CMUX_BACKGROUND_READY_STAY_HIDDEN
                    } else {
                        CMUX_BACKGROUND_READY_EXIT
                    };
                    assert_eq!(
                        cmux_background_ready_on_quit(mode, origin, update, completely),
                        want,
                        "mode {mode} origin {origin} update {update} completely {completely}"
                    );
                }
            }
        }
    }
}

#[test]
fn on_quit_stays_only_for_the_two_on_modes_with_a_plain_cmd_q() {
    assert_eq!(
        cmux_background_ready_on_quit(1, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
        1
    );
    assert_eq!(
        cmux_background_ready_on_quit(2, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
        1
    );
    for origin in [
        CMUX_BACKGROUND_READY_QUIT_EXPLICIT,
        CMUX_BACKGROUND_READY_QUIT_SCRIPTED,
        CMUX_BACKGROUND_READY_QUIT_POWER_OFF,
        CMUX_BACKGROUND_READY_QUIT_SIGNAL,
    ] {
        for mode in MODES {
            assert_eq!(cmux_background_ready_on_quit(mode, origin, false, false), 0);
        }
    }
}

#[test]
fn on_quit_unknown_mode_or_origin_exits() {
    for bad in UNKNOWN {
        for update in BOOLS {
            for completely in BOOLS {
                for origin in ORIGINS {
                    assert_eq!(cmux_background_ready_on_quit(bad, origin, update, completely), 0);
                }
                for mode in MODES {
                    assert_eq!(cmux_background_ready_on_quit(mode, bad, update, completely), 0);
                }
                assert_eq!(cmux_background_ready_on_quit(bad, bad, update, completely), 0);
            }
        }
    }
}

#[test]
fn hidden_plan_full_truth_table() {
    let overrides: [(Option<&str>, u8); 9] = [
        (None, CMUX_BACKGROUND_READY_PLAN_KEEP_WINDOWS),
        (Some("keep"), CMUX_BACKGROUND_READY_PLAN_KEEP_WINDOWS),
        (Some("close"), CMUX_BACKGROUND_READY_PLAN_CLOSE_WINDOWS),
        (Some(""), 0),
        (Some("Keep"), 0),
        (Some("CLOSE"), 0),
        (Some("close "), 0),
        (Some("native"), 0),
        (Some("1"), 0),
    ];
    for mode in MODES.iter().copied().chain(UNKNOWN) {
        for (over, want) in overrides {
            assert_eq!(plan(mode, false, over), want, "mode {mode} override {over:?}");
            assert_eq!(
                plan(mode, true, over),
                CMUX_BACKGROUND_READY_PLAN_NATIVE_ONLY,
                "login-started mode {mode} override {over:?}"
            );
        }
    }
    let bad = [0xffu8, b'k', b'e', b'e', b'p', 0];
    assert_eq!(unsafe { cmux_background_ready_hidden_plan(1, false, bad.as_ptr().cast()) }, 0);
}

#[test]
fn registers_login_item_only_for_mode_two() {
    for mode in 0..=u8::MAX {
        assert_eq!(cmux_background_ready_registers_login_item(mode), mode == 2, "mode {mode}");
    }
}

#[test]
fn at_launch_full_truth_table() {
    for mode in 0..=u8::MAX {
        assert_eq!(
            cmux_background_ready_at_launch(mode, false),
            CMUX_BACKGROUND_READY_LAUNCH_NORMAL
        );
        let want = if mode == 2 {
            CMUX_BACKGROUND_READY_LAUNCH_START_HIDDEN
        } else {
            CMUX_BACKGROUND_READY_LAUNCH_EXIT_AND_UNREGISTER
        };
        assert_eq!(cmux_background_ready_at_launch(mode, true), want, "mode {mode}");
    }
}

#[test]
fn exits_for_update_full_truth_table() {
    for mode in MODES.iter().copied().chain(UNKNOWN) {
        for hidden in BOOLS {
            for staged in BOOLS {
                assert_eq!(
                    cmux_background_ready_exits_for_update(mode, hidden, staged),
                    hidden && staged,
                    "mode {mode} hidden {hidden} staged {staged}"
                );
            }
        }
    }
}

#[test]
fn starts_chromium_warmup_full_truth_table() {
    for plan in 0..=u8::MAX {
        for shown in BOOLS {
            assert_eq!(
                cmux_background_ready_starts_chromium_warmup(plan, shown),
                plan != CMUX_BACKGROUND_READY_PLAN_NATIVE_ONLY || shown,
                "plan {plan} shown {shown}"
            );
        }
    }
}

#[test]
fn off_changes_nothing() {
    // With the setting off every answer is the app's answer before it existed.
    for origin in ORIGINS {
        for update in BOOLS {
            for completely in BOOLS {
                assert_eq!(cmux_background_ready_on_quit(0, origin, update, completely), 0);
            }
        }
    }
    assert!(!cmux_background_ready_registers_login_item(0));
    assert_eq!(cmux_background_ready_at_launch(0, false), 0);
    assert!(!cmux_background_ready_exits_for_update(0, false, true));
}
