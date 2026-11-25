//! YouTube wallpapers: the `youtube:` background id every part shares
//! (the video wallpapers contract), and turning whatever a person pastes
//! into it.
//!
//! ```text
//! youtube:<VIDEO_ID>[?start=<S>][&end=<E>][&quality=<Q>]
//! ```
//!
//! - `VIDEO_ID`: exactly 11 characters of `[A-Za-z0-9_-]`.
//! - `start`, `end`: whole seconds, `0 <= start < end <= 86400`; no `end`
//!   plays to the end of the video.
//! - `quality`: the player height in pixels, one of [`QUALITIES`]; omitted is
//!   [`DEFAULT_QUALITY`].
//! - Canonical: `start`, `end`, `quality` in that order, each left out when it
//!   is its default. No `|` ever appears, so a light/dark pair keeps working.
//!
//! [`YouTubeWallpaper::from_input`] reads a pasted address (`watch?v=`,
//! `youtu.be/`, `shorts/`, `embed/`, `live/`, `m.`, `music.`, `www.`,
//! `youtube-nocookie.com`, a start from `t=` or `start=` and an end from
//! `end=`, as `90`, `90s`, `1m30s`, `1h2m3s` or `1:30`) or a `youtube:` id in
//! any order; a playlist alone, a channel and any other site are refused with
//! what to paste instead. The app parses only the canonical id.

use std::fmt;

/// The prefix of a YouTube background id.
pub const PREFIX: &str = "youtube:";
/// The player heights a wallpaper may ask for.
pub const QUALITIES: [u32; 6] = [360, 480, 720, 1080, 1440, 2160];
/// The player height when the id names none.
pub const DEFAULT_QUALITY: u32 = 1080;
/// The latest `end` (and the bound on `start`): one day, in seconds.
pub const MAX_SECONDS: u32 = 86_400;
/// The length of a video id.
const VIDEO_ID_LEN: usize = 11;

/// JSON Schema pattern of a canonical `youtube:` id: an 11-character video id,
/// then optionally `start` (not 0), `end` and `quality` (not 1080) in that order.
/// [`is_canonical_id`] also checks the numbers' range and that `start < end`.
pub const ID_PATTERN: &str = "^youtube:[A-Za-z0-9_-]{11}(\\?(start=[1-9][0-9]{0,4}(&end=[1-9][0-9]{0,4})?(&quality=(360|480|720|1440|2160))?|end=[1-9][0-9]{0,4}(&quality=(360|480|720|1440|2160))?|quality=(360|480|720|1440|2160)))?$";

/// One YouTube wallpaper: the video, where its loop starts and ends, and the
/// player height.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct YouTubeWallpaper {
    pub video: String,
    /// Seconds into the video; 0 is the start.
    pub start: u32,
    /// Seconds into the video; `None` plays to the end.
    pub end: Option<u32>,
    /// The player height in pixels, one of [`QUALITIES`].
    pub quality: u32,
}

/// Why a text is not a YouTube wallpaper. Each message says what to paste instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum YouTubeError {
    /// Not a `youtube:` id or an address of any site.
    NotYouTube,
    /// An address of another site.
    OtherSite(String),
    /// A playlist with no one video in it.
    Playlist,
    /// A channel or a person's page.
    Channel,
    /// A YouTube address that names no video (the home page, search, a feed).
    NoVideo,
    /// A video id that is not 11 characters of letters, digits, `-` and `_`.
    BadVideoId(String),
    /// A `start` or `end` that is not a time.
    BadTime { name: &'static str, value: String },
    /// A `start` or `end` past [`MAX_SECONDS`].
    TimeTooLate { name: &'static str, seconds: u64 },
    /// An `end` at or before the `start`.
    EndNotAfterStart { start: u32, end: u32 },
    /// A `quality` that is not one of [`QUALITIES`].
    BadQuality(String),
    /// A `youtube:` id with a parameter the id does not have.
    UnknownParameter(String),
}

impl fmt::Display for YouTubeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let qualities = QUALITIES.map(|q| q.to_string()).join(", ");
        match self {
            YouTubeError::NotYouTube => write!(
                f,
                "not a YouTube video: paste its address (https://www.youtube.com/watch?v=..., https://youtu.be/...) or youtube:<video id>"
            ),
            YouTubeError::OtherSite(host) => write!(
                f,
                "{host} is not YouTube: a video background plays a YouTube address or a video file on this Mac"
            ),
            YouTubeError::Playlist => write!(
                f,
                "that is a playlist: open one of its videos and paste that video's address"
            ),
            YouTubeError::Channel => write!(
                f,
                "that is a channel: open one of its videos and paste that video's address"
            ),
            YouTubeError::NoVideo => write!(
                f,
                "that YouTube address names no video: paste a video's address (watch?v=..., youtu.be/..., shorts/...)"
            ),
            YouTubeError::BadVideoId(id) => write!(
                f,
                "{id:?} is not a YouTube video id: an id is 11 letters, digits, - or _ (the part after watch?v=)"
            ),
            YouTubeError::BadTime { name, value } => write!(
                f,
                "{name} {value:?} is not a time: write seconds (90), 90s, 1m30s, 1h2m3s or 1:30"
            ),
            YouTubeError::TimeTooLate { name, seconds } => write!(
                f,
                "{name} {seconds}s is past the longest a video background loops ({MAX_SECONDS}s, one day)"
            ),
            YouTubeError::EndNotAfterStart { start, end } => {
                write!(f, "the end ({end}s) must come after the start ({start}s)")
            }
            YouTubeError::BadQuality(value) => {
                write!(
                    f,
                    "quality {value:?} is not one of {qualities} (the player height in pixels)"
                )
            }
            YouTubeError::UnknownParameter(name) => {
                write!(f, "a youtube: id takes start, end and quality, not {name:?}")
            }
        }
    }
}

