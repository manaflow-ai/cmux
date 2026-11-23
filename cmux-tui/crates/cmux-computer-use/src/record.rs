//! Recording a display to a video file (the `record` tool).
//!
//! A recording is a thread in the engine's process that takes one display
//! capture per frame, through the same policy path as a display screenshot
//! (denied, protected and Never apps are left out by the capture system
//! where it can and painted out otherwise, read again for every frame),
//! gives each frame to the desktop's H.264 encoder and writes an MP4
//! ([`mp4`]). It lives in the engine, not in the caller: `start` returns at
//! once, no connection is held open, and the recording ends by itself at
//! `max_seconds`, when the screen locks, when Computer Use is turned off or
//! when the person stops the session, so a caller that crashed never leaves
//! one running.
//!
//! The file is written into the engine's own private folder; a caller never
//! names a path (an Observe tool must not write files where an agent says).
//! The result names the file, and `read` returns its bytes in pieces to a
//! caller on another machine.

pub mod mp4;
pub mod synthetic;

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::desktop::{App, CaptureTarget, Desktop, DesktopError, RawFrame, Rect};
use crate::frame;
use crate::policy::{self, PolicyConfig, SavedApprovals, TargetApp};
use crate::session::Sessions;
use crate::stop::Stops;

/// No recording runs longer than this, whatever the caller asks.
pub const MAX_SECONDS: f64 = 1800.0;
/// `start` without `max_seconds`.
pub const DEFAULT_MAX_SECONDS: f64 = 300.0;
pub const DEFAULT_FPS: u32 = 10;
pub const MAX_FPS: u32 = 30;
/// The picture's long edge, in pixels, unless the caller asks otherwise.
pub const DEFAULT_MAX_EDGE: u32 = 1920;
pub const MIN_MAX_EDGE: u32 = 320;
pub const MAX_MAX_EDGE: u32 = 3840;
/// The bytes one `read` returns (base64 of it stays well under the 1 MiB a
/// daemon reply may be).
pub const READ_CHUNK: usize = 256 * 1024;
/// A keyframe at least this often, so a player can seek.
const KEY_EVERY: Duration = Duration::from_secs(2);
/// Finished recordings the engine remembers (and keeps the files of).
const KEEP: usize = 8;
const FILE_PREFIX: &str = "cmux-recording-";

/// Turns frames into H.264. One per recording, made by the desktop
/// ([`Desktop::frame_encoder`]) for one picture size.
pub trait FrameEncoder: Send {
    /// Encodes one frame of the size the encoder was made for, captured `at`
    /// after the start. Returns one Annex-B access unit, with the parameter
    /// sets (SPS, PPS) before every keyframe; empty when the encoder skipped
    /// the frame.
    fn encode(
        &mut self,
        frame: &RawFrame,
        force_key: bool,
        at: Duration,
    ) -> Result<Vec<u8>, String>;
    fn name(&self) -> String;
}

/// A refusal or failure with its tool-result code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordError {
    pub code: String,
    pub message: String,
}

impl RecordError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_string(), message: message.into() }
    }
    fn desktop(e: &DesktopError) -> Self {
        Self::new(e.code(), e.to_string())
    }
}

/// A finished recording, as its file reads back.
#[derive(Clone, Debug, PartialEq)]
pub struct Summary {
    pub path: PathBuf,
    pub duration_ms: u64,
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub width: u32,
    pub height: u32,
    /// Frames per second it came to.
    pub fps: f64,
    /// Why it ended: `stopped`, `max_seconds`, `locked`, `computer_use_off`,
    /// `stopped_by_person`, `display_changed`, `capture_failed`,
    /// `encode_failed`.
    pub ended: String,
    /// What went wrong, for the endings that are failures.
    pub detail: Option<String>,
    pub display: String,
    pub encoder: String,
    /// The most denied windows painted out of one frame.
    pub redacted_windows: usize,
    /// The most denied apps the capture left out of one frame.
    pub left_out_apps: usize,
}

/// A recording that ended.
#[derive(Clone, Debug)]
pub struct Done {
    pub id: String,
    pub session: String,
    pub outcome: Result<Summary, RecordError>,
    /// Whether a caller has had this result.
    collected: bool,
}

struct Active {
    id: String,
    session: String,
    stop: Arc<AtomicBool>,
}

