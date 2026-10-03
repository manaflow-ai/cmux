//! Unit tests of the terminal wrapper (moved out of terminal.rs).

use crate::kitty::{
    KittyGraphicsSnapshot, KittyImage, KittyImageAlias, KittyImageFormat, KittyPlacement,
    KittyPlacementAnchor, KittyPlacementKey, KittyReplaySnapshot,
};

use super::{
    C1Normalizer, Callbacks, ClearHistoryOutcome, KittyReplayCatalog, MouseModeChangeDetector,
    PaletteOsc, PromptSemantic, PromptSemanticTracker, PromptTrackState, Screen, Terminal,
    kitty_replay_image_encodings, kitty_replay_image_len, kitty_replay_placement,
    reset_kitty_replay_image_encodings, vt_replay_row_window,
};

/// The temporary-file medium crosses the FFI as a GhosttyString in both
/// directions (it was a bool on the old fork). Enable it with a directory,
/// read it back as enabled, then disable it with NULL and read it back as
/// disabled. A bool-sized read or write here would corrupt memory.
#[test]
fn snapshot_era_kitty_temp_file_medium_crosses_ffi_as_a_string_both_ways() {
    let term = Terminal::new(20, 4, 4096, Callbacks::default()).unwrap();
    assert_eq!(term.kitty_external_image_media_enabled().unwrap(), (false, false, false));

    let directory = b"/tmp/cmux-kitty-temp";
    let value = crate::sys::GhosttyString { ptr: directory.as_ptr(), len: directory.len() };
    crate::check(unsafe {
        crate::sys::ghostty_terminal_set(
            term.raw(),
            crate::sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            (&value as *const crate::sys::GhosttyString).cast(),
        )
    })
    .unwrap();
    let mut read_back = crate::sys::GhosttyString::default();
    crate::check(unsafe {
        crate::sys::ghostty_terminal_get(
            term.raw(),
            crate::sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            (&mut read_back as *mut crate::sys::GhosttyString).cast(),
        )
    })
    .unwrap();
    let read_bytes = unsafe { std::slice::from_raw_parts(read_back.ptr, read_back.len) };
    assert_eq!(read_bytes, directory);
    assert_eq!(term.kitty_external_image_media_enabled().unwrap(), (false, true, false));

    crate::check(unsafe {
        crate::sys::ghostty_terminal_set(
            term.raw(),
            crate::sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            std::ptr::null(),
        )
    })
    .unwrap();
    assert_eq!(term.kitty_external_image_media_enabled().unwrap(), (false, false, false));
}

fn replay_placement_fixture(
    source: (u32, u32),
    grid: (u32, u32),
    pixels: (u32, u32),
    sizing: (u32, u32),
    viewport: (i32, i32),
    offset: (u32, u32),
) -> KittyPlacement {
    KittyPlacement {
        key: KittyPlacementKey { image_id: 1, placement_id: 2, ordinal: 0 },
        image_id: 1,
        placement_id: 2,
        is_internal: false,
        x_offset: offset.0,
        y_offset: offset.1,
        source_x: 0,
        source_y: 0,
        source_width: source.0,
        source_height: source.1,
        columns: sizing.0,
        rows: sizing.1,
        grid_cols: grid.0,
        grid_rows: grid.1,
        pixel_width: pixels.0,
        pixel_height: pixels.1,
        viewport_col: viewport.0,
        viewport_row: viewport.1,
        viewport_visible: true,
        anchor: None,
        z: 3,
    }
}

fn replay_placement_command(placement: &KittyPlacement) -> String {
    String::from_utf8(kitty_replay_placement(placement, (10, 20)).unwrap()).unwrap()
}

#[test]
fn unrelated_osc_tracking_keeps_palette_state_out_of_line() {
    assert!(size_of::<PaletteOsc>() <= 16);
}

#[test]
fn prompt_semantic_tracking_does_not_buffer_unrelated_osc_payloads() {
    let mut tracker = PromptSemanticTracker::default();

    tracker.feed(b"\x1b]0;");
    tracker.feed(&vec![b'x'; 4 * 1024]);

    assert!(size_of::<PromptTrackState>() <= 16);
    assert!(matches!(tracker.state, PromptTrackState::Osc(_)));
}

#[test]
fn terminal_instances_have_lifetime_stable_ids() {
    let first = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

    assert_ne!(first.instance_id(), second.instance_id());
}

#[test]
fn history_epoch_ignores_output_that_only_mutates_the_active_screen() {
    let mut terminal = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
    let initial = terminal.history_epoch();

    terminal.vt_write(b"visible");
    terminal.vt_write(b"\x1b[H\x1b[2K\x1b]2;title\x07");

    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.history_epoch(), initial);

    terminal.vt_write(b"first\r\nsecond\r\nthird");
    assert!(terminal.history_rows() > 0);
    assert!(terminal.history_epoch() > initial);
}

#[test]
fn history_epoch_ignores_kitty_content_updates_that_do_not_move_history() {
    let mut terminal = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
    terminal.vt_write(b"first\r\nsecond\r\nthird");
    assert!(terminal.history_rows() > 0);
    let history_epoch = terminal.history_epoch();

    terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=8,p=1,s=1,v=1,c=1,r=1,C=1,q=2;/wAA\x1b\\");
    terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=8,p=1,s=1,v=1,c=1,r=1,C=1,q=2;AP8A\x1b\\");

    assert_eq!(terminal.history_epoch(), history_epoch);
}

