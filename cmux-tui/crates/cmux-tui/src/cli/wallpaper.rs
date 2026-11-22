//! `cmux wallpaper`: the picture behind the window, and how it changes by
//! itself (light/dark, a time-of-day schedule, a macOS dynamic wallpaper,
//! a folder on rotation). Every verb is a few `appearance.*` settings: the
//! words are read and checked here against this build's settings schema,
//! then sent as one `cmux settings edit` with this run's global options, so
//! a mode switch is one atomic write and the running app reloads it at once.
//!
//! - `show`: the configured mode and its keys, read from the settings file
//!   (works with cmux quit), and the picture the app shows now when it
//!   reports one (`debug.themes`, `backdrop.picture`).
//! - `set BACKGROUND`: one picture (a path, `none`, `daily`, `desktop`, a
//!   painting id or a macOS wallpaper name), or a folder to shuffle.
//! - `follow-appearance --light X --dark Y`: one picture per appearance.
//! - `schedule WHEN=BACKGROUND...`: pictures by time of day (`--clear` to stop).
//! - `use-macos-dynamic [NAME|PATH] [--follow time|appearance]`: a macOS
//!   dynamic wallpaper; with no NAME, the ones this Mac has.
//! - `rotate FOLDER [--every INTERVAL]`: the pictures of a folder in turn.
//! - `location LAT,LON|auto`: where the sun is reckoned from.
//! - `off`: no picture.

use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use cmux_config::Schema;
use cmux_config::domains::Domains;
use cmux_config::schema::{Kind, accepts};
use cmux_config::{FileRead, State, Target};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
cmux wallpaper: the picture behind the window, and how it changes by itself.
  cmux wallpaper show [--json]                       the mode, its settings, and the picture shown now
  cmux wallpaper set BACKGROUND                      one picture, or a folder to shuffle
  cmux wallpaper follow-appearance --light X --dark Y   one picture for light mode, one for dark
  cmux wallpaper schedule WHEN=BACKGROUND...         pictures by time of day; --clear stops it
      WHEN: HH:MM (24 h), or sunrise|sunset|dawn|dusk|noon with an offset such as sunset-30m, dawn+1h
  cmux wallpaper use-macos-dynamic [NAME|PATH] [--follow time|appearance]
      a macOS dynamic wallpaper (Catalina, Sonoma, ...); time follows the sun (default),
      appearance shows its light or dark picture; no NAME lists the ones this Mac has
  cmux wallpaper rotate FOLDER [--every 15m|30m|1h|daily|N]   the folder's pictures in turn (N minutes)
  cmux wallpaper location LAT,LON|auto               where sunrise and sunset are reckoned (auto: the time zone)
  cmux wallpaper off                                 no picture
BACKGROUND: an image or movie path, a YouTube video address (or youtube:<video id>), a folder,
  none, daily (shuffle paintings), desktop (your desktop picture), a painting id, or a macOS
  wallpaper name such as Sonoma.
Examples:
  cmux wallpaper follow-appearance --light ~/Pictures/day.jpg --dark ~/Pictures/night.jpg
  cmux wallpaper schedule 07:00=~/Pictures/day.jpg sunset=~/Pictures/night.jpg
  cmux wallpaper use-macos-dynamic catalina
  cmux wallpaper rotate ~/Pictures/Walls --every 30m";

pub(super) const BACKGROUND: &str = "appearance.background";
pub(super) const LIGHT: &str = "appearance.backgroundLight";
pub(super) const DARK: &str = "appearance.backgroundDark";
pub(super) const SCHEDULE: &str = "appearance.backgroundSchedule";
pub(super) const DYNAMIC: &str = "appearance.backgroundDynamic";
pub(super) const LOCATION: &str = "appearance.backgroundLocation";
pub(super) const ROTATION: &str = "appearance.backgroundRotation";
const KEYS: [&str; 7] = [BACKGROUND, LIGHT, DARK, SCHEDULE, DYNAMIC, LOCATION, ROTATION];

/// Where macOS keeps its wallpapers.
const SYSTEM_PICTURES: &str = "/System/Library/Desktop Pictures";
const SYSTEM_ROOTS: [&str; 2] = ["/System/Library/Desktop Pictures/", "/Library/Desktop Pictures/"];
const SUN_EVENTS: [&str; 5] = ["sunrise", "sunset", "dawn", "dusk", "noon"];

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Request {
    Show,
    Set { background: String },
    FollowAppearance { light: Option<String>, dark: Option<String> },
    Schedule { entries: Vec<(String, String)>, clear: bool },
    MacosDynamic { name: Option<String>, follow: String },
    Rotate { folder: String, every: Option<String> },
    Location { value: String },
    Off,
}

