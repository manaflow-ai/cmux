use super::*;

#[test]
fn a_record_reads_back_and_names_only_plain_ids() {
    let p = Pending {
        session_id: "s-1".into(),
        to: PlaceMode::Cloud,
        machine: Some("m-1".into()),
        before: None,
        was: PlaceMode::Auto,
        pin: PlaceMode::Cloud,
        why: "you chose it".into(),
        cwd: None,
        move_id: "mv".into(),
        stage: Stage::Waiting,
    };
    let back: Pending = serde_json::from_slice(&serde_json::to_vec(&p).unwrap()).unwrap();
    assert_eq!(back, p);
    assert!(path("../x").is_none() && path("").is_none() && path(".x").is_none());
    assert!(path("019a-b_c").is_some());
}
