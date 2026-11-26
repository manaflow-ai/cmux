//! A turn's frames (RFD 0150-0153, cmuxterm-hq `docs/rfd/0151-deterministic-capture.md`): while an
//! agent works on UI, acpmux keeps pictures of the chat's page as it forms, at no agent tokens. The
//! chat draws them as a strip under the turn and as a live preview window
//! (`webviews/.../liveFrames`), through `_acpmux/turn_frames` (capability `turn-frames-v1`).
//!
//! Triggers, all deterministic and from the daemon's own records:
//! - `turn-start`: the turn began.
//! - `edit`: a finished tool call named a UI file ([`ui_path`]); debounced [`DEBOUNCE`], so a burst
//!   of edits is one frame.
//! - `build`: a finished shell call (a build, a reload); debounced the same way.
//! - `turn-end`: the turn's result was written.
//! - `look`: the agent asked (the `look` MCP tool), the one trigger that costs it tokens.
//!
//! The page is the one turn shots take (`turn_shots.rs`): the selected, live, agent-driven http(s)
//! tab of the chat's workspace, through the app's own browser host. No page: no frame, never a wait.
//!
//! A frame within [`SAME`] bits (64-bit dHash) of the turn's last kept frame is dropped, so a turn
//! that changed nothing on screen keeps one frame. At most [`MAX_FRAMES`] a turn (the turn's end
//! always gets one more). Each frame keeps a [`THUMB_WIDTH`] px thumbnail and a picture at most
//! [`FULL_WIDTH`] px wide. Disk: `<ACPMUX_HOME>/turn-frames/<session>/<turn>/`, [`KEEP_TURNS`]
//! turns per chat and [`KEEP_CHATS`] chats, as turn shots; a deleted chat's go with it.

use super::Session;
use super::turn_shots::{capture_page, prune, segment};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::Duration;

/// Frames a turn keeps before its end (whose frame always comes).
pub(crate) const MAX_FRAMES: usize = 24;
pub(crate) const KEEP_TURNS: usize = 6;
pub(crate) const KEEP_CHATS: usize = 32;
/// A burst of edits or shell calls inside this is one frame.
pub(crate) const DEBOUNCE: Duration = Duration::from_millis(1500);
/// Hamming distance at or under which two frames are the same picture.
pub(crate) const SAME: u32 = 4;
pub(crate) const THUMB_WIDTH: u32 = 320;
pub(crate) const FULL_WIDTH: u32 = 1280;
/// The long edge of the picture a `look` hands the agent (RFD 0153: about 350-700 image tokens).
pub(crate) const LOOK_EDGE: u32 = 512;
const REPL_SESSION: &str = "acpmux-turn-frames";
const LOOK_REPL_SESSION: &str = "acpmux-turn-frames-look";
const INDEX: &str = "frames.json";
/// One app-window capture, run to answer.
const WINDOW_LIMIT: Duration = Duration::from_secs(20);

/// Every frame's place in the daemon's order: the preview window asks for what is newer than the
/// last it drew.
static SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct Frame {
    pub index: usize,
    pub seq: u64,
    pub trigger: String,
    /// Epoch ms.
    pub at: u64,
    pub width: u32,
    pub height: u32,
    /// Bits from the frame before, over 64 (`0..1`; 0 for the first).
    pub distance: f64,
    /// Bits from the turn's first frame, over 64.
    #[serde(default)]
    pub moved: f64,
    pub hash: u64,
    #[serde(default)]
    pub url: Option<String>,
}

/// The chat's running (or last) turn and its frames.
struct Turn {
    id: String,
    workspace: String,
    frames: Vec<Frame>,
    live: bool,
    /// A capture is running; the next asked waits in `again`.
    capturing: bool,
    again: Option<&'static str>,
    /// Bumped by each edit or shell call, so only a burst's last schedules the frame.
    debounce: u64,
    /// The tool kind of each call this turn, by id (`tool_call_update` records often omit it).
    kinds: HashMap<String, String>,
    /// The turn customizes the app itself ([`customizes_app`]): with no agent-driven page, frames
    /// are of the app's window (`cmux window screenshot`, masked by the app).
    chrome: bool,
}

