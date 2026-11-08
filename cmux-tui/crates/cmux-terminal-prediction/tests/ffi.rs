//! The C ABI (src/ffi.rs), called the way the app calls it.

use cmux_terminal_prediction::ffi::*;
use std::ptr::{null, null_mut};

const MS: u64 = 1_000_000;

/// An owned handle, freed on drop.
struct Handle(*mut CmuxTerminalPrediction);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: from cmux_terminal_prediction_new, freed once.
        unsafe { cmux_terminal_prediction_free(self.0) };
    }
}

impl Handle {
    fn new(enabled: bool, remote: bool) -> Self {
        // SAFETY: a null config means the defaults.
        let handle = unsafe { cmux_terminal_prediction_new(null(), enabled, remote) };
        assert!(!handle.is_null());
        Self(handle)
    }

    fn input(&self, text: &str, now: u64) -> bool {
        // SAFETY: a live handle and a readable buffer.
        unsafe { cmux_terminal_prediction_on_input(self.0, text.as_ptr(), text.len(), now) }
    }

    fn output(&self, text: &str, now: u64) -> bool {
        // SAFETY: a live handle and a readable buffer.
        unsafe { cmux_terminal_prediction_on_output(self.0, text.as_ptr(), text.len(), now) }
    }

    fn status(&self, now: u64) -> i32 {
        // SAFETY: a live handle.
        unsafe { cmux_terminal_prediction_status(self.0, now) }
    }

    fn glyphs(&self) -> Vec<CmuxTerminalPredictionGlyph> {
        let mut buffer = [CmuxTerminalPredictionGlyph::default(); 64];
        // SAFETY: a live handle; the buffer holds 64 glyphs.
        let total = unsafe { cmux_terminal_prediction_glyphs(self.0, buffer.as_mut_ptr(), buffer.len()) };
        buffer[..total.min(buffer.len())].to_vec()
    }

    /// Two echoes 70 ms after their keys, ending at 150 ms.
    fn armed() -> Self {
        let handle = Self::new(true, true);
        handle.input("l", 10 * MS);
        handle.output("l", 80 * MS);
        handle.input("s", 90 * MS);
        handle.output("s", 160 * MS);
        // SAFETY: a live handle.
        unsafe { cmux_terminal_prediction_on_frame(handle.0, 160 * MS) };
        handle
    }
}

#[test]
fn the_abi_version_is_the_constant() {
    assert_eq!(cmux_terminal_prediction_abi_version(), CMUX_TERMINAL_PREDICTION_ABI_VERSION);
}

#[test]
fn a_null_config_is_the_defaults_and_the_defaults_round_trip() {
    let mut config = CmuxTerminalPredictionConfig {
        engage_above_echo_latency_ns: 0,
        speculative_lifetime_ns: 0,
        confirmation_hold_ns: 0,
        mispredictions_before_suspending: 0,
        misprediction_window_ns: 0,
        suspension_ns: 0,
        maximum_speculative_glyphs: 0,
    };
    // SAFETY: a writable config.
    unsafe { cmux_terminal_prediction_config_default(&mut config) };
    assert_eq!(config.engage_above_echo_latency_ns, 25 * MS);
    assert_eq!(config.speculative_lifetime_ns, 1_500 * MS);
    assert_eq!(config.confirmation_hold_ns, 120 * MS);
    assert_eq!(config.mispredictions_before_suspending, 4);
    assert_eq!(config.misprediction_window_ns, 10_000 * MS);
    assert_eq!(config.suspension_ns, 30_000 * MS);
    assert_eq!(config.maximum_speculative_glyphs, 40);
    let round_trip: CmuxTerminalPredictionConfig =
        cmux_terminal_prediction::PredictionConfiguration::from(config).into();
    assert_eq!(round_trip, config);

    // An explicit config is used: a 200 ms threshold leaves a 70 ms link alone.
    config.engage_above_echo_latency_ns = 200 * MS;
    // SAFETY: a readable config.
    let handle = Handle(unsafe { cmux_terminal_prediction_new(&config, true, true) });
    handle.input("l", 10 * MS);
    handle.output("l", 80 * MS);
    handle.input("s", 90 * MS);
    handle.output("s", 160 * MS);
    assert_eq!(handle.status(160 * MS), CMUX_TERMINAL_PREDICTION_STATUS_LINK_IS_FAST_ENOUGH);
}