#[test]
fn history_epochs_change_across_mutations_and_terminal_instances() {
    let mut first = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
    let initial = first.history_epoch();
    first.vt_write(b"first\r\nsecond\r\nthird");
    let after_output = first.history_epoch();
    first.resize(40, 12, 8, 16).unwrap();
    let after_resize = first.history_epoch();
    let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

    assert!(after_output > initial);
    assert!(after_resize > after_output);
    assert_ne!(second.history_epoch(), after_resize);
}

#[test]
fn ordinary_output_does_not_probe_unchanged_ambiguous_mouse_modes() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1015h");
    let probes_after_modes = terminal.mouse_mode_probe.signature_calls();

    for _ in 0..128 {
        terminal.vt_write(b"ordinary application output\r\n");
    }

    assert_eq!(
        terminal.mouse_mode_probe.signature_calls(),
        probes_after_modes,
        "ordinary PTY output must not run synthetic mouse encodes"
    );
}

#[test]
fn unrelated_dec_modes_do_not_probe_ambiguous_mouse_modes() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1015h");
    let probes_after_modes = terminal.mouse_mode_probe.signature_calls();

    for _ in 0..128 {
        terminal.vt_write(b"\x1b[?2026hpaint\x1b[?2026l");
    }

    assert_eq!(
        terminal.mouse_mode_probe.signature_calls(),
        probes_after_modes,
        "synchronized-output framing must not run synthetic mouse encodes"
    );
}

/// Encode a left press, its release, and a wheel-up through encoders
/// synced from `terminal`, exactly like a scoped attach client forwarding
/// host clicks to the inner PTY.
fn synced_mouse_bytes(terminal: &Terminal) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    use crate::key::Mods;
    use crate::mouse::{MouseAction, MouseButton, MouseEncoders, MouseInput};

    let input = |action, button, any_button_pressed| MouseInput {
        action,
        button,
        mods: Mods::default(),
        position: (36.5, 20.5),
        screen_size: (80, 24),
        cell_size: (1, 1),
        any_button_pressed,
    };
    let mut encoders = MouseEncoders::new().unwrap();
    encoders.sync_from_terminal(terminal);
    let (mut press, mut release, mut wheel) = (Vec::new(), Vec::new(), Vec::new());
    encoders
        .encode_press_pair(
            input(MouseAction::Press, Some(MouseButton::Left), true),
            input(MouseAction::Release, Some(MouseButton::Left), false),
            &mut press,
            &mut release,
        )
        .unwrap();
    encoders
        .encode(input(MouseAction::Press, Some(MouseButton::WheelUp), false), &mut wheel)
        .unwrap();
    (press, release, wheel)
}

fn replayed_mirror(inner_mode_bytes: &[u8]) -> Terminal {
    let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    host.vt_write(inner_mode_bytes);
    let replay = host.vt_replay().unwrap();
    let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    mirror.apply_vt_replay(&replay).unwrap();
    mirror
}

/// btop enables 1002h, 1015h, 1006h in that order: SGR is set last, so
/// last-set-wins makes SGR the active extended-coordinate encoding.
/// Replay must reproduce that semantic, not a numeric flag dump that
/// re-enables urxvt (1015) after SGR (1006) and flips the active encoding.
#[test]
fn replay_preserves_sgr_mouse_encoding_when_sgr_is_set_last() {
    let mirror = replayed_mirror(b"\x1b[?1002h\x1b[?1015h\x1b[?1006h");
    let (press, release, wheel) = synced_mouse_bytes(&mirror);
    assert_eq!(press, b"\x1b[<0;37;21M", "press must stay SGR after replay");
    assert_eq!(release, b"\x1b[<0;37;21m", "release must stay SGR after replay");
    assert_eq!(wheel, b"\x1b[<64;37;21M", "wheel must stay SGR after replay");
}

/// The mirror case: an application that deliberately sets urxvt last must
/// keep urxvt across replay.
#[test]
fn replay_preserves_urxvt_mouse_encoding_when_urxvt_is_set_last() {
    let mirror = replayed_mirror(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h");
    let (press, release, wheel) = synced_mouse_bytes(&mirror);
    assert_eq!(press, b"\x1b[32;37;21M", "press must stay urxvt after replay");
    assert_eq!(release, b"\x1b[35;37;21M", "release must stay urxvt after replay");
    assert_eq!(wheel, b"\x1b[96;37;21M", "wheel must stay urxvt after replay");
}

/// The active wire format is a single last-set-wins selector; resetting
/// the active selector falls back to X10 even while other format flags
/// stay set (xterm semantics, mirrored by Ghostty's stream handler).
#[test]
fn active_mouse_format_tracks_last_set_wins() {
    use crate::mouse::MouseWireFormat;

    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::X10);
    terminal.vt_write(b"\x1b[?1005h");
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Utf8);
    terminal.vt_write(b"\x1b[?1015h");
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Urxvt);
    terminal.vt_write(b"\x1b[?1006h");
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Sgr);
    assert_eq!(terminal.pointer_semantic_snapshot().active_mouse_format, MouseWireFormat::Sgr);
    terminal.vt_write(b"\x1b[?1016h");
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::SgrPixels);
    terminal.vt_write(b"\x1b[?1016l");
    assert_eq!(terminal.active_mouse_format(), MouseWireFormat::X10);
}