static TURNS: LazyLock<Mutex<HashMap<String, Turn>>> = LazyLock::new(Default::default);

fn turns() -> std::sync::MutexGuard<'static, HashMap<String, Turn>> {
    TURNS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn root() -> PathBuf {
    crate::config::home().join("turn-frames")
}

fn turn_dir(base: &Path, session: &str, turn: &str) -> Option<PathBuf> {
    Some(base.join(segment(session)?).join(segment(turn)?))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---- pictures ---------------------------------------------------------------------------------

/// A decoded picture, 8-bit RGB.
pub(crate) struct Rgb {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

pub(crate) fn decode(bytes: &[u8]) -> Option<Rgb> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let (width, height) = (info.width, info.height);
    if width == 0 || height == 0 {
        return None;
    }
    let channels = match info.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return None,
    };
    let data = &buf[..info.buffer_size()];
    let mut pixels = Vec::with_capacity((width * height * 3) as usize);
    for px in data.chunks_exact(channels) {
        match channels {
            1 | 2 => pixels.extend_from_slice(&[px[0], px[0], px[0]]),
            _ => pixels.extend_from_slice(&px[..3]),
        }
    }
    Some(Rgb { width, height, pixels })
}

/// `picture` shrunk by area averaging so that it is at most `max_width` wide and, with
/// `max_height`, at most that tall. Never enlarged.
pub(crate) fn shrink(picture: &Rgb, max_width: u32, max_height: Option<u32>) -> Rgb {
    let mut scale = f64::from(max_width) / f64::from(picture.width);
    if let Some(h) = max_height {
        scale = scale.min(f64::from(h) / f64::from(picture.height));
    }
    if scale >= 1.0 {
        return Rgb {
            width: picture.width,
            height: picture.height,
            pixels: picture.pixels.clone(),
        };
    }
    let width = ((f64::from(picture.width) * scale).round() as u32).max(1);
    let height = ((f64::from(picture.height) * scale).round() as u32).max(1);
    resample(picture, width, height)
}

/// Area average onto `width` x `height`.
fn resample(picture: &Rgb, width: u32, height: u32) -> Rgb {
    let (sw, sh) = (picture.width as usize, picture.height as usize);
    let mut pixels = Vec::with_capacity((width * height * 3) as usize);
    for y in 0..height as usize {
        let y0 = y * sh / height as usize;
        let y1 = ((y + 1) * sh / height as usize).max(y0 + 1).min(sh);
        for x in 0..width as usize {
            let x0 = x * sw / width as usize;
            let x1 = ((x + 1) * sw / width as usize).max(x0 + 1).min(sw);
            let mut sum = [0u64; 3];
            for row in y0..y1 {
                for col in x0..x1 {
                    let at = (row * sw + col) * 3;
                    for (c, total) in sum.iter_mut().enumerate() {
                        *total += u64::from(picture.pixels[at + c]);
                    }
                }
            }
            let count = ((y1 - y0) * (x1 - x0)) as u64;
            pixels.extend(sum.iter().map(|total| (total / count) as u8));
        }
    }
    Rgb { width, height, pixels }
}

pub(crate) fn encode(picture: &Rgb) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, picture.width, picture.height);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(&picture.pixels).ok()?;
    }
    Some(bytes)
}

/// The 64-bit difference hash: 9x8 grey, one bit per left-right step that brightens.
pub(crate) fn dhash(picture: &Rgb) -> u64 {
    let small = resample(picture, 9, 8);
    let grey: Vec<u32> = small
        .pixels
        .chunks_exact(3)
        .map(|p| (u32::from(p[0]) * 299 + u32::from(p[1]) * 587 + u32::from(p[2]) * 114) / 1000)
        .collect();
    let mut hash = 0u64;
    for row in 0..8 {
        for col in 0..8 {
            hash <<= 1;
            if grey[row * 9 + col] < grey[row * 9 + col + 1] {
                hash |= 1;
            }
        }
    }
    hash
}

