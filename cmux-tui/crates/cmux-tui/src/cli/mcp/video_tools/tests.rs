use super::*;
use std::cell::RefCell;

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap()
}

fn video() -> tempfile::NamedTempFile {
    let file = tempfile::Builder::new().suffix(".mp4").tempfile().unwrap();
    std::fs::write(file.path(), b"not decoded here").unwrap();
    file
}

/// An app that answers like the decoder: a 16 s 1920x1080 video, a frame at each asked
/// time (a grey sample that changes at 4 s and, more, at 10 s), every request recorded.
fn app(sent: &RefCell<Vec<Value>>) -> impl FnMut(Value) -> Result<Value, CallFailure> + '_ {
    move |params: Value| {
        sent.borrow_mut().push(params.clone());
        let frames = params["times"]
            .as_array()
            .unwrap()
            .iter()
            .map(|time| {
                let at = time.as_f64().unwrap();
                let data = if params["format"] == "luma" {
                    let grey = if at >= 10.0 {
                        200
                    } else if at >= 4.0 {
                        60
                    } else {
                        0
                    };
                    use base64::Engine as _;
                    base64::engine::general_purpose::STANDARD.encode(vec![grey; 256])
                } else {
                    "anBn".to_owned()
                };
                json!({"atMs": (at * 1000.0).round() as u64, "data": data})
            })
            .collect::<Vec<_>>();
        Ok(
            json!({"durationMs": 16000, "width": 1920, "height": 1080, "fps": 30.0, "hasAudio": false, "frames": frames, "dropped": 0}),
        )
    }
}

fn same(path: &str) -> String {
    path.to_owned()
}

#[test]
fn the_tools_list_their_selectors_and_steer_away_from_ffmpeg() {
    let tools = descriptors();
    let frames = tools.iter().find(|tool| tool["name"] == FRAMES).unwrap();
    let description = frames["description"].as_str().unwrap();
    assert!(description.contains("instead of ffmpeg"), "{description}");
    let properties = frames["inputSchema"]["properties"].as_object().unwrap();
    for key in ["path", "at", "range", "scenes", "count", "maxSide"] {
        assert!(properties.contains_key(key), "{key}");
    }
    assert_eq!(frames["inputSchema"]["properties"]["at"]["maxItems"], MAX_FRAMES);
    assert!(tools.iter().all(|tool| tool["annotations"]["readOnlyHint"] == true));
}

#[test]
fn a_call_names_one_selector_and_stays_within_the_caps() {
    let ok = |value| frames_request(&args(value));
    assert_eq!(ok(json!({"path": "a.mp4"})).unwrap().pick, Pick::Spread(DEFAULT_COUNT));
    assert_eq!(ok(json!({"path": "a.mp4"})).unwrap().max_side, DEFAULT_MAX_SIDE);
    assert_eq!(
        ok(json!({"path": "a.mp4", "scenes": true, "count": 4})).unwrap().pick,
        Pick::Scenes(4)
    );
    assert_eq!(
        ok(json!({"path": "a.mp4", "range": {"from": 2, "to": 6, "count": 3}})).unwrap().pick,
        Pick::Range { from: Some(2.0), to: Some(6.0), count: 3 }
    );
    for (bad, says) in [
        (json!({"path": "a.mp4", "at": [1], "scenes": true}), "one of"),
        (json!({"path": "a.mp4", "at": (0..17).collect::<Vec<_>>()}), "1 to 16"),
        (json!({"path": "a.mp4", "count": 17}), "1 to 16"),
        (json!({"path": "a.mp4", "maxSide": 10}), "maxSide"),
        (json!({"path": "a.mp4", "range": {"from": 5, "to": 1}}), "before"),
        (json!({"path": "a.mp4", "at": [-1]}), "0 or more"),
        (json!({"path": "a.mp4", "fps": 1}), "no argument"),
        (json!({"at": [1]}), "needs path"),
    ] {
        let message = frames_request(&args(bad.clone())).unwrap_err();
        assert!(message.contains(says), "{bad}: {message}");
    }
}

#[test]
fn times_stay_inside_the_video() {
    let (at, tolerance) = times(&Pick::At(vec![0.0, 99.0]), 16.0, 30.0);
    assert_eq!(tolerance, 0.0, "an asked time is exact");
    assert_eq!(at[0], 0.0);
    assert!(at[1] < 16.0 && at[1] > 15.9, "{at:?}");
    let (range, _) = times(&Pick::Range { from: Some(2.0), to: Some(6.0), count: 5 }, 16.0, 30.0);
    assert_eq!(range, vec![2.0, 3.0, 4.0, 5.0, 6.0]);
    let (spread, _) = times(&Pick::Spread(4), 16.0, 30.0);
    assert_eq!(spread, vec![2.0, 6.0, 10.0, 14.0]);
    let (one, _) = times(&Pick::Range { from: None, to: None, count: 1 }, 16.0, 30.0);
    assert_eq!(one, vec![0.0]);
}

#[test]
fn scenes_are_the_first_frame_and_the_biggest_changes_in_time_order() {
    let sample = |at_ms, grey| Sample { at_ms, pixels: vec![grey; 4] };
    let samples =
        [sample(0, 0), sample(1000, 0), sample(2000, 50), sample(3000, 51), sample(4000, 250)];
    let picked = scene_times(&samples, 3);
    assert_eq!(picked.iter().map(|(at, _)| *at).collect::<Vec<_>>(), vec![0, 2000, 4000]);
    assert_eq!(picked[2].1, 199.0);
    // A change under the floor (1 grey level) is noise: only the first frame.
    assert_eq!(scene_times(&samples[..2], 4).len(), 1);
    assert_eq!(scene_times(&[sample(0, 0), sample(1000, 1)], 4).len(), 1);
    assert!(scene_times(&[], 4).is_empty());
}

