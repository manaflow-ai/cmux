//! The Swift behavior this crate ports (ScreenStream.swift, ScreenSession.swift), case by case.

use cmux_screen_stream::ffi;
use cmux_screen_stream::ops::{OpError, call};
use cmux_screen_stream::quality::{self, Degradation, Quality, Rect};
use cmux_screen_stream::wire::{
    Delivery, PasteImageOutcome, ScreenHostMessage, ScreenInput, SourceState, delivery,
};
use serde_json::json;

#[test]
fn input_decodes_like_the_swift_decoder() {
    let input =
        ScreenInput::decode(br#"{"t":"scroll","x":0.5,"y":0.25,"dx":2.5,"dy":-2.5,"u":"px"}"#)
            .unwrap();
    assert_eq!((input.dx, input.dy), (Some(3), Some(-3)));
    assert_eq!(
        ScreenInput::decode(br#"{"t":"scroll","dx":1e300}"#).unwrap().dx,
        Some(1_000_000_000_000_000)
    );
    assert_eq!(
        ScreenInput::decode(br#"{"t":"scroll","dx":123456789012345678}"#).unwrap().dx,
        Some(123_456_789_012_345_678)
    );
    let whole =
        ScreenInput::decode(br#"{"t":"scroll","dx":2e15,"dy":-2000000000000000.0}"#).unwrap();
    assert_eq!((whole.dx, whole.dy), (Some(2_000_000_000_000_000), Some(-2_000_000_000_000_000)));
    // A whole float is an Int; a fraction anywhere else fails the message.
    assert_eq!(ScreenInput::decode(br#"{"t":"display","i":2.0}"#).unwrap().i, Some(2));
    assert!(ScreenInput::decode(br#"{"t":"display","i":2.5}"#).is_none());
    assert!(ScreenInput::decode(br#"{"t":"move","b":256}"#).is_none());
    assert!(ScreenInput::decode(br#"{"t":"key","k":-1}"#).is_none());
    assert!(ScreenInput::decode(br#"{"x":1}"#).is_none());
    // Nulls are absent; unknown keys are ignored.
    let input = ScreenInput::decode(br#"{"t":"move","x":null,"zz":1}"#).unwrap();
    assert_eq!(input, ScreenInput::new("move"));
}

#[test]
fn input_encodes_only_present_keys() {
    assert_eq!(
        ScreenInput::scroll(0.5, 0.5, 1, -2, true).encode(),
        r#"{"t":"scroll","x":0.5,"y":0.5,"dx":1,"dy":-2,"u":"px"}"#
    );
    assert_eq!(
        ScreenInput::scroll(0.5, 0.5, 1, -2, false).encode(),
        r#"{"t":"scroll","x":0.5,"y":0.5,"dx":1,"dy":-2}"#
    );
    assert_eq!(ScreenInput::frame_rate(120).encode(), r#"{"t":"fps","i":120}"#);
}

#[test]
fn host_reads_viewer_messages() {
    let fps = |i| ScreenInput { i: Some(i), ..ScreenInput::new("fps") };
    assert_eq!(fps(120).reported_frame_rate(), Some(120));
    assert_eq!(fps(0).reported_frame_rate(), None);
    assert_eq!(fps(1001).reported_frame_rate(), None);
    let caps = |s: &str| ScreenInput { s: Some(s.into()), ..ScreenInput::new("caps") };
    assert!(caps("telepointers").viewer_draws_pointers());
    assert!(!caps("telepointers").viewer_draws_cursor_shapes());
    assert!(caps(" telepointers ,\tcursor-shape").viewer_draws_cursor_shapes());
    assert!(!caps("cursor-shape").viewer_draws_pointers());
    assert!(ScreenInput::new("bye").ends_session());
}

#[test]
fn delivery_follows_view_only_and_the_scroll_unit() {
    let px = vec!["scroll-px".to_owned()];
    let display = ScreenInput { i: Some(1), ..ScreenInput::new("display") };
    assert_eq!(delivery(&display, true, &[]), Delivery::SelectDisplay);
    assert_eq!(delivery(&ScreenInput::new("display"), false, &[]), Delivery::Drop);
    assert_eq!(delivery(&ScreenInput::new("move"), true, &[]), Delivery::Drop);
    assert_eq!(delivery(&ScreenInput::new("refresh"), true, &[]), Delivery::Handle);
    let pixels = ScreenInput::scroll(0.0, 0.0, 1, 1, true);
    assert_eq!(delivery(&pixels, false, &[]), Delivery::Drop);
    assert_eq!(delivery(&pixels, false, &px), Delivery::Handle);
    let lines = ScreenInput::scroll(0.0, 0.0, 1, 1, false);
    assert_eq!(delivery(&lines, false, &[]), Delivery::Handle);
    let odd = ScreenInput { u: Some("pt".into()), ..lines };
    assert_eq!(delivery(&odd, false, &px), Delivery::Drop);
}

#[test]
fn host_messages_round_trip() {
    let source = ScreenHostMessage::source(SourceState::Locked);
    assert_eq!(source.encode(), r#"{"t":"source","s":"locked"}"#);
    assert_eq!(
        ScreenHostMessage::decode(source.encode().as_bytes()).unwrap().source_state(),
        Some(SourceState::Locked)
    );
    assert_eq!(
        ScreenHostMessage { s: Some("asleep".into()), ..ScreenHostMessage::new("caps") }
            .source_state(),
        None
    );
    let caps =
        ScreenHostMessage::capabilities(&["scroll-px".into(), "mods".into()], false).unwrap();
    assert_eq!(caps.encode(), r#"{"t":"caps","s":"scroll-px,mods"}"#);
    assert!(ScreenHostMessage::capabilities(&["mods".into()], true).is_none());
    assert!(ScreenHostMessage::capabilities(&[], false).is_none());
    let read = ScreenHostMessage { s: Some(" a, ,b ,".into()), ..ScreenHostMessage::new("caps") };
    assert_eq!(read.host_capabilities(), Some(vec!["a".to_owned(), "b".to_owned()]));
    assert_eq!(ScreenHostMessage::new("displays").host_capabilities(), None);
    let paste = ScreenHostMessage::paste_image(PasteImageOutcome::Incomplete, Some("i".into()));
    assert_eq!(paste.encode(), r#"{"t":"paste-image","s":"incomplete","id":"i"}"#);
    assert_eq!(paste.paste_image_outcome(), Some(PasteImageOutcome::Incomplete));
    let displays = ScreenHostMessage::decode(
        br#"{"t":"displays","displays":[{"w":3456,"h":2234}],"current":0,"fps":120}"#,
    )
    .unwrap();
    assert!(displays.is_displays());
    assert_eq!(displays.fps, Some(120));
    let cursor =
        ScreenHostMessage::decode(br#"{"t":"cursor","cursor":{"id":"a","hx":0.5}}"#).unwrap();
    assert_eq!(cursor.cursor, Some(json!({"id": "a", "hx": 0.5})));
}

#[test]
fn quality_settings_match_the_presets() {
    let auto = Quality::Auto.settings(3456, 2234, 60);
    assert_eq!(auto.degradation, Degradation::MaintainResolution);
    assert_eq!(auto.max_bitrate, 16_000_000);
    assert_eq!(auto.min_bitrate, None);
    assert_eq!(auto.scale_down, 1.0);
    let fast = Quality::Smooth.settings(3456, 2234, 120);
    assert_eq!(fast.degradation, Degradation::MaintainFramerate);
    assert_eq!(fast.max_framerate, 120);
    assert!((fast.scale_down - 1.6044).abs() < 0.001, "{}", fast.scale_down);
    assert_eq!(fast.max_bitrate, 24_000_000);
    // 1280x800 at 60: about 11 Mbps.
    assert_eq!(Quality::Auto.settings(1280, 800, 60).max_bitrate, 11_059_200);
    assert_eq!(Quality::Auto.settings(0, 0, 60).max_bitrate, 12_000_000);
    assert_eq!(Quality::Auto.settings(100, 100, 60).max_bitrate, 4_000_000);
    let low = Quality::Low.settings(0, 1440, 120);
    assert_eq!(
        (low.max_bitrate, low.min_bitrate, low.max_framerate, low.scale_down),
        (1_500_000, Some(1_500_000), 30, 2.0)
    );
    assert_eq!(Quality::Medium.settings(0, 720, 60).scale_down, 1.0);
    assert_eq!(Quality::High.settings(0, 2234, 60).max_framerate, 60);
}

#[test]
fn frame_rate_follows_both_displays() {
    assert_eq!(Quality::Auto.frame_rate(Some(120), Some(120)), 120);
    assert_eq!(Quality::Auto.frame_rate(Some(120), None), 60);
    assert_eq!(Quality::Smooth.frame_rate(Some(240), Some(144)), 120);
    assert_eq!(Quality::Auto.frame_rate(Some(30), Some(0)), 60);
    assert_eq!(Quality::Low.frame_rate(Some(120), Some(120)), 30);
    assert_eq!(Quality::High.frame_rate(None, None), 60);
    assert_eq!(Quality::Auto.capture_cap(Some(1280), true), Some(1280));
    assert_eq!(Quality::Auto.capture_cap(Some(1280), false), None);
    assert_eq!(Quality::High.capture_cap(Some(1280), true), None);
    assert_eq!(Quality::parse("smooth"), Some(Quality::Smooth));
    assert_eq!(Quality::Medium.title(), "Fixed Medium (1080p)");
}

#[test]
fn pointer_fraction_and_pixel() {
    let d = Rect { x: 100.0, y: 50.0, w: 200.0, h: 100.0 };
    assert_eq!(quality::fraction(Some((150.0, 75.0)), Some(d)), Some((0.25, 0.25)));
    assert_eq!(quality::fraction(Some((300.0, 75.0)), Some(d)), None);
    assert_eq!(quality::fraction(Some((100.0, 50.0)), Some(d)), Some((0.0, 0.0)));
    assert_eq!(quality::fraction(None, Some(d)), None);
    assert_eq!(quality::fraction(Some((1.0, 1.0)), Some(Rect { w: 0.0, ..d })), None);
    assert_eq!(quality::pixel(Some(0.5), 100.0, 201.0), 200);
    assert_eq!(quality::pixel(Some(2.0), 100.0, 200.0), 300);
    assert_eq!(quality::pixel(Some(f64::NAN), 100.7, 200.0), 100);
    assert_eq!(quality::pixel(None, -0.5, 200.0), -1);
    assert_eq!(quality::pixel(Some(0.5), 1e300, 1.0), 0);
    assert_eq!(quality::pixel(None, f64::INFINITY, 1.0), 0);
}

#[test]
fn ops_answer_json() {
    let reply = call("settings", &json!({"quality": "low", "sourceHeight": 1440})).unwrap();
    assert_eq!(reply["maxBitrate"], 1_500_000);
    assert_eq!(reply["degradation"], "disabled");
    assert_eq!(reply["scaleDown"], 2.0);
    let read = call("input_read", &json!({"text": r#"{"t":"scroll","dx":1,"dy":1,"u":"px"}"#, "backendCapabilities": ["scroll-px"]})).unwrap();
    assert_eq!(read["delivery"], "handle");
    assert_eq!(
        call("input_read", &json!({"text": "nope"})).unwrap()["input"],
        serde_json::Value::Null
    );
    assert_eq!(
        call("host_read", &json!({"text": r#"{"t":"source","s":"asleep"}"#})).unwrap()["sourceState"],
        "asleep"
    );
    let chunks =
        call("paste_chunks", &json!({"data": "AQID", "type": "public.png", "id": "x"})).unwrap();
    assert_eq!(
        chunks["texts"][0],
        r#"{"t":"paste-image","s":"AQID","i":0,"n":1,"id":"x","f":"public.png"}"#
    );
    assert_eq!(call("encoding_name", &json!({"raw": 5})).unwrap()["name"], "Hextile");
    assert_eq!(
        call("rung", &json!({"longEdge": 1179, "displayLongEdge": 3456})).unwrap()["rung"],
        1280
    );
    assert_eq!(call("nope", &json!({})), Err(OpError::Unknown));
    assert_eq!(call("settings", &json!({"quality": "ultra"})), Err(OpError::Invalid));
}

#[test]
fn ffi_handles() {
    unsafe {
        let demand = ffi::cmux_screen_stream_demand_new();
        assert_eq!(ffi::cmux_screen_stream_demand_cap(demand), ffi::CMUX_SCREEN_STREAM_NONE);
        assert!(!ffi::cmux_screen_stream_demand_report(demand, 1000, 3456, false, 0.0));
        assert!(ffi::cmux_screen_stream_demand_report(demand, 1000, 3456, false, 6.0));
        assert_eq!(ffi::cmux_screen_stream_demand_cap(demand), 1280);
        ffi::cmux_screen_stream_demand_free(demand);

        let source = ffi::cmux_screen_stream_source_new();
        assert_eq!(ffi::cmux_screen_stream_source_check(source, false, true), 2);
        assert_eq!(
            ffi::cmux_screen_stream_source_check(source, false, true),
            ffi::CMUX_SCREEN_STREAM_NONE
        );
        ffi::cmux_screen_stream_source_stop(source);
        assert_eq!(
            ffi::cmux_screen_stream_source_check(source, true, false),
            ffi::CMUX_SCREEN_STREAM_NONE
        );
        assert_eq!(ffi::cmux_screen_stream_source_state(source), 2);
        ffi::cmux_screen_stream_source_free(source);

        let assembler = ffi::cmux_screen_stream_assembler_new();
        let chunk = br#"{"t":"paste-image","s":"AQID","i":0,"n":1,"id":"x","f":"public.png"}"#;
        let caps = b"scroll-px,paste-image";
        let mut out = ffi::CmuxScreenStreamBytes { ptr: std::ptr::null_mut(), len: 0 };
        let rc = ffi::cmux_screen_stream_assembler_take(
            assembler,
            chunk.as_ptr(),
            chunk.len(),
            false,
            caps.as_ptr(),
            caps.len(),
            &mut out,
        );
        assert_eq!(rc, ffi::CMUX_SCREEN_STREAM_OK);
        let reply: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(out.ptr, out.len)).unwrap();
        assert_eq!(reply["paste"]["id"], "x");
        ffi::cmux_screen_stream_bytes_free(out);
        let image = ffi::cmux_screen_stream_assembler_image(assembler);
        assert_eq!(std::slice::from_raw_parts(image.ptr, image.len), &[1, 2, 3]);
        ffi::cmux_screen_stream_bytes_free(image);
        assert!(ffi::cmux_screen_stream_assembler_image(assembler).ptr.is_null());
        ffi::cmux_screen_stream_assembler_free(assembler);

        let cursor = ffi::cmux_screen_stream_cursor_new();
        let shape = br#"{"id":"arrow","png":"AA=="}"#;
        let display = ffi::CmuxScreenStreamRect { x: 0.0, y: 0.0, w: 10.0, h: 10.0 };
        let mut text = ffi::CmuxScreenStreamBytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            ffi::cmux_screen_stream_cursor_prepare(
                cursor,
                shape.as_ptr(),
                shape.len(),
                display,
                &mut text
            ),
            0
        );
        assert!(
            std::str::from_utf8(std::slice::from_raw_parts(text.ptr, text.len))
                .unwrap()
                .starts_with(r#"{"t":"cursor""#)
        );
        ffi::cmux_screen_stream_bytes_free(text);
        let id = ffi::cmux_screen_stream_cursor_finish(cursor, true);
        assert_eq!(std::slice::from_raw_parts(id.ptr, id.len), b"arrow");
        ffi::cmux_screen_stream_bytes_free(id);
        ffi::cmux_screen_stream_cursor_free(cursor);

        assert_eq!(ffi::cmux_screen_stream_pixel(0.5, true, 0.0, 100.0), 50);
        assert_eq!(ffi::cmux_screen_stream_pixel(0.5, false, 7.0, 100.0), 7);
        assert_eq!(ffi::cmux_screen_stream_attempt_timeout(40.0), 5.0);
        assert!(ffi::cmux_screen_stream_gives_up(1, 5, 46.0));
    }
}
