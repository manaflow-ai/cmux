//! `cmux window record` and `cmux pane record`: a clip of one of the app's own windows or panes,
//! recorded with no Screen Recording permission, so an agent on a Mac whose cmux has no grant (a
//! fleet Mac, a Mac nobody has clicked Allow on) can still record the change it made.
//!
//! The frames are the app's own `window.screenshot` / `pane.screenshot` (``AppWindowImage``: the
//! window server's image of the app's own windows plus each Chromium page's own image), asked
//! for at `--fps` over `--seconds` on several connections at once, since one capture waits for
//! its masks to settle (about 100 ms) and the next need not wait for it. The run is the same
//! action a script's `cmux window screenshot` is, so it has the same gate (the app's control
//! socket, which only this user's processes reach) and the same privacy: every browser page,
//! chat and Home view is grey, and the report names those areas.
//!
//! Frames are PNG files in a folder with `frames.json` (each frame's file and its time in ms
//! from the start). `--out FILE.mp4` encodes them with ffmpeg at their own times (variable frame
//! rate, so the clip plays in real time) when ffmpeg is installed, and deletes the frames; with no
//! ffmpeg the folder is the result.
//!
//! Leo, 2026-11-22: agents could not record a clip of cmux NEXT on fleet Macs ("the screen_capture
//! permission is not granted"; `screencapture -v` wrote nothing), which blocked every UI change's
//! recorded verification there.

use std::fmt::Write as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use super::super::OutputMode;
use super::{ActionName, AppCommand, GlobalArgs, Options, UsageError};

pub(super) const DEFAULT_SECONDS: u64 = 5;
pub(super) const MAX_SECONDS: u64 = 60;
pub(super) const DEFAULT_FPS: u64 = 30;
pub(super) const MAX_FPS: u64 = 60;
/// The most frames one recording takes: 30 s at 60 fps. A Retina window's PNG is a few MB.
pub(super) const MAX_FRAMES: u64 = 1800;
/// Captures in flight at once. One waits about 100 ms for its masks to settle and then a few tens
/// of ms to capture and encode; eight cover 60 fps with room, measured on a mini at 40 fps with six.
const CONNECTIONS: usize = 8;
/// One capture's own deadline. A frame that misses it is a failed frame, not a failed recording.
// timeout: a capture that misses it is one failed frame of the recording, counted in its report, never a failed recording.
const FRAME_TIMEOUT: Duration = Duration::from_secs(10);
/// The extensions `--out` encodes to a movie.
const MOVIE_EXTENSIONS: &[&str] = &["mp4", "mov", "m4v"];

/// Which of the app's surfaces a recording shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Noun {
    Window,
    Pane,
}

impl Noun {
    fn word(self) -> &'static str {
        match self {
            Noun::Window => "window",
            Noun::Pane => "pane",
        }
    }

    /// The app action each frame runs: the screenshot of the same surface.
    fn screenshot_action(self) -> &'static str {
        match self {
            Noun::Window => "window screenshot",
            Noun::Pane => "pane screenshot",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Request {
    pub noun: Noun,
    pub target: Option<String>,
    pub seconds: u64,
    pub fps: u64,
    /// `--out` as typed, made absolute against the caller's folder.
    pub out: Option<String>,
}

/// `rest` starts with `record`; `noun` is the word before it.
pub(super) fn parse(noun: Noun, rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control.record;
    let usage = || UsageError::new(messages.usage.replace("{noun}", noun.word()));
    if rest.first().map(String::as_str) != Some("record") {
        return Err(usage());
    }
    let words = rest.get(1..).unwrap_or_default();
    if words.iter().any(|word| word == "--help" || word == "-h") {
        return Err(usage());
    }
    let options = Options::parse(words, &["target", "seconds", "fps", "out"], &[])?;
    let number = |key: &str, default: u64, max: u64, message: &'static str| match options.value(key)
    {
        None => Ok(default),
        Some(value) => value
            .parse::<u64>()
            .ok()
            .filter(|number| (1..=max).contains(number))
            .ok_or_else(|| UsageError::new(message)),
    };
    let seconds = number("seconds", DEFAULT_SECONDS, MAX_SECONDS, messages.seconds)?;
    let fps = number("fps", DEFAULT_FPS, MAX_FPS, messages.fps)?;
    if seconds * fps > MAX_FRAMES {
        return Err(UsageError::new(
            messages.too_many_frames.replace("{max}", &MAX_FRAMES.to_string()),
        ));
    }
    let out = options
        .value("out")
        .filter(|out| !out.is_empty())
        .map(|out| super::caller_absolute(out).unwrap_or_else(|| expand_home(out)));
    let target = options.value("target").filter(|target| !target.is_empty()).map(str::to_owned);
    Ok(AppCommand::Record(Request { noun, target, seconds, fps, out }))
}

fn expand_home(path: &str) -> String {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => Path::new(&home).join(rest).to_string_lossy().into_owned(),
        _ => path.to_owned(),
    }
}

