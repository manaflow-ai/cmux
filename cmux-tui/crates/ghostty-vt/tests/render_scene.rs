use ghostty_vt::{
    Callbacks, EncodedRenderScene, RenderSceneEncoder, RenderSceneError, RenderSceneHighlight,
    RenderSceneHighlightKind, RenderSceneLimits, RenderSceneOptions, RenderScenePreedit,
    SceneSectionKind, Terminal,
};

const TERMINAL_ID: [u8; 16] = [
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0x4c, 0xde, 0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
];
const PRESENTATION_ID: [u8; 16] = [
    0x20, 0x42, 0x64, 0x86, 0xa8, 0xca, 0x4e, 0xf0, 0x90, 0x22, 0x44, 0x66, 0x88, 0xaa, 0xcc, 0xee,
];

fn options() -> RenderSceneOptions<'static> {
    RenderSceneOptions {
        terminal_id: TERMINAL_ID,
        terminal_epoch: 7,
        content_sequence: 11,
        presentation_id: PRESENTATION_ID,
        presentation_generation: 3,
        presentation_sequence: 5,
        canonical_kind: SceneSectionKind::Full,
        focused: true,
        cursor_blink_visible: true,
        custom_shader_count: 0,
        preedit: None,
        highlights: &[],
        limits: RenderSceneLimits::default(),
    }
}

fn terminal() -> Terminal {
    Terminal::new(8, 2, 100, Callbacks::default()).unwrap()
}

fn assert_send_sync<T: Send + Sync>() {}

#[test]
fn full_scene_preserves_exact_caller_identity_and_sequence_header() {
    let mut terminal = terminal();
    terminal.vt_write(b"one\r\ntwo\r\nthree");
    let mut encoder = RenderSceneEncoder::new().unwrap();
    let options = options();
    let scene = encoder.encode(&mut terminal, options).unwrap();
    let bytes = scene.as_bytes();

    assert_eq!(&bytes[0..4], b"GSCN");
    assert_eq!(u16::from_le_bytes(bytes[4..6].try_into().unwrap()), 5);
    assert_eq!(bytes[16], 1);
    assert_eq!(&bytes[24..40], &TERMINAL_ID);
    assert_eq!(u64::from_le_bytes(bytes[40..48].try_into().unwrap()), 7);
    assert_eq!(u64::from_le_bytes(bytes[48..56].try_into().unwrap()), 11);
    assert_eq!(&bytes[80..96], &PRESENTATION_ID);
    assert_eq!(u64::from_le_bytes(bytes[96..104].try_into().unwrap()), 3);
    assert_eq!(u64::from_le_bytes(bytes[104..112].try_into().unwrap()), 5);
    assert_send_sync::<EncodedRenderScene>();
}

#[test]
fn canonical_delta_uses_cached_base_and_reset_requires_full() {
    let mut terminal = terminal();
    let mut encoder = RenderSceneEncoder::new().unwrap();
    let mut options = options();
    let _initial = encoder.encode(&mut terminal, options).unwrap();

    terminal.vt_write(b"changed");
    options.content_sequence += 1;
    options.presentation_sequence += 1;
    options.canonical_kind = SceneSectionKind::Delta;
    let delta = encoder.encode(&mut terminal, options).unwrap();
    assert_eq!(delta.as_bytes()[16], 2);

    encoder.reset();
    options.content_sequence += 1;
    assert_eq!(
        encoder.encode(&mut terminal, options).unwrap_err(),
        RenderSceneError::RequiresFullSnapshot
    );
}

#[test]
fn presentation_identity_is_not_cached_with_canonical_state() {
    let mut terminal = terminal();
    let mut encoder = RenderSceneEncoder::new().unwrap();
    let mut value = options();
    let _initial = encoder.encode(&mut terminal, value).unwrap();

    value.presentation_id = [0x44; 16];
    value.presentation_generation = 1;
    value.presentation_sequence = 1;
    value.canonical_kind = SceneSectionKind::Unchanged;
    let presentation = encoder.encode(&mut terminal, value).unwrap();
    assert_eq!(presentation.as_bytes()[16], 0);
    assert_eq!(&presentation.as_bytes()[80..96], &[0x44; 16]);
}

#[test]
fn scene_buffer_remains_valid_after_encoder_drop() {
    let mut terminal = terminal();
    let scene = {
        let mut encoder = RenderSceneEncoder::new().unwrap();
        encoder.encode(&mut terminal, options()).unwrap()
    };
    assert_eq!(&scene.as_bytes()[0..4], b"GSCN");
}

