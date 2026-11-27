use super::*;

fn w(id: &str, used: f64, resets: Option<i64>) -> Value {
    let mut w = json!({"id": id, "usedPercent": used});
    if let Some(at) = resets {
        w["resetsAt"] = json!(at);
    }
    w
}

#[test]
fn the_newest_window_wins_and_a_passed_one_is_left_out() {
    let now = 1_000;
    let older = json!({"windows": [w("weekly", 60.0, Some(5_000)), w("session", 90.0, Some(900))]});
    let newer =
        json!({"windows": [w("session", 12.0, Some(2_000)), w("weekly", 55.0, Some(5_000))]});
    let got = freshest_windows([&older, &newer], now).unwrap();
    // The 5-hour window that reset at 900 is gone; the one resetting at 2000 is newer.
    // Within the same weekly window, the higher use is the later reading.
    assert_eq!(
        got,
        json!({"windows": [w("session", 12.0, Some(2_000)), w("weekly", 60.0, Some(5_000))]})
    );
}

#[test]
fn windows_come_in_a_stable_order_and_nothing_known_is_none() {
    let a = json!({"windows": [w("weekly_opus", 3.0, None), w("weekly", 4.0, None), w("session", 5.0, None)], "plan": "max"});
    let got = freshest_windows([&a], 0).unwrap();
    let ids: Vec<&str> =
        got["windows"].as_array().unwrap().iter().map(|w| w["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["session", "weekly", "weekly_opus"]);
    assert_eq!(got["plan"], "max");
    assert_eq!(freshest_windows([&json!({"windows": []})], 0), None);
    assert_eq!(freshest_windows([&json!({"windows": [w("session", 99.0, Some(1))]})], 5), None);
    assert_eq!(freshest_windows(std::iter::empty(), 0), None);
}

#[test]
fn the_newest_miss_is_the_latest_one_with_a_cause() {
    let old = json!({"cause": "expired", "at": 100});
    let new = json!({"cause": "model", "at": 300});
    let bad = json!({"at": 900});
    let zero = json!({"cause": "effort", "at": 0});
    assert_eq!(newest_miss([&old, &bad, &new, &zero]), Some(new.clone()));
    assert_eq!(newest_miss([&bad, &zero]), None);
    assert_eq!(newest_miss(std::iter::empty()), None);
}

#[test]
fn the_default_home_and_its_spelled_out_folder_are_one_account() {
    let spelled = default_claude_home().unwrap();
    let with_slash = PathBuf::from(format!("{}/", spelled.display()));
    assert_eq!(claude_home(None), claude_home(Some(&spelled)));
    assert_eq!(claude_home(None), claude_home(Some(&with_slash)));
    assert_ne!(claude_home(None), claude_home(Some(Path::new("/tmp/claude-2"))));
}
