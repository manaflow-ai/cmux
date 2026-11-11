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
//! 6. An acting call returns the window as it is after acting: a fixed wait
//!    ([`Settle::floor`]), then screenshots until the pixels differ from what
//!    the agent last saw, up to [`Settle::ceiling`], plus its tree. One round
//!    trip per step; `observe: false` skips it.
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
    PointerTarget, Rect, TreeOptions, Window,
};
use crate::frame::{self, Geometry};
use crate::keys::KeyCombo;
use crate::policy::{
    self, Access, Decision, OriginKind, PolicyConfig, Refusal, Request, SettleMode, TargetApp,
};
use crate::session::{Prior, Sessions};
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
}

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

    /// The MCP `tools/call` result.
    pub fn to_mcp(&self) -> Value {
        let mut content = vec![json!({"type": "text", "text": self.body.to_string()})];
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
/// fixed `floor` first (most apps redraw within it), then a screenshot every
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
/// The tools a `batch` may run.
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
        }
    }
}

pub struct Engine {
    desktop: Arc<dyn Desktop>,
    config: RwLock<PolicyConfig>,
    sessions: Sessions,
    cursor: Arc<dyn CursorSink>,
    approver: Arc<dyn Approver>,
    takeover: Arc<dyn PersonActivity>,
    /// (session, "w:<window>" | "d:<display>") -> what the agent last saw.
    seen: Mutex<HashMap<(String, String), (Geometry, u64)>>,
    /// session -> its latest display screenshot key.
    last_display: Mutex<HashMap<String, String>>,
    audit: Option<PathBuf>,
    machine_name: String,
    settle: Settle,
    sleep: Arc<dyn Fn(Duration) + Send + Sync>,
    clock: Arc<dyn Fn() -> Duration + Send + Sync>,
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
        Self {
            sessions: Sessions::open(parts.state_dir.as_deref()),
            desktop: parts.desktop,
            config: RwLock::new(parts.config),
            cursor: parts.cursor,
            approver: parts.approver,
            takeover: parts.takeover,
            seen: Mutex::new(HashMap::new()),
            last_display: Mutex::new(HashMap::new()),
            audit,
            machine_name: parts.machine_name,
            settle: parts.settle,
            sleep: parts.sleep,
            clock: parts.clock,
        }
    }

    pub fn config(&self) -> PolicyConfig {
        self.config.read().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Applies new settings at once; calls already past the policy check finish.
    pub fn set_config(&self, config: PolicyConfig) {
        let off = config.mode == policy::Mode::Off;
        *self.config.write().unwrap_or_else(std::sync::PoisonError::into_inner) = config;
        if off {
            self.sessions.revoke_all(None);
        }
    }

    pub fn sessions(&self) -> &Sessions {
        &self.sessions
    }

    /// The agent session ended: hide its cursor and forget what it saw.
    pub fn end_session(&self, session: &str) {
        self.cursor.show(CursorEvent::Hide { session: session.to_string() });
        lock(&self.seen).retain(|(s, _), _| s != session);
        lock(&self.last_display).remove(session);
    }

    pub fn call(&self, ctx: &CallContext, name: &str, args: &Value) -> ToolOutput {
        // The label reaches the person (approval panel, cursor, notifications):
        // any caller with the socket secret sets it, so it is bounded here.
        let safe;
        let ctx = if safe_label(&ctx.label) == ctx.label {
            ctx
        } else {
            safe = CallContext { label: safe_label(&ctx.label), ..ctx.clone() };
            &safe
        };
        let Some(tool) = tools::find(name) else {
            return ToolOutput::error("unknown_tool", format!("unknown tool {name:?}"));
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
        let mut guard = self.focus_begin(tool, &args);
        let (mut out, app) = match self.dispatch(tool, ctx, &args) {
            Ok((out, app)) => (out, app),
            Err(out) => (out, None),
        };
        let mut focus = guard.as_mut().map(|g| self.focus_after_action(g, &out));
        if let Some(call_id) = acting_id {
            self.sessions.remember(&ctx.session, call_id, out.to_json().to_string());
        }
        if tool.acts()
            && let Some(reason) = out.code.as_deref().and_then(refusal_caption)
        {
            self.cursor.show(CursorEvent::Refused {
                session: ctx.session.clone(),
                label: ctx.label.clone(),
                at: None,
                reason: reason.to_string(),
            });
        }
        // After the record: a retry returns the action's result, and the agent
        // takes a fresh screenshot for the state then.
        // A batch attaches its own state, once, at its end.
        if !out.is_error
            && tools::OBSERVES.contains(&name)
            && name != "batch"
            && args.get("observe").and_then(Value::as_bool) != Some(false)
            && let Some(window_id) = args_str(&args, "window_id")
            && let Some(app) = &app
        {
            let mode = self.settle_mode(&args);
            self.attach_state(ctx, window_id, app, &mut out, mode, name == "type_text");
        }
        if let Some(g) = &guard {
            focus = Some(self.focus_after_settle(g, focus));
        }
        if let Some(report) = &focus {
            report.attach(&mut out);
        }
        self.write_audit_with(ctx, name, app.as_ref(), &out, focus.as_ref());
        out
    }

    fn dispatch(
        &self,
        tool: &tools::Tool,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let config = self.config();
        match tool.name {
            "status" => Ok((self.status(&config), None)),
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
                            v["denied"] = json!(true);
                            v["denied_reason"] = json!(r.code());
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
                        v["window_id"] = json!(w.id);
                        if let Some(o) = v.as_object_mut() {
                            o.remove("id");
                        }
                        v["app_name"] = json!(t.name);
                        if let Some(r) = blocked {
                            v["title"] = json!("");
                            v["denied"] = json!(true);
                            v["denied_reason"] = json!(r.code());
                        }
                        v
                    })
                    .collect();
                Ok((ToolOutput::ok(json!({"windows": list})), None))
            }
            "request_permission" => {
                let which = need(args, "permission")?;
                self.desktop.request_permission(which).map_err(|e| ToolOutput::desktop(&e))?;
                Ok((ToolOutput::ok(json!({"requested": which})), None))
            }
            "screenshot" => self.screenshot(&config, ctx, args),
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
                    .desktop
                    .ui_tree(&window.id, TreeOptions { max_nodes, ..TreeOptions::default() })
                    .map_err(|e| ToolOutput::desktop(&e))?;
                let geometry = self.geometry_for(ctx, &window);
                rewrite_frames(&mut tree.root, &geometry);
                self.hide_denied_menu_items(&config, &mut tree.root);
                Ok((
                    ToolOutput::ok(json!({
                        "window_id": tree.window_id,
                        "truncated": tree.truncated,
                        "frames_in": "screenshot pixels",
                        "root": tree.root,
                    })),
                    Some(app),
                ))
            }
            "click" => self.click(&config, ctx, args),
            "type_text" => {
                let window = self.window(need(args, "window_id")?)?;
                let text = args
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolOutput::error("invalid_arguments", "text is required"))?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery, false)?;
                self.cursor.show(CursorEvent::Typing {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: None,
                    text: caption(text),
                });
                let element = args_str(args, "element_id");
                let out = if self.settle_mode(args) == SettleMode::Anthropic {
                    self.type_paced(&window.id, element, text, delivery)?
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
                let target = self.pointer_target(ctx, &window, args)?;
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
                let g = self.geometry_for(ctx, &window);
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
                let value = args.get("value").and_then(Value::as_str).unwrap_or_default();
                let out = self
                    .desktop
                    .set_value(&window.id, need(args, "element_id")?, value)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "perform_action" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background, false)?;
                let out = self
                    .desktop
                    .perform_action(&window.id, need(args, "element_id")?, need(args, "action")?)
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
                let primary = identities.first().cloned().unwrap_or_else(|| id.to_string());
                let app = TargetApp { id: primary, name: id.to_string() };
                self.authorize(&config, ctx, Access::Act, Some(&app), false)?;
                let started = self.desktop.launch_app(id).map_err(|e| ToolOutput::desktop(&e))?;
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
        let (x, y) = match (args_f64(args, "x"), args_f64(args, "y")) {
            (Some(x), Some(y)) => (x, y),
            _ => {
                // Scroll with no point: the window's center.
                let g = self.geometry_for(ctx, window);
                (g.width as f64 / 2.0, g.height as f64 / 2.0)
            }
        };
        let point = self.geometry_for(ctx, window).to_global(x, y);
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
        let (window, target) = match args_str(args, "window_id") {
            Some(id) => {
                let window = self.window(id)?;
                if args_str(args, "element_id").is_none()
                    && (args_f64(args, "x").is_none() || args_f64(args, "y").is_none())
                {
                    return Err(ToolOutput::error(
                        "invalid_arguments",
                        "click needs element_id or x and y",
                    ));
                }
                let target = self.pointer_target(ctx, &window, args)?;
                (window, target)
            }
            None => {
                let (x, y) = (need_f64(args, "x")?, need_f64(args, "y")?);
                let key = lock(&self.last_display).get(&ctx.session).cloned().ok_or_else(|| {
                    ToolOutput::error(
                        "invalid_arguments",
                        "click with no window_id uses your latest display screenshot; take one first, or pass window_id",
                    )
                })?;
                let geometry = lock(&self.seen)
                    .get(&(ctx.session.clone(), key))
                    .map(|(g, _)| *g)
                    .ok_or_else(|| {
                    ToolOutput::error("invalid_arguments", "take a display screenshot first")
                })?;
                let point = geometry.to_global(x, y);
                let window = self
                    .windows()?
                    .into_iter()
                    .find(|w| w.on_screen && !w.minimized && contains(&w.frame, point))
                    .ok_or_else(|| {
                        ToolOutput::error("target_not_found", "no window at that point")
                    })?;
                let target = PointerTarget::Point { window_id: window.id.clone(), point };
                (window, target)
            }
        };
        let app = self.act_on(config, ctx, &window, delivery, true)?;
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

    /// Waits for the window to settle after an acting call ([`Settle`]) and
    /// adds its screenshot and tree to `out` as `state`. The ceiling counts
    /// elapsed time, captures included. The window must still be `app`'s and
    /// `app` still allowed before every capture and the tree; a window that
    /// closed, changed app or became denied leaves the action's result as it
    /// is, with the reason.
    /// Types `text` the way Anthropic's reference tool does: in groups of
    /// [`ANTHROPIC_TYPING_GROUP`] characters, [`ANTHROPIC_TYPING_DELAY`]
    /// between keys. The first character goes to `element` (it focuses it);
    /// the rest follow at the caret.
    fn type_paced(
        &self,
        window_id: &str,
        element: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> Result<crate::desktop::ActionOutcome, ToolOutput> {
        let chars: Vec<char> = text.chars().collect();
        let mut last = crate::desktop::ActionOutcome::default();
        for (group_index, group) in chars.chunks(ANTHROPIC_TYPING_GROUP).enumerate() {
            for (i, c) in group.iter().enumerate() {
                if i > 0 {
                    (self.sleep)(ANTHROPIC_TYPING_DELAY);
                }
                let first = group_index == 0 && i == 0;
                last = self
                    .desktop
                    .type_text(
                        window_id,
                        if first { element } else { None },
                        &c.to_string(),
                        delivery,
                    )
                    .map_err(|e| ToolOutput::desktop(&e))?;
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
                self.attach_state(ctx, &id, &app, &mut out, SettleMode::Openai, false);
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
                out.body["state"] = shot.body;
                out.png_base64 = shot.png_base64;
                Ok((out, None))
            }
        }
    }

    /// `batch`: OpenAI's `actions` array. Runs up to [`BATCH_MAX`] actions on
    /// one window in order, each checked like its own call, stops at the first
    /// failure, and returns one state at the end (the batch's `settle`). The
    /// batch is one call: a retried `call_id` runs none of it again.
    fn batch(
        &self,
        ctx: &CallContext,
        args: &Value,
    ) -> Result<(ToolOutput, Option<TargetApp>), ToolOutput> {
        let window_id = need(args, "window_id")?.to_string();
        let actions = args
            .get("actions")
            .and_then(Value::as_array)
            .filter(|a| !a.is_empty())
            .ok_or_else(|| ToolOutput::error("invalid_arguments", "actions is required"))?;
        if actions.len() > BATCH_MAX {
            return Err(ToolOutput::error(
                "invalid_arguments",
                format!("a batch runs at most {BATCH_MAX} actions"),
            ));
        }
        let mut results = Vec::new();
        let mut acted_on: Option<TargetApp> = None;
        let mut failed: Option<ToolOutput> = None;
        for (index, action) in actions.iter().enumerate() {
            let Some(name) = action.get("action").and_then(Value::as_str) else {
                failed = Some(ToolOutput::error(
                    "invalid_arguments",
                    format!("action {index} has no \"action\""),
                ));
                break;
            };
            let Some(tool) = tools::find(name).filter(|_| BATCHABLE.contains(&name)) else {
                failed = Some(ToolOutput::error(
                    "invalid_arguments",
                    format!("action {index}: {name:?} cannot run in a batch"),
                ));
                break;
            };
            let mut step = action.clone();
            if let Some(map) = step.as_object_mut() {
                map.remove("action");
                map.insert("window_id".into(), json!(window_id));
                if name == "wait" {
                    // A wait inside a batch only waits; the state comes once, at the end.
                    let ms = map
                        .get("ms")
                        .and_then(Value::as_f64)
                        .or_else(|| map.get("duration").and_then(Value::as_f64).map(|s| s * 1000.0))
                        .unwrap_or(WAIT_DEFAULT.as_millis() as f64)
                        .clamp(0.0, WAIT_MAX.as_millis() as f64);
                    (self.sleep)(Duration::from_millis(ms.round() as u64));
                    results
                        .push(json!({"action": name, "ok": true, "waited_ms": ms.round() as u64}));
                    continue;
                }
                if let Some(settle) = args.get("settle") {
                    map.entry("settle").or_insert(settle.clone());
                }
            }
            match self.dispatch(tool, ctx, &step) {
                Ok((done, app)) => {
                    self.write_audit(ctx, name, app.as_ref(), &done);
                    if done.is_error {
                        failed = Some(done);
                        break;
                    }
                    results.push(json!({"action": name, "ok": true, "result": done.body}));
                    acted_on = app.or(acted_on);
                }
                Err(refused) => {
                    self.write_audit(ctx, name, None, &refused);
                    failed = Some(refused);
                    break;
                }
            }
        }
        let completed = results.len();
        if let Some(failure) = &failed {
            results.push(json!({
                "action": actions.get(completed).and_then(|a| a.get("action")).cloned(),
                "ok": false,
                "code": failure.code,
                "message": failure.body.get("message").cloned(),
            }));
        }
        let mut out = ToolOutput::ok(json!({
            "completed": completed,
            "of": actions.len(),
            "stopped": failed.is_some(),
            "results": results,
        }));
        if let Some(app) = &acted_on
            && args.get("observe").and_then(Value::as_bool) != Some(false)
        {
            let mode = self.settle_mode(args);
            self.attach_state(ctx, &window_id, app, &mut out, mode, false);
        }
        Ok((out, acted_on))
    }

    /// The call's `settle` argument, else the setting.
    fn settle_mode(&self, args: &Value) -> SettleMode {
        args_str(args, "settle").and_then(SettleMode::parse).unwrap_or(self.config().settle)
    }

    /// Waits as `mode` says after an acting call and adds the window's
    /// screenshot and tree to `out` as `state`:
    /// - adaptive: [`Settle`]: a floor, then a screenshot every step until it
    ///   differs from what the agent last saw, up to the ceiling (elapsed
    ///   time, captures included); an unchanged window returns no image.
    /// - anthropic: [`ANTHROPIC_SCREENSHOT_DELAY`] (none after typing), then
    ///   the screenshot, always with its image.
    /// - openai: the screenshot at once, always with its image.
    ///
    /// The window must still be `app`'s and `app` still allowed before every
    /// capture and the tree; a window that closed, changed app or became
    /// denied leaves the action's result as it is, with the reason.
    fn attach_state(
        &self,
        ctx: &CallContext,
        window_id: &str,
        app: &TargetApp,
        out: &mut ToolOutput,
        mode: SettleMode,
        typed: bool,
    ) {
        let s = self.settle;
        let start = (self.clock)();
        let args = json!({"window_id": window_id});
        let forced = json!({"window_id": window_id, "force": true});
        let mut captures = 0u32;
        let shot = match mode {
            SettleMode::Adaptive => {
                (self.sleep)(s.floor);
                loop {
                    let config = self.config();
                    captures += 1;
                    match self.capture_for(&config, ctx, &args, false, Check::StillAllowed(app)) {
                        Ok((shot, _)) => {
                            let changed = shot.body["unchanged"] != json!(true);
                            let elapsed = (self.clock)().saturating_sub(start);
                            if changed || elapsed >= s.ceiling {
                                break Ok((shot, elapsed));
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
                out.body["state"] = json!({
                    "available": false,
                    "reason": e.body.get("message").cloned().unwrap_or(json!(e.code)),
                    "next": "call list_windows, then screenshot the window you need",
                });
                return;
            }
        };
        let mut state = shot.body.clone();
        state["settle"] = json!(mode.as_str());
        state["waited_ms"] = json!(elapsed.as_millis() as u64);
        state["captures"] = json!(captures);
        let config = self.config();
        if self.still_allowed(&config, ctx, window_id, app).is_ok()
            && let Ok(mut tree) = self.desktop.ui_tree(window_id, TreeOptions::default())
        {
            // The capture just recorded this window's geometry for the session.
            let seen = lock(&self.seen)
                .get(&(ctx.session.clone(), format!("w:{window_id}")))
                .map(|(g, _)| *g);
            if let Some(geometry) = seen {
                rewrite_frames(&mut tree.root, &geometry);
            }
            self.hide_denied_menu_items(&config, &mut tree.root);
            state["frames_in"] = json!("screenshot pixels");
            state["truncated"] = json!(tree.truncated);
            state["root"] = serde_json::to_value(&tree.root).unwrap_or(Value::Null);
        }
        out.body["state"] = state;
        out.png_base64 = shot.png_base64;
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
            line["focus"] = report.to_json();
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

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "engine_focus_tests.rs"]
mod focus_tests;

#[cfg(test)]
#[path = "engine_menus_tests.rs"]
mod menus_tests;