/// `cmux [global options] wallpaper ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (_, rest) = words.split_first().filter(|(scope, _)| *scope == "wallpaper")?;
    let prefix: Vec<String> = args
        .iter()
        .take_while(|word| *word != "wallpaper")
        .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
        .cloned()
        .collect();
    if rest.first().is_none_or(|verb| verb == "help")
        || rest.iter().any(|word| matches!(word.as_str(), "-h" | "--help"))
    {
        println!("{USAGE}");
        return Some(0);
    }
    Some(match parse(rest) {
        Ok(request) => run(&global, &prefix, request),
        Err(message) => {
            eprintln!("{message}");
            2
        }
    })
}

pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let usage = || USAGE.to_owned();
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let mut positional: Vec<String> = Vec::new();
    let (mut light, mut dark, mut every, mut follow) = (None, None, None, None);
    let mut clear = false;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let mut next =
            || words.next().cloned().ok_or_else(|| format!("{word} needs a value\n\n{USAGE}"));
        match word.as_str() {
            "--light" if verb == "follow-appearance" => light = Some(next()?),
            "--dark" if verb == "follow-appearance" => dark = Some(next()?),
            "--every" if verb == "rotate" => every = Some(next()?),
            "--follow" if verb == "use-macos-dynamic" => follow = Some(next()?),
            "--clear" if verb == "schedule" => clear = true,
            "-h" | "--help" => return Err(usage()),
            flag if flag.starts_with("--") => {
                return Err(format!("cmux wallpaper {verb}: unknown option {flag}\n\n{USAGE}"));
            }
            _ => positional.push(word.clone()),
        }
    }
    Ok(match (verb.as_str(), positional.as_slice()) {
        ("show", []) => Request::Show,
        ("set", [background]) => Request::Set { background: background.clone() },
        ("follow-appearance", []) if light.is_some() || dark.is_some() => {
            Request::FollowAppearance { light, dark }
        }
        ("follow-appearance", [one, two]) if light.is_none() && dark.is_none() => {
            Request::FollowAppearance { light: Some(one.clone()), dark: Some(two.clone()) }
        }
        ("follow-appearance", _) => {
            return Err(format!(
                "cmux wallpaper follow-appearance needs --light PICTURE and/or --dark PICTURE\n\n{USAGE}"
            ));
        }
        ("schedule", []) if clear => Request::Schedule { entries: Vec::new(), clear },
        ("schedule", []) => {
            return Err(format!(
                "cmux wallpaper schedule needs WHEN=BACKGROUND pairs, e.g. 07:00=~/day.jpg sunset=~/night.jpg (or --clear)\n\n{USAGE}"
            ));
        }
        ("schedule", pairs) if !clear => {
            let mut entries = Vec::new();
            for pair in pairs {
                let Some((when, background)) = pair.split_once('=') else {
                    return Err(format!(
                        "{pair:?} is not WHEN=BACKGROUND: write it as sunset={pair} or 07:00={pair}"
                    ));
                };
                entries.push((when.to_string(), background.to_string()));
            }
            Request::Schedule { entries, clear }
        }
        ("use-macos-dynamic", []) if follow.is_none() => {
            Request::MacosDynamic { name: None, follow: "time".into() }
        }
        ("use-macos-dynamic", [name]) => {
            let follow = follow.unwrap_or_else(|| "time".into()).to_ascii_lowercase();
            if !matches!(follow.as_str(), "time" | "appearance") {
                return Err(format!(
                    "--follow {follow}: pick time (the picture follows the sun) or appearance (light or dark)"
                ));
            }
            Request::MacosDynamic { name: Some(name.clone()), follow }
        }
        ("rotate", [folder]) => Request::Rotate { folder: folder.clone(), every },
        ("location", [value]) => Request::Location { value: value.clone() },
        ("off", []) => Request::Off,
        _ => return Err(usage()),
    })
}

/// What the verbs resolve against: the home folder, the working folder and
/// the folder of macOS wallpapers (a temporary one in tests).
#[derive(Debug, Clone)]
pub(super) struct Env {
    pub home: PathBuf,
    pub cwd: PathBuf,
    pub pictures: PathBuf,
}

impl Env {
    pub(super) fn current() -> Env {
        Env {
            home: std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default(),
            cwd: std::env::current_dir().unwrap_or_default(),
            pictures: PathBuf::from(SYSTEM_PICTURES),
        }
    }

    /// `text` as an absolute path: `~` is the home folder, a relative path
    /// starts at the working folder, `.` and `..` are taken out.
    pub(super) fn absolute(&self, text: &str) -> PathBuf {
        let path = if text == "~" {
            self.home.clone()
        } else if let Some(rest) = text.strip_prefix("~/") {
            self.home.join(rest)
        } else {
            let path = PathBuf::from(text);
            if path.is_absolute() { path } else { self.cwd.join(path) }
        };
        let mut clean = PathBuf::new();
        for part in path.components() {
            match part {
                Component::CurDir => {}
                Component::ParentDir => {
                    clean.pop();
                }
                other => clean.push(other),
            }
        }
        clean
    }
}

