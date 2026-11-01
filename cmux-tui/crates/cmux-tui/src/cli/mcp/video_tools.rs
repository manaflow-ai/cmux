//! `video_info` and `video_frames`: an agent looks into a video file without ffmpeg.
//!
//! Leo, 2026-11-01, after an agent in a cmux chat had to hand-write
//! `ffmpeg -vf fps=1,scale=640:-1,tile=4x4` into /tmp to see a 16 s screen recording:
//! "i feel like cmux-next should give u better tools to deal with this kind of thing".
//!
//! The app decodes (AVFoundation, the decoder the composer's video chips use, through the app
//! method `video.frames`); this server picks the times, the size and the byte budget, finds
//! scene changes, and answers MCP image blocks. The server names the file by its device and
//! inode as it sees it, and the app refuses a path whose file is not that one, so a chat whose
//! server runs on another machine (Cloud, ssh) never gets frames of a same-named file on the
//! Mac; it is told so, and to use that machine's own tools.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::transport::CallFailure;
use super::{Backend, Server, envelope, failure_result, success, tool_error, v2_tools};

pub(super) const INFO: &str = "video_info";
pub(super) const FRAMES: &str = "video_frames";
/// The app method that decodes (CmuxNextApp `VideoControl`).
const METHOD: &str = "video.frames";
/// The most frames one call answers.
pub(super) const MAX_FRAMES: usize = 16;
/// Frames a call that names no count gets.
const DEFAULT_COUNT: usize = 8;
/// The longest side of a frame by default: about what a model reads a screenshot at.
const DEFAULT_MAX_SIDE: u64 = 1280;
const MIN_SIDE: u64 = 64;
const MAX_SIDE: u64 = 2048;
/// The most base64 bytes of JPEG one call answers, under `cmux_exec`'s own image budget
/// (code_mode `MAX_IMAGE_BYTES`, 8 MiB).
const MAX_TOTAL_BYTES: u64 = 6 << 20;
/// How many small grey samples `scenes` compares, and their side.
const SCENE_SAMPLES: usize = 64;
const SCENE_SIDE: u64 = 16;
/// A change between two samples smaller than this (mean absolute grey difference, 0 to 255)
/// is not a scene change: noise, a blinking caret.
const SCENE_MIN_CHANGE: f64 = 1.5;
/// The app's decode: up to 64 small frames or 16 large ones from a long file.
const TIMEOUT: Duration = Duration::from_secs(60);

const PATH_DOC: &str = "The video file: absolute, ~/, or relative to this chat's folder. .mov, .mp4, .m4v and whatever else AVFoundation opens.";

