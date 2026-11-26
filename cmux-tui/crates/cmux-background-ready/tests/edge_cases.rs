//! The edge cases of the background ready copy, each as the sequence of decisions the app asks for:
//! an update arriving while hidden, Quit Completely, a crash of the hidden process, two channels
//! installed side by side, and logout and restart. The truth tables (truth_tables.rs) cover every
//! input; these say what a person gets in each case.

use std::ffi::c_char;
use std::ptr;

use cmux_background_ready::ffi::*;

const OFF: u8 = CMUX_BACKGROUND_READY_MODE_OFF;
const AFTER_QUIT: u8 = CMUX_BACKGROUND_READY_MODE_AFTER_QUIT;
const AT_LOGIN: u8 = CMUX_BACKGROUND_READY_MODE_AFTER_QUIT_AND_LOGIN;
const ON: [u8; 2] = [AFTER_QUIT, AT_LOGIN];

fn on_quit(mode: u8, origin: u8, update_installs: bool, quit_completely: bool) -> u8 {
    cmux_background_ready_on_quit(mode, origin, update_installs, quit_completely)
}

fn plan(mode: u8, at_login: bool) -> u8 {
    let none: *const c_char = ptr::null();
    unsafe { cmux_background_ready_hidden_plan(mode, at_login, none) }
}

/// With the setting off every quit exits, whatever its origin: today's behaviour exactly.
#[test]
fn setting_off_is_todays_quit() {
    for origin in 0..=4 {
        for update in [false, true] {
            for completely in [false, true] {
                assert_eq!(on_quit(OFF, origin, update, completely), CMUX_BACKGROUND_READY_EXIT);
            }
        }
    }
    assert!(!cmux_background_ready_registers_login_item(OFF));
    assert_eq!(cmux_background_ready_at_launch(OFF, false), CMUX_BACKGROUND_READY_LAUNCH_NORMAL);
}

/// An update arrives while the copy is hidden: the hidden process exits so the installer runs, and
/// the next open is a normal launch of the new copy, never the old hidden one shown again.
#[test]
fn update_while_hidden_is_not_blocked_and_the_new_copy_shows() {
    for mode in ON {
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
            CMUX_BACKGROUND_READY_STAY_HIDDEN
        );
        assert!(
            cmux_background_ready_exits_for_update(mode, true, true),
            "a hidden copy with an update staged exits"
        );
        // The new copy is opened by a person (Dock, Finder), not by the login item: an ordinary launch.
        assert_eq!(
            cmux_background_ready_at_launch(mode, false),
            CMUX_BACKGROUND_READY_LAUNCH_NORMAL
        );
        // A shown copy is not ended under the person; nothing staged ends nothing.
        assert!(!cmux_background_ready_exits_for_update(mode, false, true));
        assert!(!cmux_background_ready_exits_for_update(mode, true, false));
    }
}

/// A Cmd-Q while an update is staged to install on quit exits, so the install is never held behind a
/// hidden process.
#[test]
fn quit_with_update_installing_on_quit_exits() {
    for mode in ON {
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, true, false),
            CMUX_BACKGROUND_READY_EXIT
        );
    }
}

/// Restart to Update records an explicit quit: it exits in every mode.
#[test]
fn restart_to_update_exits() {
    for mode in [OFF, AFTER_QUIT, AT_LOGIN] {
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_EXPLICIT, true, false),
            CMUX_BACKGROUND_READY_EXIT
        );
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_EXPLICIT, false, false),
            CMUX_BACKGROUND_READY_EXIT
        );
    }
}

/// Quit Completely ends the process for good with the setting on, from a shown window or from the
/// hidden copy's menu bar item.
#[test]
fn quit_completely_quits_for_good() {
    for mode in ON {
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, true),
            CMUX_BACKGROUND_READY_EXIT
        );
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_EXPLICIT, false, true),
            CMUX_BACKGROUND_READY_EXIT
        );
    }
}

/// A script or signal that quits expects the process gone.
#[test]
fn scripted_and_signal_quits_exit() {
    for mode in ON {
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_SCRIPTED, false, false),
            CMUX_BACKGROUND_READY_EXIT
        );
        assert_eq!(
            on_quit(mode, CMUX_BACKGROUND_READY_QUIT_SIGNAL, false, false),
            CMUX_BACKGROUND_READY_EXIT
        );
    }
}