/// A single-format application must not grow a correction suffix: its
/// numeric flag dump already replays the right active encoding.
#[test]
fn single_format_replay_carries_no_mouse_format_suffix() {
    let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    host.vt_write(b"\x1b[?1002h\x1b[?1006h");
    assert!(host.mouse_format_replay_suffix().is_empty());
    let replay = host.vt_replay_bytes().unwrap();
    let text = String::from_utf8_lossy(&replay);
    assert!(!text.contains("[?1006l"), "suffix must not reset the only format");
    assert_eq!(text.matches("[?1006h").count(), 1, "active selector emitted once");
}

#[test]
fn replay_restores_the_osc_title() {
    let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    host.vt_write(b"\x1b]2;renamed tab\x07");
    let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    mirror.apply_vt_replay(&host.vt_replay().unwrap()).unwrap();
    assert_eq!(mirror.title().as_deref(), Some("renamed tab"));

    let mut theme_portable = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    theme_portable
        .apply_vt_replay(&host.vt_replay_bounded_theme_portable_with_aliases(1 << 20).unwrap())
        .unwrap();
    assert_eq!(theme_portable.title(), mirror.title());
}

#[test]
fn replay_without_a_title_carries_no_title_suffix() {
    let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    assert!(host.title_replay_suffix().is_empty());
    let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    mirror.apply_vt_replay(&host.vt_replay().unwrap()).unwrap();
    assert_eq!(mirror.title(), None);
}

#[test]
fn replay_preflight_reserves_title_suffix_at_exact_boundary() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]2;title\x07");
    let suffix_len = terminal.replay_state_suffix().len();
    assert!(suffix_len > 0);
    assert!(terminal.preflight_vt_replay_bounded(suffix_len).is_ok());
    assert!(terminal.preflight_vt_replay_bounded(suffix_len - 1).is_err());
}

#[test]
fn replay_preflight_reserves_mouse_suffix_at_exact_boundary() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[?1006h\x1b[?1015h\x1b[?1006h");
    let suffix_len = terminal.mouse_format_replay_suffix().len();
    assert!(suffix_len > 0);
    assert!(terminal.preflight_vt_replay_bounded(suffix_len).is_ok());
    assert!(terminal.preflight_vt_replay_bounded(suffix_len - 1).is_err());
}

#[test]
fn mouse_mode_detector_keeps_controls_inside_escape_and_csi() {
    let mut detector = MouseModeChangeDetector::default();

    assert!(!detector.write(b"\x1b\x07[?100"));
    assert!(detector.write(b"6\x7fh"));
    assert!(!detector.write(&[0xc4]));
    assert!(!detector.write(&[0x9b, b'h']), "UTF-8 continuation must not open CSI");
    assert!(detector.write(b"\x1b\x07c"), "C0 controls must not hide a hard reset");
}

#[test]
fn shell_history_latest_input_text_reads_the_submitted_command() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07~/repo % \x1b]133;B\x07make test\r\n\x1b]133;C\x07");
    assert_eq!(terminal.latest_input_text(32).as_deref().map(str::trim), Some("make test"));
    // Output after C is not input; the submitted line is still found.
    terminal.vt_write(b"building\r\nok\r\n");
    assert_eq!(terminal.latest_input_text(32).as_deref().map(str::trim), Some("make test"));
}

#[test]
fn shell_history_latest_input_text_ignores_how_output_was_chunked() {
    // Prompt, B and typed text in one write (typeahead): the prompt is
    // never part of the command.
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07ls -la\r\n\x1b]133;C\x07");
    let text = terminal.latest_input_text(32).unwrap();
    assert_eq!(text.trim(), "ls -la");
    assert!(!text.contains('$'));
}

#[test]
fn shell_history_latest_input_text_is_none_without_input_or_on_the_alternate_screen() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"plain output\r\n");
    assert_eq!(terminal.latest_input_text(32), None);
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07vim\r\n\x1b]133;C\x07\x1b[?1049h");
    assert_eq!(terminal.latest_input_text(32), None);
}

#[test]
fn cursor_prompt_detection_requires_primary_screen_semantic_metadata() {
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"ordinary output");
    assert!(!terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\r\n\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?1049h");
    assert_eq!(terminal.active_screen(), Screen::Alternate);
    assert!(!terminal.cursor_is_at_prompt());
}

#[test]
fn cursor_prompt_detection_follows_live_semantics_after_input_wraps() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07123456789\x1b[B");

    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b]133;C\x07\x1b[B");
    assert!(!terminal.cursor_is_at_prompt());
}

#[test]
fn cursor_prompt_detection_keeps_primary_semantics_out_of_alternate_screen() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?1049h\x1b]133;C\x07");
    assert!(!terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?1049l");
    assert!(terminal.cursor_is_at_prompt());
}

#[test]
fn cursor_prompt_detection_follows_saved_private_screen_mode() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?1049s\x1b[?1049h\x1b]133;C\x07\x1b[?1049r");

    assert_eq!(terminal.active_screen(), Screen::Primary);
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b]133;C\x07");
    assert!(!terminal.cursor_is_at_prompt());
}

