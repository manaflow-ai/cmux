use super::*;

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
