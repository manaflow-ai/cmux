use super::*;

fn run(op: &str, request: Value) -> Value {
    call(op, &request).unwrap().unwrap()
}

#[test]
fn rotation_op_parses_and_turns() {
    assert_eq!(run("backdrop.rotation", json!({"rotation": "bogus"})), json!({}));
    assert_eq!(run("backdrop.rotation", json!({"rotation": 30.4}))["rotation"], "30");
    let out = run(
        "backdrop.rotation",
        json!({"rotation": "hourly", "now": 3_600.0 * 5.0 + 10.0, "count": 4}),
    );
    assert_eq!(out["next_turn"], json!(3_600.0 * 6.0));
    assert_eq!(out["wait"], json!(3_600.0 - 10.0 + 1.0));
    assert_eq!(out["period"], 5);
}

#[test]
fn display_refresh_follows_the_swift_binding() {
    let root = json!({"appearance": {
        "displayBackgrounds": {"a": "none", "b": "daily", "c": "folder:/pics", "d": "file:/x.png", "e": "folder:rel"},
        "displayBackgroundRotations": {"c": "15m"}, "backgroundRotation": "hourly"}});
    let go = |id: &str| {
        run(
            "backdrop.display_refresh",
            json!({"root": root, "display_id": id, "now": 1_000.0, "paintings": 150}),
        )
    };
    assert_eq!(go("a")["kind"], "none");
    assert_eq!(go("zz")["kind"], "inherit");
    assert_eq!(go("e")["kind"], "inherit");
    assert_eq!(go("d"), json!({"kind": "pin", "id": "file:/x.png"}));
    let daily = go("b");
    assert_eq!(daily["kind"], "daily");
    assert!(daily["index"].is_u64());
    let folder = go("c");
    assert_eq!(
        (folder["rotation"].as_str(), folder["next_turn"].as_f64()),
        (Some("15m"), Some(1_800.0))
    );
    assert_eq!(folder["path"], "/pics");
    // Without a display id the display inherits.
    assert_eq!(
        run("backdrop.display_refresh", json!({"root": root, "now": 0.0}))["kind"],
        "inherit"
    );
}

#[test]
fn time_of_day_op_resolves() {
    let out = run("backdrop.time_of_day", json!({"entries": {"07:00": "daily"}, "now": 0.0}));
    assert_eq!(out["valid"], false);
    let out = run(
        "backdrop.time_of_day",
        json!({"entries": {"07:00": "desktop", "19:00": "system:/a.heic"},
        "now": 8.0 * 3_600.0}),
    );
    assert_eq!(out["value"], "desktop");
    assert_eq!(out["next"], json!(19.0 * 3_600.0));
    assert_eq!(
        run("backdrop.time_of_day", json!({"entries": {"7": "desktop"}, "now": 0.0}))["valid"],
        false
    );
}

#[test]
fn favorites_port_the_swift_tests() {
    let root = |theme: Option<&str>, rotate: Option<&str>| {
        let mut appearance = json!({"favoriteThemes": ["Nord", "Dracula", "Nord", 1, "light:A,dark:B", " ", "Rose Pine"]});
        if let Some(t) = theme {
            appearance["theme"] = json!(t);
        }
        if let Some(r) = rotate {
            appearance["rotateFavoriteThemes"] = json!(r);
        }
        json!({"appearance": appearance})
    };
    let out = run("theme.favorites", json!({"root": root(None, None)}));
    assert_eq!(out["favorites"], json!(["Nord", "Dracula", "Rose Pine"]));
    assert_eq!(run("theme.favorites", json!({"root": {}}))["favorites"], json!([]));
    let next = |current: Option<&str>, list: Value| {
        run("theme.favorite_next", json!({"current": current, "favorites": list}))["next"].clone()
    };
    let three = json!(["Nord", "Dracula", "Rose Pine"]);
    assert_eq!(next(Some("Nord"), three.clone()), "Dracula");
    assert_eq!(next(Some("Rose Pine"), three.clone()), "Nord");
    assert_eq!(next(Some("Tokyo Night"), three.clone()), "Nord");
    assert_eq!(next(None, three), "Nord");
    assert_eq!(next(Some("Nord"), json!(["Nord"])), Value::Null);
    let rotated = |root: Value, today: &str, last: Option<&str>| {
        run("theme.favorite_rotated", json!({"root": root, "today": today, "last_day": last}))["next"].clone()
    };
    let two = |theme: &str, rotate: &str| json!({"appearance": {"favoriteThemes": ["Nord", "Dracula"], "theme": theme, "rotateFavoriteThemes": rotate}});
    assert_eq!(rotated(root(Some("Nord"), None), "2026-10-20", None), Value::Null);
    assert_eq!(rotated(root(Some("Nord"), Some("bogus")), "2026-10-20", None), Value::Null);
    assert_eq!(rotated(two("Nord", "launch"), "2026-10-20", Some("2026-10-20")), "Dracula");
    assert_eq!(rotated(two("Dracula", "daily"), "2026-10-20", Some("2026-10-20")), Value::Null);
    assert_eq!(rotated(two("Dracula", "daily"), "2026-10-21", Some("2026-10-20")), "Nord");
    assert_eq!(rotated(two("Dracula", "daily"), "2026-10-21", None), "Nord");
    for spec in ["light:Rose Pine Dawn,dark:Rose Pine", "light:Nord,dark:Nord", "dark:Nord"] {
        assert_eq!(rotated(two(spec, "launch"), "2026-10-20", None), Value::Null, "{spec}");
    }
    assert_eq!(run("theme.day", json!({"now": 1_792_454_400.0}))["day"], "2026-10-20");
}

#[test]
fn title_area_contrast_clamps() {
    let go = |v: Value| {
        run("title_area.contrast", json!({"root": {"appearance": {"titleAreaContrast": v}}}))
    };
    assert_eq!(go(json!(1.5))["value"], 1.5);
    let high = go(json!(3));
    assert_eq!(high["value"], 2.0);
    assert!(high["diagnostics"][0]["message"].as_str().unwrap().ends_with("; clamped"));
    assert_eq!(go(json!("x"))["value"], 1.0);
    assert_eq!(run("title_area.contrast", json!({"root": {}}))["value"], 1.0);
}