pub(super) fn descriptors() -> Vec<Value> {
    vec![
        json!({
            "name": INFO,
            "title": "Read a video's length and size",
            "description": "A video file's duration, size (width and height as it shows, after rotation), frame rate and whether it has audio, without ffmpeg. Use it before video_frames to choose times, or alone to answer how long a recording is.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["path"],
                "properties": {"path": {"type": "string", "minLength": 1, "description": PATH_DOC}}
            },
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
        json!({
            "name": FRAMES,
            "title": "Look at a video's frames",
            "description": format!("See into a video file (a screen recording, a bug repro, an attached .mp4 or .mov): its frames come back as images you can look at, with one text block giving the duration, size and each frame's time. Use this instead of ffmpeg or ffprobe. Pick frames with one of at (exact times in seconds), range ({{from, to, count}}: count frames evenly from from to to, both included) or scenes: true (the count moments where the picture changes most, for a recording where something happens); with none, count frames spread evenly over the whole video. At most {MAX_FRAMES} frames a call (count defaults to {DEFAULT_COUNT}), each at most maxSide pixels on its longest side (default {DEFAULT_MAX_SIDE}); a call whose frames would pass {} MiB returns the first ones and says how many it left out, so ask again with a smaller maxSide or a later range. Look at a long video in steps: a few frames over all of it, then a range around what matters.", MAX_TOTAL_BYTES >> 20),
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["path"],
                "properties": {
                    "path": {"type": "string", "minLength": 1, "description": PATH_DOC},
                    "at": {"type": "array", "items": {"type": "number", "minimum": 0}, "minItems": 1, "maxItems": MAX_FRAMES, "description": "Times in seconds; each frame is the one shown at that time."},
                    "range": {
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {
                            "from": {"type": "number", "minimum": 0, "description": "Seconds; default 0."},
                            "to": {"type": "number", "minimum": 0, "description": "Seconds; default the end."},
                            "count": {"type": "integer", "minimum": 1, "maximum": MAX_FRAMES, "description": format!("Default {DEFAULT_COUNT}.")}
                        }
                    },
                    "scenes": {"type": "boolean", "description": "true: the moments the picture changes most (and the first frame), in time order."},
                    "count": {"type": "integer", "minimum": 1, "maximum": MAX_FRAMES, "description": format!("Frames for scenes, or spread over the whole video when no at or range is given. Default {DEFAULT_COUNT}.")},
                    "maxSide": {"type": "integer", "minimum": MIN_SIDE, "maximum": MAX_SIDE, "description": format!("The longest side of each frame in pixels. Default {DEFAULT_MAX_SIDE}; a frame is never made larger than the video.")}
                }
            },
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
    ]
}

/// Which frames a `video_frames` call asks for.
#[derive(Clone, Debug, PartialEq)]
enum Pick {
    At(Vec<f64>),
    Range { from: Option<f64>, to: Option<f64>, count: usize },
    Scenes(usize),
    Spread(usize),
}

#[derive(Clone, Debug, PartialEq)]
struct Request {
    path: String,
    pick: Pick,
    max_side: u64,
}

fn number(value: &Value, what: &str) -> Result<f64, String> {
    value
        .as_f64()
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .ok_or_else(|| format!("video_frames {what} must be a number of seconds, 0 or more"))
}

fn count(value: Option<&Value>, what: &str) -> Result<usize, String> {
    match value {
        None | Some(Value::Null) => Ok(DEFAULT_COUNT),
        Some(value) => value
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .filter(|count| (1..=MAX_FRAMES).contains(count))
            .ok_or_else(|| {
                format!("video_frames {what} must be an integer from 1 to {MAX_FRAMES}")
            }),
    }
}

fn path_argument(arguments: &Map<String, Value>, tool: &str) -> Result<String, String> {
    arguments
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("{tool} needs path: the video file"))
}

fn info_request(arguments: &Map<String, Value>) -> Result<String, String> {
    if let Some(name) = arguments.keys().find(|name| name.as_str() != "path") {
        return Err(format!("video_info has no argument {name:?}"));
    }
    path_argument(arguments, INFO)
}

fn frames_request(arguments: &Map<String, Value>) -> Result<Request, String> {
    let known = ["path", "at", "range", "scenes", "count", "maxSide"];
    if let Some(name) = arguments.keys().find(|name| !known.contains(&name.as_str())) {
        return Err(format!("video_frames has no argument {name:?}"));
    }
    let path = path_argument(arguments, FRAMES)?;
    let scenes = match arguments.get("scenes") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::Bool(true)) => true,
        Some(_) => return Err("video_frames scenes must be true or false".into()),
    };
    let at = arguments.get("at").filter(|value| !value.is_null());
    let range = arguments.get("range").filter(|value| !value.is_null());
    if [at.is_some(), range.is_some(), scenes].iter().filter(|given| **given).count() > 1 {
        return Err("video_frames takes one of at, range or scenes".into());
    }
    if arguments.get("count").is_some_and(|value| !value.is_null())
        && (at.is_some() || range.is_some())
    {
        return Err(
            "video_frames count goes with scenes or alone; a range has its own count".into()
        );
    }
    let pick = if let Some(at) = at {
        let times = at.as_array().ok_or("video_frames at must be a list of seconds")?;
        if times.is_empty() || times.len() > MAX_FRAMES {
            return Err(format!("video_frames at takes 1 to {MAX_FRAMES} times"));
        }
        Pick::At(times.iter().map(|time| number(time, "at")).collect::<Result<_, _>>()?)
    } else if let Some(range) = range {
        let range = range.as_object().ok_or("video_frames range must be {from, to, count}")?;
        if let Some(name) =
            range.keys().find(|name| !matches!(name.as_str(), "from" | "to" | "count"))
        {
            return Err(format!("video_frames range has no field {name:?}"));
        }
        let bound = |key: &str| {
            range
                .get(key)
                .filter(|value| !value.is_null())
                .map(|value| number(value, &format!("range.{key}")))
                .transpose()
        };
        let (from, to) = (bound("from")?, bound("to")?);
        if let (Some(from), Some(to)) = (from, to)
            && to < from
        {
            return Err("video_frames range.to must not be before range.from".into());
        }
        Pick::Range { from, to, count: count(range.get("count"), "range.count")? }
    } else if scenes {
        Pick::Scenes(count(arguments.get("count"), "count")?)
    } else {
        Pick::Spread(count(arguments.get("count"), "count")?)
    };
    let max_side = match arguments.get("maxSide") {
        None | Some(Value::Null) => DEFAULT_MAX_SIDE,
        Some(value) => {
            value.as_u64().filter(|side| (MIN_SIDE..=MAX_SIDE).contains(side)).ok_or_else(|| {
                format!("video_frames maxSide must be an integer from {MIN_SIDE} to {MAX_SIDE}")
            })?
        }
    };
    Ok(Request { path, pick, max_side })
}

