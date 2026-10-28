//! Outside bytes reach these decoders (snapshot records from a peer, PTY
//! output, replay sidecars, key events from an outer terminal). Each case
//! feeds cut, forged or boundary input and checks the result is a value or a
//! typed error with the same meaning as before the panic-free rewrite,
//! never a panic.

use ghostty_vt::{
    Callbacks, Error, KeyAction, KeyEncoder, KeyInput, KittyReplayState, Mods,
    SNAPSHOT_ENVELOPE_LEN, SNAPSHOT_RECORD_HEADER_LEN, SnapshotPhase, Terminal,
    key_input_from_chord, primary_history_pages, snapshot_digest_input, snapshot_envelope_version,
    snapshot_ready_len, snapshot_records, snapshot_tag, sys,
};

fn terminal() -> Terminal {
    Terminal::new(20, 4, 10_000, Callbacks::default()).unwrap()
}

fn envelope() -> Vec<u8> {
    let mut bytes = b"GHOSTSNP".to_vec();
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes
}

/// A record with a zero CRC: the iterators frame records, they do not check CRCs.
fn record(tag: u16, payload: &[u8]) -> Vec<u8> {
    let mut bytes = tag.to_le_bytes().to_vec();
    bytes.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_le_bytes());
    bytes.extend_from_slice(&[0; 4]);
    bytes.extend_from_slice(payload);
    bytes
}

#[test]
fn snapshot_decoders_reject_short_and_foreign_envelopes() {
    for bytes in [&b""[..], b"GHOSTSN", b"GHOSTSNP\x01", b"NOTGHOST\x01\x00"] {
        assert_eq!(snapshot_envelope_version(bytes), None);
        assert_eq!(snapshot_records(bytes).count(), 0);
        assert_eq!(snapshot_ready_len(bytes), None);
        assert!(snapshot_digest_input(bytes).is_empty());
    }
    assert_eq!(snapshot_envelope_version(&envelope()), Some(1));
}

#[test]
fn snapshot_records_stop_at_every_cut_of_a_real_snapshot() {
    let mut term = terminal();
    term.vt_write(b"hello\r\n\x1b[31mred\x1b[0m\r\n\x1b]133;A\x07$ ");
    let complete = term.encode_snapshot(SnapshotPhase::Complete).unwrap();
    let full: Vec<_> = snapshot_records(&complete).collect();
    assert_eq!(full.last().map(|record| record.tag), Some(snapshot_tag::FINISH));
    for record in &full {
        assert_eq!(record.bytes.len(), SNAPSHOT_RECORD_HEADER_LEN + record.payload().len());
        assert_eq!(&record.bytes[SNAPSHOT_RECORD_HEADER_LEN..], record.payload());
    }
    for cut in 0..complete.len() {
        let prefix = &complete[..cut];
        let records: Vec<_> = snapshot_records(prefix).collect();
        // A cut keeps exactly the records that end at or before it.
        let mut end = SNAPSHOT_ENVELOPE_LEN;
        let whole = full
            .iter()
            .take_while(|record| {
                end += record.bytes.len();
                end <= cut
            })
            .count();
        assert_eq!(records.len(), whole, "cut at {cut}");
        assert_eq!(records.as_slice(), &full[..whole]);
    }
}

#[test]
fn snapshot_record_declaring_more_payload_than_present_ends_iteration() {
    let mut bytes = envelope();
    bytes.extend_from_slice(&record(snapshot_tag::TERMINAL, b"ok"));
    let mut forged = record(snapshot_tag::SCREEN, b"");
    forged[2..6].copy_from_slice(&u32::MAX.to_le_bytes());
    bytes.extend_from_slice(&forged);
    let tags: Vec<_> = snapshot_records(&bytes).map(|record| record.tag).collect();
    assert_eq!(tags, [snapshot_tag::TERMINAL]);
    assert_eq!(snapshot_ready_len(&bytes), None);
}

