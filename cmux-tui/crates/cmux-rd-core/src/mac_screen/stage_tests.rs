use super::*;

#[test]
fn stages_are_ordered_and_named_like_the_mac() {
    assert!(
        Stage::Answer < Stage::Link && Stage::Link < Stage::Frame && Stage::Frame < Stage::Shown
    );
    let names: Vec<_> = Stage::ALL.iter().map(|s| s.name()).collect();
    assert_eq!(names, ["no_answer", "no_link", "no_frame", "shown"]);
    let keys: Vec<_> = Stage::ALL.iter().map(|s| s.timing_key()).collect();
    assert_eq!(keys, ["answer", "link", "frame", "shown"]);
    assert_eq!(Stage::Shown.timeout_key(), None);
    assert_eq!(Stage::Link.timeout_key(), Some("macScreen.card.noLink"));
    assert_eq!(serde_json::to_value(Stage::Frame).unwrap(), "frame");
}