fn bits(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

// ---- triggers ---------------------------------------------------------------------------------

/// A path an agent edits that can change what the page shows.
pub(crate) fn ui_path(path: &str) -> bool {
    const EXTENSIONS: [&str; 14] = [
        "tsx", "ts", "jsx", "js", "mjs", "css", "scss", "html", "htm", "svg", "swift", "vue",
        "svelte", "json",
    ];
    let lower = path.to_ascii_lowercase();
    let extension = lower.rsplit_once('.').map(|(_, e)| e).unwrap_or_default();
    EXTENSIONS.contains(&extension)
        || lower.contains("/webviews/")
        || lower.contains("/sources/")
        || lower.ends_with("cmux-next.json")
}

/// The paths a tool call record names: its locations, its diffs, its input's `file_path`.
fn named_paths(update: &Value) -> Vec<String> {
    let mut paths = Vec::new();
    if let Some(locations) = update.get("locations").and_then(Value::as_array) {
        paths.extend(locations.iter().filter_map(|l| l.get("path")?.as_str().map(str::to_owned)));
    }
    if let Some(content) = update.get("content").and_then(Value::as_array) {
        paths.extend(
            content
                .iter()
                .filter(|c| c["type"] == "diff")
                .filter_map(|c| c.get("path")?.as_str().map(str::to_owned)),
        );
    }
    for key in ["/rawInput/file_path", "/rawInput/path", "/rawInput/notebook_path"] {
        if let Some(path) = update.pointer(key).and_then(Value::as_str) {
            paths.push(path.to_owned());
        }
    }
    paths
}

/// What a finished tool call asks for: `edit` for a UI file, `build` for a shell call, else none.
pub(crate) fn trigger_of(kind: Option<&str>, update: &Value) -> Option<&'static str> {
    if update.get("status").and_then(Value::as_str) != Some("completed") {
        return None;
    }
    if named_paths(update).iter().any(|p| ui_path(p)) && kind != Some("read") {
        return Some("edit");
    }
    (kind == Some("execute")).then_some("build")
}

/// A tool call that changes the app's own look: an edit of its settings file, or a `cmux customize`,
/// `cmux live`, `cmux app try` or `cmux settings` run.
pub(crate) fn customizes_app(update: &Value) -> bool {
    let settings = named_paths(update).iter().any(|p| {
        let p = p.to_ascii_lowercase();
        p.ends_with("cmux-next.json") || p.ends_with("cmux.json")
    });
    let command = update
        .pointer("/rawInput/command")
        .and_then(|c| c.as_str().map(str::to_owned).or_else(|| Some(c.to_string())))
        .unwrap_or_default();
    settings
        || ["cmux customize", "cmux live", "cmux app try", "cmux settings", "cmux theme"]
            .iter()
            .any(|verb| command.contains(verb))
}

/// The turn began: a new frame list, and its first frame. Nothing for a chat with no workspace.
pub(super) fn turn_began(session: &Session, turn: &str) {
    let workspace =
        session.meta.lock().unwrap_or_else(PoisonError::into_inner).workspace_id.clone();
    let Some(workspace) = workspace else { return };
    if turn_dir(&root(), &session.id, turn).is_none() {
        return;
    }
    turns().insert(
        session.id.clone(),
        Turn {
            id: turn.to_owned(),
            workspace,
            frames: Vec::new(),
            live: true,
            capturing: false,
            again: None,
            debounce: 0,
            kinds: HashMap::new(),
            chrome: false,
        },
    );
    ask(&session.id, "turn-start");
}

