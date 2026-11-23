//! Runs one tool call, in this order, for every route:
//!
//! 1. A retried acting call (same session and `call_id`) returns its first
//!    result and does nothing.
//! 2. The target app is resolved from the desktop (never from the agent's
//!    words), then [`crate::policy::decide`]; an `Ask` goes to the
//!    [`Approver`] and its answer is saved before the call goes on.
//! 3. Acting calls that could meet the person's own input (foreground
//!    delivery, or the window the person is using) wait while the person is
//!    using the mouse or keyboard ([`PersonActivity`]) and fail with
//!    `person_in_control` if they keep on. Background calls to other windows
//!    never wait: they cannot collide with the person.
//! 4. The agent cursor glides to the target, the desktop acts, the cursor
//!    shows the click or the typing.
//! 5. Screenshots go through [`crate::frame`]; accessibility frames come back
//!    in the pixels of the agent's latest screenshot of that window.
//! 6. An acting call returns the window as it is after acting: a wait of at
//!    most [`Settle::floor`] (cut short by the app's accessibility signal),
//!    then one screenshot. Only when the app has no watched signals, or
//!    signalled a change the pixels do not show yet, do more screenshots
//!    follow until the pixels differ from what the agent last saw, up to
//!    [`Settle::ceiling`]. Plus its tree. One round trip per step;
//!    `observe: false` skips it.
//! 7. One audit line per call.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::cursor::{CursorEvent, CursorSink, NoCursor, caption};
use crate::desktop::{
    Button, CaptureTarget, ClickSpec, Delivery, Desktop, DesktopError, Element, Point,
    PointerTarget, Rect, TreeOptions, Watch, Window,
};
use crate::frame::{self, Geometry};
use crate::keys::KeyCombo;
use crate::policy::{
    self, Access, Decision, OriginKind, PolicyConfig, Refusal, Request, SettleMode, TargetApp,
};
use crate::session::{Prior, Sessions};
use crate::stop::{self, Stops};
use crate::tools;

pub use crate::policy::OriginKind as Origin;

/// Who is calling.
#[derive(Clone, Debug)]
pub struct CallContext {
    /// The agent session key (stable across reconnects and worker restarts).
    pub session: String,
    /// Shown to the person: "Claude in cmux-tui", "Codex".
    pub label: String,
    /// Set by the bridge per MCP request; a retry reuses it.
    pub call_id: Option<String>,
    pub origin: OriginKind,
    /// The agent cursor's tag: the agent's `cursor_tag`, else its cmux workspace name; None
    /// shows none (`computerUse.cursorTag` decides when it shows).
    pub tag: Option<String>,
}

/// The `_meta` key of an MCP text block that holds a look's outline, and
/// where in the result's JSON it was (`tree` or `state.tree`).
pub const OUTLINE_META: &str = "cmux/outline";

/// A tool's result.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolOutput {
    pub is_error: bool,
    /// A refusal or failure code (`app_denied`, `person_in_control`, ...).
    pub code: Option<String>,
    pub body: Value,
    pub png_base64: Option<String>,
}

impl ToolOutput {
    pub fn ok(body: Value) -> Self {
        Self { is_error: false, code: None, body, png_base64: None }
    }
    pub fn error(code: &str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            is_error: true,
            code: Some(code.to_string()),
            body: json!({"error": message, "code": code}),
            png_base64: None,
        }
    }
    fn refused(refusal: &Refusal, app: Option<&TargetApp>) -> Self {
        Self::error(refusal.code(), refusal.message(app))
    }
    fn desktop(e: &DesktopError) -> Self {
        Self::error(e.code(), e.to_string())
    }

    /// The MCP `tools/call` result. An outline (`tree`, or the state's
    /// `tree`) goes as its own text block after the JSON, as plain lines:
    /// quoted inside JSON every line break and quote would be escaped.
    pub fn to_mcp(&self) -> Value {
        let mut body = self.body.clone();
        let mut texts: Vec<(&str, String)> = Vec::new();
        // The outline replaces the JSON tree (kept for direct callers) in what
        // the model reads.
        let mut take = |o: Option<&mut serde_json::Map<String, Value>>, place: &'static str| {
            if let Some(o) = o
                && let Some(Value::String(t)) = o.remove("tree")
            {
                o.remove("root");
                o.remove("frames_in");
                texts.push((place, t));
            }
        };
        take(body.as_object_mut(), "tree");
        take(body.get_mut("state").and_then(Value::as_object_mut), "state.tree");
        let mut content = vec![json!({"type": "text", "text": body.to_string()})];
        // `_meta` says where the text came from, so a script gets it back in place.
        for (from, t) in texts {
            content.push(json!({"type": "text", "text": t, "_meta": {OUTLINE_META: from}}));
        }
        if let Some(png) = &self.png_base64 {
            content.push(json!({"type": "image", "data": png, "mimeType": "image/png"}));
        }
        json!({"content": content, "isError": self.is_error})
    }

    pub fn to_json(&self) -> Value {
        json!({"is_error": self.is_error, "code": self.code, "body": self.body, "png": self.png_base64})
    }

    pub fn from_json(v: &Value) -> Option<Self> {
        Some(Self {
            is_error: v.get("is_error")?.as_bool()?,
            code: v.get("code").and_then(Value::as_str).map(str::to_string),
            body: v.get("body")?.clone(),
            png_base64: v.get("png").and_then(Value::as_str).map(str::to_string),
        })
    }
}

/// The deny list and protected apps, for menu items that open other apps.
struct PolicyMenuGuard(Arc<RwLock<PolicyConfig>>);

impl crate::desktop::MenuGuard for PolicyMenuGuard {
    fn app_blocked(&self, id: &str, name: &str) -> bool {
        let config = self.0.read().unwrap_or_else(std::sync::PoisonError::into_inner);
        policy::is_blocked(&config, &TargetApp { id: id.to_string(), name: name.to_string() })
            .is_some()
    }
    fn denies_any(&self) -> bool {
        !self.0.read().unwrap_or_else(std::sync::PoisonError::into_inner).denied_apps.is_empty()
    }
    fn blocked_ids(&self) -> Vec<String> {
        let config = self.0.read().unwrap_or_else(std::sync::PoisonError::into_inner);
        config
            .denied_apps
            .iter()
            .map(|e| e.trim())
            .filter(|e| !e.is_empty() && !e.starts_with("name:"))
            .map(str::to_string)
            .chain(policy::protected_ids().iter().map(|s| (*s).to_string()))
            .chain(policy::protected_prefixes().iter().map(|p| format!("{p}*")))
            .collect()
    }
}

/// The cursor's caption for an acting call that was refused, or None for an
/// ordinary failure (a bad argument, a missing window).
fn refusal_caption(code: &str) -> Option<&'static str> {
    Some(match code {
        "computer_use_off" => "Computer Use is off",
        "app_protected" => "Protected app",
        "app_denied" => "App is on the deny list",
        "look_only" => "Look only",
        "app_never_allowed" => "Not allowed",
        "remote_not_allowed" | "foreign_account" => "Not allowed from there",
        "foreground_not_allowed" => "Foreground input is off",
        "person_in_control" => "You're in control",
        "approval_denied" | "approval_unavailable" => "Not approved",
        crate::locked::CODE => "Mac is locked",
        stop::STOPPED_CODE => stop::STOPPED_CAPTION,
        _ => return None,
    })
}

/// A question for the person.
#[derive(Clone, Debug, PartialEq)]
pub struct Question {
    pub session: String,
    pub agent: String,
    pub app: TargetApp,
    /// Offer "Always allow" and "Never" (Approved apps mode).
    pub remember: bool,
    /// Set when the agent runs on another machine.
    pub from_machine: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    AllowOnce,
    AllowSession,
    AlwaysAllow,
    Deny,
    Never,
    /// No way to ask here, or nobody answered in time.
    Unavailable,
}

/// Asks the person (an approval panel on the machine). Blocks.
pub trait Approver: Send + Sync {
    fn ask(&self, question: &Question) -> Answer;
}

pub struct NoApprover;

impl Approver for NoApprover {
    fn ask(&self, _question: &Question) -> Answer {
        Answer::Unavailable
    }
}

/// The person's own use of the mouse and keyboard.
pub trait PersonActivity: Send + Sync {
    /// Waits until the person has been idle (or `limit` passes); true when idle.
    fn wait_idle(&self, limit: Duration) -> bool;
    /// How many deliberate inputs (keys, clicks, scrolls, drags) the person
    /// has made so far, counted by a detector that tells theirs from ours;
    /// `None` when nothing watches. The focus guard compares two readings to
    /// know whether the person moved focus during a call.
    fn input_count(&self) -> Option<u64> {
        None
    }
    /// While input_count counts the person's keys too: an epoch that rises
    /// whenever their keys may have gone uncounted (Secure Event Input, a
    /// blind detector, dictation). `None` while the count does not cover keys
    /// (macOS: no Input Monitoring). Two equal readings mean every key of the
    /// person was counted between them.
    fn keys_epoch(&self) -> Option<u64> {
        None
    }
}

pub struct NoTakeover;

impl PersonActivity for NoTakeover {
    fn wait_idle(&self, _limit: Duration) -> bool {
        true
    }
}

/// How long an acting call waits for the person to stop.
pub const TAKEOVER_WAIT: Duration = Duration::from_secs(15);

/// How an acting call waits before it reports the window's new state: a
/// `floor` first (most apps redraw within it; the app's accessibility signal
/// ends it early, and a watched app that signals nothing and shows nothing
/// new after it gets no more screenshots), then a screenshot every
/// `step` until the pixels differ from what the agent last saw, never past
/// `ceiling`. A fixed delay with change detection, not "until quiet": an app
/// that keeps animating never holds the reply past the ceiling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settle {
    pub floor: Duration,
    pub step: Duration,
    pub ceiling: Duration,
}

impl Default for Settle {
    fn default() -> Self {
        Self {
            floor: Duration::from_millis(120),
            step: Duration::from_millis(100),
            ceiling: Duration::from_millis(1000),
        }
    }
}