/// Where a recording goes: the folder its frames are written to and, for a movie, the file.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Destination {
    pub frames: PathBuf,
    pub movie: Option<PathBuf>,
}

/// `--out FILE.mp4` is a movie, its frames beside it in `FILE.mp4.frames/`; any other `--out` is
/// the frames' folder. No `--out` is a movie in `$TMPDIR/cmux-recordings/`.
pub(super) fn destination(out: Option<&str>, stamp: u128, temporary: &Path) -> Destination {
    match out {
        Some(out) if is_movie(out) => Destination {
            frames: PathBuf::from(format!("{out}.frames")),
            movie: Some(PathBuf::from(out)),
        },
        Some(out) => Destination { frames: PathBuf::from(out), movie: None },
        None => {
            let base = temporary.join("cmux-recordings").join(format!("record-{stamp}"));
            Destination {
                frames: base.with_extension("frames"),
                movie: Some(base.with_extension("mp4")),
            }
        }
    }
}

fn is_movie(path: &str) -> bool {
    Path::new(path).extension().and_then(|extension| extension.to_str()).is_some_and(|extension| {
        MOVIE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
    })
}

/// One capture's outcome.
#[derive(Clone, Debug)]
pub(super) struct Frame {
    pub index: u64,
    /// When it was asked for, ms from the recording's start.
    pub at_ms: u64,
    pub file: String,
    pub result: Result<Value, Value>,
}