/// A record the hub writes: a finished tool call that edited a UI file or ran a shell command asks
/// for a frame once its burst settles.
pub(super) fn record(session: &str, kind: &str, msg: &Value) {
    if !matches!(kind, "tool_call" | "tool_call_update") {
        return;
    }
    let Some(update) = msg.pointer("/params/update") else { return };
    let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default();
    let generation = {
        let mut all = turns();
        let Some(turn) = all.get_mut(session).filter(|t| t.live) else { return };
        if let Some(tool) = update.get("kind").and_then(Value::as_str)
            && !id.is_empty()
            && turn.kinds.len() < 4096
        {
            turn.kinds.insert(id.to_owned(), tool.to_owned());
        }
        let tool =
            update.get("kind").and_then(Value::as_str).or(turn.kinds.get(id).map(String::as_str));
        if customizes_app(update) {
            turn.chrome = true;
        }
        let Some(trigger) = trigger_of(tool, update) else { return };
        turn.debounce += 1;
        (turn.id.clone(), turn.debounce, trigger)
    };
    let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
    let session = session.to_owned();
    let (turn_id, debounce, trigger) = generation;
    runtime.spawn(async move {
        tokio::time::sleep(DEBOUNCE).await;
        let settled = turns()
            .get(&session)
            .is_some_and(|t| t.id == turn_id && t.live && t.debounce == debounce);
        if settled {
            ask(&session, trigger);
        }
    });
}

/// The turn's result was written: its last frame.
pub(super) fn turn_ended(session: &Session, turn: &str) {
    let ours = {
        let mut all = turns();
        match all.get_mut(&session.id).filter(|t| t.id == turn) {
            Some(t) => {
                t.live = false;
                true
            }
            None => false,
        }
    };
    if ours {
        ask(&session.id, "turn-end");
    }
}

/// A turn refused after it began: no more frames come.
pub(super) fn turn_refused(session: &Session, turn: &str) {
    if let Some(t) = turns().get_mut(&session.id).filter(|t| t.id == turn) {
        t.live = false;
    }
}

/// Session `id`'s frames, deleted with its chat. Blocking.
pub(crate) fn remove_session(id: &str) {
    turns().remove(id);
    if let Some(id) = segment(id) {
        let _ = crate::home_fs::remove_dir_all(root().join(id));
    }
}

/// Asks for a frame now; one capture at a time per chat, the newest ask waiting behind it (a turn's
/// end wins over any other).
fn ask(session: &str, trigger: &'static str) {
    {
        let mut all = turns();
        let Some(turn) = all.get_mut(session) else { return };
        if turn.frames.len() >= MAX_FRAMES && trigger != "turn-end" {
            return;
        }
        if turn.capturing {
            if turn.again != Some("turn-end") {
                turn.again = Some(trigger);
            }
            return;
        }
        turn.capturing = true;
    }
    if tokio::runtime::Handle::try_current().is_err() {
        if let Some(turn) = turns().get_mut(session) {
            turn.capturing = false;
        }
        return;
    }
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || {
        let mut trigger = trigger;
        loop {
            take(&session, trigger, REPL_SESSION);
            let mut all = turns();
            let Some(turn) = all.get_mut(&session) else { return };
            match turn.again.take() {
                Some(next) => trigger = next,
                None => {
                    turn.capturing = false;
                    return;
                }
            }
        }
    });
}

/// Takes one frame of `session`'s current turn and keeps it unless it is the same picture as the
/// last kept. The kept frame, or none. Blocking.
fn take(session: &str, trigger: &'static str, repl: &str) -> Option<Frame> {
    let (turn_id, _, dir, picture) = shoot(session, repl)?;
    keep(session, &turn_id, &dir, &picture, trigger, None)
}

/// A picture of `session`'s page now: the agent-driven page of its workspace, else, in a turn that
/// customizes the app, the app's window. The turn, what was shot (a tab id or `window`), the turn's
/// folder and the picture. Blocking.
fn shoot(session: &str, repl: &str) -> Option<(String, String, PathBuf, Rgb)> {
    let (turn_id, workspace, chrome) = {
        let all = turns();
        let turn = all.get(session)?;
        (turn.id.clone(), turn.workspace.clone(), turn.chrome)
    };
    let base = root();
    let dir = turn_dir(&base, session, &turn_id)?;
    crate::home_fs::create_dirs(&dir).ok()?;
    let raw = dir.join(format!("{repl}.capture.png"));
    let mut shown = capture_page(&base, &workspace, &raw, repl, "Turn frames");
    if shown.is_none() && chrome && window_shot(&raw) {
        shown = Some("window".to_owned());
    }
    let bytes = shown.as_ref().and_then(|_| std::fs::read(&raw).ok());
    let _ = crate::home_fs::remove_file(&raw);
    let picture = decode(&bytes?)?;
    Some((turn_id, shown?, dir, picture))
}

