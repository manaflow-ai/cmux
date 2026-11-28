use super::*;

#[test]
fn raw_values_round_trip_in_menu_order() {
    let raws: Vec<_> = Tool::ALL.iter().map(|t| t.raw()).collect();
    assert_eq!(
        raws,
        [
            "cleanShotX",
            "shottr",
            "xnapper",
            "snagit",
            "monosnap",
            "skitch",
            "flameshot",
            "kap",
            "cap",
            "quickTime"
        ]
    );
    for tool in Tool::ALL {
        assert_eq!(Tool::from_raw(tool.raw()), Some(tool));
    }
    assert_eq!(Tool::from_raw("nope"), None);
}

#[test]
fn only_history_folders_are_marked_history() {
    let history: Vec<_> = Tool::ALL
        .into_iter()
        .filter(|t| t.fixed_folders().iter().any(|f| f.history))
        .map(Tool::raw)
        .collect();
    assert_eq!(history, ["cleanShotX", "snagit", "cap"]);
}