/// One settings edit, as `settings.edit` takes it.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Edit {
    Set(&'static str, Value),
    Reset(&'static str),
    /// Reset only while the file still holds this value.
    ResetUnchanged(&'static str, Value),
}

impl Edit {
    fn to_json(&self) -> Value {
        match self {
            Edit::Set(key, value) => json!({ "op": "set", "key": key, "value": value }),
            Edit::Reset(key) => json!({ "op": "reset", "key": key }),
            Edit::ResetUnchanged(key, value) => {
                json!({ "op": "reset_unchanged", "key": key, "value": value })
            }
        }
    }
}

/// A write: its edits and the one line that says what is now set.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Plan {
    pub mode: &'static str,
    pub edits: Vec<Edit>,
    pub summary: String,
}

/// Whether a background may shuffle (`folder:`, `daily`) or must be one picture.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum Use {
    Main,
    Fixed,
}

/// The settings id for a background word: `none`, `daily`, `desktop`, a
/// painting id, a YouTube address (`youtube:`), a path (`file:`, `system:`
/// under the macOS wallpapers, `folder:` for a folder), an id with its
/// prefix, a macOS wallpaper name, or a bare YouTube video id.
pub(super) fn background_id(arg: &str, env: &Env, usage: Use) -> Result<String, String> {
    let word = arg.trim();
    let lower = word.to_ascii_lowercase();
    let not_fixed = |what: &str| {
        format!(
            "{arg}: {what} changes picture by itself; give one picture here, or use `cmux wallpaper rotate`"
        )
    };
    match lower.as_str() {
        "" => return Err("give a picture: a path, none, desktop or a painting id".into()),
        "none" | "off" => return Ok("none".into()),
        "desktop" => return Ok("desktop".into()),
        "daily" | "paintings" | "shuffle" => {
            return match usage {
                Use::Main => Ok("daily".into()),
                Use::Fixed => Err(not_fixed("daily")),
            };
        }
        "appearance" | "schedule" => {
            return Err(format!(
                "{arg} is a mode, not a picture: `cmux wallpaper follow-appearance` or `cmux wallpaper schedule` sets it"
            ));
        }
        _ => {}
    }
    // A YouTube address or `youtube:` id: its canonical id (cmux_config::youtube). Another
    // site's address is refused by name, never read as a path.
    let web = ["http://", "https://"].iter().any(|scheme| lower.starts_with(scheme));
    if web || cmux_config::youtube::claims_youtube(word) {
        return cmux_config::youtube::YouTubeWallpaper::from_input(word)
            .map(|wallpaper| wallpaper.id())
            .map_err(|error| format!("{arg}: {error}"));
    }
    for prefix in ["system:", "file:", "folder:"] {
        if let Some(path) = word.strip_prefix(prefix) {
            if prefix == "folder:" && usage == Use::Fixed {
                return Err(not_fixed("a folder"));
            }
            let path = env.absolute(path);
            if prefix == "folder:" && path.parent().is_none() {
                return Err(format!("{arg}: pick a folder of pictures, not /"));
            }
            return Ok(format!("{prefix}{}", path.display()));
        }
    }
    let looks_like_path = word.starts_with(['/', '~', '.']) || word.contains('/');
    let candidate = env.absolute(word);
    if looks_like_path || candidate.exists() {
        return path_id(arg, &candidate, usage);
    }
    if painting_ids().contains(&word) {
        return Ok(word.to_string());
    }
    if let Some(picture) = find_system_picture(&env.pictures, word, false)? {
        return Ok(format!("system:{}", picture.path.display()));
    }
    // Last, a bare YouTube video id (11 letters, digits, - or _, a capital or digit among them).
    if cmux_config::youtube::looks_like_video_id(word) {
        return Ok(format!("{}{word}", cmux_config::youtube::PREFIX));
    }
    let paintings = painting_ids();
    let listed = if paintings.is_empty() {
        String::new()
    } else {
        format!("; painting ids: {}", paintings.join(", "))
    };
    Err(format!(
        "{arg:?} is not a file, folder, painting, YouTube video or macOS wallpaper: pass a path (~/Pictures/x.jpg), a YouTube address, none, daily, desktop, or a macOS wallpaper name (`cmux wallpaper use-macos-dynamic` lists the dynamic ones){listed}"
    ))
}

