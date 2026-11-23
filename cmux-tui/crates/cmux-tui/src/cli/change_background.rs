//! `cmux settings change-background [VALUE]`: with no VALUE, the app opens
//! its background picker (`appearance.changeBackground`, today's behavior);
//! with one, the CLI reads VALUE into the background id a pick in the picker
//! stores and writes it where the picker does:
//!
//! - All Workspaces: `appearance.background`, one `settings edit` through the
//!   settings owner (the `cmux wallpaper set` path, cli/wallpaper.rs).
//! - `--light` / `--dark`: that side of the light/dark pair, and the
//!   background follows light/dark (`cmux wallpaper follow-appearance`).
//! - `--workspace [ID]`: the workspace's own background (This Workspace), the
//!   app's `appearance.set` with scope `workspace` and property `background`,
//!   which saves it where the picker does (`ThemeCoordinator.setWorkspaceBackground`).
//!
//! VALUE is a YouTube address or `youtube:` id (`cmux_config::youtube` turns
//! it into the canonical id), a picture or video file of this Mac
//! (`file:<absolute path>`), or any background word `cmux wallpaper set`
//! takes (`none`, `desktop`, `daily`, a painting id, a folder, a macOS
//! wallpaper name, a bare YouTube video id). The id is checked against this
//! build's settings schema before anything is written.

use cmux_config::youtube::{self, YouTubeWallpaper};
use serde_json::json;

use super::UsageError;
use super::app::{ActionName, run_action};
use super::wallpaper::{self, BACKGROUND, DARK, Edit, Env, LIGHT, Request, Use};

/// The action's CLI name.
const ACTION: &str = "settings change-background";

pub(super) const USAGE: &str = "\
cmux settings change-background [VALUE] [options]
  With no VALUE, opens the background picker (Settings > Appearance).
  With a VALUE, sets the background to it, as a pick in the picker does.
VALUE:
  a picture or video file of this Mac (stored as file:<absolute path>)
  none, desktop, daily, a painting id, a folder to shuffle, a macOS wallpaper name,
    or any background id (system:, file:, folder:, youtube:)
  a YouTube video address or youtube:<video id> (its t= or start= is where the loop starts)
Options:
  --start T        where a YouTube loop starts: 90, 90s, 1m30s, 1h2m3s or 1:30
  --end T          where it ends and starts over (default: the end of the video)
  --quality Q      the YouTube player height: 360, 480, 720, 1080 (default), 1440 or 2160
  --light          set the light side of the light/dark pair (the background follows light/dark)
  --dark           set the dark side of the light/dark pair
  --workspace [ID] set the workspace's own background (default: the shown workspace)
  --no-wait        with no VALUE or with --workspace: return once the app has the request
Examples:
  cmux settings change-background ~/Movies/rain.mov
  cmux settings change-background ~/Movies/night.mov --dark
  cmux settings change-background none --workspace";

/// What the words ask for, before VALUE is read into an id.
#[derive(Debug, Default, PartialEq)]
struct Words {
    value: Option<String>,
    start: Option<String>,
    end: Option<String>,
    quality: Option<String>,
    side: Option<&'static str>,
    /// `--workspace`: `Some(None)` for the shown one, `Some(Some(id))` for one by id.
    workspace: Option<Option<String>>,
    no_wait: bool,
}

