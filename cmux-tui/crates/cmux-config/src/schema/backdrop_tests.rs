use super::*;

fn list(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| item.to_string()).collect()
}

#[test]
fn record_recent_puts_the_previous_first_once() {
    assert_eq!(record_recent(&[], "daily"), list(&["daily"]));
    let recents = list(&["folder:/Walls", "desktop", "daily"]);
    assert_eq!(record_recent(&recents, "daily"), list(&["daily", "folder:/Walls", "desktop"]));
    assert_eq!(
        record_recent(&recents, "file:/a.png"),
        list(&["file:/a.png", "folder:/Walls", "desktop", "daily"])
    );
}

#[test]
fn record_recent_caps_and_refuses_junk() {
    let many: Vec<String> = (0..12).map(|n| format!("file:/p{n}.png")).collect();
    let next = record_recent(&many, "folder:/Walls");
    assert_eq!(next.len(), RECENTS_CAP);
    assert_eq!(next[0], "folder:/Walls");
    assert_eq!(next[1], "file:/p0.png");
    assert_eq!(record_recent(&list(&["daily"]), "not a background"), list(&["daily"]));
    assert_eq!(
        record_recent(&list(&["junk", "folder:/", "desktop"]), "none"),
        list(&["none", "desktop"])
    );
    assert!(is_recents(&Value::Array(next.iter().cloned().map(Value::String).collect())));
}

#[test]
fn previous_background_swaps_back_and_forth() {
    // A rotating folder, then one picture: the swap goes to the folder, and back.
    let mut current = "file:/Users/me/harbor.png".to_string();
    let mut recents = list(&["folder:/Users/me/Walls"]);
    for expected in
        ["folder:/Users/me/Walls", "file:/Users/me/harbor.png", "folder:/Users/me/Walls"]
    {
        let previous = previous_background(&current, &recents).expect("a previous one");
        assert_eq!(previous, expected);
        recents = record_recent(&recents, &current);
        current = previous;
    }
    assert_eq!(previous_background("daily", &list(&["daily"])), None);
    assert_eq!(previous_background("daily", &[]), None);
    assert_eq!(
        previous_background("daily", &list(&["daily", "junk", "desktop"])),
        Some("desktop".into())
    );
}

#[test]
fn recents_accepts_backgrounds_only() {
    use serde_json::json;
    assert!(is_recents(&json!([])));
    assert!(is_recents(&json!([
        "daily",
        "folder:/Walls",
        "desktop",
        "none",
        "file:/a.png",
        "schedule"
    ])));
    for bad in [
        json!("daily"),
        json!(["daily", "daily"]),
        json!(["folder:/"]),
        json!(["file:relative.png"]),
        json!([1]),
        json!(["__not_a_backdrop__"]),
        json!(["a", "b", "c", "d", "e", "f", "g", "h", "i"].map(|n| format!("file:/{n}.png"))),
    ] {
        assert!(!is_recents(&bad), "{bad}");
    }
}

#[test]
fn schedule_keys_follow_swift() {
    for good in ["07:00", "9:30", "23:59", "sunset", "sunset-30m", "sunrise+1h", "dusk+90m", "noon"]
    {
        assert!(is_when(good), "{good}");
    }
    for bad in [
        "24:00",
        "07:60",
        "7",
        "sunset-",
        "sunset+30s",
        "midnight",
        "Sunset",
        "sunrise+25h",
        "07:0",
    ] {
        assert!(!is_when(bad), "{bad}");
    }
}

#[test]
fn locations_are_lat_lon() {
    assert!(is_location("37.77,-122.42"));
    assert!(is_location("-33.87, 151.21"));
    for bad in ["", "37.77", "91,0", "0,181", "north,east", "1,2,3"] {
        assert!(!is_location(bad), "{bad}");
    }
}

/// The Swift enum's cases, read from its source: the app draws exactly
/// the living wallpapers the schema lets a theme file or recipe pick.
#[test]
fn shader_names_match_swift() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropShader.swift"
    );
    let Ok(text) = std::fs::read_to_string(path) else {
        // A crate-only checkout has no Swift tree; the full repo always does.
        return;
    };
    let body = text.split("enum BackdropShader").nth(1).expect("the enum");
    let body = &body[..body.find("public static").expect("the enum's first member")];
    let swift: Vec<&str> = body
        .lines()
        .filter_map(|line| line.trim().strip_prefix("case "))
        .map(|name| name.split([' ', '=']).next().unwrap_or(name).trim())
        .collect();
    assert_eq!(swift, SHADERS, "SHADERS must list BackdropShader's cases, in order");
}

#[test]
fn every_listed_shader_is_a_background_and_others_are_not() {
    for id in shader_ids() {
        assert!(is_picture(&id), "{id}");
        assert!(is_path_or_video(&id), "{id}");
    }
    for bad in ["shader:", "shader:nope", "shader:Aurora", "aurora", "shader:aurora "] {
        assert!(!is_shader(bad), "{bad}");
    }
}