#[test]
fn snapshot_digest_input_zeroes_only_a_full_screen_history_extent() {
    let long: Vec<u8> = (1..=14).collect();
    let short: Vec<u8> = (1..=11).collect();
    let mut bytes = envelope();
    bytes.extend_from_slice(&record(snapshot_tag::TERMINAL, b"excluded"));
    bytes.extend_from_slice(&record(snapshot_tag::SCREEN, &long));
    bytes.extend_from_slice(&record(snapshot_tag::SCREEN, &short));
    bytes.extend_from_slice(&record(snapshot_tag::PAGE, &[9, 9]));

    let mut expected = Vec::new();
    expected.extend_from_slice(&snapshot_tag::SCREEN.to_le_bytes());
    expected.extend_from_slice(&14u32.to_le_bytes());
    expected.extend_from_slice(&[1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 13, 14]);
    expected.extend_from_slice(&snapshot_tag::SCREEN.to_le_bytes());
    expected.extend_from_slice(&11u32.to_le_bytes());
    expected.extend_from_slice(&short);
    expected.extend_from_slice(&snapshot_tag::PAGE.to_le_bytes());
    expected.extend_from_slice(&2u32.to_le_bytes());
    expected.extend_from_slice(&[9, 9]);
    assert_eq!(snapshot_digest_input(&bytes), expected);
}

#[test]
fn primary_history_pages_refuse_short_and_missing_records() {
    let ready = |tail: &[Vec<u8>]| {
        let mut bytes = envelope();
        bytes.extend_from_slice(&record(snapshot_tag::READY, b""));
        for record in tail {
            bytes.extend_from_slice(record);
        }
        bytes
    };
    let history = |pages: u32| {
        let mut payload = vec![0, 0];
        payload.extend_from_slice(&pages.to_le_bytes());
        record(snapshot_tag::HISTORY, &payload)
    };
    let page = |rows: u16| {
        let mut payload = vec![0, 0];
        payload.extend_from_slice(&rows.to_le_bytes());
        record(snapshot_tag::PAGE, &payload)
    };

    let no_ready = record(snapshot_tag::HISTORY, &[0; 6]);
    let mut no_ready_bytes = envelope();
    no_ready_bytes.extend_from_slice(&no_ready);
    assert_eq!(primary_history_pages(&no_ready_bytes), Err(Error::InvalidValue));
    assert_eq!(primary_history_pages(&ready(&[])), Err(Error::InvalidValue));
    let short_history = record(snapshot_tag::HISTORY, &[0; 5]);
    assert_eq!(primary_history_pages(&ready(&[short_history])), Err(Error::InvalidValue));
    assert_eq!(primary_history_pages(&ready(&[history(2), page(3)])), Err(Error::InvalidValue));
    let short_page = record(snapshot_tag::PAGE, &[0; 3]);
    assert_eq!(primary_history_pages(&ready(&[history(1), short_page])), Err(Error::InvalidValue));
    assert_eq!(
        primary_history_pages(&ready(&[history(1), record(snapshot_tag::FINISH, &[0; 4])])),
        Err(Error::InvalidValue)
    );

    let pages = primary_history_pages(&ready(&[history(2), page(3), page(5)])).unwrap();
    let rows: Vec<_> = pages.iter().map(|page| (page.first_row, page.rows)).collect();
    // Newest first: the first page holds the bottom rows.
    assert_eq!(rows, [(5, 3), (0, 5)]);
    assert_eq!(pages[0].record, page(3));
}

