//! `cmux video open SRC [SRC2]`: watch a video, or two side by side (before and after), in a
//! cmux WebKit tab with a viewer (Leo 2026-11-22: "is there a way we can just watch the .mp4s
//! in the app? i want that. in-app video player.").
//!
//! The tab is WebKit: the app's Chromium build decodes no H.264, HEVC or AAC, which is why the
//! app already sends mp4, mov and m4v to WebKit (CmuxNextBrowserCore LocalFileHandoff.swift).
//! A tab sent straight to a GitHub media URL downloads it instead (GitHub serves it as
//! `application/octet-stream` with `nosniff`), and a WebKit `file://` page reads only its own
//! folder (WebKitTab+Navigations.swift `allowingReadAccessTo`). So the viewer page and the
//! media sit in one cache folder, named by a hash of the sources:
//! `<cache>/cmux/video-view/<32 hex>/{index.html, a.mp4, b.mp4}`. A local file is copied there
//! (a clone on APFS, so constant cost), an https URL downloaded once; the same sources open the
//! same folder again. Past [`KEEP_FOLDERS`] folders or [`KEEP_BYTES`] the oldest go.
//!
//! The tab itself is `cmux browser open FILE_URL --engine webkit`: the same request, the same
//! placement beside the caller (beside.rs) and the same app path (frontend_browser.rs).

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::command::{CommandPlan, ParsedCommand};
use super::{GlobalArgs, OutputMode};

const PAGE: &str = include_str!("video_view.html");
const EXTENSIONS: &[&str] = &["mp4", "m4v", "mov", "webm"];
const RATES: &[(&str, f64)] =
    &[("0.5", 0.5), (".5", 0.5), ("1", 1.0), ("1.0", 1.0), ("2", 2.0), ("2.0", 2.0)];
const MAX_DOWNLOAD: u64 = 200 * 1024 * 1024;
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(120);
pub(super) const KEEP_FOLDERS: usize = 20;
pub(super) const KEEP_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// The parent selectors `browser open` takes, passed on as they are.
const PLACES: &[&str] = &["workspace", "screen", "pane"];

pub(super) const USAGE: &str = "\
usage: cmux video open <src> [<src2>] [--loop] [--rate 0.5|1|2] [--name <tab name>]
                       [--workspace <ws>] [--screen <screen>] [--pane <pane>]

Opens a video in a cmux browser tab (WebKit) with a viewer: play and pause, a scrub bar,
speed, frame steps and loop. Two sources play side by side (or stacked) in lockstep,
labelled Before and After when their names say so, else by file name.

  <src>        An https:// URL, a local path or a file:// URL (.mp4, .m4v, .mov, .webm).
               A URL is downloaded once (up to 200 MiB) into cmux's cache.
  --loop       Start with loop on.
  --rate R     Start at 0.5x, 1x or 2x.
  --name N     The tab's name (default: the file names).
  --workspace, --screen, --pane
               Where the tab goes, as for `cmux browser open`; by default, the column
               beside the caller.

Keys: Space or K play/pause, , and . step a frame, [ and ] speed, L loop,
Left and Right 5 s, Home and End.
";

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Source {
    Web(String),
    Local(PathBuf),
}

impl Source {
    /// The name a person knows it by: the file name (a URL's last path segment, decoded).
    pub(super) fn name(&self) -> String {
        match self {
            Self::Local(path) => path
                .file_name()
                .map_or_else(|| path.display().to_string(), |name| name.to_string_lossy().into()),
            Self::Web(url) => url::Url::parse(url)
                .ok()
                .and_then(|url| url.path_segments()?.next_back().map(percent_decode))
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| url.clone()),
        }
    }

    pub(super) fn extension(&self) -> String {
        Path::new(&self.name())
            .extension()
            .map(|extension| extension.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default()
    }
}

