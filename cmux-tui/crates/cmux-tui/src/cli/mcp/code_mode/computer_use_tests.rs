use super::*;

fn image(data: &str) -> Value {
    json!({"type": "image", "data": data, "mimeType": "image/png"})
}

/// A script's returned placeholders pick its images; with none returned,
/// every image but Computer Use's screenshots comes back (a `video_frames`
/// script that returns text still shows its frames), and the internal mark
/// never leaves.
#[test]
fn the_images_a_script_returns_are_the_ones_sent() {
    let mut cu = image("Y3U=");
    cu.set(FROM_COMPUTER_USE, json!(true));
    let frames = vec![cu, image("ZnJhbWU=")];
    let (sent, left_out) = returned_images(Some(&json!("done")), frames.clone());
    assert_eq!((sent, left_out), (vec![image("ZnJhbWU=")], 0));
    let returned = json!({"shot": {"images": [{"type": "image", "image": 0}]}});
    let (sent, _) = returned_images(Some(&returned), frames.clone());
    assert_eq!(sent, vec![image("Y3U=")], "returned, and without the mark");
    let both = json!([{"type": "image", "image": 1}, {"type": "image", "image": 0},
                      {"type": "image", "image": 1}, {"type": "image", "image": 9}]);
    let (sent, _) = returned_images(Some(&both), frames);
    assert_eq!(sent, vec![image("ZnJhbWU="), image("Y3U=")], "first seen first, once");
    let many: Vec<Value> = (0..MAX_IMAGES + 3).map(|_| image("eA==")).collect();
    let (sent, left_out) = returned_images(None, many);
    assert_eq!((sent.len(), left_out), (MAX_IMAGES, 3));
}

/// In a script an acting cu_* call skips its settle screenshot unless it asks;
/// a reading call and every other tool are left as they are.
#[test]
fn script_calls_default_acting_cu_tools_to_no_observation() {
    let defaulted = |name: &str, args: Value| {
        let mut args = args.as_object().cloned().unwrap();
        script_arguments(name, &mut args);
        Value::Object(args)
    };
    assert_eq!(
        defaulted("cu_click", json!({"x": 1})),
        json!({"x": 1, "observe": false, "format": "json"})
    );
    assert_eq!(
        defaulted("cu_batch", json!({"observe": true})),
        json!({"observe": true, "format": "json"})
    );
    // Trees come back as JSON in a script unless it asks for the outline.
    for name in ["cu_get_ui_tree", "cu_wait"] {
        assert_eq!(defaulted(name, json!({})), json!({"format": "json"}), "{name}");
    }
    assert_eq!(
        defaulted("cu_get_ui_tree", json!({"format": "outline"})),
        json!({"format": "outline"})
    );
    for name in ["cu_screenshot", "pane_split", "video_frames"] {
        assert_eq!(defaulted(name, json!({})), json!({}), "{name}");
    }
}