fn path_id(arg: &str, path: &Path, usage: Use) -> Result<String, String> {
    let shown = path.display();
    let Ok(metadata) = std::fs::metadata(path) else {
        return Err(format!("{arg}: there is no file or folder at {shown}"));
    };
    if metadata.is_dir() {
        if usage == Use::Fixed {
            return Err(format!(
                "{arg}: a folder changes picture by itself; give one picture here, or use `cmux wallpaper rotate {arg}`"
            ));
        }
        if path.parent().is_none() {
            return Err(format!("{arg}: pick a folder of pictures, not /"));
        }
        return Ok(format!("folder:{shown}"));
    }
    let text = path.to_string_lossy();
    let system = SYSTEM_ROOTS.iter().any(|root| text.starts_with(root));
    Ok(format!("{}:{shown}", if system { "system" } else { "file" }))
}

/// This build's painting ids: the background row's choices other than the
/// words the CLI reads itself.
fn painting_ids() -> Vec<&'static str> {
    let Some(row) = Schema::embedded().row(BACKGROUND) else { return Vec::new() };
    let choices = match &row.kind {
        Kind::Choice(choices) => choices,
        _ => return Vec::new(),
    };
    choices
        .iter()
        .map(|choice| choice.value.as_str())
        .filter(|value| !matches!(*value, "none" | "daily" | "desktop" | "appearance" | "schedule"))
        .collect()
}

/// A WHEN as the schedule stores it: `HH:MM` (24 h), or a sun event with an
/// optional offset in minutes or hours (`sunset-30m`, `dawn+1h`).
pub(super) fn parse_when(text: &str) -> Result<String, String> {
    let lower = text.trim().to_ascii_lowercase();
    let fix = "write WHEN as HH:MM (07:00, 19:30) or sunrise|sunset|dawn|dusk|noon, optionally with an offset (sunset-30m, sunrise+1h)";
    if let Some((hours, minutes)) = lower.split_once(':') {
        let hour = hours.parse::<u32>().ok().filter(|h| hours.len() <= 2 && *h < 24);
        let minute = minutes.parse::<u32>().ok().filter(|m| minutes.len() == 2 && *m < 60);
        return match (hour, minute) {
            (Some(hour), Some(minute)) => Ok(format!("{hour:02}:{minute:02}")),
            _ => Err(format!("{text:?} is not a time of day: {fix}")),
        };
    }
    let Some(event) = SUN_EVENTS.iter().find(|event| lower.starts_with(**event)) else {
        return Err(format!("{text:?} is not a time: {fix}"));
    };
    let offset = lower.strip_prefix(*event).unwrap_or_default();
    if offset.is_empty() {
        return Ok((*event).to_string());
    }
    let (sign, amount) = if let Some(amount) = offset.strip_prefix('+') {
        ("+", amount)
    } else if let Some(amount) = offset.strip_prefix('-') {
        ("-", amount)
    } else {
        return Err(format!("{text:?}: {fix}"));
    };
    if !amount.is_empty() && amount.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!(
            "{text:?}: the offset needs a unit, as in {event}{sign}{amount}m or {event}{sign}{amount}h"
        ));
    }
    let (number, unit_minutes, unit) = if let Some(number) = amount.strip_suffix('m') {
        (number, 1, "m")
    } else if let Some(number) = amount.strip_suffix('h') {
        (number, 60, "h")
    } else {
        return Err(format!("{text:?}: {fix}"));
    };
    let Some(count) = number.parse::<u64>().ok().filter(|n| *n > 0 && n.to_string() == number)
    else {
        return Err(format!("{text:?}: {fix}"));
    };
    if count.saturating_mul(unit_minutes) > 12 * 60 {
        return Err(format!(
            "{text:?}: an offset is at most 12h; use a clock time (HH:MM) instead"
        ));
    }
    Ok(format!("{event}{sign}{count}{unit}"))
}

/// `appearance.backgroundRotation` for `--every`: the named choices
/// (`15m`, `hourly`, `daily`), else a number of minutes from 1 to 1440.
pub(super) fn parse_interval(text: &str) -> Result<Value, String> {
    let lower = text.trim().to_ascii_lowercase();
    let fix = "--every takes 15m, 30m, 1h, hourly, daily, or a number of minutes from 1 to 1440";
    let minutes = match lower.as_str() {
        "hourly" => 60,
        "daily" | "1d" | "day" => 1440,
        _ => {
            let (number, scale) = if let Some(n) = lower.strip_suffix('h') {
                (n, 60)
            } else if let Some(n) = lower.strip_suffix("min").or_else(|| lower.strip_suffix('m')) {
                (n, 1)
            } else {
                (lower.as_str(), 1)
            };
            match number.parse::<u32>() {
                Ok(n) if n > 0 => n.saturating_mul(scale),
                _ => return Err(format!("--every {text}: {fix}")),
            }
        }
    };
    Ok(match minutes {
        15 => json!("15m"),
        60 => json!("hourly"),
        1440 => json!("daily"),
        1..=1440 => json!(minutes),
        _ => return Err(format!("--every {text}: {fix}")),
    })
}