/// Records, writes `frames.json`, encodes, and prints the report.
pub(super) fn run(global: &GlobalArgs, request: Request) -> i32 {
    let messages = &crate::localization::catalog().app_control.record;
    let stamp =
        SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_millis()).unwrap_or(0);
    let place = destination(request.out.as_deref(), stamp, &std::env::temp_dir());
    if let Err(error) = std::fs::create_dir_all(&place.frames) {
        let message = messages
            .cannot_write
            .replace("{path}", &place.frames.to_string_lossy())
            .replace("{error}", &error.to_string());
        return super::failure("record.write_failed", &message, global.output, 1);
    }
    // Every connection is opened before the clock starts, so the first frames are not late.
    let mut streams = Vec::new();
    for _ in 0..CONNECTIONS.min(request.fps as usize) {
        match super::connect_command(global) {
            Ok(stream) => streams.push(stream),
            Err(error) if streams.is_empty() => {
                return super::super::wire::print_local_error(&error, global.output, 3);
            }
            Err(_) => break,
        }
    }
    let started = Instant::now();
    let frames = capture(&request, &place.frames, streams, started);
    let elapsed = started.elapsed();
    let mut ok: Vec<&Frame> = frames.iter().filter(|frame| frame.result.is_ok()).collect();
    ok.sort_by_key(|frame| (frame.at_ms, frame.index));
    if ok.is_empty() {
        let _ = std::fs::remove_dir_all(&place.frames);
        let error =
            frames.iter().find_map(|frame| frame.result.as_ref().err().cloned()).unwrap_or_else(
                || json!({"code": "record.no_frames", "message": "no frame was asked for"}),
            );
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default().to_owned();
        let mut error = error;
        if let Some(object) = error.as_object_mut() {
            object.insert("message".into(), json!(messages.no_frames.replace("{error}", &message)));
        }
        return super::super::wire::print_local_error(&error, global.output, 1);
    }
    let asked = request.seconds * request.fps;
    let failed = frames.len() - ok.len();
    let dropped = (asked as usize).saturating_sub(frames.len());
    let report_frames = timeline(&ok, request.fps);
    let masked = masked_areas(&ok);
    let first = ok
        .first()
        .and_then(|frame| frame.result.as_ref().ok())
        .map(|value| field(value, "result").clone())
        .unwrap_or(Value::Null);
    let seconds = elapsed.as_secs_f64();
    let reached = if seconds > 0.0 { ok.len() as f64 / seconds } else { 0.0 };
    let mut report = json!({
        "noun": request.noun.word(),
        "frames": ok.len(),
        "asked_frames": asked,
        "fps": (reached * 10.0).round() / 10.0,
        "asked_fps": request.fps,
        "seconds": (seconds * 100.0).round() / 100.0,
        "dropped": dropped,
        "failed": failed,
        "width": field(&first, "width"),
        "height": field(&first, "height"),
        "scale": field(&first, "scale"),
        "masked_areas": masked,
        "frames_dir": place.frames.to_string_lossy(),
    });
    let index = json!({"fps": request.fps, "frames": report_frames});
    let index_path = place.frames.join("frames.json");
    if let Err(error) = std::fs::write(&index_path, format!("{index:#}\n")) {
        let message = messages
            .cannot_write
            .replace("{path}", &index_path.to_string_lossy())
            .replace("{error}", &error.to_string());
        return super::failure("record.write_failed", &message, global.output, 1);
    }
    // The concat list is written whether or not ffmpeg is here, so the folder can be encoded later
    // on another Mac with the same command (`encode`).
    let list = place.frames.join(CONCAT_LIST);
    if let Err(error) = std::fs::write(&list, concat_list(&report_frames)) {
        let message = messages
            .cannot_write
            .replace("{path}", &list.to_string_lossy())
            .replace("{error}", &error.to_string());
        return super::failure("record.write_failed", &message, global.output, 1);
    }
    let mut note = None;
    if let Some(movie) = &place.movie {
        match ffmpeg() {
            None => {
                let args = ffmpeg_args(&place.frames, movie);
                let words: Vec<String> = args.iter().map(|arg| shell_word(arg)).collect();
                put(&mut report, "encode_command", json!(format!("ffmpeg {}", words.join(" "))));
                note = Some(messages.no_ffmpeg.replace("{dir}", &place.frames.to_string_lossy()));
            }
            Some(ffmpeg) => match encode(&ffmpeg, &place.frames, movie) {
                Ok(()) => {
                    let _ = std::fs::remove_dir_all(&place.frames);
                    put(&mut report, "frames_dir", Value::Null);
                    put(&mut report, "path", json!(movie.to_string_lossy()));
                }
                Err(error) => {
                    note = Some(
                        messages
                            .encode_failed
                            .replace("{error}", &error)
                            .replace("{dir}", &place.frames.to_string_lossy()),
                    );
                }
            },
        }
    }
    if report.get("path").is_none_or(Value::is_null) {
        put(&mut report, "path", json!(place.frames.to_string_lossy()));
    }
    if let Some(note) = &note {
        put(&mut report, "note", json!(note));
    }
    match global.output {
        OutputMode::Human => {
            print!("{}", human(&report, &crate::localization::catalog().app_control.record));
            0
        }
        _ => super::super::wire::print_local_success(&report, global.output),
    }
}

/// Asks for one frame every `1 / fps` until `seconds` pass, each on the first free connection. A
/// tick with every connection busy is skipped (the report's `dropped`), never queued: a late frame
/// would show the window later than its time says.
fn capture(
    request: &Request,
    folder: &Path,
    streams: Vec<UnixStream>,
    started: Instant,
) -> Vec<Frame> {
    let busy = AtomicUsize::new(0);
    let (jobs, queue) = mpsc::channel::<(u64, u64)>();
    let queue = Mutex::new(queue);
    let (done, results) = mpsc::channel::<Frame>();
    let workers = streams.len();
    // The workers end with this scope: the last job closes the queue and each one returns.
    std::thread::scope(|scope| {
        for mut stream in streams {
            let (queue, busy, done) = (&queue, &busy, done.clone());
            scope.spawn(move || {
                loop {
                    let job = queue.lock().ok().and_then(|queue| queue.recv().ok());
                    let Some((index, at_ms)) = job else { break };
                    let file = format!("frame-{index:05}.png");
                    let result = shoot(&mut stream, request, &folder.join(&file));
                    busy.fetch_sub(1, Ordering::SeqCst);
                    if done.send(Frame { index, at_ms, file, result }).is_err() {
                        break;
                    }
                }
            });
        }
        drop(done);
        let interval = Duration::from_secs_f64(1.0 / request.fps as f64);
        for index in 0..request.seconds * request.fps {
            let due = interval * index as u32;
            if let Some(wait) = due.checked_sub(started.elapsed()) {
                std::thread::sleep(wait);
            }
            if busy.load(Ordering::SeqCst) >= workers {
                continue;
            }
            busy.fetch_add(1, Ordering::SeqCst);
            let at_ms = started.elapsed().as_millis() as u64;
            if jobs.send((index, at_ms)).is_err() {
                break;
            }
        }
        drop(jobs);
    });
    results.into_iter().collect()
}