#[derive(Debug, PartialEq)]
pub(super) struct Open {
    pub sources: Vec<Source>,
    pub looping: bool,
    pub rate: f64,
    pub name: Option<String>,
    /// `(selector, value)` for `--workspace`, `--screen`, `--pane`.
    pub place: Vec<(String, String)>,
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (scope, rest) = words.split_first()?;
    if scope != "video" {
        return None;
    }
    let asks_help = rest.iter().any(|word| matches!(word.as_str(), "-h" | "--help"));
    let Some((verb, after)) = rest.split_first().filter(|(verb, _)| *verb != "help" && !asks_help)
    else {
        print!("{USAGE}");
        return Some(0);
    };
    if verb != "open" {
        let message = format!("unknown video verb `{verb}`; run `cmux video --help`");
        return Some(failure(&global, "usage.invalid", &message, 2));
    }
    if global.machine.is_some() {
        let message = "--machine: a video opens on this machine (its cache folder is here)";
        return Some(failure(&global, "usage.invalid", message, 2));
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let open = match parse_open(after, &cwd) {
        Ok(open) => open,
        Err(message) => return Some(failure(&global, "usage.invalid", &message, 2)),
    };
    let Some(root) = cache_root() else {
        return Some(failure(&global, "video.unavailable", "no cache folder (HOME is not set)", 1));
    };
    let prepared = match prepare(&open, &root, &mut download) {
        Ok(prepared) => prepared,
        Err(message) => return Some(failure(&global, "video.unavailable", &message, 1)),
    };
    if matches!(global.output, OutputMode::Human) {
        for (name, bytes) in &prepared.downloaded {
            eprintln!("cmux video: downloaded {name} ({:.1} MB)", *bytes as f64 / 1e6);
        }
    }
    let Ok(url) = url::Url::from_file_path(&prepared.index) else {
        let message = format!("{} is not an absolute path", prepared.index.display());
        return Some(failure(&global, "video.unavailable", &message, 1));
    };
    let words = browser_words(&open, url.as_str());
    Some(match super::parse_command(global.clone(), words, super::Surface::current()) {
        Ok(ParsedCommand::Command { global, plan: CommandPlan::Protocol(request) }) => {
            super::wire::run(global, *request)
        }
        Ok(_) => failure(&global, "usage.invalid", "browser open made no tab request", 2),
        Err(error) => failure(&global, "usage.invalid", &error.0, 2),
    })
}

fn failure(global: &GlobalArgs, code: &str, message: &str, exit: i32) -> i32 {
    let message = match global.output {
        OutputMode::Quiet | OutputMode::Human => format!("cmux video: {message}"),
        _ => message.to_owned(),
    };
    super::wire::print_local_error(
        &json!({"code": code, "message": message, "details": {}, "retryable": false}),
        global.output,
        exit,
    )
}

/// `video open`'s words after `open`. Local paths resolve against `cwd`; whether they exist is
/// checked when the folder is made.
pub(super) fn parse_open(args: &[String], cwd: &Path) -> Result<Open, String> {
    let mut open =
        Open { sources: Vec::new(), looping: false, rate: 1.0, name: None, place: Vec::new() };
    let mut index = 0;
    let mut literal = false;
    while let Some(arg) = args.get(index) {
        index += 1;
        if literal || !arg.starts_with("--") {
            open.sources.push(parse_source(arg, cwd)?);
            continue;
        }
        if arg == "--" {
            literal = true;
            continue;
        }
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (arg.as_str(), None),
        };
        let mut value = || -> Result<String, String> {
            let value = match inline.clone() {
                Some(value) => value,
                None => {
                    index += 1;
                    args.get(index - 1).cloned().ok_or_else(|| format!("{flag} needs a value"))?
                }
            };
            if value.is_empty() { Err(format!("{flag} needs a value")) } else { Ok(value) }
        };
        match flag {
            "--loop" if inline.is_none() => open.looping = true,
            "--rate" => open.rate = parse_rate(&value()?)?,
            "--name" => open.name = Some(value()?),
            "--engine" => return Err("a video always opens in WebKit; drop --engine".into()),
            _ if PLACES.contains(&flag.strip_prefix("--").unwrap_or(flag)) => {
                let selector = flag.strip_prefix("--").unwrap_or(flag).to_owned();
                if open.place.iter().any(|(known, _)| *known == selector) {
                    return Err(format!("{flag} given twice"));
                }
                open.place.push((selector, value()?));
            }
            _ => return Err(format!("unknown option {flag}; run `cmux video --help`")),
        }
    }
    match open.sources.len() {
        0 => Err("video open needs a source: an https:// URL or a local file".into()),
        1 | 2 => Ok(open),
        _ => Err("video open shows one or two sources".into()),
    }
}