/// `appearance.backgroundLocation` for `LAT,LON`; `None` for `auto`.
pub(super) fn parse_location(text: &str) -> Result<Option<String>, String> {
    let trimmed = text.trim();
    if matches!(trimmed.to_ascii_lowercase().as_str(), "auto" | "timezone" | "time-zone") {
        return Ok(None);
    }
    let fix = "write it as LAT,LON in degrees, e.g. 37.77,-122.42 (or auto: from the time zone)";
    let Some((lat, lon)) = trimmed.split_once(',') else {
        return Err(format!("{text:?}: {fix}"));
    };
    let (lat, lon) = (lat.trim(), lon.trim());
    match (lat.parse::<f64>(), lon.parse::<f64>()) {
        (Ok(a), Ok(b)) if (-90.0..=90.0).contains(&a) && (-180.0..=180.0).contains(&b) => {
            Ok(Some(format!("{a},{b}")))
        }
        (Ok(_), Ok(_)) => {
            Err(format!("{text:?}: latitude is -90 to 90 and longitude -180 to 180; {fix}"))
        }
        _ => Err(format!("{text:?}: {fix}")),
    }
}

/// A macOS wallpaper on this Mac.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct SystemPicture {
    pub name: String,
    pub path: PathBuf,
    /// `sun`, `time of day` or `light/dark` for a dynamic one, else `None`.
    pub dynamic: Option<&'static str>,
}

/// The macOS wallpapers in `folder`: `.madesktop` files (their plist says
/// `isDynamic` and `isSolar`) and `.heic` files (dynamic when they carry
/// `apple_desktop` metadata: solar, h24 or apr frames), by name.
pub(super) fn system_pictures(folder: &Path) -> Vec<SystemPicture> {
    let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut pictures: Vec<SystemPicture> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            let extension = path.extension()?.to_str()?.to_ascii_lowercase();
            let name = path.file_stem()?.to_str()?.to_string();
            if name.starts_with('.') {
                return None;
            }
            let dynamic = match extension.as_str() {
                "madesktop" => madesktop_kind(&path),
                "heic" => heic_kind(&path),
                _ => return None,
            };
            Some(SystemPicture { name, path, dynamic })
        })
        .collect();
    pictures.sort_by_key(|picture| picture.name.to_lowercase());
    pictures
}

fn madesktop_kind(path: &Path) -> Option<&'static str> {
    let value = plist::Value::from_file(path).ok()?;
    let dictionary = value.as_dictionary()?;
    let flag = |key: &str| dictionary.get(key).and_then(plist::Value::as_boolean) == Some(true);
    if !flag("isDynamic") {
        return None;
    }
    Some(if flag("isSolar") { "sun" } else { "time of day" })
}

/// A HEIC's dynamic metadata sits in its XMP, near the start of the file.
fn heic_kind(path: &Path) -> Option<&'static str> {
    use std::io::Read as _;
    let mut head = Vec::new();
    std::fs::File::open(path).ok()?.take(256 * 1024).read_to_end(&mut head).ok()?;
    let text = String::from_utf8_lossy(&head);
    let at = text.find("apple_desktop:")?;
    let rest = text.get(at..)?;
    Some(if rest.contains("apple_desktop:solar") {
        "sun"
    } else if rest.contains("apple_desktop:h24") {
        "time of day"
    } else {
        "light/dark"
    })
}

/// The wallpaper `name` names: its exact name (any case), else the one
/// whose name starts with it, else the one that contains it. With
/// `dynamic_only`, only dynamic ones; a name that matches several is an error.
pub(super) fn find_system_picture(
    folder: &Path,
    name: &str,
    dynamic_only: bool,
) -> Result<Option<SystemPicture>, String> {
    let wanted = name.trim().to_lowercase();
    let pictures: Vec<SystemPicture> = system_pictures(folder)
        .into_iter()
        .filter(|picture| !dynamic_only || picture.dynamic.is_some())
        .collect();
    let lower = |picture: &SystemPicture| picture.name.to_lowercase();
    if let Some(exact) = pictures.iter().find(|picture| lower(picture) == wanted) {
        return Ok(Some(exact.clone()));
    }
    fn starts(p: &str, w: &str) -> bool {
        p.starts_with(w)
    }
    fn contains(p: &str, w: &str) -> bool {
        p.contains(w)
    }
    for test in [starts as fn(&str, &str) -> bool, contains] {
        let matches: Vec<&SystemPicture> =
            pictures.iter().filter(|picture| test(&lower(picture), &wanted)).collect();
        match matches.as_slice() {
            [] => {}
            [one] => return Ok(Some((*one).clone())),
            many => {
                let names: Vec<&str> = many.iter().map(|p| p.name.as_str()).collect();
                return Err(format!(
                    "{name:?} names several macOS wallpapers: {}; give the whole name",
                    names.join(", ")
                ));
            }
        }
    }
    Ok(None)
}