/// The last time a frame can be read at: a little before the end, where a decoder has no
/// frame.
fn last_time(duration: f64, fps: f64) -> f64 {
    let frame = if fps.is_finite() && fps > 0.0 { 1.0 / fps } else { 1.0 / 30.0 };
    (duration - frame).max(0.0)
}

/// `count` times from `from` to `to`, both included (one frame: `from`).
fn evenly(from: f64, to: f64, count: usize) -> Vec<f64> {
    if count <= 1 || to <= from {
        return vec![from];
    }
    let step = (to - from) / (count - 1) as f64;
    (0..count).map(|index| from + step * index as f64).collect()
}

/// The middle of each of `count` equal parts of `duration`: neither the first frame (often
/// black) nor the very last (AgentPaneVideoInfo.frameTimes).
fn spread(duration: f64, count: usize) -> Vec<f64> {
    (0..count).map(|index| duration * (index as f64 + 0.5) / count as f64).collect()
}

/// The times the app decodes for `pick` in a video `duration` seconds long, clamped into it,
/// and how far from each a decoder may land (seconds): exact for `at`, a quarter of the
/// spacing otherwise, so a sync frame nearby is fast.
fn times(pick: &Pick, duration: f64, fps: f64) -> (Vec<f64>, f64) {
    let end = last_time(duration, fps);
    let clamp = |time: f64| time.clamp(0.0, end);
    match pick {
        Pick::At(times) => (times.iter().copied().map(clamp).collect(), 0.0),
        Pick::Range { from, to, count } => {
            let from = clamp(from.unwrap_or(0.0));
            let to = clamp(to.unwrap_or(end)).max(from);
            let times = evenly(from, to, *count);
            let spacing = if *count > 1 { (to - from) / (*count - 1) as f64 } else { 0.0 };
            (times, (spacing / 4.0).min(0.5))
        }
        Pick::Spread(count) => (
            spread(duration, *count).into_iter().map(clamp).collect(),
            (duration / *count as f64 / 4.0).min(0.5),
        ),
        Pick::Scenes(_) => (
            spread(duration, SCENE_SAMPLES).into_iter().map(clamp).collect(),
            (duration / SCENE_SAMPLES as f64 / 4.0).min(0.5),
        ),
    }
}

/// One small grey sample: where it is (ms) and its pixels.
struct Sample {
    at_ms: u64,
    pixels: Vec<u8>,
}

