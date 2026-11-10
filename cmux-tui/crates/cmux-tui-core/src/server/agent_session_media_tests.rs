// A chat on another machine plays its videos in place (Leo, 2026-11-04: "i can neither preview a
// vid in place nor have it pop up anymore :("): `agent-session-media` with an `offset` reads one
// byte range of a video through the attached session's acpmux media reader, so the app streams
// it to its player without reading the whole file. Included by agent_session_attach_tests.rs for
// the real command dispatcher and private fake acpmux socket.

/// The one video the fake's media reader serves: an mp4 head and some bytes.
const FAKE_VIDEO: &[u8] = b"\0\0\0\x18ftypmp42\0\0\0\0mp42isomVIDEO-BYTES-0123456789";
/// The handle the fake's open answers.
const FAKE_HANDLE: &str = "h_video_1";

/// The fake acpmux's `_acpmux/media_open` and `_acpmux/media_range` (hub/media_read.rs): a range
/// reads the open file and closes it at its end, as acpmux does; a range on another handle is
/// refused.
fn media_reply(frame: &Value) -> Value {
    use base64::Engine as _;
    let params = &frame["params"];
    let size = FAKE_VIDEO.len() as u64;
    if frame["method"] == json!("_acpmux/media_open") {
        return json!({"handle": FAKE_HANDLE, "size": size, "mimeType": "video/mp4", "identity": "id_1"});
    }
    if params["handle"] != json!(FAKE_HANDLE) {
        return json!({FAKE_ERROR: "no such media handle", FAKE_ERROR_DATA: {"reason": "media.handle"}});
    }
    let offset = params["offset"].as_u64().unwrap_or(u64::MAX);
    let length = params["length"].as_u64().unwrap_or(0);
    if offset >= size || length == 0 {
        return json!({FAKE_ERROR: "bad range", FAKE_ERROR_DATA: {"reason": "media.range"}});
    }
    let end = size.min(offset + length) as usize;
    json!({"offset": offset, "size": size, "identity": "id_1",
           "data": base64::engine::general_purpose::STANDARD.encode(&FAKE_VIDEO[offset as usize..end])})
}

fn decoded(reply: &Value) -> Vec<u8> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD
        .decode(reply["data"]["data"].as_str().expect("range bytes"))
        .unwrap()
}

#[test]
fn a_video_streams_in_ranges_of_one_open_on_the_pinned_session() {
    let fake = FakeAcpmux::start("media-range");
    let mux = mux_with(&fake, "asa-media-range");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "media-range");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    let _ = fake.frame();
    let size = FAKE_VIDEO.len() as u64;

    // The first range opens the file on the tab's own session and reads from the offset.
    let first = client.request(json!({"cmd":"agent-session-media", "surface":surface,
        "path":"/tmp/clip.mp4", "offset":0, "length":8}));
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(first["data"]["mimeType"], "video/mp4", "{first}");
    assert_eq!(first["data"]["size"], size, "{first}");
    assert_eq!(first["data"]["identity"], "id_1", "{first}");
    assert_eq!(first["data"]["offset"], 0, "{first}");
    assert_eq!(first["data"]["handle"], FAKE_HANDLE, "the file is still open: {first}");
    assert_eq!(decoded(&first), FAKE_VIDEO[..8]);
    let open = fake.frame();
    assert_eq!(open["method"], "_acpmux/media_open");
    assert_eq!(open["params"], json!({"sessionId": SESSION, "path": "/tmp/clip.mp4"}));
    let range = fake.frame();
    assert_eq!(range["method"], "_acpmux/media_range");
    assert_eq!(
        range["params"],
        json!({"sessionId": SESSION, "handle": FAKE_HANDLE, "offset": 0, "length": 8})
    );

    // The next range reads the same open file, to its end: no handle is left to continue.
    let rest = client.request(json!({"cmd":"agent-session-media", "surface":surface,
        "path":"/tmp/clip.mp4", "offset":8, "handle":FAKE_HANDLE}));
    assert_eq!(rest["ok"], true, "{rest}");
    assert_eq!(rest["data"]["offset"], 8, "{rest}");
    assert!(rest["data"].get("handle").is_none(), "the file was read to its end: {rest}");
    assert_eq!(decoded(&rest), FAKE_VIDEO[8..]);
    let range = fake.frame();
    assert_eq!(range["method"], "_acpmux/media_range", "no second open: {range}");
    assert_eq!(range["params"]["handle"], FAKE_HANDLE);
    assert_eq!(range["params"]["offset"], 8);
    fake.no_frame();
}

#[test]
fn a_media_range_is_only_a_videos_and_names_nothing_else() {
    let fake = FakeAcpmux::start("media-range-bad");
    let mux = mux_with(&fake, "asa-media-range-bad");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "media-range-bad");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    let _ = fake.frame();
    for bad in [
        // Not a video: an image is read whole, a text file never.
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/a.png", "offset":0}),
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/notes.txt", "offset":0}),
        // A handle or a length without an offset.
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "handle":FAKE_HANDLE}),
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "length":8}),
        // A range past acpmux's most bytes, an empty one, a handle that is not one.
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "offset":0,
               "length": (64u64 << 20)}),
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "offset":0, "length":0}),
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "offset":0,
               "handle":"x".repeat(500)}),
        // The session is the tab's own.
        json!({"cmd":"agent-session-media", "surface":surface, "path":"/tmp/clip.mp4", "offset":0,
               "sessionId":"acp_other"}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
    // A range acpmux refuses (a handle it closed) is the refusal, never bytes.
    let refused = client.request(json!({"cmd":"agent-session-media", "surface":surface,
        "path":"/tmp/clip.mp4", "offset":0, "handle":"h_gone"}));
    assert_eq!(refused["ok"], false, "{refused}");
}