#[test]
fn two_echoes_arm_and_the_next_key_is_predicted() {
    let handle = Handle::armed();
    assert_eq!(handle.status(160 * MS), CMUX_TERMINAL_PREDICTION_STATUS_PREDICTING);
    let mut latency = 0;
    // SAFETY: a live handle and a writable u64.
    assert!(unsafe { cmux_terminal_prediction_echo_latency_ns(handle.0, &mut latency) });
    assert_eq!(latency, 70 * MS);
    let mut expiry = 0;
    // SAFETY: as above.
    assert!(!unsafe { cmux_terminal_prediction_next_expiry_ns(handle.0, &mut expiry) });

    assert!(handle.input("s", 170 * MS));
    let glyphs = handle.glyphs();
    assert_eq!(
        glyphs,
        [CmuxTerminalPredictionGlyph {
            offset: 0,
            codepoint: u32::from('s'),
            standing: CMUX_TERMINAL_PREDICTION_STANDING_SPECULATIVE,
        }]
    );
    // SAFETY: as above.
    assert!(unsafe { cmux_terminal_prediction_next_expiry_ns(handle.0, &mut expiry) });
    assert_eq!(expiry, 1_670 * MS);
}

#[test]
fn a_presented_frame_retires_a_confirmed_glyph() {
    let handle = Handle::armed();
    handle.input("s", 170 * MS);
    assert!(handle.output("s", 240 * MS));
    assert_eq!(handle.glyphs()[0].standing, CMUX_TERMINAL_PREDICTION_STANDING_CONFIRMED);
    assert_eq!(handle.glyphs()[0].offset, -1);

    // SAFETY: a live handle.
    assert!(unsafe { cmux_terminal_prediction_on_frame(handle.0, 245 * MS) });
    assert!(handle.glyphs().is_empty());
}

#[test]
fn the_layout_places_the_row_and_refuses_the_last_column() {
    let handle = Handle::armed();
    handle.input("a", 170 * MS);
    handle.input("b", 180 * MS);

    let mut layout = CmuxTerminalPredictionLayout::default();
    let mut buffer = [CmuxTerminalPredictionGlyph::default(); 8];
    // SAFETY: a live handle, a writable layout and an 8-glyph buffer.
    let drawn = unsafe {
        cmux_terminal_prediction_layout(handle.0, 5, 80, &mut layout, buffer.as_mut_ptr(), buffer.len())
    };
    assert!(drawn);
    assert_eq!(
        layout,
        CmuxTerminalPredictionLayout {
            leading_offset: 0,
            cell_count: 3,
            has_caret: true,
            caret_offset: 2,
            glyph_count: 2
        }
    );
    assert_eq!(buffer[0].codepoint, u32::from('a'));
    assert_eq!(buffer[1].codepoint, u32::from('b'));
    assert_eq!(buffer[1].offset, 1);

    // SAFETY: as above.
    let on_margin = unsafe {
        cmux_terminal_prediction_layout(handle.0, 79, 80, &mut layout, buffer.as_mut_ptr(), buffer.len())
    };
    assert!(!on_margin);
}

#[test]
fn a_small_buffer_gets_its_capacity_and_the_total() {
    let handle = Handle::armed();
    for (index, key) in ["a", "b", "c"].into_iter().enumerate() {
        handle.input(key, (170 + 10 * index as u64) * MS);
    }
    let sentinel = CmuxTerminalPredictionGlyph { offset: 99, codepoint: 0, standing: 9 };
    let mut buffer = [sentinel; 3];
    // SAFETY: a live handle; the buffer holds 3 glyphs, 2 offered.
    let total = unsafe { cmux_terminal_prediction_glyphs(handle.0, buffer.as_mut_ptr(), 2) };
    assert_eq!(total, 3);
    assert_eq!(buffer[0].codepoint, u32::from('a'));
    assert_eq!(buffer[1].codepoint, u32::from('b'));
    assert_eq!(buffer[2], sentinel);
    // SAFETY: a null buffer with no capacity only counts.
    assert_eq!(unsafe { cmux_terminal_prediction_glyphs(handle.0, null_mut(), 0) }, 3);
}

#[test]
fn a_password_prompt_never_yields_a_glyph() {
    let handle = Handle::armed();
    handle.output("\r\n[sudo] password for leo: ", 230 * MS);
    for (index, key) in ["h", "u", "n", "t", "e", "r", "2"].into_iter().enumerate() {
        handle.input(key, (240 + 10 * index as u64) * MS);
        assert!(handle.glyphs().is_empty());
    }
    assert_eq!(handle.status(320 * MS), CMUX_TERMINAL_PREDICTION_STATUS_LISTENING);
}

#[test]
fn turning_the_setting_off_withdraws() {
    let handle = Handle::armed();
    handle.input("s", 170 * MS);
    assert_eq!(handle.glyphs().len(), 1);

    // SAFETY: a live handle.
    assert!(unsafe { cmux_terminal_prediction_set_enabled(handle.0, false) });
    assert!(handle.glyphs().is_empty());
    assert_eq!(handle.status(180 * MS), CMUX_TERMINAL_PREDICTION_STATUS_DISABLED);
    // Turning it back on starts listening again, with no stale run.
    // SAFETY: as above.
    unsafe { cmux_terminal_prediction_set_enabled(handle.0, true) };
    assert_eq!(handle.status(180 * MS), CMUX_TERMINAL_PREDICTION_STATUS_LISTENING);
}

