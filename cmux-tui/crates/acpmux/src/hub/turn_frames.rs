//! Live frames of the chat's page while an agent works: the strip of pictures between a turn's
//! before and after (`turn_shots.rs`). Leo: "the agent needs to be able to simply go ahead with
//! it, and then we can deterministically do the vast majority of the work without adding
//! unnecessary context to it... especially sometimes the agent may be able to call in as it works
//! to look at the image OR COMPUTER USE AN INTERACTION AS IT WORKS."
//!
//! So the daemon takes the pictures itself, at no cost in the agent's tokens, of the same tab
//! `turn_shots` pictures (the chat workspace's selected live tab an agent drove), at:
//! - the turn's start and end: `turn_shots`' before and after are handed in (`start`, `end`),
//!   and when it took none (no page at the start, an agent opened one) the end is taken here;
//! - an edit or write of a UI file ([`is_ui_path`]), [`DEBOUNCE`] after the last such tool call
//!   or its completion (`edit`), from the hub's tool call records ([`tool_record`]);
//! - the agent's own ask, the `look` MCP tool (`look`, [`look`]).
//!
//! Each frame keeps its PNG, a JPEG thumbnail [`THUMB_WIDTH`] wide and a 64-bit dHash; a frame
//! within [`SAME_FRAME`] bits of the last kept one is dropped (nothing changed on screen). At most
//! [`MAX_FRAMES`] per turn: past that a new frame takes the last one's place, so the strip keeps
//! its history and its newest picture. `_acpmux/turn_frames` reads them, `sinceSeq` only the new
//! ones for a poller, and `_acpmux/look` takes one now for the agent.
//!
//! Disk: `<ACPMUX_HOME>/turn-frames/<session>/<turn>/{frames.json,NNN.png,NNN.jpg}`, the
//! [`super::turn_shots::KEEP_TURNS`] newest turns of a chat and
//! [`super::turn_shots::KEEP_CHATS`] chats; full PNGs past [`MAX_TURN_IMAGE_BYTES`] in one turn
//! keep their thumbnail only. A deleted chat's go with it. Unix only, as `turn_shots`.

use super::Session;
use super::turn_shots::{self, KEEP_CHATS, KEEP_TURNS, MAX_SHOT_BYTES};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::Duration;

/// Frames kept per turn.
pub(crate) const MAX_FRAMES: usize = 24;
/// A frame whose dHash is within this many bits of the last kept frame's shows nothing new.
pub(crate) const SAME_FRAME: u32 = 4;
/// How long after the last UI edit of a burst its frame is taken.
pub(crate) const DEBOUNCE: Duration = Duration::from_millis(1500);
/// A thumbnail's width (never scaled up).
pub(crate) const THUMB_WIDTH: u32 = 320;
/// The `look` picture's long edge.
pub(crate) const LOOK_EDGE: u32 = 512;
/// Full PNGs one turn keeps; past it a frame keeps its thumbnail only.
pub(crate) const MAX_TURN_IMAGE_BYTES: u64 = 32 << 20;
/// Pixels a picture may have to be read at all (a 8K by 8K page).
const MAX_PIXELS: u64 = 64 << 20;
const JPEG_QUALITY: u8 = 72;
const INDEX: &str = "frames.json";
/// This daemon's REPL session on the browser host for frames: its own, so a frame never waits on
/// a before or after in `turn_shots`' session.
const REPL_SESSION: &str = "acpmux-turn-frames";

/// What took a frame.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Trigger {
    Start,
    Edit,
    End,
    Look,
}

impl Trigger {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Trigger::Start => "start",
            Trigger::Edit => "edit",
            Trigger::End => "end",
            Trigger::Look => "look",
        }
    }
}