#[test]
fn frames_come_back_as_image_blocks_after_one_text_block() {
    let file = video();
    let path = file.path().to_str().unwrap().to_owned();
    let sent = RefCell::new(Vec::new());
    let answer = run_frames(&args(json!({"path": path, "at": [1, 2.5]})), &same, &mut app(&sent));
    assert_eq!(answer["isError"], false, "{answer}");
    assert!(
        answer.get("structuredContent").is_none(),
        "cmux_exec moves the images only without it"
    );
    let content = answer["content"].as_array().unwrap();
    assert_eq!(content.len(), 3);
    let text = content[0]["text"].as_str().unwrap();
    assert!(text.contains("16.00 s, 1920x1080, 30 fps, no audio"), "{text}");
    assert!(text.contains("#1 at 1.00 s") && text.contains("#2 at 2.50 s"), "{text}");
    assert_eq!(content[1], json!({"type": "image", "data": "anBn", "mimeType": "image/jpeg"}));
    let sent = sent.borrow();
    assert_eq!(sent.len(), 2, "a probe, then the frames");
    let real = std::fs::canonicalize(&path).unwrap();
    assert_eq!(sent[1]["path"], real.to_str().unwrap());
    assert!(sent[1]["dev"].is_string() && sent[1]["ino"].is_string());
    assert_eq!(sent[1]["side"], DEFAULT_MAX_SIDE);
    assert_eq!(sent[1]["tolerance"], 0.0);
    assert_eq!(sent[1]["maxBytes"], MAX_TOTAL_BYTES);
}

#[test]
fn scenes_sample_small_grey_frames_then_read_the_changes() {
    let file = video();
    let path = file.path().to_str().unwrap().to_owned();
    let sent = RefCell::new(Vec::new());
    let answer = run_frames(
        &args(json!({"path": path, "scenes": true, "count": 3, "maxSide": 640})),
        &same,
        &mut app(&sent),
    );
    let sent = sent.borrow();
    assert_eq!(sent.len(), 3, "probe, samples, frames");
    assert_eq!(sent[1]["format"], "luma");
    assert_eq!(sent[1]["times"].as_array().unwrap().len(), SCENE_SAMPLES);
    let frames = sent[2]["times"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_f64().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(frames.len(), 3, "{frames:?}");
    assert!(
        frames[0] == 0.0 && (4.0..4.5).contains(&frames[1]) && (10.0..10.5).contains(&frames[2]),
        "{frames:?}"
    );
    assert_eq!(sent[2]["side"], 640);
    let text = answer["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("(change 140.0)") && text.contains("(change 60.0)"), "{text}");
}

#[test]
fn a_left_out_frame_and_a_refusal_are_said() {
    let file = video();
    let path = file.path().to_str().unwrap().to_owned();
    let mut partial = |params: Value| -> Result<Value, CallFailure> {
        let frames = if params["times"].as_array().unwrap().is_empty() {
            json!([])
        } else {
            json!([{"atMs": 0, "data": "anBn"}])
        };
        Ok(
            json!({"durationMs": 2000, "width": 10, "height": 10, "fps": 0, "hasAudio": true, "frames": frames, "dropped": 3}),
        )
    };
    let answer = run_frames(&args(json!({"path": path, "count": 4})), &same, &mut partial);
    let text = answer["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("3 more frames were left out"), "{text}");
    assert!(text.contains("with audio"), "{text}");

    let mut elsewhere = |_: Value| -> Result<Value, CallFailure> {
        Err(CallFailure {
            kind: super::super::FailureKind::Rejected,
            error: json!({"code": "not_found", "message": "that file is not on this Mac"}),
            idempotency_key: None,
        })
    };
    let answer = run_info(&args(json!({"path": path})), &same, &mut elsewhere);
    assert_eq!(answer["isError"], true);
    assert!(answer["content"][0]["text"].as_str().unwrap().contains("not on this Mac"));

    let missing = run_info(&args(json!({"path": "/nonexistent/clip.mp4"})), &same, &mut elsewhere);
    assert!(missing["content"][0]["text"].as_str().unwrap().contains("cannot read"), "{missing}");
}

#[test]
fn a_first_frame_over_the_budget_says_so() {
    let file = video();
    let path = file.path().to_str().unwrap().to_owned();
    let mut over = |params: Value| -> Result<Value, CallFailure> {
        let dropped = params["times"].as_array().map_or(0, Vec::len);
        Ok(json!({"durationMs": 2000, "width": 8000, "height": 8000, "fps": 30, "hasAudio": false,
                      "frames": [], "dropped": dropped}))
    };
    let answer = run_frames(&args(json!({"path": path, "at": [1]})), &same, &mut over);
    let text = answer["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("smaller maxSide"), "{text}");
}

#[test]
fn video_info_answers_the_numbers_without_frames() {
    let file = video();
    let path = file.path().to_str().unwrap().to_owned();
    let sent = RefCell::new(Vec::new());
    let answer = run_info(&args(json!({"path": path})), &same, &mut app(&sent));
    assert_eq!(answer["structuredContent"]["durationMs"], 16000);
    assert_eq!(answer["structuredContent"]["hasAudio"], false);
    assert!(answer["structuredContent"].get("frames").is_none());
    assert_eq!(sent.borrow()[0]["times"], json!([]));
}