#[test]
fn a_reset_keeps_the_classification_and_drops_the_run() {
    let handle = Handle::armed();
    handle.input("s", 170 * MS);
    // SAFETY: a live handle.
    assert!(unsafe { cmux_terminal_prediction_reset(handle.0) });
    assert!(handle.glyphs().is_empty());
    assert_eq!(handle.status(180 * MS), CMUX_TERMINAL_PREDICTION_STATUS_LISTENING);
    let mut latency = 0;
    // SAFETY: as above.
    assert!(!unsafe { cmux_terminal_prediction_echo_latency_ns(handle.0, &mut latency) });

    // A local surface reset stays local.
    let local = Handle::new(true, false);
    // SAFETY: a live handle.
    unsafe { cmux_terminal_prediction_reset(local.0) };
    assert_eq!(local.status(0), CMUX_TERMINAL_PREDICTION_STATUS_LOCAL_SURFACE);
    // SAFETY: as above.
    unsafe { cmux_terminal_prediction_set_remote(local.0, true) };
    assert_eq!(local.status(0), CMUX_TERMINAL_PREDICTION_STATUS_LISTENING);
}

#[test]
fn a_seeded_alternate_screen_withholds_prediction() {
    let handle = Handle::new(true, true);
    // SAFETY: a live handle.
    unsafe { cmux_terminal_prediction_seed_alternate_screen(handle.0, true) };
    assert_eq!(handle.status(0), CMUX_TERMINAL_PREDICTION_STATUS_ALTERNATE_SCREEN);
}

#[test]
fn the_other_inputs_reach_the_engine() {
    let handle = Handle::armed();
    handle.input("s", 170 * MS);
    // SAFETY: a live handle for every call.
    unsafe {
        assert!(!cmux_terminal_prediction_on_nothing_sent(handle.0, 175 * MS));
        assert_eq!(handle.glyphs().len(), 1);
        // Ctrl-U blanks the glyph in flight.
        assert!(cmux_terminal_prediction_on_line_erase(handle.0, 180 * MS));
        assert_eq!(handle.glyphs()[0].standing, CMUX_TERMINAL_PREDICTION_STANDING_ERASED);
        assert!(cmux_terminal_prediction_on_missed_output(handle.0, 190 * MS));
        assert!(handle.glyphs().is_empty());
        assert!(!cmux_terminal_prediction_on_untracked_input(handle.0, 200 * MS));
        assert!(!cmux_terminal_prediction_tick(handle.0, 210 * MS));
        assert!(!cmux_terminal_prediction_holds_layout_until_frame(handle.0));
    }
}

#[test]
fn every_function_tolerates_a_null_handle() {
    let h = null_mut();
    let mut ns = 7;
    let mut layout = CmuxTerminalPredictionLayout::default();
    // SAFETY: every function accepts a null handle.
    unsafe {
        cmux_terminal_prediction_free(h);
        cmux_terminal_prediction_config_default(null_mut());
        assert!(!cmux_terminal_prediction_set_enabled(h, true));
        assert!(!cmux_terminal_prediction_set_remote(h, true));
        cmux_terminal_prediction_seed_alternate_screen(h, true);
        assert!(!cmux_terminal_prediction_reset(h));
        assert!(!cmux_terminal_prediction_on_input(h, b"s".as_ptr(), 1, 0));
        assert!(!cmux_terminal_prediction_on_input(h, null(), 0, 0));
        assert!(!cmux_terminal_prediction_on_line_erase(h, 0));
        assert!(!cmux_terminal_prediction_on_nothing_sent(h, 0));
        assert!(!cmux_terminal_prediction_on_untracked_input(h, 0));
        assert!(!cmux_terminal_prediction_on_output(h, b"s".as_ptr(), 1, 0));
        assert!(!cmux_terminal_prediction_on_missed_output(h, 0));
        assert!(!cmux_terminal_prediction_on_frame(h, 0));
        assert!(!cmux_terminal_prediction_tick(h, 0));
        assert_eq!(cmux_terminal_prediction_status(h, 0), CMUX_TERMINAL_PREDICTION_STATUS_INVALID);
        assert!(!cmux_terminal_prediction_echo_latency_ns(h, &mut ns));
        assert!(!cmux_terminal_prediction_next_expiry_ns(h, &mut ns));
        assert_eq!(ns, 7);
        assert!(!cmux_terminal_prediction_holds_layout_until_frame(h));
        assert_eq!(cmux_terminal_prediction_glyphs(h, null_mut(), 0), 0);
        assert!(!cmux_terminal_prediction_layout(h, 0, 80, &mut layout, null_mut(), 0));
    }
    // A live handle with null buffers and outputs only counts.
    let handle = Handle::armed();
    // SAFETY: null outputs are allowed.
    unsafe {
        assert!(cmux_terminal_prediction_echo_latency_ns(handle.0, null_mut()));
        // Empty input is a key with no knowable effect: it withdraws nothing drawn.
        assert!(!cmux_terminal_prediction_on_input(handle.0, null(), 0, 170 * MS));
    }
}