/// One `window|pane screenshot` run into `file`. A refusal or a broken connection is that frame's
/// error.
fn shoot(stream: &mut UnixStream, request: &Request, file: &Path) -> Result<Value, Value> {
    let mut params = super::run::action_run_params(
        request.noun.screenshot_action(),
        ActionName::Cli,
        super::action_origin(),
    );
    if let Some(target) = &request.target {
        params.insert("target".into(), json!(target));
    }
    let mut arguments = Map::new();
    arguments.insert("out".into(), json!(file.to_string_lossy()));
    params.insert("args".into(), Value::Object(arguments));
    let mut params = Value::Object(params);
    if let Err(error) = super::run::insert_run_key(&mut params, None) {
        return Err(json!({"code": "app.transport", "message": error}));
    }
    let deadline = Instant::now() + FRAME_TIMEOUT;
    match super::run::request_with_retry_until(
        stream,
        "action.run",
        &params,
        Some(FRAME_TIMEOUT),
        deadline,
    ) {
        Ok(Ok(value)) if field(field(&value, "result"), "path").is_string() => Ok(value),
        Ok(Ok(value)) => Err(json!({
            "code": "record.no_image",
            "message": field(field(&value, "error"), "message")
                .as_str()
                .unwrap_or("the capture gave no image"),
        })),
        Ok(Err(error)) => Err(error),
        Err(error) => Err(json!({"code": "app.transport", "message": error})),
    }
}

/// `frames.json`'s rows: each frame's file, its time and how long it shows (to the next frame's
/// time; the last one frame interval).
pub(super) fn timeline(frames: &[&Frame], fps: u64) -> Vec<Value> {
    let last = 1000 / fps.max(1);
    frames
        .iter()
        .enumerate()
        .map(|(position, frame)| {
            let next = frames.get(position + 1).map(|next| next.at_ms);
            let duration = next.map_or(last, |next| next.saturating_sub(frame.at_ms).max(1));
            json!({"file": frame.file, "t_ms": frame.at_ms, "duration_ms": duration})
        })
        .collect()
}

/// Every area any frame masked, each once, sorted.
fn masked_areas(frames: &[&Frame]) -> Vec<String> {
    let mut areas: Vec<String> = frames
        .iter()
        .filter_map(|frame| frame.result.as_ref().ok())
        .filter_map(|value| field(field(value, "result"), "masked_areas").as_array())
        .flatten()
        .filter_map(|area| area.as_str().map(str::to_owned))
        .collect();
    areas.sort();
    areas.dedup();
    areas
}

/// ffmpeg on PATH, else where Homebrew puts it (a launchd or ssh shell's PATH often lacks it).
fn ffmpeg() -> Option<PathBuf> {
    let on_path = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|folder| folder.join("ffmpeg"));
    on_path
        .chain(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map(PathBuf::from))
        .find(|path| path.is_file())
}

/// The concat list ffmpeg reads: each frame with how long it shows, so the movie keeps the
/// frames' own times. The last file is listed twice, as the concat demuxer needs for its duration.
pub(super) fn concat_list(frames: &[Value]) -> String {
    let mut list = String::from("ffconcat version 1.0\n");
    for frame in frames {
        let file = field(frame, "file").as_str().unwrap_or_default();
        let seconds = field(frame, "duration_ms").as_u64().unwrap_or(0) as f64 / 1000.0;
        let _ = writeln!(list, "file '{file}'\nduration {seconds:.3}");
    }
    if let Some(file) = frames.last().and_then(|frame| field(frame, "file").as_str()) {
        let _ = writeln!(list, "file '{file}'");
    }
    list
}