impl std::error::Error for YouTubeError {}

impl YouTubeWallpaper {
    /// A wallpaper of the whole video at the default quality.
    pub fn new(video: &str) -> Result<YouTubeWallpaper, YouTubeError> {
        check_video_id(video)?;
        Ok(YouTubeWallpaper {
            video: video.to_owned(),
            start: 0,
            end: None,
            quality: DEFAULT_QUALITY,
        })
    }

    /// The canonical id: `youtube:<VIDEO_ID>` and the parameters that are not
    /// their default, in the order start, end, quality.
    pub fn id(&self) -> String {
        let mut params = Vec::new();
        if self.start != 0 {
            params.push(format!("start={}", self.start));
        }
        if let Some(end) = self.end {
            params.push(format!("end={end}"));
        }
        if self.quality != DEFAULT_QUALITY {
            params.push(format!("quality={}", self.quality));
        }
        if params.is_empty() {
            format!("{PREFIX}{}", self.video)
        } else {
            format!("{PREFIX}{}?{}", self.video, params.join("&"))
        }
    }

    /// `Ok` when the times and quality are in range: `start < end <= 86400`,
    /// `start < 86400`, and a listed quality.
    pub fn check(&self) -> Result<(), YouTubeError> {
        check_video_id(&self.video)?;
        if self.start >= MAX_SECONDS {
            return Err(YouTubeError::TimeTooLate { name: "start", seconds: self.start.into() });
        }
        if let Some(end) = self.end {
            if end > MAX_SECONDS {
                return Err(YouTubeError::TimeTooLate { name: "end", seconds: end.into() });
            }
            if end <= self.start {
                return Err(YouTubeError::EndNotAfterStart { start: self.start, end });
            }
        }
        if !QUALITIES.contains(&self.quality) {
            return Err(YouTubeError::BadQuality(self.quality.to_string()));
        }
        Ok(())
    }

    /// A `youtube:` id (the prefix in any case), its parameters in any order,
    /// times in any form [`parse_time`] reads and quality as `720` or `720p`.
    pub fn parse_id(text: &str) -> Result<YouTubeWallpaper, YouTubeError> {
        let text = text.trim();
        let rest = strip_prefix_ignore_case(text, PREFIX).ok_or(YouTubeError::NotYouTube)?;
        let (video, query) = rest.split_once('?').unwrap_or((rest, ""));
        let mut wallpaper = YouTubeWallpaper::new(video)?;
        for pair in query.split('&').filter(|pair| !pair.is_empty()) {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            match name {
                "start" | "t" => wallpaper.start = parse_time("start", value)?,
                "end" => wallpaper.end = Some(parse_time("end", value)?),
                "quality" => wallpaper.quality = parse_quality(value)?,
                other => return Err(YouTubeError::UnknownParameter(other.to_owned())),
            }
        }
        wallpaper.check()?;
        Ok(wallpaper)
    }

    /// What a person pastes: a `youtube:` id or a YouTube video address. A
    /// bare video id is not read here (an 11-letter word may be a painting or
    /// a file); [`YouTubeWallpaper::from_input_or_video_id`] reads one too.
    pub fn from_input(text: &str) -> Result<YouTubeWallpaper, YouTubeError> {
        let text = text.trim();
        if strip_prefix_ignore_case(text, PREFIX).is_some() {
            return YouTubeWallpaper::parse_id(text);
        }
        from_address(text)
    }

    /// [`YouTubeWallpaper::from_input`], or a bare video id ([`looks_like_video_id`]).
    pub fn from_input_or_video_id(text: &str) -> Result<YouTubeWallpaper, YouTubeError> {
        let text = text.trim();
        if looks_like_video_id(text) {
            return YouTubeWallpaper::new(text);
        }
        YouTubeWallpaper::from_input(text)
    }
}