/// Where a change-background run goes.
#[derive(Debug, PartialEq)]
enum Plan {
    /// A settings write, as `cmux wallpaper` makes it (`settings edit`).
    Settings(Request),
    /// An app action: its CLI name and the flags `run_action` reads.
    App { action: &'static str, flags: Vec<String> },
}

/// `cmux [global options] settings|config change-background ...`; `None` for
/// any other command and for `--help` (cli/extra_help prints it).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let rest = match words.as_slice() {
        [scope, verb, rest @ ..]
            if matches!(scope.as_str(), "settings" | "config") && verb == "change-background" =>
        {
            rest
        }
        _ => return None,
    };
    if rest.iter().any(|word| matches!(word.as_str(), "-h" | "--help")) {
        return None;
    }
    let plan = read_words(rest).and_then(|words| plan(&words, &Env::current()));
    let youtube = plan.as_ref().is_ok_and(Plan::sets_youtube);
    let code = match plan {
        Ok(Plan::Settings(request)) => {
            let prefix: Vec<String> = args
                .iter()
                .take_while(|word| !matches!(word.as_str(), "settings" | "config"))
                .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
                .cloned()
                .collect();
            wallpaper::run(&global, &prefix, request)
        }
        Ok(Plan::App { action, flags }) => match run_action(action, &flags, ActionName::Cli) {
            Ok(command) => super::app::run(&global, command),
            Err(error) => super::app::failure("usage.invalid", &error.0, global.output, 2),
        },
        Err(error) => super::app::failure("usage.invalid", &error.0, global.output, 2),
    };
    if code == 0 && youtube {
        eprintln!("{YOUTUBE_OFF_NOTE}");
    }
    Some(code)
}

/// Said after a YouTube background is set: the app does not offer YouTube
/// playback yet (Swift `BackdropYouTube.isOffered`), so the id is stored and
/// shows once it does.
pub(super) const YOUTUBE_OFF_NOTE: &str =
    "YouTube backgrounds are not turned on in this build yet; it will show once they are.";

impl Plan {
    /// Whether the plan sets a `youtube:` background.
    fn sets_youtube(&self) -> bool {
        let youtube =
            |id: &Option<String>| id.as_deref().is_some_and(|id| id.starts_with(youtube::PREFIX));
        match self {
            Plan::Settings(Request::Set { background }) => background.starts_with(youtube::PREFIX),
            Plan::Settings(Request::FollowAppearance { light, dark }) => {
                youtube(light) || youtube(dark)
            }
            Plan::Settings(_) => false,
            Plan::App { flags, .. } => {
                flags.iter().any(|flag| flag.starts_with(&format!("--value={}", youtube::PREFIX)))
            }
        }
    }
}

/// A misuse of the words: the message and the usage.
fn usage_error(message: impl std::fmt::Display) -> UsageError {
    UsageError::new(format!("cmux {ACTION}: {message}\n\n{USAGE}"))
}

/// A VALUE that is no background: the message alone, which says what to give.
fn value_error(message: impl std::fmt::Display) -> UsageError {
    UsageError::new(format!("cmux {ACTION}: {message}"))
}

fn read_words(args: &[String]) -> Result<Words, UsageError> {
    let mut words = Words::default();
    let mut index = 0;
    let mut literal = false;
    while let Some(word) = args.get(index) {
        let word = word.as_str();
        index += 1;
        if literal || !word.starts_with("--") {
            if words.value.replace(word.to_owned()).is_some() {
                return Err(usage_error("give one VALUE"));
            }
            continue;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (word, None),
        };
        let mut value = |name: &str| -> Result<String, UsageError> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            let next =
                args.get(index).ok_or_else(|| usage_error(format!("{name} needs a value")))?;
            index += 1;
            Ok(next.clone())
        };
        match flag {
            "--" => literal = true,
            "--start" => words.start = Some(value("--start")?),
            "--end" => words.end = Some(value("--end")?),
            "--quality" => words.quality = Some(value("--quality")?),
            "--light" | "--dark" if inline.is_none() => {
                let side = flag.strip_prefix("--").unwrap_or(flag);
                if words.side.is_some_and(|chosen| chosen != side) {
                    return Err(usage_error(
                        "pick one of --light or --dark: each run sets one side of the pair",
                    ));
                }
                words.side = Some(if side == "light" { "light" } else { "dark" });
            }
            "--workspace" => {
                // `--workspace ws_…` names one; a bare `--workspace` is the shown one, so a
                // VALUE after it stays the VALUE.
                let id = inline.clone().or_else(|| {
                    let next = args.get(index).filter(|next| next.starts_with("ws_"))?;
                    index += 1;
                    Some(next.clone())
                });
                words.workspace = Some(id);
            }
            "--no-wait" if inline.is_none() => words.no_wait = true,
            _ => return Err(usage_error(format!("unknown option {word}"))),
        }
    }
    Ok(words)
}