#[test]
fn cursor_prompt_detection_saves_private_screen_modes_independently() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?47h\x1b[?1049s\x1b[?1049r");

    assert_eq!(terminal.active_screen(), Screen::Primary);
    assert!(terminal.cursor_is_at_prompt());
    terminal.vt_write(b"\x1b]133;C\x07");
    assert!(!terminal.cursor_is_at_prompt());
}

#[test]
fn cursor_prompt_detection_restores_private_screen_modes_in_wire_order() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
    terminal.vt_write(b"\x1b[?47h\x1b]133;C\x07\x1b[?47s\x1b[?47l\x1b[?1049s");

    terminal.vt_write(b"\x1b[?47;1049r");
    assert_eq!(terminal.active_screen(), Screen::Primary);
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\x1b[?1049;47r");
    assert_eq!(terminal.active_screen(), Screen::Alternate);
    terminal.vt_write(b"\x1b]133;C\x07\x1b[?47l");
    assert_eq!(terminal.active_screen(), Screen::Primary);
    assert!(terminal.cursor_is_at_prompt());
}

#[test]
fn clear_history_preserves_the_active_prompt_and_cursor() {
    let mut terminal = Terminal::new(20, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..10 {
        terminal.vt_write(format!("history-{line}\r\n").as_bytes());
    }
    terminal.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
    let cursor_before = terminal.cursor_position();

    let ClearHistoryOutcome::Cleared(clear) = terminal.clear_history_preserving_prompt() else {
        panic!("active prompt was wholly inside the viewport");
    };

    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.cursor_position(), cursor_before);
    let viewport = terminal.viewport_text().unwrap();
    assert!(viewport.contains("prompt> pending"));
    assert!(!viewport.contains("history-"));
    assert!(!clear.contains(&b'\x0c'));
}

#[test]
fn clear_history_fails_closed_when_pending_wrap_cannot_be_restored() {
    let mut terminal = Terminal::new(10, 3, 1_000, Callbacks::default()).unwrap();
    for line in 0..5 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x0712345678");
    assert!(terminal.cursor_pending_wrap());
    let viewport_before = terminal.viewport_text().unwrap();

    let ClearHistoryOutcome::Cleared(clear) = terminal.clear_history_preserving_prompt() else {
        panic!("pending-wrap prompt was wholly inside the viewport");
    };

    assert_eq!(clear, b"\x1b[3J");
    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
    assert!(terminal.cursor_pending_wrap());
}

#[test]
fn clear_history_leaves_viewport_spanning_active_input_intact() {
    let mut terminal = Terminal::new(8, 3, 1_000, Callbacks::default()).unwrap();
    for line in 0..5 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07123456789012345678901234567");
    let history_before = terminal.history_rows();
    let contents_before = terminal.plain_text().unwrap();

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), history_before);
    assert_eq!(terminal.plain_text().unwrap(), contents_before);
}

#[test]
fn clear_history_rejects_prompt_continuations_whose_prompt_row_is_in_history() {
    let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..6 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(
        b"\x1b]133;A\x07$ \x1b]133;B\x07active-one\r\nactive-two\r\nactive-three\r\nactive-four\r\nactive-five",
    );
    let history_before = terminal.history_rows();
    let contents_before = terminal.plain_text().unwrap();
    let cursor_y = terminal.cursor_position().unwrap().1;
    assert!(terminal.cursor_is_at_prompt());
    assert_eq!(terminal.active_prompt_start_row(cursor_y), None);

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), history_before);
    assert_eq!(terminal.plain_text().unwrap(), contents_before);
}

#[test]
fn clear_history_rejects_repeated_prompt_markers_that_begin_in_history() {
    let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..6 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(
        b"\x1b]133;A\x07prompt-one\r\n\
          \x1b]133;A\x07prompt-two\r\n\
          \x1b]133;A\x07prompt-three\r\n\
          \x1b]133;A\x07prompt-four\r\n\
          \x1b]133;A\x07prompt-five\x1b]133;B\x07pending",
    );
    let history_before = terminal.history_rows();
    let contents_before = terminal.plain_text().unwrap();
    let cursor_y = terminal.cursor_position().unwrap().1;
    assert!(terminal.cursor_is_at_prompt());
    assert_eq!(terminal.active_prompt_start_row(cursor_y), Some(0));

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), history_before);
    assert_eq!(terminal.plain_text().unwrap(), contents_before);
}