/// The edits and summary for a write request. `Show` and the listing are not writes.
pub(super) fn plan(request: &Request, env: &Env) -> Result<Plan, String> {
    Ok(match request {
        Request::Show | Request::MacosDynamic { name: None, .. } => {
            return Err("not a write".into());
        }
        Request::Off => Plan {
            mode: "off",
            edits: vec![Edit::Set(BACKGROUND, json!("none"))],
            summary: "wallpaper: off (appearance.background = none)".into(),
        },
        Request::Set { background } => {
            let id = background_id(background, env, Use::Main)?;
            let mode = mode_of(&id, None);
            Plan {
                mode,
                summary: format!("wallpaper: {} (appearance.background = {id})", mode_words(mode)),
                edits: vec![Edit::Set(BACKGROUND, json!(id))],
            }
        }
        Request::FollowAppearance { light, dark } => {
            let mut edits = vec![Edit::Set(BACKGROUND, json!("appearance"))];
            let mut parts = Vec::new();
            for (side, key, value) in [("light", LIGHT, light), ("dark", DARK, dark)] {
                if let Some(value) = value {
                    let id = background_id(value, env, Use::Fixed)?;
                    parts.push(format!("{side} {id}"));
                    edits.push(Edit::Set(key, json!(id)));
                }
            }
            Plan {
                mode: "appearance",
                edits,
                summary: format!("wallpaper: follows light/dark: {}", parts.join(", ")),
            }
        }
        Request::Schedule { clear: true, .. } => Plan {
            mode: "off",
            edits: vec![Edit::Reset(SCHEDULE), Edit::ResetUnchanged(BACKGROUND, json!("schedule"))],
            summary: "wallpaper: schedule cleared".into(),
        },
        Request::Schedule { entries, clear: false } => {
            let mut map = Map::new();
            for (when, background) in entries {
                let when = parse_when(when)?;
                let id = background_id(background, env, Use::Fixed)?;
                if map.insert(when.clone(), json!(id)).is_some() {
                    return Err(format!("{when} is given twice; give each time once"));
                }
            }
            let parts: Vec<String> = map
                .iter()
                .map(|(when, id)| format!("{when} {}", id.as_str().unwrap_or_default()))
                .collect();
            Plan {
                mode: "schedule",
                summary: format!("wallpaper: by time of day: {}", parts.join(", ")),
                edits: vec![
                    Edit::Set(BACKGROUND, json!("schedule")),
                    Edit::Set(SCHEDULE, Value::Object(map)),
                ],
            }
        }
        Request::MacosDynamic { name: Some(name), follow } => {
            let looks_like_path = name.starts_with(['/', '~', '.']) || name.contains('/');
            let path = if looks_like_path {
                let path = env.absolute(name);
                if !path.is_file() {
                    return Err(format!(
                        "{name}: there is no wallpaper file at {}",
                        path.display()
                    ));
                }
                path
            } else {
                match find_system_picture(&env.pictures, name, true)? {
                    Some(picture) => picture.path,
                    None => {
                        let still = find_system_picture(&env.pictures, name, false)
                            .ok()
                            .flatten()
                            .map(|p| format!(" ({} does not change by itself; `cmux wallpaper set {:?}` shows it)", p.name, p.name))
                            .unwrap_or_default();
                        return Err(format!(
                            "no dynamic macOS wallpaper is called {name:?}{still}; `cmux wallpaper use-macos-dynamic` lists them"
                        ));
                    }
                }
            };
            let id = format!("system:{}", path.display());
            let how = if follow == "time" { "follows the sun" } else { "light or dark picture" };
            Plan {
                mode: "dynamic",
                summary: format!(
                    "wallpaper: macOS {} ({how}; appearance.background = {id})",
                    stem(&path)
                ),
                edits: vec![Edit::Set(BACKGROUND, json!(id)), Edit::Set(DYNAMIC, json!(follow))],
            }
        }
        Request::Rotate { folder, every } => {
            let lower = folder.to_ascii_lowercase();
            let id = if matches!(lower.as_str(), "paintings" | "daily") {
                "daily".to_string()
            } else {
                let path = env.absolute(folder);
                if !path.is_dir() {
                    return Err(format!(
                        "{folder}: there is no folder at {}; rotate takes a folder of pictures (or paintings)",
                        path.display()
                    ));
                }
                background_id(&format!("folder:{}", path.display()), env, Use::Main)?
            };
            let mut edits = vec![Edit::Set(BACKGROUND, json!(id))];
            let mut summary = format!("wallpaper: rotates {id}");
            if let Some(every) = every {
                let interval = parse_interval(every)?;
                summary.push_str(&format!(" every {}", interval_words(&interval)));
                edits.push(Edit::Set(ROTATION, interval));
            }
            Plan { mode: "rotate", edits, summary }
        }
        Request::Location { value } => match parse_location(value)? {
            Some(location) => Plan {
                mode: "location",
                summary: format!("wallpaper: sun times from {location}"),
                edits: vec![Edit::Set(LOCATION, json!(location))],
            },
            None => Plan {
                mode: "location",
                summary: "wallpaper: sun times from the time zone".into(),
                edits: vec![Edit::Reset(LOCATION)],
            },
        },
    })
}

