use std::path::PathBuf;

use serde_json::json;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

/// A home folder with pictures and a fake macOS wallpaper folder, removed when the test ends.
struct Fixture(PathBuf);

impl Fixture {
    fn new(tag: &str) -> Fixture {
        let dir =
            std::env::temp_dir().join(format!("cmux-wallpaper-cli-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for folder in ["home/Pictures/Walls", "work", "pictures"] {
            std::fs::create_dir_all(dir.join(folder)).expect("temp dir");
        }
        std::fs::write(dir.join("home/Pictures/day.jpg"), b"jpg").expect("write");
        std::fs::write(dir.join("home/Pictures/night.jpg"), b"jpg").expect("write");
        std::fs::write(dir.join("work/here.png"), b"png").expect("write");
        let madesktop = |dynamic: bool, solar: bool| {
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>isDynamic</key><{dynamic}/><key>isSolar</key><{solar}/></dict></plist>"#
            )
        };
        let pictures = dir.join("pictures");
        std::fs::write(pictures.join("Catalina.madesktop"), madesktop(true, true)).expect("w");
        std::fs::write(pictures.join("Catalina Clouds.madesktop"), madesktop(false, false))
            .expect("w");
        std::fs::write(pictures.join("Big Sur.madesktop"), madesktop(true, false)).expect("w");
        std::fs::write(pictures.join("Big Sur Graphic.madesktop"), madesktop(true, false))
            .expect("w");
        std::fs::write(
            pictures.join("Sonoma.heic"),
            b"ftypheic....<x:xmpmeta apple_desktop:apr=\"x\"/>",
        )
        .expect("w");
        std::fs::write(pictures.join("Mac Blue.heic"), b"ftypheic plain").expect("w");
        Fixture(dir)
    }

    fn env(&self) -> Env {
        Env {
            home: self.0.join("home"),
            cwd: self.0.join("work"),
            pictures: self.0.join("pictures"),
        }
    }