/// The concat list's name in the frames' folder.
const CONCAT_LIST: &str = "frames.ffconcat";

/// ffmpeg's arguments after the program: the folder's concat list to `movie`, each frame for its
/// own duration (variable frame rate on a 1 ms time base: ffmpeg 9 refuses `-r` with `vfr`, and its
/// default 1/25 time base dropped a sixth of a 30 fps recording), even sides for yuv420p.
pub(super) fn ffmpeg_args(folder: &Path, movie: &Path) -> Vec<String> {
    let mut args: Vec<String> =
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i"]
            .map(str::to_owned)
            .to_vec();
    args.push(folder.join(CONCAT_LIST).to_string_lossy().into_owned());
    args.extend(
        [
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-fps_mode",
            "vfr",
            "-enc_time_base",
            "1/1000",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
        ]
        .map(str::to_owned),
    );
    args.push(movie.to_string_lossy().into_owned());
    args
}

/// `text` as one shell word: as is when it is plain, else in single quotes.
fn shell_word(text: &str) -> String {
    if !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=+".contains(c))
    {
        return text.to_owned();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn encode(ffmpeg: &Path, folder: &Path, movie: &Path) -> Result<(), String> {
    if let Some(parent) = movie.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let output = cmux_process::Command::new(ffmpeg)
        .args(ffmpeg_args(folder, movie))
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(|error| error.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        let text = String::from_utf8_lossy(&output.stderr);
        Err(text.lines().last().unwrap_or("exit status").trim().to_owned())
    }
}

fn fill(template: &str, pairs: &[(&str, String)]) -> String {
    pairs.iter().fold(template.to_owned(), |text, (name, value)| {
        text.replace(&format!("{{{name}}}"), value)
    })
}

/// The summary printed without `--json`.
pub(super) fn human(report: &Value, messages: &crate::localization::RecordMessages) -> String {
    let text = |key: &str| match field(report, key) {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    let mut out = String::new();
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.recorded,
            &[
                ("frames", text("frames")),
                ("seconds", text("seconds")),
                ("fps", text("fps")),
                ("asked", text("asked_fps")),
                ("path", text("path")),
            ],
        )
    );
    let areas: Vec<&str> = field(report, "masked_areas")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !areas.is_empty() {
        let _ = writeln!(out, "{}", messages.masked.replace("{areas}", &areas.join(", ")));
    }
    if field(report, "dropped").as_u64().unwrap_or(0)
        + field(report, "failed").as_u64().unwrap_or(0)
        > 0
    {
        let _ = writeln!(
            out,
            "{}",
            fill(messages.skipped, &[("dropped", text("dropped")), ("failed", text("failed"))])
        );
    }
    if let Some(note) = field(report, "note").as_str() {
        let _ = writeln!(out, "{note}");
    }
    if let Some(command) = field(report, "encode_command").as_str() {
        let _ = writeln!(out, "  {command}");
    }
    out
}

/// A JSON object's field, or null when it is missing or the value is not an object (no indexing panic path).
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    value.get(key).unwrap_or(&NULL)
}