#[test]
fn palette_overrides_track_both_halves_of_the_index_range() {
    let mut term = terminal();
    term.vt_write(b"\x1b]4;0;#010203;127;#040506;128;#070809;255;#0a0b0c\x1b\\");
    for index in [0u8, 127, 128, 255] {
        assert!(term.palette_overridden(index), "index {index}");
        assert!(term.color_overrides().palette[usize::from(index)].is_some(), "index {index}");
    }
    for index in [1u8, 126, 129, 254] {
        assert!(!term.palette_overridden(index), "index {index}");
        assert_eq!(term.color_overrides().palette[usize::from(index)], None, "index {index}");
    }
    term.vt_write(b"\x1b]104;127;128\x07");
    assert!(term.palette_overridden(0));
    assert!(!term.palette_overridden(127));
    assert!(!term.palette_overridden(128));
    assert!(term.palette_overridden(255));
    assert_eq!(term.color_overrides().palette[128], None);
    // The last request for an index in one command wins.
    term.vt_write(b"\x1b]4;5;#111111;5;?\x07\x1b]104;6\x07\x1b]4;6;#222222\x07");
    assert!(term.palette_overridden(5));
    assert!(term.palette_overridden(6));
    term.vt_write(b"\x1b]104\x07");
    assert!((0..=u8::MAX).all(|index| !term.palette_overridden(index)));
    assert!(term.color_overrides().palette.iter().all(Option::is_none));
}

#[test]
fn kitty_palette_osc_sets_and_resets_by_key() {
    let mut term = terminal();
    term.vt_write(b"\x1b]21;200=#00ff00;foreground=#ffffff;noequals;=;201=?\x1b\\");
    assert!(term.palette_overridden(200));
    assert!(!term.palette_overridden(201));
    term.vt_write(b"\x1b]21;200=\x1b\\");
    assert!(!term.palette_overridden(200));
}

#[test]
fn oversized_and_unknown_palette_commands_change_nothing() {
    let mut term = terminal();
    let mut long = b"\x1b]4;7;".to_vec();
    long.extend(std::iter::repeat_n(b'1', 4096));
    long.extend_from_slice(b"\x1b\\");
    term.vt_write(&long);
    // Operation numbers longer than three bytes are none of 4, 21 or 104.
    term.vt_write(b"\x1b]0004;8;#ffffff\x07\x1b]1040;9;#ffffff\x07\x1b]4\x07\x1b]104;256;999\x07");
    assert!((0..=u8::MAX).all(|index| !term.palette_overridden(index)));
}

#[test]
fn alternate_screen_modes_route_prompt_marks() {
    let mut term = terminal();
    // A mark made on the alternate screen does not mark the primary prompt.
    term.vt_write(b"\x1b[?1049;47;1049h\x1b]133;A\x07\x1b[?1049l");
    assert!(!term.prompt_is_marked());
    term.vt_write(b"\x1b]133;A\x07");
    assert!(term.prompt_is_marked());
    // Unknown private modes in the list neither switch nor panic.
    term.vt_write(b"\x1b[?1;2;3;4;5;6;7;8;9;10;1047;47h\x1b[?1047;47;99l\x1b[?1049s\x1b[?1049r");
    term.vt_write(b"\x1b]133;A\x07");
    assert!(term.prompt_is_marked());
}

#[test]
fn cut_sequences_at_every_byte_never_panic() {
    let stream: &[u8] = b"a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xed\x9f\xbf\xf4\x8f\xbf\xbf\
\x1b[1;2;3m\x1b[38:2::1:2:3m\x1b[12;34H\x1b[?1049h\x1b[?1049s\x1b[?1049r\x1b[?1049l\
\x1b]4;1;#ff0000\x1b\\\x1b]104;1\x07\x1b]133;A\x07\x1b]133;B\x07\
\x1b_Ga=t,m=1;AAAA\x1b\\\x1b_Ga=t,m=0;AAAA\x1b\\\x1b_G\x1b\\\x1b_Gq=2\x1b\\\x1b_Gm,=,a=\x1b\\\
\x9d4;2;#00ff00\x9c\x9b31m\x1b[2;5r\x1bc";
    for cut in 0..=stream.len() {
        let mut term = terminal();
        let (head, tail) = stream.split_at(cut);
        term.vt_write(head);
        term.vt_write(tail);
        let mut whole = terminal();
        whole.vt_write(stream);
        assert_eq!(
            term.encode_snapshot(SnapshotPhase::Ready).unwrap(),
            whole.encode_snapshot(SnapshotPhase::Ready).unwrap(),
            "split at {cut}"
        );
    }
    // Lone and invalid UTF-8 at the end of a write, then completed or not.
    for tail in [
        &b"\xc3"[..],
        b"\xe2\x82",
        b"\xf0\x9f\x98",
        b"\xed\xa0\x80",
        b"\xf4\x90",
        b"\x1b",
        b"\x1b[",
    ] {
        let mut term = terminal();
        term.vt_write(tail);
        term.vt_write(b"\x80x");
    }
}

