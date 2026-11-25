use super::*;
use ghostty_vt::CursorShape;

#[test]
fn colors_payload_is_versioned_bounded_full_sparse_state() {
    let mut colors = TerminalColorOverrides {
        foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
        background: Some(Rgb { r: 4, g: 5, b: 6 }),
        cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
        cursor_visual: Some((CursorShape::Underline, true)),
        ..Default::default()
    };
    colors.palette[0] = Some(Rgb { r: 10, g: 11, b: 12 });
    colors.palette[255] = Some(Rgb { r: 13, g: 14, b: 15 });
    let payload = encode_terminal_color_overrides(&colors);
    assert!(payload.len() <= MAX_TERMINAL_COLORS_PAYLOAD);
    assert_eq!(
        payload,
        vec![
            2, 0, 15, 0, 2, 0, 0, 0, // v2 header, all fields, two palette entries
            1, 2, 3, 4, 5, 6, 7, 8, 9, // optional RGBs
            2, 1, // underline, blinking
            0, 10, 11, 12, 255, 13, 14, 15, // palette entries
        ]
    );
    assert_eq!(&payload[0..2], &TERMINAL_COLORS_WIRE_VERSION.to_le_bytes());
    assert_eq!(&payload[2..4], &0b1111u16.to_le_bytes());
    assert_eq!(&payload[17..19], &[2, 1], "cursor visual follows the optional RGBs");
    assert_eq!(decode_terminal_color_overrides(&payload).unwrap(), colors);
}

#[test]
fn colors_payload_v2_requires_resolved_cursor_visual() {
    // Without a resolved cursor visual the encoder falls back to v1.
    let fallback = encode_terminal_color_overrides(&TerminalColorOverrides::default());
    assert_eq!(fallback, [1, 0, 0, 0, 0, 0, 0, 0]);
    assert_eq!(
        decode_terminal_color_overrides(&fallback).unwrap(),
        TerminalColorOverrides::default()
    );
    assert!(
        decode_terminal_color_overrides(&[2, 0, 0, 0, 0, 0, 0, 0]).is_err(),
        "v2 without the atomic cursor pair must fail closed"
    );
}

#[test]
fn colors_payload_decodes_v1_without_cursor_visual() {
    assert_eq!(
        decode_terminal_color_overrides(&[1, 0, 0, 0, 0, 0, 0, 0]).unwrap(),
        TerminalColorOverrides::default()
    );
    let payload = [
        1, 0, // schema v1
        7, 0, // foreground, background, and cursor RGB
        0, 0, // no palette entries
        0, 0, // reserved
        1, 2, 3, // foreground
        4, 5, 6, // background
        7, 8, 9, // cursor
    ];
    assert_eq!(
        decode_terminal_color_overrides(&payload).unwrap(),
        TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            background: Some(Rgb { r: 4, g: 5, b: 6 }),
            cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
            ..Default::default()
        }
    );

    let mut v1_with_v2_flag = payload.to_vec();
    v1_with_v2_flag[2..4].copy_from_slice(&0b1111u16.to_le_bytes());
    v1_with_v2_flag.extend_from_slice(&[1, 0]);
    assert!(decode_terminal_color_overrides(&v1_with_v2_flag).is_err());
}

#[test]
fn colors_payload_cursor_visual_round_trips_every_v2_value() {
    for cursor_visual in [
        (CursorShape::Block, false),
        (CursorShape::Block, true),
        (CursorShape::Underline, false),
        (CursorShape::Underline, true),
        (CursorShape::Bar, false),
        (CursorShape::Bar, true),
    ] {
        let colors =
            TerminalColorOverrides { cursor_visual: Some(cursor_visual), ..Default::default() };
        let payload = encode_terminal_color_overrides(&colors);
        assert_eq!(payload.len(), 10);
        assert_eq!(decode_terminal_color_overrides(&payload).unwrap(), colors);
    }

    // DECSCUSR and the cross-language wire have no hollow-block value.
    let hollow = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::BlockHollow, false)),
        ..Default::default()
    };
    let payload = encode_terminal_color_overrides(&hollow);
    assert_eq!(&payload[8..10], &[1, 0]);
    assert_eq!(
        decode_terminal_color_overrides(&payload).unwrap().cursor_visual,
        Some((CursorShape::Block, false))
    );
}

#[test]
fn colors_payload_rejects_unknown_versions_duplicates_and_malformed_visuals() {
    let mut colors = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Block, false)),
        ..Default::default()
    };
    colors.palette[1] = Some(Rgb { r: 1, g: 2, b: 3 });
    colors.palette[2] = Some(Rgb { r: 4, g: 5, b: 6 });
    let payload = encode_terminal_color_overrides(&colors);

    let mut bad_version = payload.clone();
    bad_version[0..2].copy_from_slice(&3u16.to_le_bytes());
    assert!(decode_terminal_color_overrides(&bad_version).is_err());

    let mut bad_flags = payload.clone();
    bad_flags[2..4].copy_from_slice(&0b1_1000u16.to_le_bytes());
    assert!(decode_terminal_color_overrides(&bad_flags).is_err());

    let mut bad_reserved = payload.clone();
    bad_reserved[6] = 1;
    assert!(decode_terminal_color_overrides(&bad_reserved).is_err());

    let mut duplicate = payload.clone();
    duplicate[14] = duplicate[10];
    assert!(decode_terminal_color_overrides(&duplicate).is_err());

    let mut trailing = payload;
    trailing.push(0);
    assert!(decode_terminal_color_overrides(&trailing).is_err());

    let visual = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Bar, true)),
        ..Default::default()
    };
    let visual = encode_terminal_color_overrides(&visual);
    let mut zero_style = visual.clone();
    zero_style[8] = 0;
    assert!(decode_terminal_color_overrides(&zero_style).is_err());
    let mut bad_style = visual.clone();
    bad_style[8] = 4;
    assert!(decode_terminal_color_overrides(&bad_style).is_err());
    let mut bad_blink = visual.clone();
    bad_blink[9] = 2;
    assert!(decode_terminal_color_overrides(&bad_blink).is_err());
    let mut truncated = visual;
    truncated.pop();
    assert!(decode_terminal_color_overrides(&truncated).is_err());
}