#[test]
fn clear_history_accepts_row_zero_prompt_after_output_history() {
    let mut terminal = Terminal::new(32, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..6 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(
        b"\x1b]133;A\x07prompt-one\r\n\
          \x1b]133;A\x07prompt-two\r\n\
          \x1b]133;A\x07prompt-three\r\n\
          \x1b]133;A\x07prompt-four\x1b]133;B\x07pending",
    );
    let history_before = terminal.history_rows();
    let viewport_before = terminal.viewport_text().unwrap();
    let cursor_before = terminal.cursor_position();
    let cursor_y = cursor_before.unwrap().1;
    assert!(terminal.cursor_is_at_prompt());
    assert_eq!(terminal.active_prompt_start_row(cursor_y), Some(0));

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
    assert_eq!(terminal.cursor_position(), cursor_before);
}

#[test]
fn clear_history_without_prompt_metadata_clears_scrollback_only() {
    let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..6 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(b"first-active\r\nsecond-active");
    let history_before = terminal.history_rows();
    let viewport_before = terminal.viewport_text().unwrap();
    let cursor_before = terminal.cursor_position();

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
    assert_eq!(terminal.cursor_position(), cursor_before);
}

#[test]
fn clear_history_without_prompt_metadata_preserves_visible_hard_newline_rows() {
    let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
    for line in 0..6 {
        terminal.vt_write(format!("old-{line}\r\n").as_bytes());
    }
    terminal.vt_write(b"active-one\r\nactive-two\r\nactive-three\r\nactive-four");
    let history_before = terminal.history_rows();
    let viewport_before = terminal.viewport_text().unwrap();

    let outcome = terminal.clear_history_preserving_prompt();

    assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
    assert!(history_before > 0);
    assert_eq!(terminal.history_rows(), 0);
    assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
}

#[test]
fn clear_history_fails_closed_at_every_partial_vt_boundary() {
    let sequences: &[(&str, &[u8])] = &[
        ("escape-intermediate", b"\x1b(B"),
        ("csi", b"\x1b[31m"),
        ("osc-bel", b"\x1b]2;title\x07"),
        ("osc-st", b"\x1b]2;title\x1b\\"),
        ("osc-utf8-st-byte", "\x1b]2;Ütitle\x07".as_bytes()),
        ("c1-osc", b"\x9d2;title\x9c"),
        ("dcs", b"\x1bP1;2qpayload\x1b\\"),
        ("apc", b"\x1b_payload\x1b\\"),
        ("utf8", "🙂".as_bytes()),
    ];

    for &(name, sequence) in sequences {
        for split in 1..sequence.len() {
            let mut terminal = Terminal::new(20, 4, 1_000, Callbacks::default()).unwrap();
            for line in 0..10 {
                terminal.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            terminal.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
            terminal.vt_write(&sequence[..split]);
            let history_before = terminal.history_rows();
            let contents_before = terminal.plain_text().unwrap();

            assert_eq!(
                terminal.clear_history_preserving_prompt(),
                ClearHistoryOutcome::Blocked,
                "{name} split at byte {split}"
            );
            assert_eq!(terminal.history_rows(), history_before, "{name} split at byte {split}");
            assert_eq!(
                terminal.plain_text().unwrap(),
                contents_before,
                "{name} split at byte {split}"
            );

            terminal.vt_write(&sequence[split..]);
            terminal.vt_write(b"Z");
            assert!(
                terminal.viewport_text().unwrap().contains('Z'),
                "{name} split at byte {split}"
            );
            assert!(
                matches!(
                    terminal.clear_history_preserving_prompt(),
                    ClearHistoryOutcome::Cleared(_)
                ),
                "{name} remained unsafe after completing split at byte {split}"
            );
        }
    }
}

#[test]
fn prompt_semantic_tracking_ignores_utf8_continuation_bytes_that_resemble_c1() {
    let mut tracker = PromptSemanticTracker::default();
    tracker.feed(b"\x1b]133;A\x07\x1b]133;B\x07");
    assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Input);

    tracker.feed("\u{45d}".as_bytes());
    tracker.feed(b"\x1b]133;C\x07");

    assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
}

#[test]
fn prompt_semantic_tracking_ignores_control_string_payload_newlines() {
    for introducer in *b"PX^_" {
        let mut tracker = PromptSemanticTracker::default();
        tracker.feed(b"\x1b]133;I\x07");
        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::InputUntilEndOfLine);

        tracker.feed(&[0x1b, introducer, b'q', b'\n', 0x1b, b'\\']);
        assert_eq!(
            tracker.semantic(Screen::Primary),
            PromptSemantic::InputUntilEndOfLine,
            "control-string introducer {introducer:#x} leaked its payload"
        );

        tracker.feed(b"\n");
        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
    }
}

#[test]
fn prompt_semantic_tracking_rejects_suffixes_without_an_option_separator() {
    let mut tracker = PromptSemanticTracker::default();
    tracker.feed(b"\x1b]133;C\x07");
    let revision = tracker.revision();
    assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);

    tracker.feed(b"\x1b]133;Agarbage\x1b\\");

    assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
    assert_eq!(tracker.revision(), revision);

    tracker.feed(b"\x1b]133;A;redraw=1\x1b\\");
    assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Prompt);
    assert_eq!(tracker.revision(), revision.wrapping_add(1));
}