    fn home(&self, rest: &str) -> String {
        self.0.join("home").join(rest).display().to_string()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn parses_every_verb() {
    assert_eq!(parse(&words("show")), Ok(Request::Show));
    assert_eq!(parse(&words("off")), Ok(Request::Off));
    assert_eq!(parse(&words("set ~/a.jpg")), Ok(Request::Set { background: "~/a.jpg".into() }));
    assert_eq!(
        parse(&words("follow-appearance --light a --dark b")),
        Ok(Request::FollowAppearance { light: Some("a".into()), dark: Some("b".into()) })
    );
    assert_eq!(
        parse(&words("follow-appearance a b")),
        Ok(Request::FollowAppearance { light: Some("a".into()), dark: Some("b".into()) })
    );
    assert_eq!(
        parse(&words("schedule 07:00=~/day.jpg sunset=~/night.jpg")),
        Ok(Request::Schedule {
            entries: vec![
                ("07:00".into(), "~/day.jpg".into()),
                ("sunset".into(), "~/night.jpg".into())
            ],
            clear: false,
        })
    );
    assert_eq!(
        parse(&words("schedule --clear")),
        Ok(Request::Schedule { entries: vec![], clear: true })
    );
    assert_eq!(
        parse(&words("use-macos-dynamic")),
        Ok(Request::MacosDynamic { name: None, follow: "time".into() })
    );
    assert_eq!(
        parse(&words("use-macos-dynamic catalina --follow appearance")),
        Ok(Request::MacosDynamic { name: Some("catalina".into()), follow: "appearance".into() })
    );
    assert_eq!(
        parse(&words("rotate ~/Walls --every 30m")),
        Ok(Request::Rotate { folder: "~/Walls".into(), every: Some("30m".into()) })
    );
    assert_eq!(
        parse(&words("location 37.77,-122.42")),
        Ok(Request::Location { value: "37.77,-122.42".into() })
    );
}

#[test]
fn parse_errors_name_the_fix() {
    assert!(parse(&[]).unwrap_err().contains("cmux wallpaper show"));
    assert!(parse(&words("schedule")).unwrap_err().contains("WHEN=BACKGROUND"));
    assert!(parse(&words("schedule sunset")).unwrap_err().contains("sunset=sunset"));
    assert!(parse(&words("follow-appearance")).unwrap_err().contains("--light"));
    assert!(parse(&words("use-macos-dynamic x --follow sun")).unwrap_err().contains("time"));
    assert!(parse(&words("rotate x --every")).unwrap_err().contains("needs a value"));
    assert!(parse(&words("set x --nope")).unwrap_err().contains("unknown option --nope"));
    assert!(parse(&words("off extra")).is_err());
}

#[test]
fn when_accepts_clock_times_and_sun_events_with_offsets() {
    for (text, stored) in [
        ("07:00", "07:00"),
        ("7:05", "07:05"),
        ("23:59", "23:59"),
        ("00:00", "00:00"),
        ("sunset", "sunset"),
        ("Sunrise", "sunrise"),
        ("sunset-30m", "sunset-30m"),
        ("sunrise+1h", "sunrise+1h"),
        ("dusk+90m", "dusk+90m"),
        ("dawn-2h", "dawn-2h"),
        ("noon+15m", "noon+15m"),
    ] {
        assert_eq!(parse_when(text).as_deref(), Ok(stored), "{text}");
    }
    for text in [
        "24:00",
        "7:5",
        "07:60",
        "123:00",
        "sunup",
        "sunset30m",
        "sunset-30",
        "sunset-m",
        "sunset+0m",
        "sunset-13h",
        "sunset-30s",
        "",
        "evening",
    ] {
        assert!(parse_when(text).is_err(), "{text} should be refused");
    }
    assert!(parse_when("sunset-30").unwrap_err().contains("sunset-30m"));
}

#[test]
fn intervals_map_to_the_rotation_choices_or_minutes() {
    for (text, stored) in [
        ("15m", json!("15m")),
        ("15", json!("15m")),
        ("30m", json!(30)),
        ("30", json!(30)),
        ("1h", json!("hourly")),
        ("hourly", json!("hourly")),
        ("60m", json!("hourly")),
        ("2h", json!(120)),
        ("daily", json!("daily")),
        ("1d", json!("daily")),
        ("24h", json!("daily")),
        ("1", json!(1)),
        ("1439", json!(1439)),
        ("5min", json!(5)),
    ] {
        assert_eq!(parse_interval(text), Ok(stored), "{text}");
    }
    for text in ["0", "1441", "25h", "-5", "soon", "m", ""] {
        assert!(parse_interval(text).is_err(), "{text} should be refused");
    }
}

#[test]
fn locations_are_lat_lon_or_auto() {
    assert_eq!(parse_location("37.77,-122.42"), Ok(Some("37.77,-122.42".into())));
    assert_eq!(parse_location(" 51.5 , -0.12 "), Ok(Some("51.5,-0.12".into())));
    assert_eq!(parse_location("auto"), Ok(None));
    assert!(parse_location("91,0").unwrap_err().contains("-90 to 90"));
    assert!(parse_location("0,181").is_err());
    assert!(parse_location("somewhere").unwrap_err().contains("37.77,-122.42"));
}

#[test]
fn paths_expand_home_and_become_absolute() {
    let fixture = Fixture::new("paths");
    let env = fixture.env();
    assert_eq!(env.absolute("~/x.jpg"), fixture.0.join("home/x.jpg"));
    assert_eq!(env.absolute("~"), fixture.0.join("home"));
    assert_eq!(env.absolute("a/../b/./c.jpg"), fixture.0.join("work/b/c.jpg"));
    assert_eq!(env.absolute("/tmp/x"), PathBuf::from("/tmp/x"));
}

#[test]
fn backgrounds_map_to_settings_ids() {
    let fixture = Fixture::new("ids");
    let env = fixture.env();
    let id = |arg: &str, usage| background_id(arg, &env, usage);
    assert_eq!(id("none", Use::Main).as_deref(), Ok("none"));
    assert_eq!(id("OFF", Use::Main).as_deref(), Ok("none"));
    assert_eq!(id("desktop", Use::Fixed).as_deref(), Ok("desktop"));
    assert_eq!(id("daily", Use::Main).as_deref(), Ok("daily"));
    assert!(id("daily", Use::Fixed).is_err());
    assert_eq!(
        id("~/Pictures/day.jpg", Use::Fixed),
        Ok(format!("file:{}", fixture.home("Pictures/day.jpg")))
    );
    assert_eq!(
        id("here.png", Use::Fixed),
        Ok(format!("file:{}", fixture.0.join("work/here.png").display()))
    );
    assert_eq!(
        id("~/Pictures/Walls", Use::Main),
        Ok(format!("folder:{}", fixture.home("Pictures/Walls")))
    );
    assert!(id("~/Pictures/Walls", Use::Fixed).unwrap_err().contains("cmux wallpaper rotate"));
    assert!(id("~/Pictures/missing.jpg", Use::Main).unwrap_err().contains("no file or folder"));
    assert_eq!(id("file:~/x.jpg", Use::Fixed), Ok(format!("file:{}", fixture.home("x.jpg"))));
    assert_eq!(
        id("system:/System/Library/Desktop Pictures/Sonoma.heic", Use::Fixed).as_deref(),
        Ok("system:/System/Library/Desktop Pictures/Sonoma.heic")
    );
    assert!(id("folder:/", Use::Main).is_err());
    assert!(id("schedule", Use::Main).unwrap_err().contains("mode"));
    // A macOS wallpaper by name, any case.
    assert_eq!(
        id("sonoma", Use::Fixed),
        Ok(format!("system:{}", fixture.0.join("pictures/Sonoma.heic").display()))
    );
    assert!(id("not-a-thing", Use::Main).unwrap_err().contains("not a file, folder, painting"));
}

#[test]
fn painting_ids_come_from_the_schema() {
    let fixture = Fixture::new("paintings");
    let env = fixture.env();
    for painting in painting_ids() {
        assert_eq!(background_id(painting, &env, Use::Fixed).as_deref(), Ok(painting));
    }
    assert!(painting_ids().contains(&"dore-raven"));
}

#[test]
fn lists_and_finds_dynamic_macos_wallpapers() {
    let fixture = Fixture::new("dynamic");
    let pictures = system_pictures(&fixture.0.join("pictures"));
    let dynamic: Vec<(&str, &str)> =
        pictures.iter().filter_map(|p| p.dynamic.map(|kind| (p.name.as_str(), kind))).collect();
    assert_eq!(
        dynamic,
        [
            ("Big Sur", "time of day"),
            ("Big Sur Graphic", "time of day"),
            ("Catalina", "sun"),
            ("Sonoma", "light/dark")
        ]
    );
    let find = |name: &str| find_system_picture(&fixture.0.join("pictures"), name, true);
    assert_eq!(find("catalina").unwrap().unwrap().name, "Catalina");
    assert_eq!(find("SONOMA").unwrap().unwrap().name, "Sonoma");
    // Exact beats prefix: "Big Sur" is not ambiguous with "Big Sur Graphic".
    assert_eq!(find("big sur").unwrap().unwrap().name, "Big Sur");
    assert_eq!(find("graphic").unwrap().unwrap().name, "Big Sur Graphic");
    assert_eq!(find("Catalina Clouds").unwrap(), None);
    assert!(find("i").unwrap_err().contains("several"));
}

#[test]
fn write_plans_are_one_edit_list_per_mode() {
    let fixture = Fixture::new("plans");
    let env = fixture.env();
    let day = format!("file:{}", fixture.home("Pictures/day.jpg"));
    let night = format!("file:{}", fixture.home("Pictures/night.jpg"));

    let plan_of = |line: &str| plan(&parse(&words(line)).expect("parse"), &env);

    let follow =
        plan_of("follow-appearance --light ~/Pictures/day.jpg --dark ~/Pictures/night.jpg")
            .expect("plan");
    assert_eq!(
        follow.edits,
        vec![
            Edit::Set(BACKGROUND, json!("appearance")),
            Edit::Set(LIGHT, json!(day)),
            Edit::Set(DARK, json!(night)),
        ]
    );

    let schedule =
        plan_of("schedule 7:00=~/Pictures/day.jpg sunset-30m=~/Pictures/night.jpg").expect("plan");
    assert_eq!(
        schedule.edits,
        vec![
            Edit::Set(BACKGROUND, json!("schedule")),
            Edit::Set(SCHEDULE, json!({ "07:00": day, "sunset-30m": night })),
        ]
    );
    assert!(
        plan_of("schedule 07:00=~/Pictures/day.jpg 7:00=~/Pictures/night.jpg")
            .unwrap_err()
            .contains("twice")
    );
    assert!(plan_of("schedule 25:00=~/Pictures/day.jpg").is_err());
    assert_eq!(
        plan_of("schedule --clear").expect("plan").edits,
        vec![Edit::Reset(SCHEDULE), Edit::ResetUnchanged(BACKGROUND, json!("schedule"))]
    );

    let dynamic = plan_of("use-macos-dynamic catalina").expect("plan");
    let catalina = format!("system:{}", fixture.0.join("pictures/Catalina.madesktop").display());
    assert_eq!(
        dynamic.edits,
        vec![Edit::Set(BACKGROUND, json!(catalina)), Edit::Set(DYNAMIC, json!("time"))]
    );
    let still =
        Request::MacosDynamic { name: Some("Catalina Clouds".into()), follow: "time".into() };
    assert!(plan(&still, &env).unwrap_err().contains("does not change by itself"));
    assert!(plan_of("use-macos-dynamic mac").unwrap_err().contains("does not change by itself"));

    let rotate = plan_of("rotate ~/Pictures/Walls --every 30m").expect("plan");
    assert_eq!(
        rotate.edits,
        vec![
            Edit::Set(BACKGROUND, json!(format!("folder:{}", fixture.home("Pictures/Walls")))),
            Edit::Set(ROTATION, json!(30)),
        ]
    );
    assert_eq!(
        plan_of("rotate paintings").expect("plan").edits,
        vec![Edit::Set(BACKGROUND, json!("daily"))]
    );
    assert!(plan_of("rotate ~/Pictures/day.jpg").unwrap_err().contains("no folder"));

    assert_eq!(plan_of("location auto").expect("plan").edits, vec![Edit::Reset(LOCATION)]);
    assert_eq!(plan_of("off").expect("plan").edits, vec![Edit::Set(BACKGROUND, json!("none"))]);
}

#[test]
fn edits_go_on_the_wire_as_settings_edit_takes_them() {
    assert_eq!(
        Edit::Set(BACKGROUND, json!("none")).to_json(),
        json!({"op":"set","key":BACKGROUND,"value":"none"})
    );
    assert_eq!(Edit::Reset(LOCATION).to_json(), json!({"op":"reset","key":LOCATION}));
    assert_eq!(
        Edit::ResetUnchanged(BACKGROUND, json!("schedule")).to_json(),
        json!({"op":"reset_unchanged","key":BACKGROUND,"value":"schedule"})
    );
}

#[test]
fn modes_follow_the_background_id() {
    assert_eq!(mode_of("none", None), "off");
    assert_eq!(mode_of("daily", None), "rotate");
    assert_eq!(mode_of("folder:/x", None), "rotate");
    assert_eq!(mode_of("appearance", None), "appearance");
    assert_eq!(mode_of("schedule", None), "schedule");
    assert_eq!(mode_of("system:/a.madesktop", Some("time")), "dynamic");
    assert_eq!(mode_of("system:/a.madesktop", Some("appearance")), "picture");
    assert_eq!(mode_of("file:/a.jpg", None), "picture");
}

/// The schema accepts what every verb writes (needs this build's
/// wallpaper rows), and refuses a key it lacks with the fix.
#[test]
fn every_write_passes_the_settings_schema() {
    let fixture = Fixture::new("schema");
    let env = fixture.env();
    for line in [
        "off",
        "set ~/Pictures/day.jpg",
        "set ~/Pictures/Walls",
        "follow-appearance --light ~/Pictures/day.jpg --dark desktop",
        "schedule 07:00=~/Pictures/day.jpg sunset=~/Pictures/night.jpg",
        "schedule --clear",
        "use-macos-dynamic catalina --follow appearance",
        "use-macos-dynamic sonoma",
        "rotate ~/Pictures/Walls --every 30m",
        "rotate ~/Pictures/Walls --every 1h",
        "rotate paintings --every 1440",
        "location 37.77,-122.42",
        "location auto",
    ] {
        let plan = plan(&parse(&words(line)).expect("parse"), &env).expect(line);
        assert_eq!(validate(&plan.edits), Ok(()), "{line}");
    }
    let missing = validate(&[Edit::Set("appearance.noSuchWallpaperKey", json!(1))]).unwrap_err();
    assert!(missing.contains("appearance.noSuchWallpaperKey"), "{missing}");
    assert!(validate(&[Edit::Set(BACKGROUND, json!("folder:relative"))]).is_err());
}