fn parse_rate(value: &str) -> Result<f64, String> {
    let bare = value.strip_suffix(['x', 'X']).unwrap_or(value);
    RATES
        .iter()
        .find(|(word, _)| *word == bare)
        .map(|(_, rate)| *rate)
        .ok_or_else(|| format!("--rate must be 0.5, 1 or 2 (not {value})"))
}

pub(super) fn parse_source(word: &str, cwd: &Path) -> Result<Source, String> {
    let source = if let Some((scheme, _)) = word.split_once("://") {
        let url = url::Url::parse(word).map_err(|error| format!("{word}: {error}"))?;
        match scheme.to_ascii_lowercase().as_str() {
            "https" => {
                if !url.username().is_empty() || url.password().is_some() {
                    return Err("a video URL carries no credentials (user:password@)".into());
                }
                if url.host_str().is_none_or(str::is_empty) {
                    return Err(format!("{word}: no host"));
                }
                Source::Web(url.to_string())
            }
            "file" => Source::Local(
                url.to_file_path().map_err(|()| format!("{word}: not a local file URL"))?,
            ),
            _ => {
                return Err(format!(
                    "{scheme}:// is not supported: give an https:// URL, a local path or a file:// URL"
                ));
            }
        }
    } else if word.is_empty() {
        return Err("a source cannot be empty".into());
    } else {
        let path = PathBuf::from(word);
        Source::Local(if path.is_absolute() { path } else { cwd.join(path) })
    };
    let extension = source.extension();
    if !EXTENSIONS.contains(&extension.as_str()) {
        return Err(format!(
            "{}: not a video cmux plays (.mp4, .m4v, .mov or .webm)",
            source.name()
        ));
    }
    Ok(source)
}

/// What identifies a source's bytes: a URL, or a file's path, size and change time (so an
/// edited file gets a fresh copy).
fn identity(source: &Source) -> Result<String, String> {
    match source {
        Source::Web(url) => Ok(format!("url:{url}")),
        Source::Local(path) => {
            let metadata =
                std::fs::metadata(path).map_err(|error| format!("{}: {error}", path.display()))?;
            if !metadata.is_file() {
                return Err(format!("{}: not a file", path.display()));
            }
            let path = path.canonicalize().unwrap_or_else(|_| path.clone());
            let modified = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |time| time.as_nanos());
            Ok(format!("file:{}:{}:{modified}", path.display(), metadata.len()))
        }
    }
}

/// The cache folder's name for these sources' identities: 32 hex characters.
pub(super) fn folder_name(identities: &[String]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"cmux-video-view-v1\0");
    for identity in identities {
        hash.update(identity.as_bytes());
        hash.update(b"\0");
    }
    hash.finalize().iter().take(16).map(|byte| format!("{byte:02x}")).collect()
}

fn is_folder_name(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The media file's name in the folder: `a.mp4`, `b.webm`.
pub(super) fn media_name(index: usize, source: &Source) -> String {
    format!("{}.{}", if index == 0 { "a" } else { "b" }, source.extension())
}

/// The clips' labels: Before and After when the names say so, else the names.
pub(super) fn labels(names: &[String]) -> Vec<String> {
    let says = |name: &str, word: &str| name.to_ascii_lowercase().contains(word);
    match names {
        [first, second] if says(first, "before") && says(second, "after") => {
            vec!["Before".into(), "After".into()]
        }
        [first, second] if says(first, "after") && says(second, "before") => {
            vec!["After".into(), "Before".into()]
        }
        _ => names.to_vec(),
    }
}

pub(super) fn tab_name(open: &Open) -> String {
    if let Some(name) = &open.name {
        return name.clone();
    }
    let names: Vec<String> = open.sources.iter().map(Source::name).collect();
    names.join(" vs ")
}

/// The viewer page with the sources baked in. The configuration is JSON in a
/// `<script type="application/json">`, with `<`, `>` and `&` escaped, so no name ends it.
pub(super) fn render(open: &Open) -> String {
    let names: Vec<String> = open.sources.iter().map(Source::name).collect();
    let labels = labels(&names);
    let sources: Vec<Value> = open
        .sources
        .iter()
        .enumerate()
        .zip(names.iter().zip(&labels))
        .map(|((index, source), (name, label))| {
            json!({"src": media_name(index, source), "name": name, "label": label})
        })
        .collect();
    let config = json!({"sources": sources, "loop": open.looping, "rate": open.rate});
    // The template is cut at its placeholders before anything is put in, so a title holding
    // `{{CONFIG}}` stays text. video_tests.rs checks the page has both, once, in this order.
    let Some((head, rest)) = PAGE.split_once("{{TITLE}}") else {
        return PAGE.to_owned();
    };
    let Some((middle, tail)) = rest.split_once("{{CONFIG}}") else {
        return PAGE.to_owned();
    };
    let mut page = String::with_capacity(PAGE.len() + 512);
    page.push_str(head);
    page.push_str(&html_escape(&tab_name(open)));
    page.push_str(middle);
    page.push_str(&script_json(&config));
    page.push_str(tail);
    page
}

fn html_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            other => out.push(other),
        }
    }
    out
}

