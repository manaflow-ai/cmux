use super::*;
use serde_json::json;

#[test]
fn answers_a_glyph_per_id_known_or_not() {
    let id = "01a1f1fd-638f-73f4-b295-534adfe6d7cc";
    let reply = handle(json!({"sessionIds": [id, "no-such-session", id]})).unwrap();
    let signatures = reply["signatures"].as_object().unwrap();
    assert_eq!(signatures.len(), 2, "one glyph per distinct id");
    assert_eq!(signatures[id], serde_json::to_value(cmux_wallpaper::glyph(id)).unwrap());
    let g = &signatures["no-such-session"];
    assert!(g["seed"].is_number() && g["drift"].is_number());
    assert!(g["variant"].is_string() && g["accent"].as_str().unwrap().starts_with('#'));
    let dots = g["dots"].as_array().unwrap();
    assert!((5..=9).contains(&dots.len()));
    assert!(dots.iter().all(|d| ["x", "y", "r", "phase"].iter().all(|k| d[k].is_number())));
}

#[test]
fn refuses_more_than_512_ids_and_a_bad_shape() {
    let ids: Vec<String> = (0..=MAX_SESSION_IDS).map(|i| i.to_string()).collect();
    assert_eq!(handle(json!({"sessionIds": ids})).unwrap_err().code, -32602);
    let ids: Vec<String> = (0..MAX_SESSION_IDS).map(|i| i.to_string()).collect();
    let reply = handle(json!({"sessionIds": ids})).unwrap();
    assert_eq!(reply["signatures"].as_object().unwrap().len(), MAX_SESSION_IDS);
    assert_eq!(handle(json!({})).unwrap_err().code, -32602);
    assert_eq!(handle(json!({"sessionIds": "a"})).unwrap_err().code, -32602);
    assert_eq!(handle(json!({"sessionIds": []})).unwrap(), json!({"signatures": {}}));
}