/// One kept frame, as `frames.json` holds it and `_acpmux/turn_frames` answers it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Frame {
    /// Its place in the turn's strip, from 0.
    pub index: usize,
    /// When it was kept, after every frame kept before it on this machine: a poller's `sinceSeq`.
    pub seq: u64,
    /// `start`, `edit`, `end` or `look`.
    pub trigger: String,
    /// Unix ms.
    pub at: u64,
    pub width: u32,
    pub height: u32,
    /// The 64-bit dHash, 16 hex digits.
    pub hash: String,
    /// Bits from the frame before it; none for the first.
    pub distance: Option<u32>,
    /// Bits from the turn's first frame.
    pub first_distance: u32,
    /// The page's address when it was taken.
    pub url: Option<String>,
    pub thumbnail_width: u32,
    pub thumbnail_height: u32,
    /// Whether its full PNG is kept (`_acpmux/turn_frames` with `index`).
    pub has_image: bool,
}

/// A picture read for a frame: its size, dHash, thumbnail and, when asked, the `look` copy.
pub(crate) struct Picture {
    pub width: u32,
    pub height: u32,
    pub hash: u64,
    pub thumb: Vec<u8>,
    pub thumb_size: (u32, u32),
    pub look: Option<(Vec<u8>, u32, u32)>,
}

/// The size of a `w`x`h` thumbnail: [`THUMB_WIDTH`] wide, never up.
fn thumb_size(w: u32, h: u32) -> (u32, u32) {
    if w <= THUMB_WIDTH {
        return (w.max(1), h.max(1));
    }
    let h = (u64::from(h) * u64::from(THUMB_WIDTH)).div_ceil(u64::from(w)).max(1);
    (THUMB_WIDTH, h.min(u64::from(u16::MAX)) as u32)
}

/// Reads a PNG once, a row at a time, into its thumbnail, its dHash and (with `look`) its `look`
/// copy. None for a PNG that is not valid, is interlaced or is too large.
pub(crate) fn analyze(png_bytes: &[u8], look: bool) -> Option<Picture> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png_bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    decoder.set_limits(png::Limits { bytes: 256 << 20 });
    let mut reader = decoder.read_info().ok()?;
    let (w, h) = (reader.info().width, reader.info().height);
    if reader.info().interlaced || w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return None;
    }
    let channels = match reader.output_color_type().0 {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return None,
    };
    let (tw, th) = thumb_size(w, h);
    let mut thumb = cmux_image_linear::Downscaler::new(w, h, tw, th, false);
    let mut hash = cmux_image_linear::Downscaler::new(w, h, 9, 8, false);
    let mut looked = look.then(|| {
        let (lw, lh) = cmux_image_linear::fit(w, h, LOOK_EDGE);
        cmux_image_linear::Downscaler::new(w, h, lw, lh, false)
    });
    for _ in 0..h {
        let row = reader.next_row().ok()??;
        let pixels = row.data().chunks_exact(channels).take(w as usize).map(|px| match px {
            [g] => [*g, *g, *g, 255],
            [g, a] => [*g, *g, *g, *a],
            [r, g, b] => [*r, *g, *b, 255],
            [r, g, b, a] => [*r, *g, *b, *a],
            _ => [0; 4],
        });
        // Collected once: three scalers read the same row.
        let pixels: Vec<[u8; 4]> = pixels.collect();
        thumb.push_row(pixels.iter().copied());
        hash.push_row(pixels.iter().copied());
        if let Some(scaler) = looked.as_mut() {
            scaler.push_row(pixels.iter().copied());
        }
    }
    let hash_size = hash.output_size();
    let hash = dhash(&hash.finish(), hash_size);
    let thumb_size = thumb.output_size();
    let thumb = jpeg(&thumb.finish(), thumb_size)?;
    let look = match looked {
        Some(scaler) => {
            let size = scaler.output_size();
            Some((jpeg(&scaler.finish(), size)?, size.0, size.1))
        }
        None => None,
    };
    Some(Picture { width: w, height: h, hash, thumb, thumb_size, look })
}

