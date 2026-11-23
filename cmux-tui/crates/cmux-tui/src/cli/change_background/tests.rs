use std::path::PathBuf;

use serde_json::{Value, json};

use super::super::app::AppCommand;
use super::*;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// A home folder with a movie and a picture, removed when the test ends.
struct Fixture(PathBuf);

impl Fixture {
    fn new(tag: &str) -> Fixture {
        let dir = std::env::temp_dir()
            .join(format!("cmux-change-background-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for folder in ["home/Movies", "home/Walls", "work", "pictures"] {
            std::fs::create_dir_all(dir.join(folder)).expect("temp dir");
        }
        std::fs::write(dir.join("home/Movies/rain.mov"), b"mov").expect("write");
        std::fs::write(dir.join("work/here.png"), b"png").expect("write");
        Fixture(dir)
    }

    fn env(&self) -> Env {
        Env {
            home: self.0.join("home"),
            cwd: self.0.join("work"),
            pictures: self.0.join("pictures"),
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The plan the words make.
fn planned(fixture: &Fixture, words: &[&str]) -> Result<Plan, String> {
    let words = read_words(&strings(words)).map_err(|error| error.0)?;
    plan(&words, &fixture.env()).map_err(|error| error.0)
}

/// The `background` a plain VALUE writes to `appearance.background`.
fn background(fixture: &Fixture, words: &[&str]) -> Result<String, String> {
    match planned(fixture, words)? {
        Plan::Settings(Request::Set { background }) => Ok(background),
        other => Err(format!("not a background write: {other:?}")),
    }
}

/// The `action.run` params an app plan sends.
fn app_params(plan: Plan) -> Value {
    let Plan::App { action, flags } = plan else { panic!("not an app plan: {plan:?}") };
    let AppCommand::Call { method, params, .. } =
        run_action(action, &flags, ActionName::Cli).expect("run_action takes the flags")
    else {
        panic!("not a call");
    };
    assert_eq!(method, "action.run");
    params
}

#[test]
fn no_value_still_opens_the_picker() {
    let fixture = Fixture::new("none");
    let params = app_params(planned(&fixture, &[]).expect("plans"));
    assert_eq!(params["action"], ACTION);
    assert_eq!(params["cli"], true);
    assert_eq!(params["wait"], true);
    assert_eq!(params.get("args"), None);
    let params = app_params(planned(&fixture, &["--no-wait"]).expect("plans"));
    assert_eq!(params["wait"], false);
}

#[test]
fn a_youtube_address_is_written_as_its_canonical_id() {
    let fixture = Fixture::new("youtube");
    for (words, id) in [
        (
            vec!["https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s"],
            "youtube:dQw4w9WgXcQ?start=90",
        ),
        (vec!["https://youtu.be/dQw4w9WgXcQ"], "youtube:dQw4w9WgXcQ"),
        (
            vec!["youtube:dQw4w9WgXcQ?quality=720&start=5"],
            "youtube:dQw4w9WgXcQ?start=5&quality=720",
        ),
        (vec!["dQw4w9WgXcQ"], "youtube:dQw4w9WgXcQ"),
        (
            vec!["https://youtu.be/dQw4w9WgXcQ?t=10", "--end", "2m", "--quality", "720p"],
            "youtube:dQw4w9WgXcQ?start=10&end=120&quality=720",
        ),
        (
            vec!["--start=1:30", "https://www.youtube.com/shorts/dQw4w9WgXcQ", "--quality=1080"],
            "youtube:dQw4w9WgXcQ?start=90",
        ),
    ] {
        assert_eq!(background(&fixture, &words).as_deref(), Ok(id), "{words:?}");
    }
    // The write is the one `cmux wallpaper set` makes, and this build's schema takes it.
    let request = Request::Set { background: "youtube:dQw4w9WgXcQ?start=90".into() };
    let written = wallpaper::plan(&request, &fixture.env()).expect("plans");
    assert_eq!(written.edits, vec![Edit::Set(BACKGROUND, json!("youtube:dQw4w9WgXcQ?start=90"))]);
}

#[test]
fn a_file_is_written_absolute_and_other_ids_as_the_wallpaper_cli_reads_them() {
    let fixture = Fixture::new("files");
    let home = fixture.0.join("home");
    let movie = format!("file:{}", home.join("Movies/rain.mov").display());
    assert_eq!(background(&fixture, &["~/Movies/rain.mov"]), Ok(movie));
    let here = format!("file:{}", fixture.0.join("work/here.png").display());
    assert_eq!(background(&fixture, &["here.png"]), Ok(here));
    assert_eq!(background(&fixture, &["none"]).as_deref(), Ok("none"));
    assert_eq!(background(&fixture, &["desktop"]).as_deref(), Ok("desktop"));
    let walls = format!("folder:{}", home.join("Walls").display());
    assert_eq!(background(&fixture, &["~/Walls"]), Ok(walls));
    assert_eq!(
        background(&fixture, &["file:/Users/Shared/Harbor.png"]).as_deref(),
        Ok("file:/Users/Shared/Harbor.png")
    );
}

#[test]
fn light_and_dark_set_one_side_of_the_pair() {
    let fixture = Fixture::new("sides");
    assert_eq!(
        planned(&fixture, &["https://youtu.be/dQw4w9WgXcQ", "--dark"]),
        Ok(Plan::Settings(Request::FollowAppearance {
            light: None,
            dark: Some("youtube:dQw4w9WgXcQ".into())
        }))
    );
    assert_eq!(
        planned(&fixture, &["--light", "desktop"]),
        Ok(Plan::Settings(Request::FollowAppearance { light: Some("desktop".into()), dark: None }))
    );
    // The pair's write: the background follows light/dark and the side holds the video.
    let request =
        Request::FollowAppearance { light: None, dark: Some("youtube:dQw4w9WgXcQ".into()) };
    let written = wallpaper::plan(&request, &fixture.env()).expect("plans");
    assert_eq!(
        written.edits,
        vec![
            Edit::Set(BACKGROUND, json!("appearance")),
            Edit::Set(DARK, json!("youtube:dQw4w9WgXcQ"))
        ]
    );
    assert_eq!(wallpaper::validate(&written.edits), Ok(()));
}

#[test]
fn workspace_sets_the_workspace_background_through_appearance_set() {
    let fixture = Fixture::new("workspace");
    let params = app_params(
        planned(&fixture, &["--workspace", "https://youtu.be/dQw4w9WgXcQ"]).expect("plans"),
    );
    assert_eq!(params["action"], "appearance set");
    assert_eq!(
        params["args"],
        json!({ "scope": "workspace", "property": "background", "value": "youtube:dQw4w9WgXcQ" })
    );
    assert_eq!(params.get("target"), None, "the shown workspace");
    let params = app_params(
        planned(&fixture, &["none", "--workspace", "ws_1", "--no-wait"]).expect("plans"),
    );
    assert_eq!(params["args"]["value"], "none");
    assert_eq!(params["target"], "workspace:ws_1");
    assert_eq!(params["wait"], false);
}

#[test]
fn refusals_name_the_fix() {
    let fixture = Fixture::new("refusals");
    let refused = |words: &[&str], needle: &str| {
        let error = planned(&fixture, words).expect_err(&format!("{words:?} is refused"));
        assert!(error.contains(needle), "{words:?}: {error}");
    };
    refused(&["https://www.youtube.com/playlist?list=PL1"], "playlist");
    refused(&["https://www.youtube.com/@channel"], "channel");
    refused(&["https://vimeo.com/1"], "not YouTube");
    refused(&["desktop", "--start", "10"], "apply to a YouTube video");
    refused(&["https://youtu.be/dQw4w9WgXcQ", "--start", "20", "--end", "10"], "after the start");
    refused(&["https://youtu.be/dQw4w9WgXcQ", "--quality", "4k"], "quality");
    refused(&["https://youtu.be/dQw4w9WgXcQ", "--start", "soon"], "not a time");
    refused(&["--light"], "need a VALUE");
    refused(&["--start", "10"], "need a VALUE");
    refused(&["--workspace", "ws_1"], "need a VALUE");
    refused(&["desktop", "--light", "--dark"], "pick one of --light or --dark");
    refused(&["desktop", "--light", "--workspace"], "one background of its own");
    refused(&["daily", "--dark"], "changes picture by itself");
    refused(&["a", "b"], "one VALUE");
    refused(&["none", "--sideways"], "unknown option --sideways");
    refused(&["none", "--end"], "--end needs a value");
    refused(&["~/Movies/missing.mov"], "no file or folder");
}

#[test]
fn only_change_background_is_taken_and_help_is_left_to_the_help() {
    let args = |words: &[&str]| strings(words);
    assert_eq!(run_if_requested(&args(&["settings", "get", "appearance.background"])), None);
    assert_eq!(run_if_requested(&args(&["wallpaper", "set", "none"])), None);
    assert_eq!(run_if_requested(&args(&["settings", "change-background", "--help"])), None);
    assert_eq!(run_if_requested(&args(&["config", "change-background", "-h"])), None);
}

#[test]
fn help_names_the_forms_local_video_first_with_no_youtube_example() {
    for needle in ["youtube:<video id>", "file:<absolute path>", "--start", "--quality"] {
        assert!(USAGE.contains(needle), "{needle}");
    }
    let files = USAGE.find("video file of this Mac").expect("files are listed");
    let youtube = USAGE.find("a YouTube video address").expect("YouTube is listed");
    assert!(files < youtube, "local video comes first");
    let examples = &USAGE[USAGE.find("Examples:").expect("examples")..];
    assert!(!examples.to_lowercase().contains("youtu"), "{examples}");
    assert!(examples.contains("rain.mov"));
    let help =
        super::super::extra_help::text(&strings(&["settings", "change-background", "--help"]));
    assert_eq!(help.as_deref(), Some(format!("{USAGE}\n").as_str()));
}

#[test]
fn a_youtube_background_says_it_is_not_turned_on_yet() {
    let fixture = Fixture::new("note");
    for words in [
        vec!["https://youtu.be/dQw4w9WgXcQ"],
        vec!["youtube:dQw4w9WgXcQ", "--dark"],
        vec!["dQw4w9WgXcQ", "--workspace"],
    ] {
        assert!(planned(&fixture, &words).expect("plans").sets_youtube(), "{words:?}");
    }
    for words in [vec!["~/Movies/rain.mov"], vec!["none", "--workspace"], vec![]] {
        assert!(!planned(&fixture, &words).expect("plans").sets_youtube(), "{words:?}");
    }
    assert_eq!(
        YOUTUBE_OFF_NOTE,
        "YouTube backgrounds are not turned on in this build yet; it will show once they are."
    );
}