fn stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn interval_words(interval: &Value) -> String {
    match interval {
        Value::Number(minutes) => format!("{minutes} minutes"),
        Value::String(text) if text == "15m" => "15 minutes".into(),
        Value::String(text) if text == "hourly" => "hour".into(),
        Value::String(text) if text == "daily" => "day".into(),
        other => other.to_string(),
    }
}

/// The mode a background id means (`dynamic` for a `system:` wallpaper
/// whose `appearance.backgroundDynamic` is `time`).
pub(super) fn mode_of(id: &str, dynamic: Option<&str>) -> &'static str {
    match id {
        "none" => "off",
        "daily" => "rotate",
        "appearance" => "appearance",
        "schedule" => "schedule",
        id if id.starts_with("folder:") => "rotate",
        id if id.starts_with("system:") && dynamic == Some("time") => "dynamic",
        _ => "picture",
    }
}

fn mode_words(mode: &str) -> &'static str {
    match mode {
        "off" => "off",
        "rotate" => "rotates pictures",
        "appearance" => "follows light/dark",
        "schedule" => "by time of day",
        "dynamic" => "macOS dynamic, follows the sun",
        _ => "one picture",
    }
}

/// Every edit checked against this build's schema, so a refusal names the
/// key and what it takes before anything is written.
pub(super) fn validate(edits: &[Edit]) -> Result<(), String> {
    let schema = Schema::embedded();
    for edit in edits {
        let (key, value) = match edit {
            Edit::Set(key, value) => (*key, Some(value)),
            Edit::Reset(key) | Edit::ResetUnchanged(key, _) => (*key, None),
        };
        let Some(row) = schema.row(key) else {
            return Err(format!(
                "this cmux CLI has no setting {key}: run this with the cmux CLI that ships with the running app (`cmux settings set {key} ...` there)"
            ));
        };
        if let Some(value) = value
            && let Err(refusal) = accepts(row, value, &Domains::default())
        {
            return Err(refusal.to_string());
        }
    }
    Ok(())
}

/// The block that sets the same values by hand in cmux-next.json.
fn raw_block(edits: &[Edit]) -> Value {
    let mut block = Map::new();
    for edit in edits {
        if let Edit::Set(key, value) = edit {
            block.insert((*key).to_string(), value.clone());
        }
    }
    Value::Object(block)
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    super::wire::print_local_error(&json!({ "code": code, "message": message }), global.output, 1)
}

fn is_json(global: &GlobalArgs) -> bool {
    matches!(global.output, OutputMode::Json | OutputMode::JsonLines)
}

pub(super) fn run(global: &GlobalArgs, prefix: &[String], request: Request) -> i32 {
    let env = Env::current();
    match &request {
        Request::Show => return show(global),
        Request::MacosDynamic { name: None, .. } => return list_dynamic(global, &env),
        _ => {}
    }
    let plan = match plan(&request, &env).and_then(|plan| validate(&plan.edits).map(|()| plan)) {
        Ok(plan) => plan,
        Err(message) => return fail(global, "validation.invalid", message),
    };
    let edits = Value::Array(plan.edits.iter().map(Edit::to_json).collect());
    let mut command: Vec<String> = prefix.to_vec();
    command.push("--quiet".into());
    command.extend(["settings".into(), "edit".into(), edits.to_string()]);
    let code = super::run(&command, "");
    if code != 0 {
        let block = raw_block(&plan.edits);
        if !is_json(global) && block.as_object().is_some_and(|b| !b.is_empty()) {
            eprintln!(
                "To set it by hand, put these keys in {}:\n{}",
                cmux_config::config_path().display(),
                serde_json::to_string_pretty(&block).unwrap_or_default()
            );
        }
        return code;
    }
    if is_json(global) {
        let set: Map<String, Value> = plan
            .edits
            .iter()
            .map(|edit| match edit {
                Edit::Set(key, value) => ((*key).to_string(), value.clone()),
                Edit::Reset(key) | Edit::ResetUnchanged(key, _) => {
                    ((*key).to_string(), Value::Null)
                }
            })
            .collect();
        return super::wire::print_local_success(
            &json!({ "mode": plan.mode, "set": set, "summary": plan.summary }),
            global.output,
        );
    }
    println!("{}", plan.summary);
    0
}