/// Anthropic's computer-use reference tool (`BaseComputerTool`): the fixed
/// wait before the screenshot after an action, and typing in groups of
/// [`ANTHROPIC_TYPING_GROUP`] characters at [`ANTHROPIC_TYPING_DELAY`] per key.
pub const ANTHROPIC_SCREENSHOT_DELAY: Duration = Duration::from_millis(2000);
pub const ANTHROPIC_TYPING_DELAY: Duration = Duration::from_millis(12);
pub const ANTHROPIC_TYPING_GROUP: usize = 50;
/// Anthropic's double and triple clicks (`--repeat N --delay 10`).
pub const ANTHROPIC_CLICK_GAP: Duration = Duration::from_millis(10);
/// The `wait` tool: OpenAI's handlers wait 2000 ms; Anthropic's `wait` takes
/// a duration of at most 100 s.
pub const WAIT_DEFAULT: Duration = Duration::from_millis(2000);
pub const WAIT_MAX: Duration = Duration::from_secs(100);
/// The most actions one `batch` runs.
pub const BATCH_MAX: usize = 20;
/// The longest one `batch` runs: its waits and `wait_for` timeouts together
/// are refused past it before anything runs, and no step starts after it.
pub const BATCH_TIME_MAX: Duration = Duration::from_secs(120);
/// The tools a `batch` may run (and `wait_for`, which only a batch has).
const BATCHABLE: &[&str] =
    &["click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action", "wait"];

pub struct EngineParts {
    pub desktop: Arc<dyn Desktop>,
    pub config: PolicyConfig,
    pub state_dir: Option<PathBuf>,
    pub cursor: Arc<dyn CursorSink>,
    pub approver: Arc<dyn Approver>,
    pub takeover: Arc<dyn PersonActivity>,
    pub machine_name: String,
    pub settle: Settle,
    /// The settle wait's sleep and the monotonic clock it measures the
    /// ceiling with (tests pass a pair that only advances on sleep).
    pub sleep: Arc<dyn Fn(Duration) + Send + Sync>,
    pub clock: Arc<dyn Fn() -> Duration + Send + Sync>,
    /// The sessions the person stopped ([`crate::stop`]); shared so a test
    /// can stop a session from inside a running call.
    pub stops: Arc<Stops>,
    /// The platform's window streams for the live preview ([`crate::preview`]).
    pub preview: Arc<dyn crate::preview::PreviewSource>,
}

/// Time since the first call, from the monotonic clock.
fn monotonic() -> Duration {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed()
}

impl EngineParts {
    pub fn new(desktop: Arc<dyn Desktop>) -> Self {
        Self {
            desktop,
            config: PolicyConfig::default(),
            state_dir: None,
            cursor: Arc::new(NoCursor),
            approver: Arc::new(NoApprover),
            takeover: Arc::new(NoTakeover),
            machine_name: String::new(),
            settle: Settle::default(),
            sleep: Arc::new(std::thread::sleep),
            clock: Arc::new(monotonic),
            stops: Arc::new(Stops::default()),
            preview: Arc::new(crate::preview::NoPreview),
        }
    }
}

pub struct Engine {
    desktop: Arc<dyn Desktop>,
    config: Arc<RwLock<PolicyConfig>>,
    sessions: Arc<Sessions>,
    /// Every cursor event goes through [`crate::cursor::Lifecycle`], which
    /// knows which sessions' Computer Use is active.
    cursor: Arc<crate::cursor::Lifecycle>,
    preview: Arc<crate::preview::PreviewHub>,
    approver: Arc<dyn Approver>,
    takeover: Arc<dyn PersonActivity>,
    /// (session, "w:<window>" | "d:<display>") -> what the agent last saw.
    seen: Mutex<HashMap<(String, String), (Geometry, u64)>>,
    /// session -> its latest display screenshot key.
    last_display: Mutex<HashMap<String, String>>,
    /// session -> the app its foreground call brought to the front (see
    /// engine_focus: AgentFront).
    agent_front: Mutex<HashMap<String, focus::AgentFront>>,
    /// Element ids, the agents' last looks and the guards ([`crate::observe`]).
    observe: observe_glue::Observe,
    audit: Option<PathBuf>,
    machine_name: String,
    settle: Settle,
    sleep: Arc<dyn Fn(Duration) + Send + Sync>,
    clock: Arc<dyn Fn() -> Duration + Send + Sync>,
    stops: Arc<Stops>,
    /// The display recordings ([`crate::record`], the `record` tool).
    recorder: Arc<crate::record::Recorder>,
}

/// What a capture checks before it reads a window.
enum Check<'a> {
    /// The policy check, asking the person when the mode says so.
    Authorize,
    /// The state after an action already authorized on `app`: the window
    /// must still be that app's and the app still allowed (deny list,
    /// protected, Never), with no question asked again.
    StillAllowed(&'a TargetApp),
}

fn args_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn args_f64(args: &Value, key: &str) -> Option<f64> {
    args.get(key).and_then(Value::as_f64).filter(|v| v.is_finite())
}

fn parse_button(args: &Value) -> Result<Button, ToolOutput> {
    match args_str(args, "button") {
        None | Some("left") => Ok(Button::Left),
        Some("right") => Ok(Button::Right),
        Some("middle") => Ok(Button::Middle),
        Some(other) => {
            Err(ToolOutput::error("invalid_arguments", format!("unknown button {other:?}")))
        }
    }
}

fn parse_delivery(args: &Value) -> Result<Delivery, ToolOutput> {
    match args_str(args, "delivery") {
        None | Some("background") => Ok(Delivery::Background),
        Some("foreground") => Ok(Delivery::Foreground),
        Some(other) => {
            Err(ToolOutput::error("invalid_arguments", format!("unknown delivery {other:?}")))
        }
    }
}

fn need<'a>(args: &'a Value, key: &str) -> Result<&'a str, ToolOutput> {
    args_str(args, key)
        .ok_or_else(|| ToolOutput::error("invalid_arguments", format!("{key} is required")))
}

fn need_f64(args: &Value, key: &str) -> Result<f64, ToolOutput> {
    args_f64(args, key)
        .ok_or_else(|| ToolOutput::error("invalid_arguments", format!("{key} is required")))
}

impl Engine {
    pub fn new(parts: EngineParts) -> Self {
        let audit = parts.state_dir.as_ref().map(|d| d.join("audit.jsonl"));
        let config = Arc::new(RwLock::new(parts.config.clone()));
        parts.desktop.set_menu_guard(Arc::new(PolicyMenuGuard(config.clone())));
        let preview =
            Arc::new(crate::preview::PreviewHub::new(parts.preview, previews_on(&parts.config)));
        Self {
            sessions: Arc::new(Sessions::open(parts.state_dir.as_deref())),
            recorder: crate::record::Recorder::open(parts.state_dir.as_deref()),
            desktop: parts.desktop,
            config,
            cursor: Arc::new(crate::cursor::Lifecycle::new(parts.cursor, preview.clone())),
            preview,
            approver: parts.approver,
            takeover: parts.takeover,
            seen: Mutex::new(HashMap::new()),
            last_display: Mutex::new(HashMap::new()),
            agent_front: Mutex::new(HashMap::new()),
            observe: observe_glue::Observe::new(parts.state_dir.as_deref()),
            audit,
            machine_name: parts.machine_name,
            settle: parts.settle,
            sleep: parts.sleep,
            clock: parts.clock,
            stops: parts.stops,
        }
    }