/// Where `words` go: no VALUE opens the picker; a VALUE is written as the
/// picker writes it, read into its canonical id and checked first.
fn plan(words: &Words, env: &Env) -> Result<Plan, UsageError> {
    if words.workspace.is_some() && words.side.is_some() {
        return Err(usage_error(
            "a workspace has one background of its own; --light and --dark set the light/dark pair every workspace follows",
        ));
    }
    let wait: Vec<String> = if words.no_wait { vec!["--no-wait".into()] } else { Vec::new() };
    let Some(value) = &words.value else {
        let youtube_only = words.start.is_some() || words.end.is_some() || words.quality.is_some();
        if youtube_only || words.side.is_some() || words.workspace.is_some() {
            return Err(usage_error(
                "--start, --end, --quality, --light, --dark and --workspace need a VALUE to set (with no VALUE the picker opens, where This Workspace picks one workspace's)",
            ));
        }
        return Ok(Plan::App { action: ACTION, flags: wait });
    };
    let id = background_id(value, words, env)?;
    if let Some(workspace) = &words.workspace {
        let mut flags = vec![
            "--scope=workspace".into(),
            "--property=background".into(),
            format!("--value={id}"),
        ];
        if let Some(workspace) = workspace {
            flags.push(format!("--target=workspace:{workspace}"));
        }
        flags.extend(wait);
        return Ok(Plan::App { action: "appearance set", flags });
    }
    Ok(Plan::Settings(match words.side {
        Some("light") => Request::FollowAppearance { light: Some(id), dark: None },
        Some(_) => Request::FollowAppearance { light: None, dark: Some(id) },
        None => Request::Set { background: id },
    }))
}

/// VALUE as the id the picker would store: a YouTube address or `youtube:`
/// id, else every background word `cmux wallpaper` reads (a bare YouTube
/// video id last); `--start`, `--end` and `--quality` then go into the
/// YouTube id. Checked against the row it is written to.
fn background_id(value: &str, words: &Words, env: &Env) -> Result<String, UsageError> {
    let usage = if words.side.is_some() { Use::Fixed } else { Use::Main };
    let id = wallpaper::background_id(value, env, usage).map_err(value_error)?;
    let id = with_youtube_options(id, words)?;
    let key = match words.side {
        Some("light") => LIGHT,
        Some(_) => DARK,
        None => BACKGROUND,
    };
    wallpaper::validate(&[Edit::Set(key, json!(id))]).map_err(value_error)?;
    Ok(id)
}

/// `id` with `--start`, `--end` and `--quality` applied; refused for an id
/// that is not a YouTube video.
fn with_youtube_options(id: String, words: &Words) -> Result<String, UsageError> {
    if words.start.is_none() && words.end.is_none() && words.quality.is_none() {
        return Ok(id);
    }
    let Ok(mut wallpaper) = YouTubeWallpaper::parse_id(&id) else {
        return Err(value_error(format!(
            "--start, --end and --quality apply to a YouTube video, not {id}"
        )));
    };
    if let Some(start) = &words.start {
        wallpaper.start = youtube::parse_time("start", start).map_err(value_error)?;
    }
    if let Some(end) = &words.end {
        wallpaper.end = Some(youtube::parse_time("end", end).map_err(value_error)?);
    }
    if let Some(quality) = &words.quality {
        wallpaper.quality = youtube::parse_quality(quality).map_err(value_error)?;
    }
    wallpaper.check().map_err(value_error)?;
    Ok(wallpaper.id())
}

#[cfg(test)]
mod tests;