/// JSON safe inside a `<script>`: the characters that could close it or start a comment are
/// `\u` escapes (only strings hold them, and there the escape is the same text).
pub(super) fn script_json(value: &Value) -> String {
    let mut out = String::new();
    for character in value.to_string().chars() {
        match character {
            '<' => out.push_str("\\u003c"),
            '>' => out.push_str("\\u003e"),
            '&' => out.push_str("\\u0026"),
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            other => out.push(other),
        }
    }
    out
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let hex = |at: usize| bytes.get(at).and_then(|byte| (*byte as char).to_digit(16));
        if byte == b'%'
            && let (Some(high), Some(low)) = (hex(index + 1), hex(index + 2))
        {
            out.push((high * 16 + low) as u8);
            index += 3;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The `browser open` words that make the tab.
pub(super) fn browser_words(open: &Open, url: &str) -> Vec<String> {
    let mut words: Vec<String> =
        ["browser", "open", url, "--engine", "webkit", "--name"].map(str::to_owned).into();
    words.push(tab_name(open));
    for (selector, value) in &open.place {
        words.push(format!("--{selector}"));
        words.push(value.clone());
    }
    words
}

/// `CMUX_VIDEO_VIEW_DIR`, else `~/Library/Caches/cmux/video-view` on macOS and
/// `$XDG_CACHE_HOME/cmux/video-view` (`~/.cache`) elsewhere.
fn cache_root() -> Option<PathBuf> {
    let env = |key: &str| std::env::var_os(key).filter(|value| !value.is_empty());
    if let Some(dir) = env("CMUX_VIDEO_VIEW_DIR") {
        return Some(PathBuf::from(dir));
    }
    let home = env("HOME").map(PathBuf::from);
    let cache = if cfg!(target_os = "macos") {
        home?.join("Library/Caches")
    } else {
        env("XDG_CACHE_HOME").map(PathBuf::from).or_else(|| home.map(|home| home.join(".cache")))?
    };
    Some(cache.join("cmux/video-view"))
}

#[derive(Debug)]
pub(super) struct Prepared {
    pub index: PathBuf,
    /// `(name, bytes)` for each source downloaded now.
    pub downloaded: Vec<(String, u64)>,
}

/// Makes (or reuses) the sources' folder under `root`: the media, then `index.html`, then
/// prunes the oldest folders. `fetch(url, destination)` downloads a URL and returns its size.
pub(super) fn prepare(
    open: &Open,
    root: &Path,
    fetch: &mut dyn FnMut(&str, &Path) -> Result<u64, String>,
) -> Result<Prepared, String> {
    let identities = open.sources.iter().map(identity).collect::<Result<Vec<_>, _>>()?;
    let name = folder_name(&identities);
    let folder = root.join(&name);
    std::fs::create_dir_all(&folder).map_err(|error| format!("{}: {error}", folder.display()))?;
    let mut downloaded = Vec::new();
    for (index, source) in open.sources.iter().enumerate() {
        let destination = folder.join(media_name(index, source));
        if destination.is_file() {
            continue;
        }
        let part = folder.join(format!("{}.part", media_name(index, source)));
        let result = match source {
            Source::Local(path) => std::fs::copy(path, &part)
                .map(|_| ())
                .map_err(|error| format!("{}: {error}", path.display())),
            Source::Web(url) => {
                fetch(url, &part).map(|bytes| downloaded.push((source.name(), bytes)))
            }
        };
        if let Err(error) = result
            .and_then(|()| std::fs::rename(&part, &destination).map_err(|error| error.to_string()))
        {
            let _ = std::fs::remove_file(&part);
            return Err(error);
        }
    }
    let index = folder.join("index.html");
    let temporary = folder.join("index.html.part");
    std::fs::write(&temporary, render(open))
        .and_then(|()| std::fs::rename(&temporary, &index))
        .map_err(|error| format!("{}: {error}", index.display()))?;
    prune(root, &name, KEEP_FOLDERS, KEEP_BYTES);
    Ok(Prepared { index, downloaded })
}

/// Removes the oldest viewer folders past `max_folders` or `max_bytes`, never `keep`. Only
/// folders this module names (32 hex characters) are touched.
pub(super) fn prune(root: &Path, keep: &str, max_folders: usize, max_bytes: u64) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    let mut folders: Vec<(std::time::SystemTime, u64, PathBuf, bool)> = entries
        .flatten()
        .filter(|entry| entry.file_name().to_str().is_some_and(is_folder_name))
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| {
            let modified = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            let size = std::fs::read_dir(entry.path())
                .map(|files| {
                    files
                        .flatten()
                        .filter_map(|file| file.metadata().ok())
                        .map(|m| m.len())
                        .sum::<u64>()
                })
                .unwrap_or(0);
            let kept = entry.file_name() == keep;
            (modified, size, entry.path(), kept)
        })
        .collect();
    // Newest first, the one just opened ahead of all.
    folders.sort_by(|a, b| b.3.cmp(&a.3).then(b.0.cmp(&a.0)));
    let (mut count, mut bytes) = (0usize, 0u64);
    for (_, size, path, kept) in folders {
        count += 1;
        bytes = bytes.saturating_add(size);
        if !kept && (count > max_folders || bytes > max_bytes) {
            let _ = std::fs::remove_dir_all(&path);
        }
    }
}