/// The hidden process crashes: nothing is hidden any more, so the next open is an ordinary cold
/// launch with Chromium warmed as today; with the login mode, the next login starts a hidden copy again.
#[test]
fn crash_of_the_hidden_process_falls_back_to_a_normal_launch() {
    for mode in ON {
        assert_eq!(
            cmux_background_ready_at_launch(mode, false),
            CMUX_BACKGROUND_READY_LAUNCH_NORMAL
        );
        assert!(cmux_background_ready_starts_chromium_warmup(plan(mode, false), true));
    }
    assert_eq!(
        cmux_background_ready_at_launch(AT_LOGIN, true),
        CMUX_BACKGROUND_READY_LAUNCH_START_HIDDEN
    );
}

/// Two channels installed (say NIGHTLY with the login mode, stable with the setting off): each
/// bundle id has its own setting, lock and login registration. The channel that is on starts hidden at
/// login; a channel whose setting is off but whose old registration fired unregisters and exits, so it
/// never sits hidden beside the other.
#[test]
fn two_channels_decide_apart() {
    let (nightly, stable) = (AT_LOGIN, OFF);
    assert_eq!(
        cmux_background_ready_at_launch(nightly, true),
        CMUX_BACKGROUND_READY_LAUNCH_START_HIDDEN
    );
    assert_eq!(
        cmux_background_ready_at_launch(stable, true),
        CMUX_BACKGROUND_READY_LAUNCH_EXIT_AND_UNREGISTER
    );
    assert!(cmux_background_ready_registers_login_item(nightly));
    assert!(!cmux_background_ready_registers_login_item(stable));
    // Stable quits as today while NIGHTLY stays ready.
    assert_eq!(
        on_quit(stable, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
        CMUX_BACKGROUND_READY_EXIT
    );
    assert_eq!(
        on_quit(nightly, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
        CMUX_BACKGROUND_READY_STAY_HIDDEN
    );
}

/// Logout, restart and shut down are power-off quits: the hidden copy never holds them up. After a
/// restart, the login mode's copy starts hidden with no window and no Chromium until it is first shown.
#[test]
fn logout_and_restart() {
    for mode in [OFF, AFTER_QUIT, AT_LOGIN] {
        for update in [false, true] {
            assert_eq!(
                on_quit(mode, CMUX_BACKGROUND_READY_QUIT_POWER_OFF, update, false),
                CMUX_BACKGROUND_READY_EXIT
            );
        }
    }
    assert_eq!(
        cmux_background_ready_at_launch(AT_LOGIN, true),
        CMUX_BACKGROUND_READY_LAUNCH_START_HIDDEN
    );
    let login_plan = plan(AT_LOGIN, true);
    assert_eq!(login_plan, CMUX_BACKGROUND_READY_PLAN_NATIVE_ONLY);
    assert!(!cmux_background_ready_starts_chromium_warmup(login_plan, false));
    assert!(
        cmux_background_ready_starts_chromium_warmup(login_plan, true),
        "first show warms Chromium"
    );
    // The after-quit mode registers nothing, so a restart starts nothing.
    assert!(!cmux_background_ready_registers_login_item(AFTER_QUIT));
    assert_eq!(
        cmux_background_ready_at_launch(AFTER_QUIT, true),
        CMUX_BACKGROUND_READY_LAUNCH_EXIT_AND_UNREGISTER
    );
}

/// Turning the setting off while a hidden copy runs: the next quit decision is today's, and a login
/// registration left over from the login mode unregisters itself at its next fire.
#[test]
fn turning_the_setting_off_undoes_it() {
    assert!(cmux_background_ready_registers_login_item(AT_LOGIN));
    assert!(!cmux_background_ready_registers_login_item(OFF));
    assert_eq!(
        cmux_background_ready_at_launch(OFF, true),
        CMUX_BACKGROUND_READY_LAUNCH_EXIT_AND_UNREGISTER
    );
    assert_eq!(
        on_quit(OFF, CMUX_BACKGROUND_READY_QUIT_INTERACTIVE, false, false),
        CMUX_BACKGROUND_READY_EXIT
    );
}
