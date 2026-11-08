//! Runs one tool call, in this order, for every route:
//!
//! 1. A retried acting call (same session and `call_id`) returns its first
//!    result and does nothing.
//! 2. The target app is resolved from the desktop (never from the agent's
//!    words), then [`crate::policy::decide`]; an `Ask` goes to the
//!    [`Approver`] and its answer is saved before the call goes on.
//! 3. Acting calls wait while the person is using the mouse or keyboard
//!    ([`PersonActivity`]) and fail with `person_in_control` if they keep on.
//! 4. The agent cursor glides to the target, the desktop acts, the cursor
//!    shows the click or the typing.
//! 5. Screenshots go through [`crate::frame`]; accessibility frames come back
//!    in the pixels of the agent's latest screenshot of that window.
//! 6. One audit line per call.

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
use crate::frame::{self, Geometry, Image};
use crate::keys::KeyCombo;
use crate::policy::{
    self, Access, Decision, OriginKind, PolicyConfig, Refusal, Request, TargetApp,
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
    pub image: Option<Image>,
}

impl ToolOutput {
    pub fn ok(body: Value) -> Self {
        Self { is_error: false, code: None, body, image: None }
    }
    pub fn error(code: &str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            is_error: true,
            code: Some(code.to_string()),
            body: json!({"error": message, "code": code}),
            image: None,
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
        if let Some(image) = &self.image {
            content.push(json!({"type": "image", "data": image.base64, "mimeType": image.mime}));
        }
        json!({"content": content, "isError": self.is_error})
    }

    pub fn to_json(&self) -> Value {
        json!({
            "is_error": self.is_error,
            "code": self.code,
            "body": self.body,
            "image": self.image.as_ref().map(|i| &i.base64),
            "mime": self.image.as_ref().map(|i| &i.mime),
        })
    }

    pub fn from_json(v: &Value) -> Option<Self> {
        let text = |key: &str| v.get(key).and_then(Value::as_str);
        // A worker from before JPEG frames sends `png`.
        let image = match text("image") {
            Some(data) => Some((data, text("mime").unwrap_or(frame::MIME_PNG))),
            None => text("png").map(|data| (data, frame::MIME_PNG)),
        };
        Some(Self {
            is_error: v.get("is_error")?.as_bool()?,
            code: text("code").map(str::to_string),
            body: v.get("body")?.clone(),
            image: image.map(|(data, mime)| Image { mime: mime.into(), base64: data.into() }),
        })
    }
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
}

pub struct NoTakeover;

impl PersonActivity for NoTakeover {
    fn wait_idle(&self, _limit: Duration) -> bool {
        true
    }
}

/// How long an acting call waits for the person to stop.
pub const TAKEOVER_WAIT: Duration = Duration::from_secs(15);