/// The times of the `count` moments the picture changes most, in time order: the first sample,
/// then each sample that differs most from the one before (mean absolute grey difference at
/// least `SCENE_MIN_CHANGE`), with the change each one made (0 for the first).
fn scene_times(samples: &[Sample], count: usize) -> Vec<(u64, f64)> {
    let Some(first) = samples.first() else { return Vec::new() };
    let mut changes = samples
        .iter()
        .zip(samples.iter().skip(1))
        .filter(|(before, after)| {
            before.pixels.len() == after.pixels.len() && !after.pixels.is_empty()
        })
        .map(|(before, after)| {
            let total: u64 = before
                .pixels
                .iter()
                .zip(&after.pixels)
                .map(|(a, b)| u64::from(a.abs_diff(*b)))
                .sum();
            (after.at_ms, total as f64 / after.pixels.len() as f64)
        })
        .filter(|(at, change)| *change >= SCENE_MIN_CHANGE && *at != first.at_ms)
        .collect::<Vec<_>>();
    changes.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    changes.truncate(count.saturating_sub(1));
    let mut picked = vec![(first.at_ms, 0.0)];
    picked.extend(changes);
    picked.sort_by_key(|(at, _)| *at);
    picked
}

fn seconds(ms: u64) -> String {
    format!("{:.2} s", ms as f64 / 1000.0)
}

/// The text block: the video, then each frame's number and time.
fn summary(
    path: &str,
    info: &Value,
    frames: &[(u64, Option<f64>)],
    max_side: u64,
    dropped: u64,
    scenes: bool,
) -> String {
    let mut text = describe(path, info);
    if frames.is_empty() {
        text.push_str(" No frame could be decoded at those times.");
        return text;
    }
    text.push_str(&format!(
        " {} frame{} below, in order, at most {max_side} px on the longest side:",
        frames.len(),
        if frames.len() == 1 { "" } else { "s" }
    ));
    for (index, (at, change)) in frames.iter().enumerate() {
        text.push_str(&format!("\n#{} at {}", index + 1, seconds(*at)));
        if scenes && let Some(change) = change.filter(|change| *change > 0.0) {
            text.push_str(&format!(" (change {change:.1})"));
        }
    }
    if scenes && frames.len() == 1 {
        text.push_str(
            "\nThe picture barely changes: ask for range or count frames spread over it instead.",
        );
    }
    if dropped > 0 {
        text.push_str(&format!(
            "\n{dropped} more frame{} left out to stay under {} MiB: ask again with a smaller maxSide or for the times after the last one.",
            if dropped == 1 { " was" } else { "s were" },
            MAX_TOTAL_BYTES >> 20
        ));
    }
    text
}

fn describe(path: &str, info: &Value) -> String {
    let ms = info["durationMs"].as_u64().unwrap_or(0);
    let fps = info["fps"].as_f64().filter(|fps| *fps > 0.0);
    format!(
        "{path}: {}, {}x{}{}, {}.",
        seconds(ms),
        info["width"].as_u64().unwrap_or(0),
        info["height"].as_u64().unwrap_or(0),
        fps.map(|fps| format!(", {} fps", (fps * 100.0).round() / 100.0)).unwrap_or_default(),
        if info["hasAudio"] == true { "with audio" } else { "no audio" }
    )
}

/// The public part of the app's answer (no frames).
fn info_value(path: &str, info: &Value) -> Value {
    json!({
        "path": path,
        "durationMs": info["durationMs"],
        "width": info["width"],
        "height": info["height"],
        "fps": info["fps"],
        "hasAudio": info["hasAudio"],
    })
}

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

/// The file `path` names on this machine: its device and inode, for the app to check it reads
/// the same file. A folder or a missing file is refused here.
#[cfg(unix)]
fn identity(path: &str) -> Result<(String, Value), String> {
    use std::os::unix::fs::MetadataExt as _;
    let real =
        std::fs::canonicalize(path).map_err(|error| format!("cannot read {path}: {error}"))?;
    let meta = std::fs::metadata(&real).map_err(|error| format!("cannot read {path}: {error}"))?;
    if !meta.is_file() {
        return Err(format!("{path} is not a file"));
    }
    std::fs::File::open(&real).map_err(|error| format!("cannot read {path}: {error}"))?;
    let real = real.to_string_lossy().into_owned();
    Ok((
        real.clone(),
        json!({"path": real, "dev": meta.dev().to_string(), "ino": meta.ino().to_string()}),
    ))
}