/// `cmux window screenshot --out OUT`: the app's window, its private areas masked by the app
/// (`ScreenshotHandlers.swift`). Bounded by [`WINDOW_LIMIT`]; false when no app answered.
fn window_shot(out: &Path) -> bool {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else { return false };
    let binary = crate::login_env::cmux_cli();
    let mut command = tokio::process::Command::new(binary);
    command
        .args(["window", "screenshot", "--out"])
        .arg(out)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let ran = runtime.block_on(async {
        tokio::time::timeout(WINDOW_LIMIT, command.status()).await.ok().and_then(Result::ok)
    });
    ran.is_some_and(|status| status.success())
        && std::fs::metadata(out).is_ok_and(|m| m.len() > 0 && m.len() <= 8 << 20)
}

/// Keeps `picture` as the turn's next frame unless it matches the last kept one (a `turn-end`
/// matching it is still dropped: the strip already shows that picture).
fn keep(
    session: &str,
    turn_id: &str,
    dir: &Path,
    picture: &Rgb,
    trigger: &'static str,
    url: Option<String>,
) -> Option<Frame> {
    let hash = dhash(picture);
    let full = shrink(picture, FULL_WIDTH, None);
    let thumb = shrink(picture, THUMB_WIDTH, None);
    let (full_bytes, thumb_bytes) = (encode(&full)?, encode(&thumb)?);
    let mut all = turns();
    let turn = all.get_mut(session).filter(|t| t.id == turn_id)?;
    let last = turn.frames.last().map(|f| f.hash);
    if last.is_some_and(|last| bits(last, hash) <= SAME) {
        return None;
    }
    let first = turn.frames.first().map(|f| f.hash);
    let frame = Frame {
        index: turn.frames.len(),
        seq: SEQ.fetch_add(1, Ordering::SeqCst) + 1,
        trigger: trigger.to_owned(),
        at: now_ms(),
        width: full.width,
        height: full.height,
        distance: last.map_or(0.0, |l| f64::from(bits(l, hash)) / 64.0),
        moved: first.map_or(0.0, |f| f64::from(bits(f, hash)) / 64.0),
        hash,
        url,
    };
    let written =
        std::fs::write(dir.join(format!("{}.png", frame.index)), &full_bytes).and_then(|()| {
            std::fs::write(dir.join(format!("{}.thumb.png", frame.index)), &thumb_bytes)
        });
    if written.is_err() {
        return None;
    }
    turn.frames.push(frame.clone());
    let index = serde_json::to_vec(&turn.frames).unwrap_or_default();
    drop(all);
    let _ = std::fs::write(dir.join(INDEX), index);
    if frame.index == 0 {
        // A new turn's folder: the oldest turns and chats go.
        if let Some(chat) = dir.parent() {
            prune(chat, KEEP_TURNS);
        }
        prune(&root(), KEEP_CHATS);
    }
    Some(frame)
}

// ---- reads ------------------------------------------------------------------------------------

fn picture_value(bytes: &[u8]) -> Value {
    use base64::Engine as _;
    json!({"mimeType": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(bytes)})
}

fn frame_value(dir: &Path, frame: &Frame, full: bool) -> Option<Value> {
    let thumb = std::fs::read(dir.join(format!("{}.thumb.png", frame.index))).ok()?;
    let mut value = json!({
        "index": frame.index,
        "seq": frame.seq,
        "trigger": frame.trigger,
        "at": frame.at,
        "width": frame.width,
        "height": frame.height,
        "distance": frame.distance,
        "moved": frame.moved,
        "thumb": picture_value(&thumb),
    });
    if full && let Ok(bytes) = std::fs::read(dir.join(format!("{}.png", frame.index))) {
        value["full"] = picture_value(&bytes);
    }
    Some(value)
}