    pub fn config(&self) -> PolicyConfig {
        self.config.read().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Applies new settings at once; calls already past the policy check finish.
    pub fn set_config(&self, config: PolicyConfig) {
        let off = config.mode == policy::Mode::Off;
        if off || !config.allow_foreground {
            lock(&self.agent_front).clear();
        }
        let previews = previews_on(&config);
        *self.config.write().unwrap_or_else(std::sync::PoisonError::into_inner) = config;
        self.preview.set_enabled(previews);
        if off {
            self.revoke_sessions();
        }
    }

    /// Every session's grants are revoked (Computer Use turned off, or the
    /// person's Revoke): no agent's Computer Use is active any more, so
    /// every cursor hides and every preview turns done.
    pub fn revoke_sessions(&self) {
        self.sessions.revoke_all(None);
        self.cursor.end_where(|_| true);
    }

    /// The live preview's cards and watchers.
    pub fn preview(&self) -> &Arc<crate::preview::PreviewHub> {
        &self.preview
    }

    /// The sessions whose Computer Use is active now (their cursor shows).
    pub fn active_sessions(&self) -> Vec<String> {
        self.cursor.active()
    }

    /// The agent's turn ended (`session/idle`): its Computer Use is no
    /// longer active, so its cursor hides and its preview turns done; its
    /// approvals stay for its next turn. `session` names one session, or
    /// with `prefix` every session whose key starts with it (a terminal's
    /// agents, `terminal:<id>:`). The sessions it ended.
    pub fn idle(&self, session: &str, prefix: bool) -> Vec<String> {
        if session.is_empty() {
            return Vec::new();
        }
        self.cursor.end_where(|s| if prefix { s.starts_with(session) } else { s == session })
    }

    pub fn sessions(&self) -> &Sessions {
        &self.sessions
    }

    /// The window of a call that passed the policy, for its session's
    /// preview card (also before anyone watches: the daemon's watch starts
    /// with the session's first action); nothing while the preview is off.
    fn note_preview_window(&self, ctx: &CallContext, window_id: &str, app: Option<&TargetApp>) {
        if !self.preview.enabled() {
            return;
        }
        let Ok(Some(window)) = self.desktop.window(window_id) else { return };
        let name = app.map(|a| a.name.as_str()).unwrap_or_default();
        self.preview.note_window(&ctx.session, &ctx.label, &window.id, window.frame, name);
    }

    /// The agent session ended: hide its cursor and forget what it saw.
    pub fn end_session(&self, session: &str) {
        self.cursor.show(CursorEvent::Hide { session: session.to_string() });
        lock(&self.seen).retain(|(s, _), _| s != session);
        lock(&self.last_display).remove(session);
        lock(&self.agent_front).remove(session);
        self.forget_session_seen(session);
    }

    pub fn call(&self, ctx: &CallContext, name: &str, args: &Value) -> ToolOutput {
        // The label reaches the person (approval panel, cursor, notifications):
        // any caller with the socket secret sets it, so it is bounded here.
        let safe;
        let tag = ctx.tag.as_deref().and_then(tools::safe_tag);
        let ctx = if safe_label(&ctx.label) == ctx.label && tag == ctx.tag {
            ctx
        } else {
            safe = CallContext { label: safe_label(&ctx.label), tag, ..ctx.clone() };
            &safe
        };
        let Some(tool) = tools::find(name) else {
            return ToolOutput::error("unknown_tool", format!("unknown tool {name:?}"));
        };
        if self.stops.is_stopped(&ctx.session) {
            return self.refuse_stopped(ctx, tool, name);
        }
        // A window named by its title or app instead of its id: the id, so
        // the agent needs no list_windows turn first (engine_window_name.rs).
        let named;
        let args = match self.window_by_name(args) {
            Ok(Some(resolved)) => {
                named = resolved;
                &named
            }
            Ok(None) => args,
            Err(refused) => return refused,
        };
        // An acting call is recorded on disk before it acts and again with its
        // result, so a retry (same call_id), even after a worker restart,
        // never acts twice.
        let acting_id = ctx.call_id.as_deref().filter(|_| tool.acts());
        if let Some(call_id) = acting_id {
            match self.sessions.prior(&ctx.session, call_id) {
                Prior::Finished(done) => {
                    // The first reply may not have arrived; its state did not
                    // either, so the agent's next screenshot of the window
                    // returns the image, not unchanged.
                    if tools::OBSERVES.contains(&name)
                        && let Some(id) = args.get("window_id").and_then(Value::as_str)
                    {
                        lock(&self.seen).remove(&(ctx.session.clone(), format!("w:{id}")));
                        self.forget_seen(&ctx.session, id);
                    }
                    if let Some(out) = serde_json::from_str::<Value>(&done)
                        .ok()
                        .as_ref()
                        .and_then(ToolOutput::from_json)
                    {
                        return out;
                    }
                }
                Prior::Interrupted => {
                    return ToolOutput::error(
                        "maybe_done",
                        "This call was cut off by a Computer Use restart and may already have acted. Take a screenshot to check before doing it again (with a new call).",
                    );
                }
                Prior::New => {}
            }
            self.sessions.begin(&ctx.session, call_id);
        }
        let args = if args.is_object() { args.clone() } else { json!({}) };
        // The target app's windows before an observing action: a sheet,
        // popover or window it opens is an effect a window capture misses.
        let windows_before = (tools::OBSERVES.contains(&name) && name != "batch")
            .then(|| args_str(&args, "window_id").and_then(|id| self.window_ids_over_target(id)))
            .flatten();
        let acted = self.acted_id(&args);
        // Whether the agent had a screenshot of the window before acting: only
        // then can the state say its pixels changed or not.
        let had_screenshot = args_str(&args, "window_id").is_some_and(|id| {
            lock(&self.seen).contains_key(&(ctx.session.clone(), format!("w:{id}")))
        });
        // An action whose window is watched through an adaptive settle: the
        // app's accessibility signals and what is on screen outside the
        // window are read from before it acts, for its outcome.
        let watched = (tools::OBSERVES.contains(&name)
            && name != "batch"
            && args.get("observe").and_then(Value::as_bool) != Some(false)
            && self.settle_mode(&args) == SettleMode::Adaptive)
            .then(|| args_str(&args, "window_id"))
            .flatten();
        let world_before = watched.and_then(|_| self.desktop.world());
        let watch = watched.and_then(|id| self.desktop.watch(id)).filter(|w| w.listening());
        let raising = self.foreground_begin(tool, &args);
        let mut guard = self.focus_begin(&ctx.session, tool, &args);
        let (mut out, app) = match self.dispatch(tool, ctx, &args) {
            Ok((out, app)) => (out, app),
            Err(out) => (out, None),
        };
        // The live preview shows the window a call passed the policy for.
        if !out.is_error
            && app.is_some()
            && let Some(window_id) = args_str(&args, "window_id")
        {
            self.note_preview_window(ctx, window_id, app.as_ref());
        }

        let mut focus = guard.as_mut().map(|g| self.focus_after_action(g, &out));
        // Recorded at once (a restart must not act twice), but never with a
        // confirmed the outcome has not decided yet: replaced below.
        if let Some(call_id) = acting_id {
            self.sessions.remember(&ctx.session, call_id, provisional_record(&out));
        }
        if tool.acts()
            && let Some(reason) = out.code.as_deref().and_then(refusal_caption)
        {
            self.cursor.show(CursorEvent::Refused {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at: None,
                reason: reason.to_string(),
                ends: false,
            });
        }
        // After the record: a retry returns the action's result, and the agent
        // takes a fresh screenshot for the state then.
        // A batch attaches its own state, once, at its end.
        let mut settled_ms = None;
        if !out.is_error
            && tools::OBSERVES.contains(&name)
            && name != "batch"
            && args.get("observe").and_then(Value::as_bool) != Some(false)
            && out.body.pointer("/menu/state") != Some(&json!(observe_glue::MENU_BAR_LISTING))
            && let Some(window_id) = args_str(&args, "window_id")
            && let Some(app) = &app
        {
            let mode = self.settle_mode(&args);
            settled_ms = self.attach_state(
                ctx,
                window_id,
                app,
                &mut out,
                mode,
                name == "type_text",
                watch.as_deref(),
            );
        }
        // The state as the model reads it: the outline of what changed, and
        // the app's windows that opened or closed (a batch's and a wait's too).
        if !out.is_error && out.body.get("state").is_some() {
            self.present_state(
                ctx,
                &args,
                &mut out,
                windows_before.as_deref(),
                acted,
                had_screenshot,
            );
        }
        // The outcome of an action (a result with the route's evidence).
        if !out.is_error && name != "batch" && out.body.get("evidence").is_some() {
            let signals = watch.as_ref().map(|w| w.signals());
            drop(watch);
            let outside = world_before.and_then(|before| {
                let after = self.desktop.world()?;
                let mut changes = after.changes_since(&before);
                // A foreground action brings its own app to the front.
                let raised = parse_delivery(&args).ok() == Some(Delivery::Foreground)
                    && after.front_pid.is_some()
                    && args_str(&args, "window_id")
                        .and_then(|id| self.desktop.window(id).ok().flatten())
                        .is_some_and(|w| Some(w.pid) == after.front_pid);
                if raised {
                    changes.retain(|c| c != crate::desktop::FRONT_APP_CHANGED);
                }
                Some(changes)
            });
            // A stalled app shows nothing new because it does nothing: one
            // AX round-trip after the settle says it still answers.
            let responsive = settled_ms
                .and_then(|_| args_str(&args, "window_id"))
                .and_then(|id| self.desktop.responsive(id));
            self.attach_outcome(&mut out, settled_ms, signals, outside, responsive);
            // A retry returns the result with its outcome (not the state).
            if let Some(call_id) = acting_id {
                self.sessions.remember(&ctx.session, call_id, retry_record(&out));
            }
        } else if let Some(body) = out.body.as_object_mut() {
            body.remove("shows");
            body.remove("expect");
        }
        // Without an outcome (no evidence, an error): the final record.
        if let Some(call_id) = acting_id
            && (out.is_error || name == "batch" || out.body.get("evidence").is_none())
        {
            self.sessions.remember(&ctx.session, call_id, retry_record(&out));
        }
        if let Some(g) = &guard {
            focus = Some(self.focus_after_settle(g, focus));
        }
        // After the settle wait: an app activates a little after the call
        // asked it to, so reading the front app at once often missed it.
        if let Some((before, inputs)) = raising {
            self.foreground_end(&ctx.session, &before, inputs, &args, &out);
        }
        if let Some(report) = &focus {
            report.attach(&mut out);
        }
        let out = self.end_if_stopped(ctx, out);
        self.write_audit_with(ctx, name, app.as_ref(), &out, focus.as_ref());
        out
    }

    /// The person stopped this session ([`Self::stop_session`]): the agent
    /// cursor goes red with "Stopped" (then hides on its own) and the cursor
    /// glides nowhere.
    pub fn stop_session(&self, session: &str, label: &str) -> bool {
        let added = self.stops.stop(session);
        if added {
            self.cursor.show(CursorEvent::Refused {
                session: session.to_string(),
                label: safe_label(label),
                at: None,
                reason: stop::STOPPED_CAPTION.to_string(),
                ends: true,
            });
        }
        added
    }

    /// Undoes [`Self::stop_session`]: the session's next call runs.
    pub fn resume_session(&self, session: &str) -> bool {
        self.stops.resume(session)
    }

    pub fn is_stopped(&self, session: &str) -> bool {
        self.stops.is_stopped(session)
    }

    /// The stopped sessions, sorted.
    pub fn stopped_sessions(&self) -> Vec<String> {
        self.stops.list()
    }

    /// A stopped session's call: refused before it does anything (no
    /// retry record, so a resumed agent's retry runs).
    fn refuse_stopped(&self, ctx: &CallContext, tool: &tools::Tool, name: &str) -> ToolOutput {
        let out = stop::stopped();
        if tool.acts() {
            self.cursor.show(CursorEvent::Refused {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at: None,
                reason: stop::STOPPED_CAPTION.to_string(),
                ends: true,
            });
        }
        self.write_audit(ctx, name, None, &out);
        out
    }

    /// A call the person stopped while it ran ends with the stopped error,
    /// saying whether it acted before its checkpoint.
    fn end_if_stopped(&self, ctx: &CallContext, out: ToolOutput) -> ToolOutput {
        if out.code.as_deref() == Some(stop::STOPPED_CODE) || !self.stops.is_stopped(&ctx.session) {
            return out;
        }
        let acted = !out.is_error && out.body.get("completed") != Some(&json!(0));
        let mut stopped = stop::stopped_in_flight(acted);
        // A batch says how far it got, and the focus guard's report (a focus it
        // put back) stays with the call.
        for key in ["completed", "of", "stopped_at", "results", "focus"] {
            if let Some(value) = out.body.get(key) {
                set_key(&mut stopped.body, key, value.clone());
            }
        }
        stopped
    }

    fn dispatch(
        &self,
        tool: &tools::Tool,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let config = self.config();
        // Before anything is read or posted: a locked screen admits only what
        // cannot reach its password field ([`crate::locked`]). A batch's
        // steps come back here one by one.
        let kind = crate::locked::kind_of(tool.name, args);
        if !crate::locked::admits(kind, config.while_locked) && self.desktop.screen_locked() {
            let (message, detail) = crate::locked::refusal(tool.name, kind, config.while_locked);
            let mut out = ToolOutput::error(crate::locked::CODE, message);
            set_key(&mut out.body, "whileLocked", detail);
            return Err(out);
        }
        match tool.name {
            "status" => Ok((self.status(&config), None)),
            "list_displays" => {
                self.authorize(&config, ctx, Access::Discover, None, false)?;
                let body = crate::displays::list(self.desktop.as_ref())
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((ToolOutput::ok(body), None))
            }
            "list_machines" => Ok((
                ToolOutput::ok(
                    json!({"machines": [], "note": "Only this machine is reachable from here."}),
                ),
                None,
            )),
            "list_apps" => {
                self.authorize(&config, ctx, Access::Discover, None, false)?;
                let saved = self.sessions.saved();
                let apps = self.desktop.list_apps().map_err(|e| ToolOutput::desktop(&e))?;
                let apps: Vec<Value> = apps
                    .into_iter()
                    .map(|a| {
                        let t = TargetApp { id: a.id.clone(), name: a.name.clone() };
                        let mut v = serde_json::to_value(&a).unwrap_or(Value::Null);
                        if let Some(r) = self.blocked(&config, &saved, &t) {
                            set_key(&mut v, "denied", json!(true));
                            set_key(&mut v, "denied_reason", json!(r.code()));
                        }
                        v
                    })
                    .collect();
                Ok((ToolOutput::ok(json!({"apps": apps})), None))
            }
            "list_windows" => {
                self.authorize(&config, ctx, Access::Discover, None, false)?;
                let filter = args_str(args, "app_id");
                let saved = self.sessions.saved();
                let windows = self.windows()?;
                let names = self.app_names();
                let list: Vec<Value> = windows
                    .into_iter()
                    .filter(|w| filter.is_none_or(|f| w.app_id.eq_ignore_ascii_case(f)))
                    .map(|w| {
                        let t = self.target_of(&w, &names);
                        let blocked = self.blocked(&config, &saved, &t);
                        let mut v = serde_json::to_value(&w).unwrap_or(Value::Null);
                        set_key(&mut v, "window_id", json!(w.id));
                        if let Some(o) = v.as_object_mut() {
                            o.remove("id");
                        }
                        set_key(&mut v, "app_name", json!(t.name));
                        if let Some(r) = blocked {
                            set_key(&mut v, "title", json!(""));
                            set_key(&mut v, "denied", json!(true));
                            set_key(&mut v, "denied_reason", json!(r.code()));
                        }
                        v
                    })
                    .collect();
                Ok((ToolOutput::ok(json!({"windows": list})), None))
            }
            // Not focus-guarded on purpose (Access::Discover): asking for a
            // permission shows the OS prompt or opens System Settings in front,
            // which is what the person must see to grant it. Only the person at
            // this machine grants its OS permissions, so another machine's agent
            // never raises the prompt here, and the mode still applies (Off).
            "request_permission" => {
                if let OriginKind::Remote { .. } = ctx.origin {
                    return Err(ToolOutput::error(
                        Refusal::RemoteNotAllowed.code(),
                        "Only the person at this machine can grant its permissions: ask them to \
                         open Settings > Computer Use there.",
                    ));
                }
                self.authorize(&config, ctx, Access::Discover, None, false)?;
                let which = need(args, "permission")?;
                self.desktop.request_permission(which).map_err(|e| ToolOutput::desktop(&e))?;
                Ok((ToolOutput::ok(json!({"requested": which})), None))
            }
            "screenshot" => self.screenshot(&config, ctx, args),
            "record" => self.record(&config, ctx, args),
            "get_ui_tree" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.app_of(&window);
                self.authorize(&config, ctx, Access::Observe, Some(&app), false)?;
                self.cursor.show(CursorEvent::Look {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: Some(center(&window.frame)),
                    rect: Some(window.frame),
                });
                let max_nodes = args
                    .get("max_nodes")
                    .and_then(Value::as_u64)
                    .map(|n| n.clamp(1, 5000) as usize)
                    .unwrap_or(TreeOptions::default().max_nodes);
                let mut tree = self
                    .walk_tree_for(
                        Some(&ctx.session),
                        &window.id,
                        TreeOptions { max_nodes, ..TreeOptions::default() },
                    )
                    .map_err(|e| ToolOutput::desktop(&e))?;
                let geometry = self.geometry_for(ctx, &window);
                rewrite_frames(&mut tree.root, &geometry);
                let mut body = serde_json::Map::new();
                body.insert("window_id".into(), json!(tree.window_id));
                body.insert("truncated".into(), json!(tree.truncated));
                self.present(
                    &ctx.session,
                    &window.id,
                    &tree.root,
                    tree.truncated,
                    crate::observe::Look::from_args(args),
                    &mut body,
                    Vec::new(),
                    None,
                    observe_glue::Pixels::NotRead,
                );
                Ok((ToolOutput::ok(Value::Object(body)), Some(app)))
            }
            "click" => self.click(&config, ctx, args),
            "move_pointer" => self.move_pointer(&config, ctx, args),
            "type_text" => {
                let window = self.window(need(args, "window_id")?)?;
                let text = args
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolOutput::error("invalid_arguments", "text is required"))?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery, false)?;
                let guarded = self.guard(ctx, "type_text", &window, args, None)?;
                self.cursor.show(CursorEvent::Typing {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: None,
                    text: caption(text),
                });
                let element = guarded.element.as_deref();
                let out = if self.settle_mode(args) == SettleMode::Anthropic {
                    self.type_paced(&ctx.session, &window.id, element, text, delivery)?
                } else {
                    self.desktop
                        .type_text(&window.id, element, text, delivery)
                        .map_err(|e| ToolOutput::desktop(&e))?
                };
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "press_key" => {
                let window = self.window(need(args, "window_id")?)?;
                let combo = KeyCombo::parse(need(args, "keys")?)
                    .map_err(|e| ToolOutput::error("invalid_arguments", e))?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery, false)?;
                self.cursor.show(CursorEvent::Keys {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: None,
                    keys: need(args, "keys")?.to_string(),
                });
                let out = self
                    .desktop
                    .press_keys(&window.id, &combo, delivery)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "scroll" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background, true)?;
                let guarded = self.guard(ctx, "scroll", &window, args, None)?;
                let target = match guarded.element {
                    Some(element_id) => PointerTarget::Element { window_id: window.id, element_id },
                    None => self.pointer_target(ctx, &window, args)?,
                };
                let dx = args_f64(args, "dx").unwrap_or(0.0).clamp(-200.0, 200.0);
                let dy = args_f64(args, "dy").unwrap_or(0.0).clamp(-200.0, 200.0);
                if let PointerTarget::Point { point, .. } = &target {
                    self.glide(ctx, *point);
                }
                let out =
                    self.desktop.scroll(&target, dx, dy).map_err(|e| ToolOutput::desktop(&e))?;
                let at = match &target {
                    PointerTarget::Point { point, .. } => Some(*point),
                    PointerTarget::Element { .. } => out.cursor_at,
                };
                if let Some(at) = at {
                    self.cursor.show(CursorEvent::Scroll {
                        session: ctx.session.clone(),
                        label: ctx.label.clone(),
                        at,
                        dx,
                        dy,
                    });
                }
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "drag" => {
                let window = self.window(need(args, "window_id")?)?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery, true)?;
                let g = self.pixel_geometry(ctx, &window)?;
                let from = g.to_global(need_f64(args, "from_x")?, need_f64(args, "from_y")?);
                let to = g.to_global(need_f64(args, "to_x")?, need_f64(args, "to_y")?);
                self.glide(ctx, from);
                let out = self
                    .desktop
                    .drag(&window.id, from, to, parse_button(args)?, delivery)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                self.cursor.show(CursorEvent::Drag {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    from,
                    to,
                });
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "set_value" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background, false)?;
                need(args, "element_id")?;
                let guarded = self.guard(ctx, "set_value", &window, args, None)?;
                let element = guarded.element.unwrap_or_default();
                let value = args.get("value").and_then(Value::as_str).unwrap_or_default();
                let out = self
                    .desktop
                    .set_value(&window.id, &element, value)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "perform_action" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background, false)?;
                need(args, "element_id")?;
                let guarded = self.guard(ctx, "perform_action", &window, args, None)?;
                if let Some(done) = guarded.done {
                    return Ok((done, Some(app)));
                }
                let element = guarded.element.unwrap_or_default();
                let out = self
                    .desktop
                    .perform_action(&window.id, &element, need(args, "action")?)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "launch_app" => {
                let id = need(args, "app_id")?;
                // Policy sees what would really start (cmd -> cmd.exe,
                // konsole -> org.kde.konsole), never only the agent's words.
                let identities =
                    self.desktop.launch_identities(id).map_err(|e| ToolOutput::desktop(&e))?;
                let saved = self.sessions.saved();
                for identity in &identities {
                    let candidate = TargetApp { id: identity.clone(), name: id.to_string() };
                    if let Some(refusal) = policy::is_blocked(&config, &candidate) {
                        return Err(ToolOutput::refused(&refusal, Some(&candidate)));
                    }
                    if saved.is_never(identity) {
                        return Err(ToolOutput::refused(&Refusal::NeverAllowed, Some(&candidate)));
                    }
                }
                // Where launch_app takes an identity (macOS: a bundle id), a
                // name that resolved to several apps is refused before anyone
                // is asked, so no approval names an app that will not run; one
                // identity is launched as is, the one policy just checked
                // (resolving the name again could find another after an index
                // rebuild). Identities that are not ids to launch by (Windows'
                // cmd -> cmd.exe) keep the name.
                let by_identity = self.desktop.launches_by_identity();
                if by_identity && identities.len() > 1 {
                    return Err(ToolOutput::error(
                        "unsupported",
                        format!(
                            "{id:?} names several apps ({}); launch one by its bundle id",
                            identities.join(", ")
                        ),
                    ));
                }
                let primary = identities.first().cloned().unwrap_or_else(|| id.to_string());
                let app = TargetApp { id: primary, name: id.to_string() };
                self.authorize(&config, ctx, Access::Act, Some(&app), false)?;
                let launch = match identities.as_slice() {
                    [only] if by_identity => only.as_str(),
                    _ => id,
                };
                let started =
                    self.desktop.launch_app(launch).map_err(|e| ToolOutput::desktop(&e))?;
                // The app that started is checked too; a blocked one is reported, not handed over.
                let started_app = TargetApp { id: started.id.clone(), name: started.name.clone() };
                if let Some(refusal) = policy::is_blocked(&config, &started_app) {
                    return Err(ToolOutput::refused(&refusal, Some(&started_app)));
                }
                Ok((
                    ToolOutput::ok(serde_json::to_value(started).unwrap_or(Value::Null)),
                    Some(app),
                ))
            }
            "wait" => self.wait(&config, ctx, args),
            "batch" => self.batch(ctx, args),
            "list_alerts" => self.list_alerts(&config, ctx),
            "dismiss_alert" => self.dismiss_alert(&config, ctx, args),
            other => Err(ToolOutput::error("unknown_tool", format!("unknown tool {other:?}"))),
        }
    }

    fn status(&self, config: &PolicyConfig) -> ToolOutput {
        ToolOutput::ok(json!({
            "engine": "cmux Computer Use",
            "version": env!("CARGO_PKG_VERSION"),
            "machine": self.machine_name,
            "platform": self.desktop.info(),
            "permissions": self.desktop.permissions(),
            "mode": config.mode.as_str(),
            "denied_apps": config.denied_apps,
            "allow_own_machines": config.allow_own_machines,
            "pause_on_takeover": config.pause_on_takeover,
            "allow_foreground": config.allow_foreground,
            "cursor": config.show_cursor,
            "cloud_vm": config.cloud_vm,
            "menus": config.menus.as_str(),
            "screen_locked": self.desktop.screen_locked(),
            "while_locked": config.while_locked,
            "alerts": config.alerts,
            // Which binary answers, so `cmux computer-use doctor` can say
            // whether the staged, verified helper is the one running.
            "worker": {
                "executable": std::env::current_exe().ok(),
                "pid": std::process::id(),
            },
        }))
    }

    /// Protected, denied, or answered Never: hidden from listings and painted
    /// out of screenshots.
    fn blocked(
        &self,
        config: &PolicyConfig,
        saved: &policy::SavedApprovals,
        app: &TargetApp,
    ) -> Option<Refusal> {
        policy::is_blocked(config, app)
            .or_else(|| saved.is_never(&app.id).then_some(Refusal::NeverAllowed))
    }

    /// The on-screen windows over `window_id`'s window, from any process,
    /// sorted ids (None when the window or the list cannot be read).
    fn window_ids_over_target(&self, window_id: &str) -> Option<Vec<String>> {
        let w = self.window(window_id).ok()?;
        self.desktop.window_ids_over(&w.frame).ok()
    }

    fn windows(&self) -> Result<Vec<Window>, ToolOutput> {
        self.desktop.list_windows().map_err(|e| ToolOutput::desktop(&e))
    }

    fn window(&self, id: &str) -> Result<Window, ToolOutput> {
        self.desktop.window(id).map_err(|e| ToolOutput::desktop(&e))?.ok_or_else(|| {
            ToolOutput::error(
                "target_not_found",
                format!("no window {id:?}; call list_windows for current ids"),
            )
        })
    }

    fn app_names(&self) -> HashMap<String, String> {
        self.desktop
            .list_apps()
            .map(|apps| apps.into_iter().map(|a| (a.id.to_ascii_lowercase(), a.name)).collect())
            .unwrap_or_default()
    }

    /// The app of one window, named by the desktop's lookup for it alone.
    fn app_of(&self, window: &Window) -> TargetApp {
        TargetApp {
            id: window.app_id.clone(),
            name: self.desktop.app_name(window).unwrap_or_else(|| window.app_id.clone()),
        }
    }

    fn target_of(&self, window: &Window, names: &HashMap<String, String>) -> TargetApp {
        TargetApp {
            id: window.app_id.clone(),
            name: names
                .get(&window.app_id.to_ascii_lowercase())
                .cloned()
                .unwrap_or_else(|| window.app_id.clone()),
        }
    }

    /// The policy check, asking the person when the mode says so.
    fn authorize(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        access: Access,
        app: Option<&TargetApp>,
        foreground: bool,
    ) -> Result<(), ToolOutput> {
        let grant_key = app.map(|a| a.id.as_str()).unwrap_or("display");
        let saved = self.sessions.saved();
        let session_granted = self.sessions.has_grant(&ctx.session, grant_key);
        let decision = policy::decide(
            config,
            &saved,
            &Request { access, target: app, origin: &ctx.origin, foreground, session_granted },
        );
        match decision {
            Decision::Allow => {
                self.sessions.touch(&ctx.session, grant_key);
                Ok(())
            }
            Decision::Refuse(r) => Err(ToolOutput::refused(&r, app)),
            Decision::Ask { remember } => {
                let target = app
                    .cloned()
                    .unwrap_or(TargetApp { id: "display".into(), name: "the whole screen".into() });
                let answer = self.approver.ask(&Question {
                    session: ctx.session.clone(),
                    agent: ctx.label.clone(),
                    app: target.clone(),
                    remember,
                    from_machine: match &ctx.origin {
                        OriginKind::Remote { machine, .. } => Some(machine.clone()),
                        OriginKind::Local => None,
                    },
                });
                match answer {
                    Answer::AllowOnce => Ok(()),
                    Answer::AllowSession => {
                        self.sessions.grant(&ctx.session, &target.id);
                        Ok(())
                    }
                    Answer::AlwaysAllow if remember => {
                        self.sessions.update_saved(|s| s.set_always(&target.id));
                        Ok(())
                    }
                    Answer::AlwaysAllow => {
                        self.sessions.grant(&ctx.session, &target.id);
                        Ok(())
                    }
                    Answer::Never if remember => {
                        self.sessions.update_saved(|s| s.set_never(&target.id));
                        Err(ToolOutput::refused(&Refusal::NeverAllowed, Some(&target)))
                    }
                    Answer::Deny | Answer::Never => Err(ToolOutput::error(
                        "approval_denied",
                        format!("The person did not allow {} to use {}.", ctx.label, target.name),
                    )),
                    Answer::Unavailable => Err(ToolOutput::error(
                        "approval_unavailable",
                        format!(
                            "Using {} needs the person's approval and nobody answered. Ask them to allow it in the cmux prompt, or to change Settings > Computer Use > Mode.",
                            target.name
                        ),
                    )),
                }
            }
        }
    }

    /// Policy for an acting call on `window`, then the takeover wait.
    fn act_on(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        window: &Window,
        delivery: Delivery,
        pointer: bool,
    ) -> Result<TargetApp, ToolOutput> {
        let app = self.app_of(window);
        self.authorize(config, ctx, Access::Act, Some(&app), delivery == Delivery::Foreground)?;
        self.sync_menu_policy(config);
        // Background input meets the person's own only where theirs goes:
        // foreground input is system-wide; keys posted to an app reach its key
        // window (a sheet the person types in, too), so any window of the
        // frontmost app collides; pointer input goes to the window under the
        // person's pointer.
        let pointer_in = |w: &Window| self.desktop.pointer().is_some_and(|p| contains(&w.frame, p));
        let could_collide = delivery == Delivery::Foreground
            || window.focused
            || self.desktop.is_frontmost_app(window)
            || (pointer && pointer_in(window));
        if config.pause_on_takeover && could_collide && !self.takeover.wait_idle(Duration::ZERO) {
            // The person is using the mouse or keyboard right now: show that the
            // agent waits for them before it waits.
            self.cursor.show(CursorEvent::Paused {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at: Some(center(&window.frame)),
            });
        }
        if config.pause_on_takeover && could_collide && !self.takeover.wait_idle(TAKEOVER_WAIT) {
            return Err(ToolOutput::error(
                "person_in_control",
                "The person is using the mouse or keyboard; the agent paused and will not act until they stop. Try again shortly.",
            ));
        }
        Ok(app)
    }

    fn geometry_for(&self, ctx: &CallContext, window: &Window) -> Geometry {
        lock(&self.seen)
            .get(&(ctx.session.clone(), format!("w:{}", window.id)))
            .map(|(g, _)| *g)
            .unwrap_or(Geometry {
                width: window.frame.width as u32,
                height: window.frame.height as u32,
                points_per_pixel: 1.0,
                origin: Point { x: window.frame.x, y: window.frame.y },
            })
    }

    /// How the agent's pixels of `window` map to the desktop: its latest
    /// screenshot of the window, at the window's origin now (a window that
    /// moved since is still hit where the agent saw it). Refused when the
    /// session has no screenshot of the window (a retry, a worker restart, an
    /// ended session: a guessed scale is twice off on a Retina display), or
    /// when the window's size changed since (the pixels no longer say where).
    fn pixel_geometry(&self, ctx: &CallContext, window: &Window) -> Result<Geometry, ToolOutput> {
        let stored = lock(&self.seen)
            .get(&(ctx.session.clone(), format!("w:{}", window.id)))
            .map(|(g, _)| *g);
        let Some(g) = stored else {
            return Err(ToolOutput::error(
                "no_screenshot",
                format!(
                    "x and y are pixels of your latest screenshot of window {}, and there is none in this session (after a retry or a restart, or it ended). Take a screenshot of this window first, or pass element_id.",
                    window.id
                ),
            ));
        };
        let (w, h) = (g.width as f64 * g.points_per_pixel, g.height as f64 * g.points_per_pixel);
        if (w - window.frame.width).abs() > 2.0 || (h - window.frame.height).abs() > 2.0 {
            return Err(ToolOutput::error(
                "window_resized",
                format!(
                    "window {} is {}x{} points now and was {}x{} in your latest screenshot of it, so its pixels no longer say where to act. Take a new screenshot of it first, or pass element_id.",
                    window.id,
                    window.frame.width.round(),
                    window.frame.height.round(),
                    w.round(),
                    h.round()
                ),
            ));
        }
        Ok(Geometry { origin: Point { x: window.frame.x, y: window.frame.y }, ..g })
    }

    fn pointer_target(
        &self,
        ctx: &CallContext,
        window: &Window,
        args: &Value,
    ) -> Result<PointerTarget, ToolOutput> {
        if let Some(element) = args_str(args, "element_id") {
            return Ok(PointerTarget::Element {
                window_id: window.id.clone(),
                element_id: element.to_string(),
            });
        }
        let point = match (args_f64(args, "x"), args_f64(args, "y")) {
            (Some(x), Some(y)) => self.pixel_geometry(ctx, window)?.to_global(x, y),
            // Scroll with no point: the window's center, in points.
            _ => center(&window.frame),
        };
        Ok(PointerTarget::Point { window_id: window.id.clone(), point })
    }

    fn glide(&self, ctx: &CallContext, at: Point) {
        self.cursor.show(CursorEvent::Move {
            session: ctx.session.clone(),
            label: ctx.label.clone(),
            at,
        });
    }

    fn outcome(&self, ctx: &CallContext, out: crate::desktop::ActionOutcome) -> ToolOutput {
        if let Some(at) = out.cursor_at {
            self.glide(ctx, at);
        }
        ToolOutput::ok(serde_json::to_value(&out).unwrap_or(Value::Null))
    }

    fn click(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let button = parse_button(args)?;
        let delivery = parse_delivery(args)?;
        let count = args.get("count").and_then(Value::as_u64).unwrap_or(1).clamp(1, 3) as u8;
        let modifiers: Vec<String> = args
            .get("modifiers")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        let modifiers = KeyCombo::parse_modifiers(&modifiers)
            .map_err(|e| ToolOutput::error("invalid_arguments", e))?;
        let (window, target) = self.pointer_window(ctx, args, "click")?;
        if args_str(args, "menu_item").is_some() && !self.desktop.picks_menu_items() {
            return Err(ToolOutput::error(
                "unsupported",
                "menu_item is not supported on this platform yet; click to open the menu, then press its item",
            ));
        }
        let app = self.act_on(config, ctx, &window, delivery, true)?;
        let target = match target {
            Some(t) => t,
            None => self.pointer_target(ctx, &window, args)?,
        };
        let point = match &target {
            PointerTarget::Point { point, .. } if args_str(args, "window_id").is_some() => {
                Some(*point)
            }
            _ => None,
        };
        let guarded = self.guard(ctx, "click", &window, args, point)?;
        if let Some(done) = guarded.done {
            return Ok((done, Some(app)));
        }
        let target = match (guarded.element, target) {
            (Some(element_id), PointerTarget::Element { window_id, .. }) => {
                PointerTarget::Element { window_id, element_id }
            }
            (_, target) => target,
        };
        if let PointerTarget::Point { point, .. } = &target {
            self.glide(ctx, *point);
        }
        let out = self
            .desktop
            .click(
                &target,
                &ClickSpec {
                    button,
                    count,
                    modifiers,
                    delivery,
                    gap: if self.settle_mode(args) == SettleMode::Anthropic {
                        ANTHROPIC_CLICK_GAP
                    } else {
                        Duration::ZERO
                    },
                    menu_item: args_str(args, "menu_item").map(str::to_string),
                },
            )
            .map_err(|e| ToolOutput::desktop(&e))?;
        let at = out.cursor_at.or(match &target {
            PointerTarget::Point { point, .. } => Some(*point),
            PointerTarget::Element { .. } => None,
        });
        if let Some(at) = at {
            self.cursor.show(CursorEvent::Click {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at,
                button: format!("{button:?}").to_lowercase(),
                count,
            });
        }
        Ok((ToolOutput::ok(serde_json::to_value(&out).unwrap_or(Value::Null)), Some(app)))
    }

    fn screenshot(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        self.capture_for(config, ctx, args, true, Check::Authorize)
    }

    /// Types `text` the way Anthropic's reference tool does: in groups of
    /// [`ANTHROPIC_TYPING_GROUP`] characters, [`ANTHROPIC_TYPING_DELAY`]
    /// between keys. Every character goes to `element` (when one was given),
    /// so each passes the same route, focus guard and caret gate: none lands
    /// in another field that happens to have focus. A refusal partway says
    /// how many characters went into the element first. The result is
    /// confirmed only when every character was.
    fn type_paced(
        &self,
        session: &str,
        window_id: &str,
        element: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> Result<crate::desktop::ActionOutcome, ToolOutput> {
        let chars: Vec<char> = text.chars().collect();
        let mut last = crate::desktop::ActionOutcome::default();
        let mut sent = 0usize;
        let mut all_confirmed = true;
        for group in chars.chunks(ANTHROPIC_TYPING_GROUP) {
            for (i, c) in group.iter().enumerate() {
                if i > 0 {
                    (self.sleep)(ANTHROPIC_TYPING_DELAY);
                }
                // Checkpoint: the person's Stop ends the typing between two keys.
                self.stops.check(session)?;
                last = match self.desktop.type_text(window_id, element, &c.to_string(), delivery) {
                    Ok(out) => out,
                    Err(e) if sent > 0 => {
                        let mut out = ToolOutput::desktop(&e);
                        set_key(&mut out.body, "typed_before_refusal", Value::from(sent as u64));
                        let error = Value::from(format!(
                            "{}; {sent} of {} characters were typed {} before this, and none after",
                            out.body.get("error").and_then(Value::as_str).unwrap_or("refused"),
                            chars.len(),
                            if element.is_some() { "into the element" } else { "at the caret" }
                        ));
                        set_key(&mut out.body, "error", error);
                        return Err(out);
                    }
                    Err(e) => return Err(ToolOutput::desktop(&e)),
                };
                sent += 1;
                all_confirmed &= last.evidence == "confirmed";
            }
        }
        // One character's read-back cannot confirm the whole text.
        if !all_confirmed && chars.len() > 1 {
            last.evidence = "delivered".into();
            last.expect = None;
            if last.note.is_empty() {
                last.note = format!(
                    "typed {} characters one by one; not every one was confirmed",
                    chars.len()
                );
            }
        }
        Ok(last)
    }

    /// `wait`: sleeps `ms` (default [`WAIT_DEFAULT`], at most [`WAIT_MAX`];
    /// `duration` in seconds is read too, as Anthropic's tool takes it), then
    /// returns the window's state, or a display screenshot without a window.
    fn wait(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let wanted = match (args_f64(args, "ms"), args_f64(args, "duration")) {
            (Some(ms), _) => ms,
            (None, Some(seconds)) => seconds * 1000.0,
            (None, None) => WAIT_DEFAULT.as_millis() as f64,
        };
        if wanted < 0.0 {
            return Err(ToolOutput::error("invalid_arguments", "the wait cannot be negative"));
        }
        if wanted > WAIT_MAX.as_millis() as f64 {
            return Err(ToolOutput::error(
                "invalid_arguments",
                format!("a wait is at most {} s", WAIT_MAX.as_secs()),
            ));
        }
        let waited = Duration::from_millis(wanted.round() as u64);
        let target = match args_str(args, "window_id") {
            Some(id) => {
                let window = self.window(id)?;
                let app = self.app_of(&window);
                self.authorize(config, ctx, Access::Observe, Some(&app), false)?;
                Some((id.to_string(), app))
            }
            None => {
                self.authorize(config, ctx, Access::Observe, None, false)?;
                None
            }
        };
        (self.sleep)(waited);
        let mut out = ToolOutput::ok(json!({"waited_ms": waited.as_millis() as u64}));
        match target {
            Some((id, app)) => {
                self.attach_state(ctx, &id, &app, &mut out, SettleMode::Openai, false, None);
                Ok((out, Some(app)))
            }
            None => {
                let (shot, _) = self.capture_for(
                    config,
                    ctx,
                    &json!({"force": true}),
                    false,
                    Check::Authorize,
                )?;
                set_key(&mut out.body, "state", shot.body);
                out.png_base64 = shot.png_base64;
                Ok((out, None))
            }
        }
    }

    /// The call's `settle` argument, else the setting.
    fn settle_mode(&self, args: &Value) -> SettleMode {
        args_str(args, "settle").and_then(SettleMode::parse).unwrap_or(self.config().settle)
    }

    /// Waits as `mode` says after an acting call and adds the window's
    /// screenshot and tree to `out` as `state`:
    /// - adaptive: [`Settle`]: a floor (ended early by the app's signal and
    ///   its burst), then a screenshot every step until it differs from what
    ///   the agent last saw, up to the ceiling (elapsed time, captures
    ///   included); an unchanged window returns no image. A watched app that
    ///   sent no signal and whose window is unchanged at the first capture
    ///   returns then: its frames are not waited for.
    /// - anthropic: [`ANTHROPIC_SCREENSHOT_DELAY`] (none after typing), then
    ///   the screenshot, always with its image.
    /// - openai: the screenshot at once, always with its image.
    ///
    /// The window must still be `app`'s and `app` still allowed before every
    /// capture and the tree; a window that closed, changed app or became
    /// denied leaves the action's result as it is, with the reason.
    #[allow(clippy::too_many_arguments)] // each argument is one fact of the call
    fn attach_state(
        &self,
        ctx: &CallContext,
        window_id: &str,
        app: &TargetApp,
        out: &mut ToolOutput,
        mode: SettleMode,
        typed: bool,
        watch: Option<&dyn Watch>,
    ) -> Option<u64> {
        let s = self.settle;
        let start = (self.clock)();
        let args = json!({"window_id": window_id});
        let forced = json!({"window_id": window_id, "force": true});
        let mut captures = 0u32;
        // The app's signals at the previous capture: a change ends the wait
        // once the app has gone quiet (no new signal since the capture
        // before), so an effect still in progress is waited for, within
        // the ceiling.
        let mut signals_then = watch.map(|w| w.signals().total());
        let shot = match mode {
            SettleMode::Adaptive => {
                // The floor ends at the app's own signal (and its burst),
                // not at a fixed time: a watch that can block wakes on it.
                // The watch counts from before the action (it starts at 0
                // then): a signal the app sent while the action ran counts.
                let signals_before = watch.map(|_| 0u32);
                self.wait_change(watch, signals_then.unwrap_or(0), s.floor);
                // The newest capture that changed: a later one compares with
                // it, so an unchanged one after it means the window held.
                let mut changed_shot: Option<ToolOutput> = None;
                let mut first = true;
                loop {
                    // Checkpoint: the person's Stop ends the settle wait.
                    if let Err(stopped) = self.stops.check(&ctx.session) {
                        break Err(stopped);
                    }
                    let config = self.config();
                    captures += 1;
                    match self.capture_for(&config, ctx, &args, false, Check::StillAllowed(app)) {
                        Ok((shot, _)) => {
                            let elapsed = (self.clock)().saturating_sub(start);
                            let read = watch.map(|w| w.signals());
                            let signals_now = read.as_ref().map(|r| r.total());
                            // Quiet: no new signal since the capture before,
                            // and the last one a while ago (a burst that
                            // straddles a capture is not over).
                            let quiet = signals_now == signals_then
                                && read
                                    .as_ref()
                                    .and_then(|r| r.since_last_ms)
                                    .is_none_or(|ms| ms >= QUIET_MS);
                            signals_then = signals_now;
                            let shot = if shot.body.get("unchanged") != Some(&json!(true)) {
                                changed_shot = Some(shot);
                                None
                            } else {
                                Some(shot)
                            };
                            // An app that listens and sent no signal since
                            // before the action, with its window unchanged
                            // after the floor: nothing is coming. Its frames
                            // are not waited for (Leo: "why do we ever even
                            // wait for screen frames?"); only an app without
                            // signals, or one whose signals say it changed,
                            // is watched frame by frame up to the ceiling.
                            let silent = first
                                && watch.is_some()
                                && signals_now == signals_before
                                && changed_shot.is_none();
                            first = false;
                            if silent || (changed_shot.is_some() && quiet) || elapsed >= s.ceiling {
                                // One of the two is always set.
                                match changed_shot.take().or(shot) {
                                    Some(last) => break Ok((last, elapsed)),
                                    None => break Err(ToolOutput::error("failed", "no capture")),
                                }
                            }
                            (self.sleep)(s.step.min(s.ceiling - elapsed));
                        }
                        Err(e) => break Err(e),
                    }
                }
            }
            SettleMode::Anthropic | SettleMode::Openai => {
                if mode == SettleMode::Anthropic && !typed {
                    (self.sleep)(ANTHROPIC_SCREENSHOT_DELAY);
                }
                captures = 1;
                let config = self.config();
                self.capture_for(&config, ctx, &forced, false, Check::StillAllowed(app))
                    .map(|(shot, _)| (shot, (self.clock)().saturating_sub(start)))
            }
        };
        let (shot, elapsed) = match shot {
            Ok(shot) => shot,
            Err(e) => {
                let state = json!({
                    "available": false,
                    "reason": e.body.get("error").or_else(|| e.body.get("message")).cloned().unwrap_or(json!(e.code)),
                    "next": "call list_windows, then screenshot the window you need",
                });
                set_key(&mut out.body, "state", state);
                return None;
            }
        };
        // A real settle: the adaptive wait (one capture or more); the other
        // modes capture once, right away or after a fixed delay.
        let settled =
            (mode == SettleMode::Adaptive && captures >= 1).then_some(elapsed.as_millis() as u64);
        let mut state = shot.body.clone();
        set_key(&mut state, "settle", json!(mode.as_str()));
        set_key(&mut state, "waited_ms", json!(elapsed.as_millis() as u64));
        set_key(&mut state, "captures", json!(captures));
        let config = self.config();
        if self.still_allowed(&config, ctx, window_id, app).is_ok()
            && let Ok(mut tree) = self.walk_tree_for(
                Some(&ctx.session),
                window_id,
                TreeOptions { menus: false, ..TreeOptions::default() },
            )
        {
            // The capture just recorded this window's geometry for the session.
            let seen = lock(&self.seen)
                .get(&(ctx.session.clone(), format!("w:{window_id}")))
                .map(|(g, _)| *g);
            if let Some(geometry) = seen {
                rewrite_frames(&mut tree.root, &geometry);
            }
            set_key(&mut state, "frames_in", json!("screenshot pixels"));
            set_key(&mut state, "truncated", json!(tree.truncated));
            set_key(&mut state, "root", serde_json::to_value(&tree.root).unwrap_or(Value::Null));
        }
        set_key(&mut out.body, "state", state);
        out.png_base64 = shot.png_base64;
        settled
    }

    /// Decides the action's outcome ([`crate::outcome`]) from its result,
    /// its state's `changes`, the app's signals and what changed outside
    /// the window, and writes it into the result.
    fn attach_outcome(
        &self,
        out: &mut ToolOutput,
        settled_ms: Option<u64>,
        signals: Option<crate::desktop::Signals>,
        outside: Option<Vec<String>>,
        responsive: Option<bool>,
    ) {
        let shows = out
            .body
            .as_object_mut()
            .and_then(|b| b.remove("shows"))
            .and_then(|v| v.as_str().map(String::from));
        // Where the effect must show counts only with a read-back to check
        // it: without one, nothing reads the target, so no no_effect.
        let shows = shows.filter(|_| out.body.get("expect").is_some_and(|e| !e.is_null()));
        // The route's read-back, done now that the action settled: typed
        // keys and scrolls land a little after they are posted.
        let expect = out
            .body
            .as_object_mut()
            .and_then(|b| b.remove("expect"))
            .and_then(|v| serde_json::from_value::<crate::desktop::Expect>(v).ok());
        // Every confirmed result is read again too: an app can undo an
        // effect a moment after it read back (a field that reformats or
        // rejects a value, a list that reselects).
        // The one place a result becomes, or stays, confirmed: its read-back
        // after the settle shows the intended change, and the read-back
        // states a change (before != wanted). A route's own confirmed
        // without such a read-back, or one whose wanted state already held,
        // is delivered.
        let mut already = false;
        let confirmed = out.body.get("evidence") == Some(&json!("confirmed"));
        let read = expect.map(|expect| {
            already = !expect.states_change();
            match self.desktop.read_back(&expect) {
                Some(true) if already => "already".to_string(),
                Some(true) => expect.what,
                Some(false) => "failed".to_string(),
                None => "unread".to_string(),
            }
        });
        // Only after a real settle (adaptive mode, or a batch step's own
        // read now): one capture at once, or none, proves nothing.
        let shown = settled_ms.is_some()
            && read.as_deref().is_some_and(|r| !matches!(r, "already" | "failed" | "unread"));
        if shown {
            set_key(&mut out.body, "evidence", json!("confirmed"));
        } else {
            let why = match read.as_deref() {
                Some("already") => Some(
                    "the state already matched before the action, so nothing shows it was done",
                ),
                Some("failed") if confirmed => {
                    Some("read again after the settle, the effect no longer shows")
                }
                Some("failed") => {
                    Some("read back after the settle: the intended effect does not show")
                }
                _ if confirmed && settled_ms.is_none() => {
                    Some("not watched through a settle, so the effect was not read again")
                }
                _ if confirmed => Some("the effect could not be read again after the settle"),
                _ => None,
            };
            if confirmed {
                set_key(&mut out.body, "evidence", json!("delivered"));
            }
            if let Some(why) = why {
                let mut note =
                    out.body.get("note").and_then(Value::as_str).unwrap_or_default().to_string();
                crate::outcome::append(&mut note, why);
                set_key(&mut out.body, "note", json!(note));
            }
        }
        if let Some(read) = read {
            set_key(&mut out.body, "read_back", json!(read));
        }
        // no_effect needs the target read back after the settle: a read-back
        // that could not be read leaves the effect unknown (a web field's
        // value that does not answer).
        let shows = if out.body.get("read_back") == Some(&json!("unread")) { None } else { shows };
        let facts = crate::outcome::Facts {
            evidence: out
                .body
                .get("evidence")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            shows,
            menu: out.body.get("menu").is_some_and(|m| !m.is_null()),
            settled_ms,
            changes: out.body.pointer("/state/changes").cloned(),
            signals,
            outside,
            already,
            responsive,
        };
        let verdict = crate::outcome::decide(&facts);
        crate::outcome::attach(&mut out.body, &facts, &verdict, no_visible_change_note);
    }

    /// The window is still `app`'s and `app` is still allowed (deny list,
    /// protected, Never) under `config`.
    fn still_allowed(
        &self,
        config: &PolicyConfig,
        _ctx: &CallContext,
        window_id: &str,
        app: &TargetApp,
    ) -> Result<Window, ToolOutput> {
        let window = self.window(window_id)?;
        if !window.app_id.eq_ignore_ascii_case(&app.id) {
            return Err(ToolOutput::error(
                "target_not_found",
                format!("window {window_id:?} now belongs to another app"),
            ));
        }
        let saved = self.sessions.saved();
        if let Some(refusal) = self.blocked(config, &saved, app) {
            return Err(ToolOutput::refused(&refusal, Some(app)));
        }
        if config.mode == policy::Mode::Off {
            return Err(ToolOutput::refused(&Refusal::Off, Some(app)));
        }
        Ok(window)
    }

    fn capture_for(
        &self,
        config: &PolicyConfig,
        ctx: &CallContext,
        args: &Value,
        look: bool,
        check: Check<'_>,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
        // A window capture that holds only its window's pixels needs that
        // window alone; everything else needs every window, to paint or leave
        // out the denied ones.
        let only_window =
            args_str(args, "window_id").filter(|_| self.desktop.window_capture_isolated());
        let (windows, names) = match only_window {
            Some(id) => {
                let window = self.desktop.window(id).map_err(|e| ToolOutput::desktop(&e))?;
                let names: HashMap<String, String> = window
                    .iter()
                    .map(|w| (w.app_id.to_ascii_lowercase(), self.app_of(w).name))
                    .collect();
                (window.into_iter().collect::<Vec<_>>(), names)
            }
            None => (self.windows()?, self.app_names()),
        };
        let (target, key, app, look_rect) = match args_str(args, "window_id") {
            Some(id) => {
                let window = windows.iter().find(|w| w.id == id).ok_or_else(|| {
                    ToolOutput::error("target_not_found", format!("no window {id:?}"))
                })?;
                let app = self.target_of(window, &names);
                match &check {
                    Check::Authorize => {
                        self.authorize(config, ctx, Access::Observe, Some(&app), false)?;
                    }
                    Check::StillAllowed(acted_on) => {
                        self.still_allowed(config, ctx, id, acted_on)?;
                    }
                }
                (
                    CaptureTarget::Window(id.to_string()),
                    format!("w:{id}"),
                    Some(app),
                    Some(window.frame),
                )
            }
            None => {
                match &check {
                    Check::Authorize => {
                        self.authorize(config, ctx, Access::Observe, None, false)?;
                    }
                    // The state after an action is always of its window.
                    Check::StillAllowed(_) => {
                        return Err(ToolOutput::error("invalid_arguments", "no window"));
                    }
                }
                let display = args_str(args, "display").map(str::to_string);
                let key = format!("d:{}", display.as_deref().unwrap_or("main"));
                (CaptureTarget::Display(display), key, None, None)
            }
        };
        if look {
            self.cursor.show(CursorEvent::Look {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at: look_rect.as_ref().map(center),
                rect: look_rect,
            });
        }
        // Denied, protected and Never apps never reach an agent's screenshot.
        // Where the display capture can leave whole processes out (macOS:
        // ScreenCaptureKit's application filter), the compositor leaves out
        // every window of theirs, at every level, and draws what is behind
        // them, so an allowed window in front keeps its pixels. Elsewhere, and
        // for a denied window whose process was not left out (an app that
        // started during the capture), the window is painted out whole. A
        // window capture that holds only its window's pixels (macOS) needs
        // neither. The windows are read again after the capture; if that read
        // fails, the capture is not returned.
        let saved = self.sessions.saved();
        let isolated =
            matches!(&target, CaptureTarget::Window(_)) && self.desktop.window_capture_isolated();
        let blocked_pid = |pid: u32, app: &TargetApp| -> bool {
            pid != 0 && self.blocked(config, &saved, app).is_some()
        };
        // The processes to leave out come from the capture system's own app
        // list (every app with a window at any level, helpers with their own
        // ids too) as well as the engine's lists; the capture refuses rather
        // than leave a requested, running app in, and then every denied window
        // is painted out whole instead.
        let mut left_out: Vec<u32> = Vec::new();
        let mut excluding = false;
        if matches!(&target, CaptureTarget::Display(_))
            && self.desktop.excludes_apps_from_display_capture()
            && let Ok(capture_apps) = self.desktop.capture_apps()
        {
            excluding = true;
            let listed = self.desktop.list_apps().unwrap_or_default();
            for a in capture_apps.iter().chain(listed.iter()) {
                let t = TargetApp {
                    id: if a.id.is_empty() { a.name.clone() } else { a.id.clone() },
                    name: a.name.clone(),
                };
                if blocked_pid(a.pid, &t) && !left_out.contains(&a.pid) {
                    left_out.push(a.pid);
                }
            }
            for w in &windows {
                if blocked_pid(w.pid, &self.target_of(w, &names)) && !left_out.contains(&w.pid) {
                    left_out.push(w.pid);
                }
            }
        }
        let excluded = match (&target, excluding) {
            (CaptureTarget::Display(display), true) => {
                self.desktop.capture_display_excluding(display.as_deref(), &left_out).ok()
            }
            _ => None,
        };
        if excluded.is_none() {
            excluding = false;
            left_out.clear();
        }
        let raw = match excluded {
            Some(frame) => frame,
            None => self.desktop.capture(&target).map_err(|e| ToolOutput::desktop(&e))?,
        };
        let mut redact: Vec<Rect> = Vec::new();
        if !isolated {
            let after = self.windows()?;
            for w in windows.iter().chain(after.iter()) {
                let skip = !w.on_screen
                    || w.minimized
                    || matches!(&target, CaptureTarget::Window(id) if w.id == *id)
                    || (excluding && w.pid != 0 && left_out.contains(&w.pid))
                    || self.blocked(config, &saved, &self.target_of(w, &names)).is_none();
                // The same window in both lists, unmoved, is painted once.
                if !skip && !redact.contains(&w.frame) {
                    redact.push(w.frame);
                }
            }
        }
        let previous = lock(&self.seen).get(&(ctx.session.clone(), key.clone())).map(|(_, d)| *d);
        let encoded = frame::process(raw, &redact, frame::DEFAULT_MAX_EDGE, previous, force)
            .map_err(|e| ToolOutput::error("failed", e))?;
        lock(&self.seen)
            .insert((ctx.session.clone(), key.clone()), (encoded.geometry, encoded.digest));
        if key.starts_with("d:") {
            lock(&self.last_display).insert(ctx.session.clone(), key.clone());
        }
        let mut out = ToolOutput::ok(json!({
            "target": key,
            "width": encoded.geometry.width,
            "height": encoded.geometry.height,
            "unchanged": encoded.unchanged,
            "redacted_windows": encoded.redacted,
            "left_out_apps": left_out.len(),
            "coordinates": "pass pixels of this image to click, scroll and drag",
        }));
        out.png_base64 = encoded.png_base64;
        Ok((out, app))
    }

    fn write_audit(
        &self,
        ctx: &CallContext,
        tool: &str,
        app: Option<&TargetApp>,
        out: &ToolOutput,
    ) {
        self.write_audit_with(ctx, tool, app, out, None);
    }

    fn write_audit_with(
        &self,
        ctx: &CallContext,
        tool: &str,
        app: Option<&TargetApp>,
        out: &ToolOutput,
        focus: Option<&focus::FocusReport>,
    ) {
        let Some(path) = &self.audit else { return };
        if std::fs::metadata(path).map(|m| m.len() > 5 << 20).unwrap_or(false) {
            let _ = std::fs::rename(path, path.with_extension("jsonl.1"));
        }
        let ts = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        let origin = match &ctx.origin {
            OriginKind::Local => "local".to_string(),
            OriginKind::Remote { machine, .. } => format!("remote:{machine}"),
        };
        let mut line = json!({
            "ts": ts as u64, "session": ctx.session, "agent": ctx.label, "origin": origin,
            "tool": tool, "app": app.map(|a| a.id.clone()),
            "ok": !out.is_error, "code": out.code,
            "route": out.body.get("route"),
        });
        if let Some(report) = focus {
            set_key(&mut line, "focus", report.to_json());
        }
        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        if let Ok(mut f) = options.open(path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

/// Most characters of an agent label shown to the person.
pub const LABEL_MAX_CHARS: usize = 60;

/// An agent label fit to show the person: no control characters, one line,
/// at most [`LABEL_MAX_CHARS`] characters, never empty.
pub fn safe_label(label: &str) -> String {
    let mut out = String::new();
    let mut space = false;
    for c in label.chars() {
        if c.is_control() || c.is_whitespace() {
            space = !out.is_empty();
            continue;
        }
        if space {
            out.push(' ');
            space = false;
        }
        out.push(c);
    }
    let mut out: String = out.chars().take(LABEL_MAX_CHARS).collect();
    if label.chars().filter(|c| !c.is_control()).count() > LABEL_MAX_CHARS {
        out.pop();
        out.push('\u{2026}');
    }
    if out.is_empty() { "Agent".into() } else { out }
}

/// Whether the live preview runs under `config`.
fn previews_on(config: &PolicyConfig) -> bool {
    config.live_preview && config.mode != policy::Mode::Off
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn center(r: &Rect) -> Point {
    Point { x: r.x + r.width / 2.0, y: r.y + r.height / 2.0 }
}

fn contains(r: &Rect, p: Point) -> bool {
    p.x >= r.x && p.y >= r.y && p.x < r.x + r.width && p.y < r.y + r.height
}

fn rewrite_frames(e: &mut Element, g: &Geometry) {
    if let Some(f) = &e.frame {
        e.frame = Some(g.to_pixels(f));
    }
    for c in &mut e.children {
        rewrite_frames(c, g);
    }
}

#[path = "engine_focus.rs"]
mod focus;

#[path = "engine_menus.rs"]
mod menus_glue;

/// How long after its last accessibility signal an app counts as quiet.
const QUIET_MS: u64 = 60;

/// Sets `key` on a JSON object, as `target[key] = value` does (a `Null`
/// becomes an empty object first), without its panic on any other value:
/// a non-object is left as it is.
pub(crate) fn set_key(target: &mut Value, key: &str, value: Value) {
    if target.is_null() {
        *target = Value::Object(serde_json::Map::new());
    }
    if let Value::Object(map) = target {
        map.insert(key.to_string(), value);
    }
}

/// The note a `delivered` result gets when nothing visible changed through
/// a real settle wait: the window's pixels, and the windows over it (sheets,
/// panels, a Save panel another process serves).
pub(crate) fn no_visible_change_note(waited_ms: u64) -> String {
    format!(
        "no visible change within {waited_ms} ms: this window and the windows over it looked the same in every capture. If the action should change what it shows, take a screenshot before retrying, then try another way (an element_id instead of a point, a different point, set_value, a menu item) instead of repeating it or reporting it done. An effect outside this window (copy, save, another app) is not seen here."
    )
}

/// The record written before the outcome is decided: as [`retry_record`],
/// with a confirmed route downgraded to delivered and the outcome uncertain
/// (a restart before the outcome must not return a confirmed it never got).
fn provisional_record(out: &ToolOutput) -> String {
    let mut record = out.clone();
    if record.body.get("evidence") == Some(&json!("confirmed")) {
        set_key(&mut record.body, "evidence", json!("delivered"));
    }
    if record.body.get("evidence").is_some() {
        set_key(&mut record.body, "outcome", json!("uncertain"));
        set_key(
            &mut record.body,
            "outcome_reason",
            json!("the call was cut off before its outcome was read"),
        );
    }
    retry_record(&record)
}

/// What a retried call id returns: the result without its state, image or
/// the route's internal keys (`shows`, `expect`).
fn retry_record(out: &ToolOutput) -> String {
    let mut record = out.clone();
    if let Some(body) = record.body.as_object_mut() {
        for key in ["state", "shows", "expect"] {
            body.remove(key);
        }
    }
    record.png_base64 = None;
    record.to_json().to_string()
}

#[path = "engine_observe.rs"]
mod observe_glue;

#[path = "engine_batch.rs"]
mod batch_glue;

#[path = "engine_alerts.rs"]
mod alerts_glue;

#[path = "engine_record.rs"]
mod record_glue;

#[path = "engine_window_name.rs"]
mod window_name;

#[path = "engine_pointer.rs"]
mod pointer_glue;

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "engine_focus_tests.rs"]
mod focus_tests;

#[cfg(test)]
#[path = "engine_menus_tests.rs"]
mod menus_tests;

#[cfg(test)]
#[path = "engine_observe_tests.rs"]
mod observe_tests;

#[cfg(test)]
#[path = "engine_batch_tests.rs"]
mod batch_tests;

#[cfg(test)]
#[path = "engine_alerts_tests.rs"]
mod alerts_tests;

#[cfg(test)]
#[path = "engine_record_tests.rs"]
mod record_tests;

#[cfg(test)]
#[path = "engine_pointer_tests.rs"]
mod pointer_tests;