/// `rgb` pixels as a JPEG.
fn jpeg(rgb: &[u8], (w, h): (u32, u32)) -> Option<Vec<u8>> {
    let (w16, h16) = (u16::try_from(w).ok()?, u16::try_from(h).ok()?);
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, JPEG_QUALITY)
        .encode(rgb, w16, h16, jpeg_encoder::ColorType::Rgb)
        .ok()?;
    Some(out)
}

/// The difference hash of a 9x8 RGB picture (`size` as the scaler gave it): bit `8y+x` is set
/// when pixel `x` of row `y` is brighter than the one right of it.
pub(crate) fn dhash(rgb: &[u8], (w, h): (u32, u32)) -> u64 {
    let luma = |x: u32, y: u32| -> u32 {
        let (x, y) = (x.min(w.saturating_sub(1)), y.min(h.saturating_sub(1)));
        let at = ((y * w + x) * 3) as usize;
        match rgb.get(at..at + 3) {
            Some([r, g, b]) => u32::from(*r) * 299 + u32::from(*g) * 587 + u32::from(*b) * 114,
            _ => 0,
        }
    };
    let mut bits = 0u64;
    for y in 0..8 {
        for x in 0..8 {
            if luma(x, y) > luma(x + 1, y) {
                bits |= 1 << (y * 8 + x);
            }
        }
    }
    bits
}

/// The bits two hashes differ in.
pub(crate) fn distance(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

fn parse_hash(hex: &str) -> Option<u64> {
    u64::from_str_radix(hex, 16).ok()
}

/// What a new frame does to a turn's strip.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Place {
    /// Within [`SAME_FRAME`] of the last kept frame: not kept.
    Same,
    /// Kept at the end.
    Append,
    /// The strip is full ([`MAX_FRAMES`]): it takes the last frame's place, at this index.
    Replace(usize),
}

/// Where a frame of `hash` goes in `frames`.
pub(crate) fn place(frames: &[Frame], hash: u64) -> Place {
    if let Some(last) = frames.last() {
        if parse_hash(&last.hash).is_some_and(|h| distance(h, hash) <= SAME_FRAME) {
            return Place::Same;
        }
        if frames.len() >= MAX_FRAMES {
            return Place::Replace(last.index);
        }
    }
    Place::Append
}

/// Whether an edit of `path` is a UI file whose page a frame may show.
pub(crate) fn is_ui_path(path: &str) -> bool {
    const EXTENSIONS: &[&str] =
        &["tsx", "ts", "jsx", "css", "scss", "html", "htm", "swift", "vue", "svelte"];
    let path = path.replace('\\', "/");
    if path.split('/').any(|part| part == "webviews" || part == "Sources") {
        return true;
    }
    let name = path.rsplit('/').next().unwrap_or_default();
    name.rsplit_once('.').is_some_and(|(stem, ext)| {
        !stem.is_empty() && EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str())
    })
}

/// The files a `tool_call` or `tool_call_update` names: its locations, its diffs' paths and its
/// input's path.
fn record_paths(update: &Value) -> impl Iterator<Item = &str> {
    let locations = update.get("locations").and_then(Value::as_array).into_iter().flatten();
    let diffs = update
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("diff"));
    let input = ["file_path", "path", "notebook_path"]
        .into_iter()
        .filter_map(|key| update.pointer(&format!("/rawInput/{key}"))?.as_str());
    locations.chain(diffs).filter_map(|item| item.get("path")?.as_str()).chain(input)
}

/// What a tool call record says for frames: an edit of a UI file (with its call id), or the
/// completion of a call (by its id).
#[derive(Clone, PartialEq, Eq, Debug)]
pub(crate) enum Seen {
    UiEdit(Option<String>),
    Completed(String),
}