fn read_index(dir: &Path) -> Vec<Frame> {
    std::fs::read(dir.join(INDEX))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// `_acpmux/turn_frames`:
/// - `{sessionId, turnId}`: the turn's frames, thumbnails only (`{frames: [...]}`);
/// - `{sessionId, turnId, index}`: that frame with its `full` picture;
/// - `{sessionId, sinceSeq}`: the chat's newest frame after `sinceSeq` with its `full` picture, or
///   none (`{frames, seq, turnId, live}`), for the live preview window.
pub(crate) async fn turn_frames(session: &str, params: &Value) -> Value {
    let session = session.to_owned();
    let params = params.clone();
    tokio::task::spawn_blocking(move || read(&session, &params))
        .await
        .unwrap_or_else(|_| json!({"frames": []}))
}

fn read(session: &str, params: &Value) -> Value {
    let base = root();
    if let Some(turn) = params.get("turnId").and_then(Value::as_str) {
        let Some(dir) = turn_dir(&base, session, turn) else {
            return json!({"sessionId": session, "turnId": turn, "frames": []});
        };
        let index = params.get("index").and_then(Value::as_u64).map(|i| i as usize);
        let frames: Vec<Value> = read_index(&dir)
            .iter()
            .filter(|f| index.is_none_or(|i| f.index == i))
            .filter_map(|f| frame_value(&dir, f, index.is_some()))
            .collect();
        return json!({"sessionId": session, "turnId": turn, "frames": frames});
    }
    let since = params.get("sinceSeq").and_then(Value::as_u64).unwrap_or(0);
    let (turn_id, live, newest) = {
        let all = turns();
        let Some(turn) = all.get(session) else {
            return json!({"sessionId": session, "frames": [], "seq": since, "live": false});
        };
        let newest = turn.frames.iter().rev().find(|f| f.seq > since).cloned();
        (turn.id.clone(), turn.live, newest)
    };
    let seq = newest.as_ref().map_or(since, |f| f.seq);
    let frames: Vec<Value> = match (turn_dir(&base, session, &turn_id), &newest) {
        (Some(dir), Some(frame)) => frame_value(&dir, frame, true).into_iter().collect(),
        _ => Vec::new(),
    };
    json!({"sessionId": session, "turnId": turn_id, "frames": frames, "seq": seq, "live": live})
}

/// `_acpmux/turn_frames {sessionId, look: true}`: a frame now (kept as `look` when the page moved),
/// handed back at most [`LOOK_EDGE`] px on its long edge with one line of where it is: the `look`
/// MCP tool. With no page, the reason.
pub(crate) async fn look(session: &str) -> Value {
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || look_now(&session))
        .await
        .unwrap_or_else(|_| json!({"error": "the capture stopped"}))
}

fn look_now(session: &str) -> Value {
    if !turns().contains_key(session) {
        return json!({"error": "this chat has no workspace page to look at: open the page with the browser or `open` tools first"});
    }
    // A look may always see the app's own window: the agent asked.
    if let Some(turn) = turns().get_mut(session) {
        turn.chrome = true;
    }
    let Some((turn_id, tab, dir, picture)) = shoot(session, LOOK_REPL_SESSION) else {
        return json!({"error": "no agent-driven page is showing in this chat's workspace and the app's window could not be captured: open a page with the browser or `open` tools, then look again"});
    };
    let kept = keep(session, &turn_id, &dir, &picture, "look", None);
    let hash = dhash(&picture);
    let first = turns().get(session).and_then(|t| t.frames.first().map(|f| f.hash));
    let moved = first.map_or(0, |f| bits(f, hash));
    let small = shrink(&picture, LOOK_EDGE, Some(LOOK_EDGE));
    let Some(png) = encode(&small) else {
        return json!({"error": "the picture could not be encoded"});
    };
    json!({
        "image": picture_value(&png),
        "width": small.width,
        "height": small.height,
        "tab": tab,
        "movedBits": moved,
        "kept": kept.map(|f| f.index),
        "turnId": turn_id,
    })
}

#[cfg(test)]
#[path = "turn_frames_tests.rs"]
mod tests;