/// Whether `text` is a canonical `youtube:` id, exactly as [`YouTubeWallpaper::id`]
/// writes it (what the app parses and the settings file stores).
pub fn is_canonical_id(text: &str) -> bool {
    text.starts_with(PREFIX)
        && YouTubeWallpaper::parse_id(text).is_ok_and(|wallpaper| wallpaper.id() == text)
}

/// Whether `text` claims to be a YouTube wallpaper: a `youtube:` id or an
/// address of a YouTube site, valid or not. A settings write normalizes these
/// (and refuses the invalid ones with the row's own refusal); anything else
/// it leaves alone.
pub fn claims_youtube(text: &str) -> bool {
    let text = text.trim();
    strip_prefix_ignore_case(text, PREFIX).is_some()
        || split_address(text).is_some_and(|address| site(&address.host).is_some())
}

/// The canonical id for a pasted text that claims YouTube ([`claims_youtube`])
/// and reads as a wallpaper; `None` for anything else.
pub fn normalize(text: &str) -> Option<String> {
    if !claims_youtube(text) {
        return None;
    }
    YouTubeWallpaper::from_input(text).ok().map(|wallpaper| wallpaper.id())
}

/// Whether `text` is 11 characters of `[A-Za-z0-9_-]`.
pub fn is_video_id(text: &str) -> bool {
    text.len() == VIDEO_ID_LEN
        && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// Whether a bare word reads as a video id: [`is_video_id`] with at least
/// one capital or digit, as nearly every real id has, so an 11-letter word
/// such as `not-a-thing` or `sunset-glow` is never taken for a video.
pub fn looks_like_video_id(text: &str) -> bool {
    is_video_id(text) && text.bytes().any(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

fn check_video_id(text: &str) -> Result<(), YouTubeError> {
    if is_video_id(text) { Ok(()) } else { Err(YouTubeError::BadVideoId(text.to_owned())) }
}

/// A time in whole seconds: `90`, `90s`, `1m30s`, `1h2m3s` (each unit at most
/// once, in that order), or `1:30` / `1:02:03`. At most [`MAX_SECONDS`].
/// `name` (`start` or `end`) names the time in a refusal.
pub fn parse_time(name: &'static str, text: &str) -> Result<u32, YouTubeError> {
    let bad = || YouTubeError::BadTime { name, value: text.to_owned() };
    let lower = text.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return Err(bad());
    }
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    let number = |part: &str| -> Result<u64, YouTubeError> {
        if !digits(part) {
            return Err(bad());
        }
        // More digits than any time can have is still a time, just too late.
        Ok(part.parse::<u64>().unwrap_or(u64::MAX))
    };
    let seconds: u64 = if lower.contains(':') {
        let parts: Vec<&str> = lower.split(':').collect();
        let (hours, minutes, seconds) = match parts.as_slice() {
            [m, s] => ("0", *m, *s),
            [h, m, s] => (*h, *m, *s),
            _ => return Err(bad()),
        };
        // `1:30` and `1:02:03`: the parts after the first are two digits under 60.
        let tail = |part: &str| part.len() == 2 && number(part).is_ok_and(|n| n < 60);
        if !tail(seconds) || (parts.len() == 3 && !tail(minutes)) {
            return Err(bad());
        }
        number(hours)?
            .saturating_mul(3600)
            .saturating_add(number(minutes)?.saturating_mul(60))
            .saturating_add(number(seconds)?)
    } else if digits(&lower) {
        number(&lower)?
    } else {
        let mut total: u64 = 0;
        let mut rest = lower.as_str();
        let mut units = ['h', 'm', 's'].into_iter();
        while !rest.is_empty() {
            let split = rest.find(|c: char| !c.is_ascii_digit()).ok_or_else(bad)?;
            let (count, tail) = rest.split_at(split);
            let unit = tail.chars().next().ok_or_else(bad)?;
            // Each unit once, largest first: `1h2m3s`, never `3s2m` or `1m1m`.
            if !units.by_ref().any(|wanted| wanted == unit) {
                return Err(bad());
            }
            let scale = match unit {
                'h' => 3600,
                'm' => 60,
                _ => 1,
            };
            total = total.saturating_add(number(count)?.saturating_mul(scale));
            rest = tail.get(unit.len_utf8()..).ok_or_else(bad)?;
        }
        total
    };
    if seconds > u64::from(MAX_SECONDS) {
        return Err(YouTubeError::TimeTooLate { name, seconds });
    }
    Ok(seconds as u32)
}

/// A quality: one of [`QUALITIES`], as `720` or `720p`.
pub fn parse_quality(text: &str) -> Result<u32, YouTubeError> {
    let trimmed = text.trim();
    let number = trimmed.strip_suffix(['p', 'P']).unwrap_or(trimmed);
    number
        .parse::<u32>()
        .ok()
        .filter(|quality| QUALITIES.contains(quality) && number.bytes().all(|b| b.is_ascii_digit()))
        .ok_or_else(|| YouTubeError::BadQuality(text.to_owned()))
}

fn strip_prefix_ignore_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let head = text.get(..prefix.len())?;
    if !head.eq_ignore_ascii_case(prefix) {
        return None;
    }
    text.get(prefix.len()..)
}

/// The YouTube sites.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Site {
    /// youtube.com and its subdomains (www., m., music.), youtube-nocookie.com.
    YouTube,
    /// youtu.be, whose path is the video id.
    Short,
}

