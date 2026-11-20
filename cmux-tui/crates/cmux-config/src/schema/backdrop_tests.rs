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