#[cfg(not(unix))]
fn identity(path: &str) -> Result<(String, Value), String> {
    Err(format!("{path}: video tools need the cmux app on this machine"))
}

/// The app's answer to one `video.frames` request, or the tool result that says why not.
fn decode(
    app: &mut dyn FnMut(Value) -> Result<Value, CallFailure>,
    params: Value,
) -> Result<Value, Value> {
    match app(params) {
        Ok(value) if value["durationMs"].is_u64() => Ok(value),
        Ok(_) => Err(invalid("the cmux app answered video.frames without a duration")),
        Err(failure)
            if matches!(failure.error["code"].as_str(), Some("not_found" | "unsupported")) =>
        {
            Err(failure_result(failure))
        }
        Err(failure)
            if failure.error["code"] == "method_not_found"
                || failure.error["code"] == "unknown_method" =>
        {
            Err(invalid("this cmux app is too old for video frames; update it, or use ffmpeg"))
        }
        Err(failure) => Err(failure_result(failure)),
    }
}

/// `video_info`.
fn run_info(
    arguments: &Map<String, Value>,
    resolve: &dyn Fn(&str) -> String,
    app: &mut dyn FnMut(Value) -> Result<Value, CallFailure>,
) -> Value {
    let path = match info_request(arguments) {
        Ok(path) => resolve(&path),
        Err(message) => return invalid(message),
    };
    let (real, mut params) = match identity(&path) {
        Ok(found) => found,
        Err(message) => return invalid(message),
    };
    params["times"] = json!([]);
    match decode(app, params) {
        Ok(info) => success(info_value(&real, &info), false),
        Err(answer) => answer,
    }
}

/// `video_frames`: a probe for the duration, the scene samples when asked, then the frames.
fn run_frames(
    arguments: &Map<String, Value>,
    resolve: &dyn Fn(&str) -> String,
    app: &mut dyn FnMut(Value) -> Result<Value, CallFailure>,
) -> Value {
    let request = match frames_request(arguments) {
        Ok(request) => Request { path: resolve(&request.path), ..request },
        Err(message) => return invalid(message),
    };
    let (real, base) = match identity(&request.path) {
        Ok(found) => found,
        Err(message) => return invalid(message),
    };
    let with = |extra: Value| {
        let mut params = base.clone();
        for (key, value) in extra.as_object().into_iter().flatten() {
            params[key] = value.clone();
        }
        params
    };
    let info = match decode(app, with(json!({"times": []}))) {
        Ok(info) => info,
        Err(answer) => return answer,
    };
    let duration = info["durationMs"].as_u64().unwrap_or(0) as f64 / 1000.0;
    let fps = info["fps"].as_f64().unwrap_or(0.0);
    let (mut wanted, tolerance) = times(&request.pick, duration, fps);
    let mut changes = Vec::new();
    if let Pick::Scenes(count) = request.pick {
        let sampled = match decode(
            app,
            with(
                json!({"times": wanted, "format": "luma", "side": SCENE_SIDE, "tolerance": tolerance, "maxBytes": MAX_TOTAL_BYTES}),
            ),
        ) {
            Ok(sampled) => sampled,
            Err(answer) => return answer,
        };
        let samples = sampled["frames"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|frame| {
                use base64::Engine as _;
                let pixels = base64::engine::general_purpose::STANDARD
                    .decode(frame["data"].as_str()?)
                    .ok()?;
                Some(Sample { at_ms: frame["atMs"].as_u64()?, pixels })
            })
            .collect::<Vec<_>>();
        let picked = scene_times(&samples, count);
        wanted = picked.iter().map(|(at, _)| *at as f64 / 1000.0).collect();
        changes = picked;
    }
    if wanted.is_empty() {
        return success(
            json!({"message": format!("{} No frame could be decoded.", describe(&real, &info))}),
            false,
        );
    }
    let decoded = match decode(
        app,
        with(json!({
            "times": wanted,
            "format": "jpeg",
            "side": request.max_side,
            // A scene frame is the sample the change was seen in: exact.
            "tolerance": if matches!(request.pick, Pick::Scenes(_)) { 0.0 } else { tolerance },
            "maxBytes": MAX_TOTAL_BYTES,
        })),
    ) {
        Ok(decoded) => decoded,
        Err(answer) => return answer,
    };
    let frames = decoded["frames"].as_array().cloned().unwrap_or_default();
    let listed = frames
        .iter()
        .map(|frame| {
            let at = frame["atMs"].as_u64().unwrap_or(0);
            // The change the scene pick saw nearest this frame's time.
            let change = changes
                .iter()
                .min_by_key(|(picked, _)| picked.abs_diff(at))
                .map(|(_, change)| *change);
            (at, change)
        })
        .collect::<Vec<_>>();
    let dropped = decoded["dropped"].as_u64().unwrap_or(0);
    let text = summary(
        &real,
        &info,
        &listed,
        request.max_side,
        dropped,
        matches!(request.pick, Pick::Scenes(_)),
    );
    // No structured content: `cmux_exec` moves image blocks to its own result only from a
    // result without it (code_mode `script_answer`).
    let mut content = vec![json!({"type": "text", "text": text})];
    content.extend(frames.iter().filter_map(|frame| {
        Some(json!({"type": "image", "data": frame["data"].as_str()?, "mimeType": "image/jpeg"}))
    }));
    json!({"content": content, "isError": false})
}