/// A `tool_call` or `tool_call_update` record's meaning for frames, read without any lock.
pub(crate) fn seen(kind: &str, msg: &Value) -> Option<Seen> {
    if !matches!(kind, "tool_call" | "tool_call_update") {
        return None;
    }
    let update = msg.pointer("/params/update")?;
    let id = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned);
    let edit = update.get("kind").and_then(Value::as_str) == Some("edit")
        || update.get("content").and_then(Value::as_array).is_some_and(|c| {
            c.iter().any(|i| i.get("type").and_then(Value::as_str) == Some("diff"))
        });
    if edit && record_paths(update).any(is_ui_path) {
        return Some(Seen::UiEdit(id));
    }
    let done = matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
    done.then_some(id).flatten().map(Seen::Completed)
}

/// A turn whose frames are being taken.
struct Live {
    turn: String,
    workspace: String,
    /// The tab its frames show, once one was taken.
    tab: Option<String>,
    url: Option<String>,
    /// Bumped by each UI edit: a debounced capture runs only if none came after it.
    edits: u64,
    /// The UI edit calls not yet completed: their completion arms the debounce again.
    edit_calls: HashSet<String>,
    /// Held while a frame is written, so frames land one at a time.
    write: Arc<Mutex<()>>,
}

/// The running turn of each chat with a workspace, by session.
static LIVE: LazyLock<Mutex<HashMap<String, Live>>> = LazyLock::new(Default::default);
static SEQ: AtomicU64 = AtomicU64::new(0);

fn live() -> std::sync::MutexGuard<'static, HashMap<String, Live>> {
    LIVE.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// The next frame's seq: past every earlier one, and past the clock in ms, so a poller's
/// `sinceSeq` stays right across a restart.
fn next_seq() -> u64 {
    let now = now_ms();
    let prev = SEQ.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |s| Some(s.max(now) + 1));
    prev.unwrap_or(0).max(now) + 1
}

pub(crate) fn root() -> PathBuf {
    crate::config::home().join("turn-frames")
}

/// The UI edit seen in a record, for the session's running turn: the debounce generation to fire
/// at, or none (not a UI edit, no such turn, or the completion of a call that was no UI edit).
pub(crate) fn note_edit(session: &str, seen: &Seen) -> Option<(String, u64)> {
    let mut all = live();
    let turn = all.get_mut(session)?;
    match seen {
        Seen::UiEdit(id) => {
            if let Some(id) = id {
                turn.edit_calls.insert(id.clone());
            }
        }
        Seen::Completed(id) => {
            if !turn.edit_calls.remove(id) {
                return None;
            }
        }
    }
    turn.edits += 1;
    Some((turn.turn.clone(), turn.edits))
}

/// Whether the debounced capture armed at `edits` is still the newest of the session's turn.
pub(crate) fn still_newest(session: &str, turn: &str, edits: u64) -> bool {
    live().get(session).is_some_and(|t| t.turn == turn && t.edits == edits)
}

/// The hub's hook on every live tool call record (`Hub::append_at`): an edit or write of a UI file
/// takes a frame [`DEBOUNCE`] after the last of its burst. Cheap for every other record: no lock
/// unless the record is a UI edit or a call's completion.
pub(super) fn tool_record(scope: &cmux_scope::Scope, session: &Session, kind: &str, msg: &Value) {
    let Some(seen) = seen(kind, msg) else { return };
    let Some((turn, edits)) = note_edit(&session.id, &seen) else { return };
    let id = session.id.clone();
    scope.spawn_named("turn-frames-edit", async move {
        tokio::time::sleep(DEBOUNCE).await;
        if still_newest(&id, &turn, edits) {
            let _ =
                tokio::task::spawn_blocking(move || capture_now(&id, &turn, Trigger::Edit, false))
                    .await;
        }
    });
}

/// A turn of a chat with a workspace began: its frames start (`turn_shots::turn_began`). An older
/// turn of the chat that never ended stops taking frames.
pub(super) fn turn_began(session: &str, turn: &str, workspace: &str) {
    live().insert(
        session.to_owned(),
        Live {
            turn: turn.to_owned(),
            workspace: workspace.to_owned(),
            tab: None,
            url: None,
            edits: 0,
            edit_calls: HashSet::new(),
            write: Arc::default(),
        },
    );
    let base = root();
    tokio::task::spawn_blocking(move || {
        prune_all(&base);
    });
}

