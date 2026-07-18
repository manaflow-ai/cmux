use ghostty_vt::{
    Callbacks, EncodedRenderScene, RenderSceneEncoder, RenderSceneError, RenderSceneLimits,
    RenderSceneOptions, SceneSectionKind, Terminal,
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
    assert_eq!(u16::from_le_bytes(bytes[4..6].try_into().unwrap()), 1);
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
fn limits_and_unsupported_state_fail_closed() {
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
    assert_eq!(
        encoder.encode(&mut terminal, value).unwrap_err(),
        RenderSceneError::UnsupportedCustomShaders
    );

    value = options();
    value.terminal_id = [0; 16];
    assert_eq!(encoder.encode(&mut terminal, value).unwrap_err(), RenderSceneError::InvalidValue);
}

#[test]
fn live_kitty_image_state_is_rejected() {
    let mut terminal = terminal();
    terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");
    let mut encoder = RenderSceneEncoder::new().unwrap();
    assert_eq!(
        encoder.encode(&mut terminal, options()).unwrap_err(),
        RenderSceneError::UnsupportedKittyImages
    );
}