#[test]
fn limits_fail_closed_and_custom_shaders_are_negotiated() {
    let mut terminal = terminal();
    let mut encoder = RenderSceneEncoder::new().unwrap();
    let mut value = options();
    value.limits.max_encoded_bytes = 1;
    assert_eq!(encoder.encode(&mut terminal, value).unwrap_err(), RenderSceneError::LimitExceeded);

    value = options();
    value.limits.max_allocation_bytes = 1;
    assert_eq!(encoder.encode(&mut terminal, value).unwrap_err(), RenderSceneError::LimitExceeded);

    value = options();
    value.custom_shader_count = 1;
    let scene = encoder.encode(&mut terminal, value).unwrap();
    assert!(!scene.as_bytes().is_empty());

    value = options();
    value.terminal_id = [0; 16];
    assert_eq!(encoder.encode(&mut terminal, value).unwrap_err(), RenderSceneError::InvalidValue);
}

#[test]
fn static_kitty_image_state_is_content_addressed_and_bounded() {
    let mut terminal = terminal();
    terminal.resize(8, 2, 10, 20).unwrap();
    terminal.vt_write(b"\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1,z=1;/wAA/w==\x1b\\");
    let mut encoder = RenderSceneEncoder::new().unwrap();
    let scene = encoder.encode(&mut terminal, options()).unwrap();
    assert!(!scene.as_bytes().is_empty());

    let mut limited = options();
    limited.content_sequence += 1;
    limited.presentation_sequence += 1;
    limited.limits.max_kitty_resource_bytes = 3;
    assert_eq!(
        encoder.encode(&mut terminal, limited).unwrap_err(),
        RenderSceneError::LimitExceeded
    );
}

#[test]
fn animated_kitty_scene_is_deterministic_capability_gated_and_bounded() {
    let mut terminal = terminal();
    terminal.resize(8, 2, 10, 20).unwrap();
    terminal.vt_write(
        b"\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\\
          \x1b_Ga=f,t=d,f=32,i=1,s=1,v=1,c=1,z=25,X=1;AP8AgA==\x1b\\\
          \x1b_Ga=a,i=1,s=3,c=1,v=2;\x1b\\",
    );

    let first = RenderSceneEncoder::new().unwrap().encode(&mut terminal, options()).unwrap();
    let second = RenderSceneEncoder::new().unwrap().encode(&mut terminal, options()).unwrap();
    assert_eq!(first.as_bytes(), second.as_bytes());
    assert_eq!(u16::from_le_bytes(first.as_bytes()[4..6].try_into().unwrap()), 5);
    let capabilities = u64::from_le_bytes(first.as_bytes()[8..16].try_into().unwrap());
    assert_ne!(capabilities & (1 << 4), 0);
    assert_ne!(capabilities & (1 << 6), 0);
    assert_ne!(capabilities & (1 << 7), 0);

    let mut limited = options();
    limited.limits.max_kitty_frames = 1;
    assert_eq!(
        RenderSceneEncoder::new().unwrap().encode(&mut terminal, limited).unwrap_err(),
        RenderSceneError::LimitExceeded
    );
}

#[test]
fn rich_preedit_and_search_highlights_are_encoded_and_validated() {
    let mut terminal = terminal();
    terminal.vt_write(b"match");

    let baseline = RenderSceneEncoder::new().unwrap().encode(&mut terminal, options()).unwrap();

    let mut rich = options();
    rich.preedit = Some(RenderScenePreedit {
        text: "\u{65e5}\u{672c}",
        selection_start_utf16: 0,
        selection_length_utf16: 1,
        caret_utf16: 1,
    });
    let highlights = [RenderSceneHighlight {
        start_row: 0,
        start_column: 0,
        end_row: 0,
        end_column: 4,
        kind: RenderSceneHighlightKind::SearchMatchSelected,
    }];
    rich.highlights = &highlights;
    let encoded = RenderSceneEncoder::new().unwrap().encode(&mut terminal, rich).unwrap();
    assert_ne!(encoded.as_bytes(), baseline.as_bytes());
    assert_eq!(u16::from_le_bytes(encoded.as_bytes()[4..6].try_into().unwrap()), 5);

    let mut invalid_preedit = options();
    invalid_preedit.preedit = Some(RenderScenePreedit {
        text: "\u{65e5}",
        selection_start_utf16: 1,
        selection_length_utf16: 1,
        caret_utf16: 1,
    });
    assert_eq!(
        RenderSceneEncoder::new().unwrap().encode(&mut terminal, invalid_preedit).unwrap_err(),
        RenderSceneError::InvalidValue
    );

    let invalid_highlights = [RenderSceneHighlight {
        start_row: 0,
        start_column: 8,
        end_row: 0,
        end_column: 8,
        kind: RenderSceneHighlightKind::SearchMatch,
    }];
    let mut invalid_highlight = options();
    invalid_highlight.highlights = &invalid_highlights;
    assert_eq!(
        RenderSceneEncoder::new().unwrap().encode(&mut terminal, invalid_highlight).unwrap_err(),
        RenderSceneError::InvalidValue
    );
}