/// `turn_shots`' before, taken at the turn's start: the strip's first frame. Blocking.
pub(super) fn start_shot(key: &(String, String), png: &Path, tab: &str, url: Option<&str>) {
    {
        let mut all = live();
        let Some(turn) = all.get_mut(&key.0).filter(|t| t.turn == key.1) else { return };
        turn.tab.get_or_insert_with(|| tab.to_owned());
        if url.is_some() {
            turn.url = url.map(str::to_owned);
        }
    }
    if let Ok(bytes) = std::fs::read(png) {
        let _ = keep(&root(), key, &bytes, Trigger::Start, url, false);
    }
}

/// The turn ended (`turn_shots::turn_ended`): `turn_shots`' after (its PNG, tab and address) is
/// its last frame, or with none one is taken here. Then the turn stops taking frames and keeps
/// them, or its folder goes when it has none. Blocking.
pub(super) fn end_shot(key: &(String, String), after: Option<(&Path, &str, Option<&str>)>) {
    let known = {
        let mut all = live();
        match all.get_mut(&key.0).filter(|t| t.turn == key.1) {
            Some(turn) => {
                // A debounced edit still waiting takes no frame now.
                turn.edits += 1;
                true
            }
            None => false,
        }
    };
    if !known {
        return;
    }
    let base = root();
    match after.and_then(|(png, _, url)| Some((std::fs::read(png).ok()?, url))) {
        Some((bytes, url)) => {
            let _ = keep(&base, key, &bytes, Trigger::End, url, false);
        }
        None => {
            let _ = capture_now(&key.0, &key.1, Trigger::End, false);
        }
    }
    let mut all = live();
    if all.get(&key.0).is_some_and(|t| t.turn == key.1) {
        all.remove(&key.0);
    }
    drop(all);
    if let Some(dir) = turn_shots::turn_dir(&base, &key.0, &key.1)
        && read_index(&dir).is_empty()
    {
        turn_shots::drop_turn(&dir);
    }
}

/// A turn refused after it started keeps no frames.
pub(super) fn turn_refused(session: &str, turn: &str) {
    let mut all = live();
    if all.get(session).is_some_and(|t| t.turn == turn) {
        all.remove(session);
    }
    drop(all);
    if let Some(dir) = turn_shots::turn_dir(&root(), session, turn) {
        tokio::task::spawn_blocking(move || turn_shots::drop_turn(&dir));
    }
}

/// Session `id`'s frames, deleted with its chat. Blocking.
pub(crate) fn remove_session(id: &str) {
    live().remove(id);
    if let Some(id) = turn_shots::segment(id) {
        let _ = crate::home_fs::remove_dir_all(root().join(id));
    }
}

/// The newest [`KEEP_TURNS`] turns of each chat and [`KEEP_CHATS`] chats stay.
pub(crate) fn prune_all(base: &Path) {
    if let Ok(chats) = std::fs::read_dir(base) {
        for chat in chats.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())) {
            turn_shots::prune(&chat.path(), KEEP_TURNS);
        }
    }
    turn_shots::prune(base, KEEP_CHATS);
}

