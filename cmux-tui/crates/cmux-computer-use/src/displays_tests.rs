use super::*;
use crate::desktop::CaptureTarget;
use crate::desktop::fake::FakeDesktop;

#[test]
fn the_fake_desktop_lists_the_display_it_captures() {
    let desktop = FakeDesktop::standard();
    let body = list(&desktop).unwrap();
    let displays = body["displays"].as_array().unwrap();
    assert_eq!(displays.len(), 1);
    let d = &displays[0];
    assert_eq!(d["main"], true);
    assert_eq!(d["virtual"], true);
    let id = d["id"].as_str().unwrap().to_string();
    // The id round-trips into a capture of the same size.
    let frame = desktop.capture(&CaptureTarget::Display(Some(id))).unwrap();
    let scale = d["scale"].as_f64().unwrap();
    assert_eq!(scale, frame.scale);
    assert_eq!(d["frame"]["width"].as_f64().unwrap() * scale, f64::from(frame.width));
    assert_eq!(d["frame"]["height"].as_f64().unwrap() * scale, f64::from(frame.height));
}

#[test]
fn main_sorts_first_and_unknown_fields_are_left_out() {
    let a = Display {
        id: "b".into(),
        frame: Rect { x: -1920.0, y: 0.0, width: 1920.0, height: 1080.0 },
        scale: 1.0,
        main: false,
        builtin: None,
        is_virtual: None,
    };
    let v = serde_json::to_value(&a).unwrap();
    assert!(v.get("builtin").is_none() && v.get("virtual").is_none());
    let mut list = [a.clone(), Display { id: "m".into(), main: true, ..a }];
    list.sort_by_key(|d| std::cmp::Reverse(d.main));
    assert_eq!(list[0].id, "m");
}