/// Sets a field of the report object (the report is always an object; anything else is left alone).
fn put(report: &mut Value, key: &str, value: Value) {
    if let Some(object) = report.as_object_mut() {
        object.insert(key.to_owned(), value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parse_defaults_and_bounds() {
        let Ok(AppCommand::Record(request)) = parse(Noun::Window, &words("record")) else {
            panic!()
        };
        assert_eq!(
            (request.seconds, request.fps, request.target, request.out),
            (5, 30, None, None)
        );
        let Ok(AppCommand::Record(request)) = parse(
            Noun::Pane,
            &words("record --target pane_1 --seconds 10 --fps 60 --out /tmp/a.mp4"),
        ) else {
            panic!()
        };
        assert_eq!(request.noun, Noun::Pane);
        assert_eq!(request.target.as_deref(), Some("pane_1"));
        assert_eq!((request.seconds, request.fps), (10, 60));
        assert_eq!(request.out.as_deref(), Some("/tmp/a.mp4"));
        for bad in [
            "record --seconds 0",
            "record --seconds 61",
            "record --fps 0",
            "record --fps 61",
            "record --seconds 60 --fps 60",
            "record --bogus 1",
            "record --fps x",
        ] {
            assert!(parse(Noun::Window, &words(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn window_record_is_the_recording_not_an_app_action() {
        let parsed = super::super::parse(&words("window record --fps 10 --seconds 2")).unwrap();
        let Some(AppCommand::Record(request)) = parsed else { panic!("{parsed:?}") };
        assert_eq!((request.noun, request.fps, request.seconds), (Noun::Window, 10, 2));
        assert!(super::super::parse(&words("window record --fps 0")).is_err());
    }

    #[test]
    fn the_encode_reads_the_folders_list_at_the_frames_own_times() {
        let args = ffmpeg_args(Path::new("/f"), Path::new("/x/clip.mp4"));
        let at = |word: &str| args.iter().position(|arg| arg == word).unwrap();
        assert_eq!(args[at("-i") + 1], "/f/frames.ffconcat");
        assert_eq!(args[at("-fps_mode") + 1], "vfr");
        assert_eq!(args[at("-enc_time_base") + 1], "1/1000");
        assert!(!args.iter().any(|arg| arg == "-r"), "ffmpeg 9 refuses -r with vfr: {args:?}");
        assert_eq!(args.last().unwrap(), "/x/clip.mp4");
        assert_eq!(shell_word("/a b/c's"), "'/a b/c'\\''s'");
        assert_eq!(shell_word("pad=ceil(iw/2)*2"), "'pad=ceil(iw/2)*2'");
        assert_eq!(shell_word("-fps_mode"), "-fps_mode");
    }

    #[test]
    fn a_relative_out_is_the_callers() {
        let Ok(AppCommand::Record(request)) = parse(Noun::Window, &words("record --out clip.mp4"))
        else {
            panic!()
        };
        let out = request.out.unwrap();
        assert!(Path::new(&out).is_absolute() && out.ends_with("clip.mp4"), "{out}");
    }

    #[test]
    fn destinations() {
        let temporary = Path::new("/var/t");
        assert_eq!(
            destination(Some("/x/clip.MP4"), 7, temporary),
            Destination { frames: "/x/clip.MP4.frames".into(), movie: Some("/x/clip.MP4".into()) }
        );
        assert_eq!(
            destination(Some("/x/shots"), 7, temporary),
            Destination { frames: "/x/shots".into(), movie: None }
        );
        assert_eq!(
            destination(None, 7, temporary),
            Destination {
                frames: "/var/t/cmux-recordings/record-7.frames".into(),
                movie: Some("/var/t/cmux-recordings/record-7.mp4".into()),
            }
        );
    }

    fn frame(index: u64, at_ms: u64) -> Frame {
        Frame {
            index,
            at_ms,
            file: format!("frame-{index:05}.png"),
            result: Ok(json!({"result": {"path": "p", "masked_areas": ["tab-strip", "chat"]}})),
        }
    }

    #[test]
    fn the_timeline_keeps_each_frames_time() {
        let frames = [frame(0, 0), frame(1, 40), frame(3, 100)];
        let refs: Vec<&Frame> = frames.iter().collect();
        let rows = timeline(&refs, 25);
        let durations: Vec<u64> =
            rows.iter().map(|row| row["duration_ms"].as_u64().unwrap()).collect();
        assert_eq!(durations, vec![40, 60, 40]);
        assert_eq!(masked_areas(&refs), vec!["chat".to_owned(), "tab-strip".to_owned()]);
        let list = concat_list(&rows);
        assert!(
            list.starts_with("ffconcat version 1.0\nfile 'frame-00000.png'\nduration 0.040\n"),
            "{list}"
        );
        assert!(list.ends_with("duration 0.040\nfile 'frame-00003.png'\n"), "{list}");
    }

    #[test]
    fn the_summary_names_masks_and_skips() {
        let messages = &crate::localization::catalog().app_control.record;
        let report = json!({"frames": 120, "seconds": 4.02, "fps": 29.9, "asked_fps": 30, "path": "/x/clip.mp4",
                            "masked_areas": ["chat"], "dropped": 2, "failed": 0});
        let text = human(&report, messages);
        assert!(
            text.contains("120") && text.contains("/x/clip.mp4") && text.contains("chat"),
            "{text}"
        );
        assert!(text.contains('2'), "{text}");
    }
}