pub struct EngineParts {
    pub desktop: Arc<dyn Desktop>,
    pub config: PolicyConfig,
    pub state_dir: Option<PathBuf>,
    pub cursor: Arc<dyn CursorSink>,
    pub approver: Arc<dyn Approver>,
    pub takeover: Arc<dyn PersonActivity>,
    pub machine_name: String,
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
        let (out, app) = match self.dispatch(tool, ctx, &args) {
            Ok((out, app)) => (out, app),
            Err(out) => (out, None),
        };
        if let Some(call_id) = acting_id {
            self.sessions.remember(&ctx.session, call_id, out.to_json().to_string());
        }
        self.write_audit(ctx, name, app.as_ref(), &out);
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
                let app = self.target_of(&window, &self.app_names());
                self.authorize(&config, ctx, Access::Observe, Some(&app), false)?;
                self.cursor.show(CursorEvent::Look {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: Some(center(&window.frame)),
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
                let app = self.act_on(&config, ctx, &window, delivery)?;
                self.cursor.show(CursorEvent::Typing {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: None,
                    text: caption(text),
                });
                let out = self
                    .desktop
                    .type_text(&window.id, args_str(args, "element_id"), text, delivery)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "press_key" => {
                let window = self.window(need(args, "window_id")?)?;
                let combo = KeyCombo::parse(need(args, "keys")?)
                    .map_err(|e| ToolOutput::error("invalid_arguments", e))?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery)?;
                self.cursor.show(CursorEvent::Typing {
                    session: ctx.session.clone(),
                    label: ctx.label.clone(),
                    at: None,
                    text: need(args, "keys")?.to_string(),
                });
                let out = self
                    .desktop
                    .press_keys(&window.id, &combo, delivery)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "scroll" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background)?;
                let target = self.pointer_target(ctx, &window, args)?;
                let dx = args_f64(args, "dx").unwrap_or(0.0).clamp(-200.0, 200.0);
                let dy = args_f64(args, "dy").unwrap_or(0.0).clamp(-200.0, 200.0);
                if let PointerTarget::Point { point, .. } = &target {
                    self.glide(ctx, *point);
                }
                let out =
                    self.desktop.scroll(&target, dx, dy).map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "drag" => {
                let window = self.window(need(args, "window_id")?)?;
                let delivery = parse_delivery(args)?;
                let app = self.act_on(&config, ctx, &window, delivery)?;
                let g = self.geometry_for(ctx, &window);
                let from = g.to_global(need_f64(args, "from_x")?, need_f64(args, "from_y")?);
                let to = g.to_global(need_f64(args, "to_x")?, need_f64(args, "to_y")?);
                self.glide(ctx, from);
                let out = self
                    .desktop
                    .drag(&window.id, from, to, parse_button(args)?, delivery)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                self.glide(ctx, to);
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "set_value" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background)?;
                let value = args.get("value").and_then(Value::as_str).unwrap_or_default();
                let out = self
                    .desktop
                    .set_value(&window.id, need(args, "element_id")?, value)
                    .map_err(|e| ToolOutput::desktop(&e))?;
                Ok((self.outcome(ctx, out), Some(app)))
            }
            "perform_action" => {
                let window = self.window(need(args, "window_id")?)?;
                let app = self.act_on(&config, ctx, &window, Delivery::Background)?;
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
        self.windows()?.into_iter().find(|w| w.id == id).ok_or_else(|| {
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
    ) -> Result<TargetApp, ToolOutput> {
        let app = self.target_of(window, &self.app_names());
        self.authorize(config, ctx, Access::Act, Some(&app), delivery == Delivery::Foreground)?;
        if config.pause_on_takeover && !self.takeover.wait_idle(TAKEOVER_WAIT) {
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
        let app = self.act_on(config, ctx, &window, delivery)?;
        if let PointerTarget::Point { point, .. } = &target {
            self.glide(ctx, *point);
        }
        let out = self
            .desktop
            .click(&target, &ClickSpec { button, count, modifiers, delivery })
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
        let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
        // `cmux computer-use screenshot --out` saves the exact pixels.
        let lossless = args.get("lossless").and_then(Value::as_bool).unwrap_or(false);
        let windows = self.windows()?;
        let names = self.app_names();
        let (target, key, app, focus) = match args_str(args, "window_id") {
            Some(id) => {
                let window = windows.iter().find(|w| w.id == id).ok_or_else(|| {
                    ToolOutput::error("target_not_found", format!("no window {id:?}"))
                })?;
                let app = self.target_of(window, &names);
                self.authorize(config, ctx, Access::Observe, Some(&app), false)?;
                (
                    CaptureTarget::Window(id.to_string()),
                    format!("w:{id}"),
                    Some(app),
                    Some(center(&window.frame)),
                )
            }
            None => {
                self.authorize(config, ctx, Access::Observe, None, false)?;
                let display = args_str(args, "display").map(str::to_string);
                let key = format!("d:{}", display.as_deref().unwrap_or("main"));
                (CaptureTarget::Display(display), key, None, None)
            }
        };
        self.cursor.show(CursorEvent::Look {
            session: ctx.session.clone(),
            label: ctx.label.clone(),
            at: focus,
        });
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
        let after = self.windows()?;
        let mut redact: Vec<Rect> = Vec::new();
        if !isolated {
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
        let encoded =
            frame::process(raw, &redact, frame::DEFAULT_MAX_EDGE, previous, force, lossless)
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
        out.image = encoded.image;
        Ok((out, app))
    }

    fn write_audit(
        &self,
        ctx: &CallContext,
        tool: &str,
        app: Option<&TargetApp>,
        out: &ToolOutput,
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
        let line = json!({
            "ts": ts as u64, "session": ctx.session, "agent": ctx.label, "origin": origin,
            "tool": tool, "app": app.map(|a| a.id.clone()),
            "ok": !out.is_error, "code": out.code,
            "route": out.body.get("route"),
        });
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

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