#[derive(Default)]
struct State {
    seq: u64,
    active: Option<Active>,
    done: VecDeque<Done>,
}

/// The engine's recordings: at most one running, the last few finished.
pub struct Recorder {
    dir: PathBuf,
    state: Mutex<State>,
    changed: Condvar,
}

fn private_dir(path: &Path) {
    let _ = std::fs::create_dir_all(path);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
}

fn unix_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

impl Recorder {
    /// `state_dir`: the engine's folder; without one (tests) a folder of
    /// this process under the temp folder.
    pub fn open(state_dir: Option<&Path>) -> Arc<Self> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = match state_dir {
            Some(d) => d.join("recordings"),
            None => std::env::temp_dir().join(format!(
                "cmux-cu-recordings-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )),
        };
        let recorder =
            Arc::new(Self { dir, state: Mutex::new(State::default()), changed: Condvar::new() });
        recorder.drop_leftovers();
        recorder
    }

    /// An engine that starts knows no earlier recording, so nobody can ask
    /// for one by id: the files of earlier runs go, but for the newest few
    /// (a caller may still be copying one).
    fn drop_leftovers(&self) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        let mut ours: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                    n.starts_with(FILE_PREFIX) && (n.ends_with(".mp4") || n.ends_with(".part"))
                })
            })
            .collect();
        // The names start with the time they were made.
        ours.sort();
        let drop = ours.len().saturating_sub(KEEP);
        for path in ours.into_iter().take(drop) {
            let _ = std::fs::remove_file(path);
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Takes the one recording slot for `session`.
    fn begin(&self, session: &str) -> Result<(String, PathBuf, Arc<AtomicBool>), RecordError> {
        let mut state = self.lock();
        if let Some(active) = &state.active {
            let whose = if active.session == session {
                format!("recording {} is running; stop it first", active.id)
            } else {
                "another session is recording; one recording runs at a time".to_string()
            };
            return Err(RecordError::new("already_recording", whose));
        }
        state.seq += 1;
        let stamp = unix_ms();
        let id = format!("rec-{stamp:x}-{}", state.seq);
        let path = self.dir.join(format!("{FILE_PREFIX}{stamp:014}-{}.mp4", state.seq));
        let stop = Arc::new(AtomicBool::new(false));
        state.active =
            Some(Active { id: id.clone(), session: session.to_string(), stop: stop.clone() });
        Ok((id, path, stop))
    }

    /// Ends the active recording `id` with `outcome`.
    fn finish(&self, id: &str, session: &str, outcome: Result<Summary, RecordError>) {
        let mut state = self.lock();
        if state.active.as_ref().is_some_and(|a| a.id == id) {
            state.active = None;
        }
        state.done.push_back(Done {
            id: id.to_string(),
            session: session.to_string(),
            outcome,
            collected: false,
        });
        while state.done.len() > KEEP {
            if let Some(old) = state.done.pop_front()
                && let Ok(summary) = old.outcome
            {
                let _ = std::fs::remove_file(summary.path);
            }
        }
        drop(state);
        self.changed.notify_all();
    }

    /// The recording start failed before it ran: the slot is free again.
    fn abandon(&self, id: &str) {
        let mut state = self.lock();
        if state.active.as_ref().is_some_and(|a| a.id == id) {
            state.active = None;
        }
        drop(state);
        self.changed.notify_all();
    }

    /// Whether a recording is running now, and whose.
    pub fn active(&self) -> Option<(String, String)> {
        self.lock().active.as_ref().map(|a| (a.id.clone(), a.session.clone()))
    }

    /// Waits for recording `id` to end and returns its result.
    pub fn wait(&self, id: &str) -> Result<Summary, RecordError> {
        let mut state = self.lock();
        loop {
            if let Some(done) = state.done.iter_mut().find(|d| d.id == id) {
                done.collected = true;
                return done.outcome.clone();
            }
            if state.active.as_ref().is_none_or(|a| a.id != id) {
                return Err(RecordError::new("not_recording", format!("no recording {id}")));
            }
            state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Stops `session`'s recording (`id`, or the one running, or one that
    /// ended by itself and nobody has had the result of) and returns its
    /// result. A recording of another session is not found.
    pub fn stop(&self, session: &str, id: Option<&str>) -> Result<(String, Summary), RecordError> {
        let found = {
            let mut state = self.lock();
            let running = state
                .active
                .as_ref()
                .filter(|a| a.session == session && id.is_none_or(|id| id == a.id))
                .map(|a| (a.id.clone(), a.stop.clone()));
            match running {
                Some((id, stop)) => {
                    stop.store(true, Ordering::Release);
                    Some(id)
                }
                None => state
                    .done
                    .iter_mut()
                    .rev()
                    .find(|d| {
                        d.session == session
                            && match id {
                                Some(id) => d.id == id,
                                None => !d.collected,
                            }
                    })
                    .map(|d| d.id.clone()),
            }
        };
        let Some(found) = found else {
            return Err(RecordError::new(
                "not_recording",
                match id {
                    Some(id) => format!("this session has no recording {id}"),
                    None => "this session has no recording running".to_string(),
                },
            ));
        };
        self.wait(&found).map(|summary| (found, summary))
    }

    /// The file of `session`'s finished recording `id`.
    pub fn file(&self, session: &str, id: &str) -> Result<PathBuf, RecordError> {
        let state = self.lock();
        match state.done.iter().find(|d| d.id == id && d.session == session) {
            Some(Done { outcome: Ok(summary), .. }) => Ok(summary.path.clone()),
            Some(Done { outcome: Err(e), .. }) => Err(e.clone()),
            None => Err(RecordError::new(
                "not_recording",
                format!("this session has no finished recording {id}"),
            )),
        }
    }
}

/// What a recording reads the screen and the policy through: the engine's
/// own desktop, live settings, saved answers and stops.
#[derive(Clone)]
pub struct Source {
    pub desktop: Arc<dyn Desktop>,
    pub config: Arc<RwLock<PolicyConfig>>,
    pub sessions: Arc<Sessions>,
    pub stops: Arc<Stops>,
}

/// One frame, denied apps already out of it.
struct Shot {
    frame: RawFrame,
    redacted: usize,
    left_out: usize,
}

fn blocked(config: &PolicyConfig, saved: &SavedApprovals, app: &TargetApp) -> bool {
    policy::is_blocked(config, app).is_some() || saved.is_never(&app.id)
}

impl Source {
    fn config(&self) -> PolicyConfig {
        self.config.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// One display capture under the policy as it is now. This is the display
    /// branch of the engine's screenshot (`Engine::capture_for`), frame by
    /// frame: where the capture can leave whole processes out it does, and a
    /// denied window whose process was not left out is painted out whole,
    /// from the window lists read before and after the capture. If either
    /// list cannot be read, there is no frame.
    fn shoot(&self, config: &PolicyConfig, display: Option<&str>) -> Result<Shot, DesktopError> {
        let saved = self.sessions.saved();
        let windows = self.desktop.list_windows()?;
        let listed: Vec<App> = self.desktop.list_apps().unwrap_or_default();
        let names: HashMap<String, String> =
            listed.iter().map(|a| (a.id.to_ascii_lowercase(), a.name.clone())).collect();
        let target_of = |app_id: &str| TargetApp {
            id: app_id.to_string(),
            name: names
                .get(&app_id.to_ascii_lowercase())
                .cloned()
                .unwrap_or_else(|| app_id.to_string()),
        };
        let mut left_out: Vec<u32> = Vec::new();
        let mut excluding = false;
        if self.desktop.excludes_apps_from_display_capture()
            && let Ok(capture_apps) = self.desktop.capture_apps()
        {
            excluding = true;
            for a in capture_apps.iter().chain(listed.iter()) {
                let t = TargetApp {
                    id: if a.id.is_empty() { a.name.clone() } else { a.id.clone() },
                    name: a.name.clone(),
                };
                if a.pid != 0 && blocked(config, &saved, &t) && !left_out.contains(&a.pid) {
                    left_out.push(a.pid);
                }
            }
            for w in &windows {
                if w.pid != 0
                    && blocked(config, &saved, &target_of(&w.app_id))
                    && !left_out.contains(&w.pid)
                {
                    left_out.push(w.pid);
                }
            }
        }
        let excluded = if excluding {
            self.desktop.capture_display_excluding(display, &left_out).ok()
        } else {
            None
        };
        if excluded.is_none() {
            excluding = false;
            left_out.clear();
        }
        let mut raw = match excluded {
            Some(frame) => frame,
            None => self.desktop.capture(&CaptureTarget::Display(display.map(str::to_string)))?,
        };
        let after = self.desktop.list_windows()?;
        let mut rects: Vec<Rect> = Vec::new();
        for w in windows.iter().chain(after.iter()) {
            let skip = !w.on_screen
                || w.minimized
                || (excluding && w.pid != 0 && left_out.contains(&w.pid))
                || !blocked(config, &saved, &target_of(&w.app_id));
            if !skip && !rects.contains(&w.frame) {
                rects.push(w.frame);
            }
        }
        let redacted = frame::redact(&mut raw, &rects);
        Ok(Shot { frame: raw, redacted, left_out: left_out.len() })
    }
}

/// Scales `raw` so its long edge is at most `max_edge`, with even sides
/// (4:2:0 video needs them).
fn fit(raw: &RawFrame, max_edge: u32) -> RawFrame {
    let (w, h, rgba) = frame::downscale(raw, max_edge);
    let (even_w, even_h) = ((w & !1).max(2), (h & !1).max(2));
    let ratio = f64::from(w) / f64::from(raw.width.max(1));
    if (even_w, even_h) == (w, h) {
        return RawFrame {
            width: w,
            height: h,
            rgba,
            scale: raw.scale * ratio,
            origin: raw.origin,
        };
    }
    // Drop the odd last column and row; a 1-pixel side is doubled.
    let mut out = vec![0u8; even_w as usize * even_h as usize * 4];
    for y in 0..even_h as usize {
        let sy = y.min(h as usize - 1);
        for x in 0..even_w as usize {
            let sx = x.min(w as usize - 1);
            let from = (sy * w as usize + sx) * 4;
            let to = (y * even_w as usize + x) * 4;
            out[to..to + 4].copy_from_slice(&rgba[from..from + 4]);
        }
    }
    RawFrame {
        width: even_w,
        height: even_h,
        rgba: out,
        scale: raw.scale * ratio,
        origin: raw.origin,
    }
}

/// What the caller asked for.
#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    pub display: Option<String>,
    pub fps: u32,
    /// The recording ends by itself after this long.
    pub limit: Duration,
    pub max_edge: u32,
}

struct Job {
    id: String,
    session: String,
    path: PathBuf,
    options: Options,
    stop: Arc<AtomicBool>,
    source: Source,
    encoder: Box<dyn FrameEncoder>,
    writer: mp4::Mp4Writer,
    first: Shot,
}

impl Recorder {
    /// Starts a recording for `session` and returns its id. The first frame
    /// is captured before this returns, so a missing permission, an unknown
    /// display or a desktop with no encoder is the caller's error, not a
    /// file with nothing in it.
    pub fn start(
        self: &Arc<Self>,
        source: Source,
        session: &str,
        options: Options,
    ) -> Result<String, RecordError> {
        let (id, path, stop) = self.begin(session)?;
        let job = (|| {
            let config = source.config();
            let mut first = source
                .shoot(&config, options.display.as_deref())
                .map_err(|e| RecordError::desktop(&e))?;
            first.frame = fit(&first.frame, options.max_edge);
            let encoder = source
                .desktop
                .frame_encoder(first.frame.width, first.frame.height, options.fps)
                .map_err(|e| RecordError::desktop(&e))?;
            private_dir(&self.dir);
            let writer = mp4::Mp4Writer::create(&path, first.frame.width, first.frame.height)
                .map_err(|e| {
                    RecordError::new("recording_failed", format!("{}: {e}", path.display()))
                })?;
            Ok(Job {
                id: id.clone(),
                session: session.to_string(),
                path: path.clone(),
                options,
                stop,
                source,
                encoder,
                writer,
                first,
            })
        })();
        let job = match job {
            Ok(job) => job,
            Err(e) => {
                self.abandon(&id);
                return Err(e);
            }
        };
        let recorder = self.clone();
        let (thread_id, thread_session) = (id.clone(), session.to_string());
        let spawned = std::thread::Builder::new().name("cmux-cu-record".into()).spawn(move || {
            let (id, session) = (job.id.clone(), job.session.clone());
            let outcome = run(job);
            recorder.finish(&id, &session, outcome);
        });
        if let Err(e) = spawned {
            let _ = std::fs::remove_file(&path);
            self.finish(
                &thread_id,
                &thread_session,
                Err(RecordError::new("recording_failed", format!("no recording thread: {e}"))),
            );
            return Err(RecordError::new("recording_failed", format!("no recording thread: {e}")));
        }
        Ok(id)
    }
}

/// The recording loop: one frame per tick until something ends it, then the
/// file's index, then the file read back.
fn run(job: Job) -> Result<Summary, RecordError> {
    let Job { path, options, stop, source, mut encoder, mut writer, first, session, .. } = job;
    let began = Instant::now();
    let interval = Duration::from_secs_f64(1.0 / f64::from(options.fps.max(1)));
    let size = (first.frame.width, first.frame.height);
    let mut redacted = 0usize;
    let mut left_out = 0usize;
    let mut shot = first;
    let mut at = Duration::ZERO;
    let mut last_key: Option<Duration> = None;
    let mut tick: u32 = 0;
    let mut detail: Option<String> = None;
    let ended: &str = loop {
        redacted = redacted.max(shot.redacted);
        left_out = left_out.max(shot.left_out);
        let force_key = last_key.is_none_or(|k| at.saturating_sub(k) >= KEY_EVERY);
        match encoder.encode(&shot.frame, force_key, at) {
            Ok(unit) if unit.is_empty() => {}
            Ok(unit) => match writer.write_sample(&unit, at) {
                Ok(_) => {
                    if force_key {
                        last_key = Some(at);
                    }
                }
                Err(e) => {
                    detail = Some(e.to_string());
                    break "write_failed";
                }
            },
            Err(e) => {
                detail = Some(e);
                break "encode_failed";
            }
        }
        // The next tick the clock has not passed yet: a capture slower than
        // the frame time drops ticks instead of running late for ever.
        let now = began.elapsed();
        let passed = (now.as_secs_f64() / interval.as_secs_f64()).floor() as u32;
        tick = tick.max(passed).saturating_add(1);
        let due = interval * tick;
        let waited = loop {
            if stop.load(Ordering::Acquire) {
                break Some("stopped");
            }
            let now = began.elapsed();
            if now >= options.limit {
                break Some("max_seconds");
            }
            if now >= due {
                break None;
            }
            let nap = (due - now).min(options.limit - now).min(Duration::from_millis(20));
            std::thread::sleep(nap);
        };
        if let Some(why) = waited {
            break why;
        }
        // What ends a recording without the caller: the same things that
        // refuse a display screenshot.
        let config = source.config();
        if config.mode == policy::Mode::Off {
            break "computer_use_off";
        }
        if source.stops.is_stopped(&session) {
            break "stopped_by_person";
        }
        if source.desktop.screen_locked() {
            break "locked";
        }
        shot = match source.shoot(&config, options.display.as_deref()) {
            Ok(mut next) => {
                next.frame = fit(&next.frame, options.max_edge);
                next
            }
            Err(e) => {
                detail = Some(e.to_string());
                break "capture_failed";
            }
        };
        if (shot.frame.width, shot.frame.height) != size {
            detail = Some(format!(
                "the display went from {}x{} to {}x{}",
                size.0, size.1, shot.frame.width, shot.frame.height
            ));
            break "display_changed";
        }
        at = began.elapsed();
    };
    let end = began.elapsed();
    let encoder_name = encoder.name();
    drop(encoder);
    if let Err(e) = writer.finish(end) {
        let _ = std::fs::remove_file(&path);
        let why = detail.map(|d| format!(" ({ended}: {d})")).unwrap_or_default();
        return Err(RecordError::new("recording_failed", format!("{e}{why}")));
    }
    // The result is what the file says.
    let info = mp4::probe(&path).map_err(|e| {
        let _ = std::fs::remove_file(&path);
        RecordError::new("recording_failed", format!("the file does not read back: {e}"))
    })?;
    let seconds = info.duration_ms as f64 / 1000.0;
    Ok(Summary {
        path,
        duration_ms: info.duration_ms,
        frames: info.frames,
        keyframes: info.keyframes,
        bytes: info.bytes,
        width: info.width,
        height: info.height,
        fps: if seconds > 0.0 {
            (info.frames as f64 / seconds * 100.0).round() / 100.0
        } else {
            0.0
        },
        ended: ended.to_string(),
        detail,
        display: options.display.unwrap_or_else(|| "main".to_string()),
        encoder: encoder_name,
        redacted_windows: redacted,
        left_out_apps: left_out,
    })
}

#[cfg(test)]
#[path = "record_tests.rs"]
mod tests;