fn read_index(dir: &Path) -> Vec<Frame> {
    std::fs::read(dir.join(INDEX))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn frame_file(dir: &Path, index: usize, ext: &str) -> PathBuf {
    dir.join(format!("{index:03}.{ext}"))
}

/// What keeping a picture did: the frame (kept or not) and the `look` copy when asked.
pub(crate) struct Kept {
    pub frame: Frame,
    pub kept: bool,
    pub look: Option<(Vec<u8>, u32, u32)>,
}

/// Keeps the PNG `bytes` as the turn's next frame unless it shows the same as the last one.
/// Blocking.
pub(crate) fn keep(
    base: &Path,
    key: &(String, String),
    bytes: &[u8],
    trigger: Trigger,
    url: Option<&str>,
    look: bool,
) -> Option<Kept> {
    let dir = turn_shots::turn_dir(base, &key.0, &key.1)?;
    let lock = live().get(&key.0).filter(|t| t.turn == key.1).map(|t| t.write.clone())?;
    let picture = analyze(bytes, look)?;
    let _write = lock.lock().unwrap_or_else(PoisonError::into_inner);
    crate::home_fs::create_dirs(&dir).ok()?;
    let mut frames = read_index(&dir);
    let first = frames.first().and_then(|f| parse_hash(&f.hash));
    let last = frames.last().and_then(|f| parse_hash(&f.hash));
    let placed = place(&frames, picture.hash);
    let index = match placed {
        Place::Same => frames.last().map_or(0, |f| f.index),
        Place::Append => frames.len(),
        Place::Replace(index) => index,
    };
    let kept_bytes: u64 = frames
        .iter()
        .filter(|f| f.has_image && f.index != index)
        .filter_map(|f| std::fs::metadata(frame_file(&dir, f.index, "png")).ok())
        .map(|m| m.len())
        .sum();
    let has_image =
        bytes.len() <= MAX_SHOT_BYTES && kept_bytes + bytes.len() as u64 <= MAX_TURN_IMAGE_BYTES;
    let frame = Frame {
        index,
        seq: if placed == Place::Same { frames.last().map_or(0, |f| f.seq) } else { next_seq() },
        trigger: trigger.as_str().to_owned(),
        at: now_ms(),
        width: picture.width,
        height: picture.height,
        hash: format!("{:016x}", picture.hash),
        distance: last.map(|h| distance(h, picture.hash)),
        first_distance: first.map_or(0, |h| distance(h, picture.hash)),
        url: url.map(str::to_owned),
        thumbnail_width: picture.thumb_size.0,
        thumbnail_height: picture.thumb_size.1,
        has_image,
    };
    if placed == Place::Same {
        return Some(Kept { frame, kept: false, look: picture.look });
    }
    let write = |path: PathBuf, data: &[u8]| crate::config::write_atomic_unsynced(&path, data).ok();
    write(frame_file(&dir, index, "jpg"), &picture.thumb)?;
    if has_image {
        write(frame_file(&dir, index, "png"), bytes)?;
    } else {
        let _ = crate::home_fs::remove_file(frame_file(&dir, index, "png"));
    }
    frames.retain(|f| f.index != index);
    frames.push(frame.clone());
    frames.sort_by_key(|f| f.index);
    write(dir.join(INDEX), &serde_json::to_vec(&frames).ok()?)?;
    Some(Kept { frame, kept: true, look: picture.look })
}

/// Takes a frame of the turn's tab now (its first: whichever page of the workspace an agent drove
/// is shown). None when there is no such turn or page. Blocking, bounded by the capture's limit.
pub(crate) fn capture_now(session: &str, turn: &str, trigger: Trigger, look: bool) -> Option<Kept> {
    let (workspace, tab) = {
        let all = live();
        let t = all.get(session).filter(|t| t.turn == turn)?;
        (t.workspace.clone(), t.tab.clone())
    };
    let base = root();
    let dir = turn_shots::turn_dir(&base, session, turn)?;
    crate::home_fs::create_dirs(&dir).ok()?;
    let out = dir.join(format!("capture-{}.png", next_seq()));
    let shot = turn_shots::capture(
        &turn_shots::host_socket(),
        REPL_SESSION,
        &base,
        &workspace,
        tab.as_deref(),
        &out,
    );
    let bytes = shot.as_ref().and_then(|_| std::fs::read(&out).ok());
    let _ = crate::home_fs::remove_file(&out);
    let (id, url) = shot?;
    {
        let mut all = live();
        if let Some(t) = all.get_mut(session).filter(|t| t.turn == turn) {
            t.tab.get_or_insert(id);
            t.url = url.clone();
        }
    }
    keep(&base, &(session.to_owned(), turn.to_owned()), &bytes?, trigger, url.as_deref(), look)
}

/// The turn a read means: `turn` when given, else the chat's running turn, else its newest turn
/// with frames.
fn which_turn(base: &Path, session: &str, turn: Option<&str>) -> Option<String> {
    if let Some(turn) = turn {
        return Some(turn.to_owned());
    }
    if let Some(t) = live().get(session) {
        return Some(t.turn.clone());
    }
    let chat = base.join(turn_shots::segment(session)?);
    std::fs::read_dir(chat)
        .ok()?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.file_name())))
        .max_by_key(|(at, _)| *at)
        .and_then(|(_, name)| name.into_string().ok())
}