fn list_dynamic(global: &GlobalArgs, env: &Env) -> i32 {
    let pictures: Vec<SystemPicture> =
        system_pictures(&env.pictures).into_iter().filter(|p| p.dynamic.is_some()).collect();
    if is_json(global) {
        let items: Vec<Value> = pictures
            .iter()
            .map(|p| json!({ "name": p.name, "path": p.path, "follows": p.dynamic }))
            .collect();
        return super::wire::print_local_success(
            &json!({ "folder": env.pictures, "wallpapers": items }),
            global.output,
        );
    }
    if pictures.is_empty() {
        println!("no dynamic macOS wallpapers in {}", env.pictures.display());
        return 0;
    }
    println!("Dynamic macOS wallpapers (cmux wallpaper use-macos-dynamic NAME):");
    let width = pictures.iter().map(|p| p.name.len()).max().unwrap_or(0);
    for picture in &pictures {
        println!("  {:width$}  {}", picture.name, picture.dynamic.unwrap_or_default());
    }
    0
}

/// The configured keys, read as the settings owner reads the file (an
/// unset key is its default; a key this build lacks is null).
fn configured() -> Map<String, Value> {
    let path = cmux_config::config_path();
    let file = match std::fs::read_to_string(&path) {
        Ok(text) => FileRead::Text(text),
        Err(_) => FileRead::Text("{}".to_string()),
    };
    let state = State::new(
        Schema::embedded(),
        file,
        Default::default(),
        Default::default(),
        Default::default(),
        0,
    );
    KEYS.iter()
        .map(|key| {
            let view = state.get(&Target::Key((*key).to_string()));
            let value = view.row.and_then(|row| row.value).unwrap_or(Value::Null);
            ((*key).to_string(), value)
        })
        .collect()
}

/// The keys `mode` reads, for the human `show`.
fn mode_keys(mode: &str) -> &'static [&'static str] {
    match mode {
        "appearance" => &[BACKGROUND, LIGHT, DARK],
        "schedule" => &[BACKGROUND, SCHEDULE, LOCATION],
        "dynamic" => &[BACKGROUND, DYNAMIC, LOCATION],
        "rotate" => &[BACKGROUND, ROTATION],
        "picture" => &[BACKGROUND, DYNAMIC],
        _ => &[BACKGROUND],
    }
}

/// What the running app shows: `{running, picture?, next_change?}`.
fn app_now(global: &GlobalArgs) -> Value {
    let Ok(mut stream) = super::app::connect_command(global) else {
        return json!({ "running": false });
    };
    let reply = super::app::request(&mut stream, "debug.themes", json!({}), Duration::from_secs(2));
    let backdrop = match &reply {
        Ok(Ok(report)) => report.pointer("/windows/0/backdrop").cloned(),
        _ => None,
    };
    let field =
        |name: &str| backdrop.as_ref().and_then(|b| b.get(name)).filter(|v| v.is_string()).cloned();
    json!({
        "running": true,
        "picture": field("picture").unwrap_or(Value::Null),
        "next_change": field("next_change").unwrap_or(Value::Null),
    })
}

fn show(global: &GlobalArgs) -> i32 {
    let settings = configured();
    let background = settings.get(BACKGROUND).and_then(Value::as_str).unwrap_or("none");
    let mode = mode_of(background, settings.get(DYNAMIC).and_then(Value::as_str));
    let now = app_now(global);
    let file = cmux_config::config_path();
    if is_json(global) {
        return super::wire::print_local_success(
            &json!({ "mode": mode, "settings": settings, "app": now, "file": file }),
            global.output,
        );
    }
    println!("mode: {}", mode_words(mode));
    for key in mode_keys(mode) {
        let value = settings.get(*key).cloned().unwrap_or(Value::Null);
        let shown = if value.is_null() { "(unset)".to_string() } else { value.to_string() };
        println!("  {key} = {shown}");
    }
    let line = match (
        now.get("running").and_then(Value::as_bool),
        now.get("picture").and_then(Value::as_str),
    ) {
        (Some(false), _) => "now: cmux is not running".to_string(),
        (_, Some(picture)) => match now.get("next_change").and_then(Value::as_str) {
            Some(next) => format!("now: {picture} (next change {next})"),
            None => format!("now: {picture}"),
        },
        _ => "now: the running cmux does not report its picture".to_string(),
    };
    println!("{line}");
    println!("file: {}", file.display());
    0
}

#[cfg(test)]
mod tests;
