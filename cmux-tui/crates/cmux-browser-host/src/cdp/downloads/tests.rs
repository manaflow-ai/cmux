use super::*;

fn begin(state: &mut State, guid: &str) {
    let mut applied = Applied::default();
    state.download_event(
        "Browser.downloadWillBegin",
        &json!({"guid": guid, "frameId": "T", "url": "u", "suggestedFilename": "f"}),
        &mut applied,
    );
}

#[test]
fn finished_downloads_are_bounded_and_running_ones_kept() {
    let mut state = State::default();
    state.tabs.insert(
        "T".into(),
        super::super::state::TabState::new("s".into(), "u".into(), String::new(), None),
    );
    state.downloads.dir = Some(PathBuf::from("/d"));
    begin(&mut state, "running");
    for i in 0..KEPT_FINISHED + 10 {
        let guid = format!("g{i}");
        begin(&mut state, &guid);
        let mut applied = Applied::default();
        state.download_event(
            "Browser.downloadProgress",
            &json!({"guid": guid, "state": "completed"}),
            &mut applied,
        );
        assert_eq!(applied.events[0].payload["path"], format!("/d/{guid}"));
    }
    begin(&mut state, "last");
    assert!(state.downloads.entries.len() <= KEPT_FINISHED + 2);
    assert!(state.downloads.get("running").is_some());
    assert!(state.downloads.get("g0").is_none());
}