#[test]
fn replay_cursor_offset_past_the_replay_is_refused() {
    let mut term = terminal();
    let state = KittyReplayState { replay_cursor_offset: 4, ..KittyReplayState::disabled() };
    assert_eq!(term.apply_vt_replay_parts(b"abc", &[], state), Err(Error::InvalidValue));
    let state = KittyReplayState { replay_cursor_offset: 3, ..KittyReplayState::disabled() };
    assert_eq!(term.apply_vt_replay_parts(b"abc", &[], state), Ok(()));
}

#[test]
fn function_key_chords_parse_only_f1_to_f24() {
    assert_eq!(key_input_from_chord("f1").map(|input| input.key), Some(sys::GHOSTTY_KEY_F1));
    assert_eq!(
        key_input_from_chord("shift+f24").map(|input| input.key),
        Some(sys::GHOSTTY_KEY_F24)
    );
    for chord in ["f0", "f25", "fx", "f-1", "f+1", "f99999999999"] {
        assert!(key_input_from_chord(chord).is_none(), "{chord}");
    }
}

fn kitty_encode(flags: u8, input: &KeyInput) -> Vec<u8> {
    let mut term = terminal();
    term.vt_write(format!("\x1b[>{flags}u").as_bytes());
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&term);
    let mut out = Vec::new();
    encoder.encode(input, &mut out).unwrap();
    out
}

#[test]
fn csi_u_keys_restore_reported_alternate_codepoints() {
    // Disambiguate + report alternates + all keys as escape codes.
    const FLAGS: u8 = 1 | 4 | 8;
    let shifted_a = KeyInput {
        key: sys::GHOSTTY_KEY_A,
        mods: Mods::SHIFT,
        consumed_mods: Mods::SHIFT,
        utf8: "A".into(),
        unshifted_codepoint: 'a'.into(),
        action: Some(KeyAction::Press),
        ..Default::default()
    };
    let plain = kitty_encode(FLAGS, &shifted_a);
    let with_alternates = kitty_encode(
        FLAGS,
        &KeyInput {
            shifted_codepoint: 'A'.into(),
            base_layout_codepoint: u32::MAX,
            ..shifted_a.clone()
        },
    );
    let text = |bytes: &[u8]| String::from_utf8(bytes.to_vec()).unwrap();
    assert_eq!(text(&plain), "\x1b[97:65;2u");
    // A shifted slot already present keeps its value; a missing base slot is
    // appended with every digit of u32::MAX.
    assert_eq!(text(&with_alternates), "\x1b[97:65:4294967295;2u");
    let only_base = kitty_encode(
        FLAGS,
        &KeyInput {
            mods: Mods::default(),
            consumed_mods: Mods::default(),
            utf8: "a".into(),
            base_layout_codepoint: 'q'.into(),
            ..shifted_a
        },
    );
    // No shifted slot to fill: the output is Ghostty's own.
    assert_eq!(text(&only_base), "\x1b[97u");
    let base_zero_digit = kitty_encode(
        FLAGS,
        &KeyInput { shifted_codepoint: 'A'.into(), base_layout_codepoint: 10, ..shifted_a },
    );
    assert_eq!(text(&base_zero_digit), "\x1b[97:65:10;2u");
}