impl<B: Backend> Server<B> {
    /// `video_info` or `video_frames`, decoded by the app; `None` for another tool.
    pub(super) fn call_video(&self, name: &str, arguments: &Map<String, Value>) -> Option<Value> {
        let resolve = |path: &str| self.chat_path(path);
        let mut app = |params: Value| self.backend.app(METHOD, params, TIMEOUT, None, false);
        match name {
            INFO => Some(run_info(arguments, &resolve, &mut app)),
            FRAMES => Some(run_frames(arguments, &resolve, &mut app)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn args(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    fn video() -> tempfile::NamedTempFile {
        let file = tempfile::Builder::new().suffix(".mp4").tempfile().unwrap();
        std::fs::write(file.path(), b"not decoded here").unwrap();
        file
    }

    /// An app that answers like the decoder: a 16 s 1920x1080 video, a frame at each asked
    /// time (a grey sample that changes at 4 s and, more, at 10 s), every request recorded.
    fn app(sent: &RefCell<Vec<Value>>) -> impl FnMut(Value) -> Result<Value, CallFailure> + '_ {
        move |params: Value| {
            sent.borrow_mut().push(params.clone());
            let frames = params["times"]
                .as_array()
                .unwrap()
                .iter()
                .map(|time| {
                    let at = time.as_f64().unwrap();
                    let data = if params["format"] == "luma" {
                        let grey = if at >= 10.0 {
                            200
                        } else if at >= 4.0 {
                            60
                        } else {
                            0
                        };
                        use base64::Engine as _;
                        base64::engine::general_purpose::STANDARD.encode(vec![grey; 256])
                    } else {
                        "anBn".to_owned()
                    };
                    json!({"atMs": (at * 1000.0).round() as u64, "data": data})
                })
                .collect::<Vec<_>>();
            Ok(
                json!({"durationMs": 16000, "width": 1920, "height": 1080, "fps": 30.0, "hasAudio": false, "frames": frames, "dropped": 0}),
            )
        }
    }

    fn same(path: &str) -> String {
        path.to_owned()
    }

    #[test]
    fn the_tools_list_their_selectors_and_steer_away_from_ffmpeg() {
        let tools = descriptors();
        let frames = tools.iter().find(|tool| tool["name"] == FRAMES).unwrap();
        let description = frames["description"].as_str().unwrap();
        assert!(description.contains("instead of ffmpeg"), "{description}");
        let properties = frames["inputSchema"]["properties"].as_object().unwrap();
        for key in ["path", "at", "range", "scenes", "count", "maxSide"] {
            assert!(properties.contains_key(key), "{key}");
        }
        assert_eq!(frames["inputSchema"]["properties"]["at"]["maxItems"], MAX_FRAMES);
        assert!(tools.iter().all(|tool| tool["annotations"]["readOnlyHint"] == true));
    }

    #[test]
    fn a_call_names_one_selector_and_stays_within_the_caps() {
        let ok = |value| frames_request(&args(value));
        assert_eq!(ok(json!({"path": "a.mp4"})).unwrap().pick, Pick::Spread(DEFAULT_COUNT));
        assert_eq!(ok(json!({"path": "a.mp4"})).unwrap().max_side, DEFAULT_MAX_SIDE);
        assert_eq!(
            ok(json!({"path": "a.mp4", "scenes": true, "count": 4})).unwrap().pick,
            Pick::Scenes(4)
        );
        assert_eq!(
            ok(json!({"path": "a.mp4", "range": {"from": 2, "to": 6, "count": 3}})).unwrap().pick,
            Pick::Range { from: Some(2.0), to: Some(6.0), count: 3 }
        );
        for (bad, says) in [
            (json!({"path": "a.mp4", "at": [1], "scenes": true}), "one of"),
            (json!({"path": "a.mp4", "at": (0..17).collect::<Vec<_>>()}), "1 to 16"),
            (json!({"path": "a.mp4", "count": 17}), "1 to 16"),
            (json!({"path": "a.mp4", "maxSide": 10}), "maxSide"),
            (json!({"path": "a.mp4", "range": {"from": 5, "to": 1}}), "before"),
            (json!({"path": "a.mp4", "at": [-1]}), "0 or more"),
            (json!({"path": "a.mp4", "fps": 1}), "no argument"),
            (json!({"at": [1]}), "needs path"),
        ] {
            let message = frames_request(&args(bad.clone())).unwrap_err();
            assert!(message.contains(says), "{bad}: {message}");
        }
    }

    #[test]
    fn times_stay_inside_the_video() {
        let (at, tolerance) = times(&Pick::At(vec![0.0, 99.0]), 16.0, 30.0);
        assert_eq!(tolerance, 0.0, "an asked time is exact");
        assert_eq!(at[0], 0.0);
        assert!(at[1] < 16.0 && at[1] > 15.9, "{at:?}");
        let (range, _) =
            times(&Pick::Range { from: Some(2.0), to: Some(6.0), count: 5 }, 16.0, 30.0);
        assert_eq!(range, vec![2.0, 3.0, 4.0, 5.0, 6.0]);
        let (spread, _) = times(&Pick::Spread(4), 16.0, 30.0);
        assert_eq!(spread, vec![2.0, 6.0, 10.0, 14.0]);
        let (one, _) = times(&Pick::Range { from: None, to: None, count: 1 }, 16.0, 30.0);
        assert_eq!(one, vec![0.0]);
    }

    #[test]
    fn scenes_are_the_first_frame_and_the_biggest_changes_in_time_order() {
        let sample = |at_ms, grey| Sample { at_ms, pixels: vec![grey; 4] };
        let samples =
            [sample(0, 0), sample(1000, 0), sample(2000, 50), sample(3000, 51), sample(4000, 250)];
        let picked = scene_times(&samples, 3);
        assert_eq!(picked.iter().map(|(at, _)| *at).collect::<Vec<_>>(), vec![0, 2000, 4000]);
        assert_eq!(picked[2].1, 199.0);
        // A change under the floor (1 grey level) is noise: only the first frame.
        assert_eq!(scene_times(&samples[..2], 4).len(), 1);
        assert_eq!(scene_times(&[sample(0, 0), sample(1000, 1)], 4).len(), 1);
        assert!(scene_times(&[], 4).is_empty());
    }

    #[test]
    fn frames_come_back_as_image_blocks_after_one_text_block() {
        let file = video();
        let path = file.path().to_str().unwrap().to_owned();
        let sent = RefCell::new(Vec::new());
        let answer =
            run_frames(&args(json!({"path": path, "at": [1, 2.5]})), &same, &mut app(&sent));
        assert_eq!(answer["isError"], false, "{answer}");
        assert!(
            answer.get("structuredContent").is_none(),
            "cmux_exec moves the images only without it"
        );
        let content = answer["content"].as_array().unwrap();
        assert_eq!(content.len(), 3);
        let text = content[0]["text"].as_str().unwrap();
        assert!(text.contains("16.00 s, 1920x1080, 30 fps, no audio"), "{text}");
        assert!(text.contains("#1 at 1.00 s") && text.contains("#2 at 2.50 s"), "{text}");
        assert_eq!(content[1], json!({"type": "image", "data": "anBn", "mimeType": "image/jpeg"}));
        let sent = sent.borrow();
        assert_eq!(sent.len(), 2, "a probe, then the frames");
        let real = std::fs::canonicalize(&path).unwrap();
        assert_eq!(sent[1]["path"], real.to_str().unwrap());
        assert!(sent[1]["dev"].is_string() && sent[1]["ino"].is_string());
        assert_eq!(sent[1]["side"], DEFAULT_MAX_SIDE);
        assert_eq!(sent[1]["tolerance"], 0.0);
        assert_eq!(sent[1]["maxBytes"], MAX_TOTAL_BYTES);
    }

    #[test]
    fn scenes_sample_small_grey_frames_then_read_the_changes() {
        let file = video();
        let path = file.path().to_str().unwrap().to_owned();
        let sent = RefCell::new(Vec::new());
        let answer = run_frames(
            &args(json!({"path": path, "scenes": true, "count": 3, "maxSide": 640})),
            &same,
            &mut app(&sent),
        );
        let sent = sent.borrow();
        assert_eq!(sent.len(), 3, "probe, samples, frames");
        assert_eq!(sent[1]["format"], "luma");
        assert_eq!(sent[1]["times"].as_array().unwrap().len(), SCENE_SAMPLES);
        let frames = sent[2]["times"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_f64().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(frames.len(), 3, "{frames:?}");
        assert!(
            frames[0] < 1.0 && (4.0..4.5).contains(&frames[1]) && (10.0..10.5).contains(&frames[2]),
            "{frames:?}"
        );
        assert_eq!(sent[2]["side"], 640);
        let text = answer["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("(change 140.0)") && text.contains("(change 60.0)"), "{text}");
    }

    #[test]
    fn a_left_out_frame_and_a_refusal_are_said() {
        let file = video();
        let path = file.path().to_str().unwrap().to_owned();
        let mut partial = |params: Value| -> Result<Value, CallFailure> {
            let frames = if params["times"].as_array().unwrap().is_empty() {
                json!([])
            } else {
                json!([{"atMs": 0, "data": "anBn"}])
            };
            Ok(
                json!({"durationMs": 2000, "width": 10, "height": 10, "fps": 0, "hasAudio": true, "frames": frames, "dropped": 3}),
            )
        };
        let answer = run_frames(&args(json!({"path": path, "count": 4})), &same, &mut partial);
        let text = answer["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("3 more frames were left out"), "{text}");
        assert!(text.contains("with audio"), "{text}");

        let mut elsewhere = |_: Value| -> Result<Value, CallFailure> {
            Err(CallFailure {
                kind: super::super::FailureKind::Rejected,
                error: json!({"code": "not_found", "message": "that file is not on this Mac"}),
                idempotency_key: None,
            })
        };
        let answer = run_info(&args(json!({"path": path})), &same, &mut elsewhere);
        assert_eq!(answer["isError"], true);
        assert!(answer["content"][0]["text"].as_str().unwrap().contains("not on this Mac"));

        let missing =
            run_info(&args(json!({"path": "/nonexistent/clip.mp4"})), &same, &mut elsewhere);
        assert!(
            missing["content"][0]["text"].as_str().unwrap().contains("cannot read"),
            "{missing}"
        );
    }

    #[test]
    fn video_info_answers_the_numbers_without_frames() {
        let file = video();
        let path = file.path().to_str().unwrap().to_owned();
        let sent = RefCell::new(Vec::new());
        let answer = run_info(&args(json!({"path": path})), &same, &mut app(&sent));
        assert_eq!(answer["structuredContent"]["durationMs"], 16000);
        assert_eq!(answer["structuredContent"]["hasAudio"], false);
        assert!(answer["structuredContent"].get("frames").is_none());
        assert_eq!(sent.borrow()[0]["times"], json!([]));
    }
}