fn data_url(mime: &str, bytes: &[u8]) -> String {
    use base64::Engine as _;
    format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// `_acpmux/turn_frames` read from `base`. Blocking.
pub(crate) fn read_frames(
    base: &Path,
    session: &str,
    turn: Option<&str>,
    since: Option<u64>,
    index: Option<usize>,
) -> Value {
    let turn = which_turn(base, session, turn);
    let live_turn = live().get(session).map(|t| t.turn.clone());
    let running = turn.is_some() && turn == live_turn;
    let dir = turn.as_deref().and_then(|t| turn_shots::turn_dir(base, session, t));
    let frames = dir.as_deref().map(read_index).unwrap_or_default();
    let seq = frames.iter().map(|f| f.seq).max().unwrap_or(0);
    let rows: Vec<Value> = frames
        .iter()
        .filter(|f| since.is_none_or(|s| f.seq > s))
        .filter(|f| index.is_none_or(|i| f.index == i))
        .filter_map(|f| {
            let dir = dir.as_deref()?;
            let mut row = serde_json::to_value(f).ok()?;
            let thumb = std::fs::read(frame_file(dir, f.index, "jpg")).ok()?;
            row["thumbnail"] = json!(data_url("image/jpeg", &thumb));
            if index.is_some() && f.has_image {
                let full = std::fs::read(frame_file(dir, f.index, "png")).ok();
                row["image"] = json!(full.map(|b| data_url("image/png", &b)));
            }
            Some(row)
        })
        .collect();
    json!({
        "sessionId": session,
        "turnId": turn,
        "live": running,
        "seq": seq,
        "frames": rows,
    })
}

/// `_acpmux/turn_frames {sessionId, turnId?, sinceSeq?, index?}`: the turn's frames with their
/// thumbnails, only those past `sinceSeq` with it, and with `index` that one frame and its full PNG.
pub(crate) async fn turn_frames(
    session: &str,
    turn: Option<&str>,
    since: Option<u64>,
    index: Option<usize>,
) -> Value {
    let (session, turn) = (session.to_owned(), turn.map(str::to_owned));
    let read = {
        let session = session.clone();
        move || read_frames(&root(), &session, turn.as_deref(), since, index)
    };
    tokio::task::spawn_blocking(read)
        .await
        .unwrap_or_else(|_| json!({"sessionId": session, "frames": []}))
}

/// The newest kept frame of a turn and its `look` copy, from its full PNG (else its thumbnail,
/// which is a JPEG already). Blocking.
fn latest_look(base: &Path, session: &str, turn: &str) -> Option<(Frame, Vec<u8>, u32, u32)> {
    let dir = turn_shots::turn_dir(base, session, turn)?;
    let frame = read_index(&dir).into_iter().max_by_key(|f| f.seq)?;
    if frame.has_image
        && let Ok(png) = std::fs::read(frame_file(&dir, frame.index, "png"))
        && let Some((jpeg, w, h)) = analyze(&png, true).and_then(|p| p.look)
    {
        return Some((frame, jpeg, w, h));
    }
    let thumb = std::fs::read(frame_file(&dir, frame.index, "jpg")).ok()?;
    let (w, h) = (frame.thumbnail_width, frame.thumbnail_height);
    Some((frame, thumb, w, h))
}

/// `_acpmux/look {sessionId, capture?}`: a frame of the chat's page now (`capture`, the default),
/// or the turn's newest one, with a [`LOOK_EDGE`] JPEG of it for the agent. Takes a frame outside
/// a turn too (kept nowhere) when the chat has a workspace.
pub(crate) async fn look(session: &Session, capture: bool) -> Value {
    let id = session.id.clone();
    let workspace =
        session.meta.lock().unwrap_or_else(PoisonError::into_inner).workspace_id.clone();
    let answer = tokio::task::spawn_blocking(move || look_blocking(&id, workspace, capture))
        .await
        .unwrap_or_else(|_| json!({"captured": false, "reason": "the capture failed"}));
    let mut answer = answer;
    answer["sessionId"] = json!(session.id);
    answer
}

fn look_blocking(session: &str, workspace: Option<String>, capture: bool) -> Value {
    let turn = live().get(session).map(|t| t.turn.clone());
    let base = root();
    let image = |jpeg: &[u8], w: u32, h: u32| {
        use base64::Engine as _;
        json!({"mimeType": "image/jpeg", "data": base64::engine::general_purpose::STANDARD.encode(jpeg), "width": w, "height": h})
    };
    if capture {
        if let Some(turn) = &turn
            && let Some(kept) = capture_now(session, turn, Trigger::Look, true)
            && let Some((jpeg, w, h)) = &kept.look
        {
            return json!({
                "turnId": turn,
                "captured": true,
                "kept": kept.kept,
                "url": kept.frame.url,
                "firstDistance": kept.frame.first_distance,
                "frame": kept.frame,
                "image": image(jpeg, *w, *h),
            });
        }
        // No running turn: a picture of the workspace's page, kept nowhere.
        if turn.is_none()
            && let Some(workspace) = &workspace
            && let Some(answer) = look_outside_turn(&base, workspace)
        {
            return answer;
        }
    }
    let turn = which_turn(&base, session, turn.as_deref());
    match turn.as_deref().and_then(|t| latest_look(&base, session, t)) {
        Some((frame, jpeg, w, h)) => json!({
            "turnId": turn,
            "captured": false,
            "kept": true,
            "url": frame.url,
            "firstDistance": frame.first_distance,
            "frame": frame,
            "image": image(&jpeg, w, h),
        }),
        None => json!({
            "turnId": turn,
            "captured": false,
            "reason": if workspace.is_none() {
                "this chat has no cmux workspace, so it has no page to picture"
            } else {
                "no page an agent opened is shown in this chat's workspace: open one with cmux browser first"
            },
        }),
    }
}

fn look_outside_turn(base: &Path, workspace: &str) -> Option<Value> {
    crate::home_fs::create_dirs(base).ok()?;
    let out = base.join(format!("look-{}.png", next_seq()));
    let shot =
        turn_shots::capture(&turn_shots::host_socket(), REPL_SESSION, base, workspace, None, &out);
    let bytes = shot.as_ref().and_then(|_| std::fs::read(&out).ok());
    let _ = crate::home_fs::remove_file(&out);
    let (_, url) = shot?;
    let picture = analyze(&bytes?, true)?;
    let (jpeg, w, h) = picture.look?;
    use base64::Engine as _;
    Some(json!({
        "turnId": null,
        "captured": true,
        "kept": false,
        "url": url,
        "firstDistance": 0,
        "image": {"mimeType": "image/jpeg", "data": base64::engine::general_purpose::STANDARD.encode(jpeg), "width": w, "height": h},
    }))
}

#[cfg(test)]
#[path = "turn_frames_tests.rs"]
mod tests;