#[test]
fn live_output_phase_overrides_persisted_prompt_rows() {
    let mut terminal = Terminal::new(20, 4, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07command");
    assert!(terminal.cursor_is_at_prompt());

    terminal.vt_write(b"\r\n\x1b]133;C\x07output\x1b[A\r");

    assert!(!terminal.cursor_is_at_prompt());
}

#[test]
fn bounded_vt_replay_keeps_the_latest_screen_after_large_history() {
    let mut source = Terminal::new(80, 24, 2 * 1024 * 1024, Callbacks::default()).unwrap();
    let wide_line = "x".repeat(2048);
    for index in 0..500 {
        source.vt_write(format!("history-{index:04}-{wide_line}\r\n").as_bytes());
    }
    source.vt_write(b"LATEST-VISIBLE-CONTENT");

    let full = source.vt_replay_bytes().unwrap();
    assert!(full.len() > 32 * 1024);

    let bounded = source.vt_replay_bounded_bytes(32 * 1024).unwrap();
    assert!(bounded.len() <= 32 * 1024);

    let mut restored = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    restored.vt_write(&bounded);
    assert!(restored.viewport_text().unwrap().contains("LATEST-VISIBLE-CONTENT"));
}

#[test]
fn bounded_vt_replay_preserves_complete_history_when_it_fits() {
    let mut source = Terminal::new(80, 24, 4 * 1024 * 1024, Callbacks::default()).unwrap();
    for index in 0..10_000 {
        source.vt_write(format!("plain-history-{index:05}\r\n").as_bytes());
    }
    source.vt_write(b"LATEST-VISIBLE-CONTENT");

    let full = source.vt_replay_bytes().unwrap();
    assert!(full.len() < 8 * 1024 * 1024);
    assert_eq!(source.vt_replay_bounded_bytes(8 * 1024 * 1024).unwrap(), full);
}

#[test]
fn vt_replay_preserves_sparse_viewport_rows_without_scrolling_them_into_history() {
    let mut source = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    source.vt_write(b"READY\r\n");
    let expected = source.viewport_text().unwrap();
    assert!(expected.contains("READY"));

    let replay = source.vt_replay_bytes().unwrap();
    let mut target = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    target.vt_write(&replay);

    assert_eq!(target.viewport_text().unwrap(), expected);
}

#[test]
fn vt_replay_preserves_blank_tail_after_history() {
    let mut source = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    for _ in 0..12 {
        source.vt_write(b"history\r\n");
    }
    source.vt_write(b"\x1b[2J\x1b[HHEADER\x1b[5;1H> Ask Codex\x1b[6;1HSTATUS\x1b[5;3H");
    let expected = source.viewport_text().unwrap();
    let replay = source.vt_replay_bounded_theme_portable(128 * 1024).unwrap();
    let mut restored = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    restored.vt_write(&replay);

    assert_eq!(restored.viewport_text().unwrap(), expected);
    assert_eq!(restored.cursor_position(), source.cursor_position());

    // A TUI continues with absolute-cell diffs after attaching. Its header,
    // composer and cursor must still agree on the same physical rows.
    let update = b"\x1b[5;3HInput\x1b[6;1HDONE\x1b[5;8H";
    source.vt_write(update);
    restored.vt_write(update);
    assert_eq!(restored.viewport_text().unwrap(), source.viewport_text().unwrap());
}

#[test]
fn vt_replay_preserves_codex_composer_before_incremental_redraw() {
    let mut source = Terminal::new(40, 8, 100, Callbacks::default()).unwrap();
    for _ in 0..12 {
        source.vt_write(b"history\r\n");
    }
    source.vt_write(
        b"\x1b[2J\x1b[HOpenAI Codex\x1b[4;1H> Ask Codex to do anything\x1b[5;1HSTATUS\x1b[4;3H",
    );
    let expected = source.viewport_text().unwrap();
    let replay = source.vt_replay_bounded_theme_portable(128 * 1024).unwrap();
    let mut restored = Terminal::new(40, 8, 100, Callbacks::default()).unwrap();
    restored.vt_write(&replay);

    assert_eq!(restored.viewport_text().unwrap(), expected);

    // Codex redraws the composer incrementally after a restore. The
    // replacement replay and the next redraw must share the same rows.
    let update = b"\x1b[4;1H\x1b[2K> NEW PROMPT\x1b[5;1HDONE\x1b[4;3H";
    source.vt_write(update);
    restored.vt_write(update);
    assert_eq!(restored.viewport_text().unwrap(), source.viewport_text().unwrap());
}

#[test]
fn theme_portable_replay_retains_aliases_for_admitted_kitty_images() {
    let mut source = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
    source.vt_write(b"\x1b_Ga=T,t=d,f=24,I=77,p=0,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\");
    let image_id = source.kitty_graphics_snapshot().unwrap().images[0].id;

    let replay = source.vt_replay_bounded_theme_portable_with_aliases(1024 * 1024).unwrap();
    assert_eq!(replay.kitty_image_aliases, vec![KittyImageAlias { image_id, image_number: 77 }]);

    let mut target = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
    target.vt_write(&replay.bytes);
    target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    target.vt_write(b"\x1b_Ga=p,I=77,p=5,c=1,r=1,q=2;\x1b\\");
    assert_eq!(target.kitty_graphics_snapshot().unwrap().placements[0].image_id, image_id);
}

#[test]
fn kitty_replay_placement_does_not_replace_the_saved_cursor_slot() {
    let mut source = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    source.resize(20, 8, 10, 20).unwrap();
    source.vt_write(b"before");
    source.vt_write(b"\x1b_Ga=T,t=d,f=32,i=77,p=1,s=1,v=1,c=2,r=2,q=2;/wAAfw==\x1b\\");
    source.vt_write(b"\x1b[8;10Htail");
    let source_graphics = source.kitty_graphics_snapshot().unwrap();
    assert_eq!(source_graphics.placements.len(), 1);
    assert!(
        source_graphics.placements[0].pixel_width > 0,
        "fixture placement: {:?}",
        source_graphics.placements[0]
    );

    let replay = source.vt_replay_bounded_theme_portable_with_aliases(1024 * 1024).unwrap();
    let mut target = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    target.resize(20, 8, 10, 20).unwrap();
    target.vt_write(&replay.bytes);
    assert_eq!(target.kitty_graphics_snapshot().unwrap().placements.len(), 1);
    target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    target.vt_write(b"\x1b[8;20H\x1b8");

    assert_eq!(
        target.cursor_position(),
        Some((0, 0)),
        "a placement replay must leave the no-save DECRC fallback unchanged"
    );
}

#[test]
fn minimal_bounded_replay_resets_before_numbered_kitty_images() {
    let mut source = Terminal::new(256, 1, 0, Callbacks::default()).unwrap();
    source.vt_write("x".repeat(255).as_bytes());
    source.vt_write(b"\x1b_Ga=t,t=d,f=24,I=77,s=1,v=1,q=2;/wAA\x1b\\");
    let snapshot = source.kitty_graphics_snapshot().unwrap();
    let image = snapshot.images.first().unwrap();
    let max_bytes = kitty_replay_image_len(image).unwrap() + b"\x1bc".len();
    let text = source
        .vt_replay_text_layout_bounded(
            max_bytes,
            &super::KittyReplayRowIndex::default(),
            None,
            false,
        )
        .unwrap();
    assert_eq!(text.range, None, "fixture did not reach the minimal reset fallback");

    let replay = source.vt_replay_bounded_theme_portable_with_aliases(max_bytes).unwrap();
    assert_eq!(
        replay.kitty_image_aliases,
        vec![KittyImageAlias { image_id: image.id, image_number: 77 }]
    );
    assert!(
        replay.bytes.starts_with(b"\x1bc\x1b_G"),
        "the terminal reset cleared a preceding image transmission: {:?}",
        replay.bytes
    );

    let mut target = Terminal::new(256, 1, 0, Callbacks::default()).unwrap();
    target.vt_write(&replay.bytes);
    target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    target.vt_write(b"\x1b_Ga=p,I=77,p=5,c=1,r=1,q=2;\x1b\\");
    assert_eq!(target.kitty_graphics_snapshot().unwrap().placements[0].image_id, image.id);
}

#[test]
fn bounded_vt_replay_limits_rows_before_formatting_large_history() {
    let rows = vt_replay_row_window(1_000_000, 24, 80, 8 * 1024 * 1024);

    assert_eq!(rows, 3_276);
}

#[test]
fn bounded_text_replay_snaps_to_the_oldest_fitting_placement_anchor() {
    let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    for row in 0..40 {
        source.vt_write(format!("row-{row:02}\r\n").as_bytes());
    }
    source.vt_write(b"tail");
    let scrollbar = source.scrollbar().unwrap();
    let anchor_row = scrollbar.total - 12;
    let placement_rows = [anchor_row].into_iter().collect();
    let anchor_range = super::ReplayRowRange { start: anchor_row, end: scrollbar.total - 1 };
    let anchor_bytes = source
        .vt_replay_text_range_bounded(anchor_range, &placement_rows, usize::MAX, true)
        .unwrap()
        .unwrap()
        .bytes
        .len();
    let older_range =
        super::ReplayRowRange { start: scrollbar.total - 16, end: scrollbar.total - 1 };
    assert!(
        source
            .vt_replay_text_range_bounded(older_range, &placement_rows, anchor_bytes, true)
            .unwrap()
            .is_none(),
        "fixture must put the anchor between a fitting and oversized geometric window"
    );

    let replay = source
        .vt_replay_text_layout_bounded(
            anchor_bytes,
            &placement_rows,
            Some(scrollbar.total - scrollbar.len),
            true,
        )
        .unwrap();

    assert_eq!(replay.range.unwrap().start, anchor_row);
}

#[test]
fn kitty_replay_groups_each_placement_once() {
    let image_count = 64_u32;
    let images = (1..=image_count)
        .map(|id| KittyImage {
            id,
            number: 0,
            generation: u64::from(id),
            width: 1,
            height: 1,
            format: KittyImageFormat::Rgb,
            data: std::sync::Arc::from([0_u8, 0, 0]),
        })
        .collect::<Vec<_>>();
    let placements = (1..=image_count)
        .map(|id| {
            let mut placement =
                replay_placement_fixture((1, 1), (1, 1), (1, 1), (1, 1), (0, 0), (0, 0));
            placement.key.image_id = id;
            placement.image_id = id;
            placement
        })
        .collect::<Vec<_>>();
    let anchors = placements
        .iter()
        .enumerate()
        .map(|(row, placement)| {
            (placement.key, KittyPlacementAnchor { col: 0, row: u32::try_from(row).unwrap() })
        })
        .collect();
    let snapshot = KittyReplaySnapshot {
        graphics: KittyGraphicsSnapshot { generation: 1, images, placements },
        anchors,
    };

    let catalog = KittyReplayCatalog::new(&snapshot, (1, 1), 24);

    assert_eq!(catalog.placement_grouping_visits, snapshot.graphics.placements.len());
}

#[test]
fn kitty_replay_does_not_encode_images_rejected_by_the_budget() {
    let snapshot = KittyReplaySnapshot {
        graphics: KittyGraphicsSnapshot {
            generation: 1,
            images: vec![KittyImage {
                id: 1,
                number: 0,
                generation: 1,
                width: 1,
                height: 1,
                format: KittyImageFormat::Rgb,
                data: std::sync::Arc::from([0_u8, 0, 0]),
            }],
            placements: Vec::new(),
        },
        anchors: Default::default(),
    };

    reset_kitty_replay_image_encodings();
    let catalog = KittyReplayCatalog::new(&snapshot, (1, 1), 24);
    let replay = catalog.plan(None, 0, false);

    assert!(replay.image_bytes.is_empty());
    assert_eq!(
        kitty_replay_image_encodings(),
        0,
        "catalog construction encoded an image that the replay budget rejected"
    );
}

#[test]
fn bounded_replay_clips_a_placement_overlapping_the_retained_window() {
    let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    source.resize(12, 4, 10, 20).unwrap();
    for row in 0..12 {
        source.vt_write(format!("row-{row:02}\r\n").as_bytes());
    }
    source.vt_write(b"tail");
    let end = source.scrollbar().unwrap().total - 1;
    let range = super::ReplayRowRange { start: end - 5, end };
    let anchor = KittyPlacementAnchor { col: 0, row: u32::try_from(range.start - 1).unwrap() };
    let placement = replay_placement_fixture((10, 60), (1, 3), (10, 60), (1, 3), (0, 0), (0, 0));
    let snapshot = KittyReplaySnapshot {
        graphics: KittyGraphicsSnapshot {
            generation: 1,
            images: vec![KittyImage {
                id: 1,
                number: 0,
                generation: 1,
                width: 10,
                height: 60,
                format: KittyImageFormat::Rgb,
                data: std::sync::Arc::from(vec![127_u8; 10 * 60 * 3]),
            }],
            placements: vec![placement.clone()],
        },
        anchors: [(placement.key, anchor)].into_iter().collect(),
    };
    let catalog = KittyReplayCatalog::new(&snapshot, (10, 20), 4);
    let text = source
        .vt_replay_text_range_bounded(range, catalog.placement_rows(), usize::MAX, true)
        .unwrap()
        .unwrap();
    let graphics = catalog.plan(Some(range), usize::MAX, false);
    let mut replay = graphics.image_bytes;
    replay.extend(text.interleave(&graphics.placements).unwrap());

    let mut restored = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    restored.resize(12, 4, 10, 20).unwrap();
    restored.vt_write(&replay);
    let restored_graphics = restored.kitty_graphics_snapshot().unwrap();
    let restored_placement = restored_graphics.placements.first().expect("overlapping placement");

    assert_eq!(restored_placement.source_y, 20);
    assert_eq!(restored_placement.source_height, 40);
    assert_eq!(restored_placement.rows, 2);
    assert_eq!(restored_placement.grid_rows, 2);
}

#[test]
fn kitty_inflight_tracking_uses_the_normalized_c1_stream() {
    let mut terminal = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
    terminal.vt_write(&[0xe0]);
    terminal.vt_write(b"\x9fGa=t,t=d,f=24,i=92,s=1,v=2,m=1;AAAA\x9c");

    assert!(
        terminal.kitty_inflight.replay_prefix(usize::MAX).is_empty(),
        "a UTF-8 continuation byte that Ghostty parsed as text became a replayable Kitty APC"
    );
}

#[test]
fn c1_control_string_introducers_normalize_to_escape_forms() {
    let mut normalizer = C1Normalizer::default();
    assert_eq!(normalizer.normalize(b"a\x90b"), b"a\x1bPb".as_slice());
    assert_eq!(normalizer.normalize(b"a\x98b"), b"a\x1bXb".as_slice());
    assert_eq!(normalizer.normalize(b"a\x9eb"), b"a\x1b^b".as_slice());
}

#[test]
fn c1_control_string_normalization_handles_split_sequences_and_st() {
    let mut normalizer = C1Normalizer::default();
    assert_eq!(normalizer.normalize(b"\x90payload"), b"\x1bPpayload".as_slice());
    assert_eq!(normalizer.normalize(b"\x9c"), b"\x1b\\".as_slice());

    assert_eq!(normalizer.normalize(b"\x98part"), b"\x1bXpart".as_slice());
    assert_eq!(normalizer.normalize(b"ial\x9e"), b"ial\x1b^".as_slice());
    assert_eq!(normalizer.normalize(b"body\x9c"), b"body\x1b\\".as_slice());
}

#[test]
fn c1_control_string_continuation_bytes_are_not_normalized() {
    let mut normalizer = C1Normalizer::default();
    assert_eq!(normalizer.normalize(&[0xe2]).as_ref(), &[0xe2]);
    assert_eq!(normalizer.normalize(&[0x98, 0x80]).as_ref(), &[0x98, 0x80]);
}

#[test]
fn replay_native_left_clip_preserves_native_pixel_size() {
    let command = replay_placement_command(&replay_placement_fixture(
        (15, 10),
        (2, 1),
        (15, 10),
        (0, 0),
        (-1, 0),
        (4, 0),
    ));

    assert!(command.contains("x=6,y=0,w=9,h=10,X=0,Y=0"), "{command:?}");
    assert!(!command.contains(",c="), "{command:?}");
    assert!(!command.contains(",r="), "{command:?}");
}

#[test]
fn replay_column_only_top_clip_keeps_rows_inferred() {
    let command = replay_placement_command(&replay_placement_fixture(
        (20, 10),
        (2, 2),
        (20, 10),
        (2, 0),
        (0, -1),
        (0, 15),
    ));

    assert!(command.contains("x=0,y=5,w=20,h=5,X=0,Y=0,c=2"), "{command:?}");
    assert!(!command.contains(",r="), "{command:?}");
}

#[test]
fn replay_row_only_left_clip_keeps_columns_inferred() {
    let command = replay_placement_command(&replay_placement_fixture(
        (10, 40),
        (2, 2),
        (10, 40),
        (0, 2),
        (-1, 0),
        (5, 0),
    ));

    assert!(command.contains("x=5,y=0,w=5,h=40,X=0,Y=0,r=2"), "{command:?}");
    assert!(!command.contains(",c="), "{command:?}");
}