fn site(host: &str) -> Option<Site> {
    let under = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
    if under("youtube.com") || under("youtube-nocookie.com") {
        Some(Site::YouTube)
    } else if under("youtu.be") {
        Some(Site::Short)
    } else {
        None
    }
}

/// An address split into its lowercased host (no port, no user), path, query
/// and fragment.
struct Address<'a> {
    host: String,
    path: &'a str,
    query: &'a str,
    fragment: &'a str,
}

/// `text` as an address: `http://` or `https://` (any case) or `//` then a
/// host, or a bare host that has a dot before its first `/`, `?` or `#`
/// (`youtu.be/ID`). `None` for anything else (a path, another scheme).
fn split_address(text: &str) -> Option<Address<'_>> {
    let rest = strip_prefix_ignore_case(text, "https://")
        .or_else(|| strip_prefix_ignore_case(text, "http://"))
        .or_else(|| text.strip_prefix("//"));
    let schemed = rest.is_some();
    let rest = rest.unwrap_or(text);
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    if !schemed && (!authority.contains('.') || authority.contains(':') || authority.contains('@'))
    {
        // `C:\x`, `user@host:path` and `file:/x` are not a bare host.
        return None;
    }
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host).trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() || host.contains(char::is_whitespace) {
        return None;
    }
    let (tail, fragment) = tail.split_once('#').unwrap_or((tail, ""));
    let (path, query) = tail.split_once('?').unwrap_or((tail, ""));
    Some(Address { host, path, query, fragment })
}

/// The value of `name` in `query` (`a=1&b=2`), the last one when it repeats.
fn param<'a>(query: &'a str, name: &str) -> Option<&'a str> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('=').or(Some((pair, ""))))
        .filter(|(key, _)| *key == name)
        .map(|(_, value)| value)
        .next_back()
}

fn from_address(text: &str) -> Result<YouTubeWallpaper, YouTubeError> {
    let address = split_address(text).ok_or(YouTubeError::NotYouTube)?;
    let site = site(&address.host).ok_or_else(|| YouTubeError::OtherSite(address.host.clone()))?;
    let segments: Vec<&str> = address.path.split('/').filter(|part| !part.is_empty()).collect();
    let playlist = param(address.query, "list").is_some_and(|list| !list.is_empty());
    let video = match (site, segments.as_slice()) {
        (Site::Short, [id, ..]) => *id,
        (Site::Short, []) => return Err(YouTubeError::NoVideo),
        (Site::YouTube, ["watch", ..]) => match param(address.query, "v") {
            Some(id) if !id.is_empty() => id,
            _ if playlist => return Err(YouTubeError::Playlist),
            _ => return Err(YouTubeError::NoVideo),
        },
        (Site::YouTube, ["playlist", ..]) | (Site::YouTube, ["embed", "videoseries", ..]) => {
            return Err(YouTubeError::Playlist);
        }
        (Site::YouTube, ["shorts" | "embed" | "live" | "v" | "e", id, ..]) => *id,
        (Site::YouTube, [first, ..])
            if first.starts_with('@') || matches!(*first, "channel" | "c" | "user") =>
        {
            return Err(YouTubeError::Channel);
        }
        (Site::YouTube, _) if playlist => return Err(YouTubeError::Playlist),
        (Site::YouTube, _) => return Err(YouTubeError::NoVideo),
    };
    let mut wallpaper = YouTubeWallpaper::new(video)?;
    // `t=` in the fragment (`#t=90`) is an older share form; the query wins.
    let start = param(address.query, "start")
        .or_else(|| param(address.query, "t"))
        .or_else(|| param(address.fragment, "t"));
    if let Some(start) = start {
        wallpaper.start = parse_time("start", start)?;
    }
    if let Some(end) = param(address.query, "end") {
        wallpaper.end = Some(parse_time("end", end)?);
    }
    wallpaper.check()?;
    Ok(wallpaper)
}

#[cfg(test)]
mod tests;