/// Downloads an https URL to `destination`: redirects only to https, at most
/// [`MAX_DOWNLOAD`] bytes, within [`DOWNLOAD_TIMEOUT`].
fn download(url: &str, destination: &Path) -> Result<u64, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?;
    runtime.block_on(download_async(url, destination))
}

async fn download_async(url: &str, destination: &Path) -> Result<u64, String> {
    let name = Source::Web(url.to_owned()).name();
    // The person named this URL (`cmux video open URL`); a redirect off it is still checked.
    cmux_egress::allow_named(url);
    let client = cmux_egress::client_builder("cmux_tui::cli::video")
        .timeout(DOWNLOAD_TIMEOUT)
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                attempt.error("too many redirects")
            } else if attempt.url().scheme() != "https" {
                attempt.error("a redirect left https")
            } else {
                attempt.follow()
            }
        }))
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| error.to_string())?;
    let failed = |error: reqwest::Error| format!("{name}: {error}");
    let mut response = client.get(url).send().await.map_err(failed)?;
    if !response.status().is_success() {
        return Err(format!("{name}: the server answered {}", response.status()));
    }
    let too_big = || format!("{name}: larger than {} MiB", MAX_DOWNLOAD / (1024 * 1024));
    if response.content_length().is_some_and(|length| length > MAX_DOWNLOAD) {
        return Err(too_big());
    }
    let html = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.trim_start().to_ascii_lowercase().starts_with("text/html"));
    if html {
        return Err(format!("{name}: the server sent a web page, not a video"));
    }
    let mut file = std::fs::File::create(destination)
        .map_err(|error| format!("{}: {error}", destination.display()))?;
    let mut total = 0u64;
    while let Some(chunk) = response.chunk().await.map_err(failed)? {
        total += chunk.len() as u64;
        if total > MAX_DOWNLOAD {
            return Err(too_big());
        }
        file.write_all(&chunk).map_err(|error| format!("{}: {error}", destination.display()))?;
    }
    Ok(total)
}

#[cfg(test)]
#[path = "video_tests.rs"]
mod tests;
