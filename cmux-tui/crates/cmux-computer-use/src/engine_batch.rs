//! `batch`: up to [`BATCH_MAX`] steps on one window, in order, in one call,
//! with nothing hidden from the agent or the person:
//!
//! - Every step is checked before any runs (its action, its `require`, its
//!   `target`, its wait), and the waits together fit [`BATCH_TIME_MAX`].
//! - An acting step runs as its own call would (policy, guards, the caret and
//!   web gates in the desktop, never the person's focus), then captures the
//!   window at once (no wait; a step with `require` confirmed or not_no_effect,
//!   or `settle: "adaptive"`, settles first, as those outcomes need) and gets its own outcome (`confirmed`, `no_effect`,
//!   `uncertain`) from its own read-back, its own pixels and elements and
//!   what changed outside the window during it. A later step can never
//!   confirm an earlier one: it has not run when the earlier one is decided.
//! - `require` sets when a step stops the batch: `confirmed` (unless its
//!   outcome is confirmed), `not_no_effect`, or by default only an error.
//! - `wait_for` waits until an element appears or disappears, or its value
//!   equals or contains a text, reading the window again whenever the app's
//!   accessibility watch signals a change (and every so often, as not every
//!   change sends one), within its timeout.
//! - `target: {role, label, text}` names an element by what it is instead of
//!   its id, so a step can act on what an earlier step made appear. It is
//!   resolved when the step runs, from a fresh read of the window, and then
//!   goes through the same use-time fingerprint check as an id
//!   (`stale_element`); two matches are refused as ambiguous, never picked.
//! - The reply lists every step: `done` with its outcome, reason, read-back
//!   and a short list of what changed during it; `failed` with the error;
//!   `not_run` for every step after the one that stopped the batch, which
//!   `stopped_at` names with its reason.
//!
//! No loops and no conditions beyond the guards: a batch is a fixed list.

use super::observe_glue::Pixels;
use super::*;
use crate::observe::{Look, diff, ids, outline};

/// How often a `wait_for` reads the window again when no signal wakes it
/// first: with the app's accessibility watch listening, and without one.
const RECHECK_LISTENING: Duration = Duration::from_millis(500);
const RECHECK_POLL: Duration = Duration::from_millis(150);
/// After a signal wakes a `wait_for`, at most this long for a burst of
/// signals to end (no new one within [`QUIET_MS`]) before it reads.
const BURST_MAX: Duration = Duration::from_millis(250);
/// A `wait_for`'s timeout when it names none.
pub const WAIT_FOR_DEFAULT: Duration = Duration::from_secs(10);
/// The most lines of what changed during one step.
const STEP_DIFF_LINES: usize = 8;
/// The most matches an ambiguous `target` lists.
const AMBIGUOUS_LISTED: usize = 5;
/// The widest read of a window a `target` or `wait_for` makes when the
/// default read was cut short.
const WIDE_READ: usize = 5000;
/// The tools that take an element, so a `target` may name it.
const TAKES_ELEMENT: &[&str] = &["click", "type_text", "scroll", "set_value", "perform_action"];

/// When a step stops the batch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Require {
    /// Only on an error (the default).
    NoError,
    /// Also when its outcome is `no_effect`.
    NotNoEffect,
    /// Unless its outcome is `confirmed`.
    Confirmed,
}

impl Require {
    fn parse(v: Option<&Value>) -> Result<Self, String> {
        match v {
            None | Some(Value::Null) => Ok(Require::NoError),
            Some(Value::String(s)) => match s.as_str() {
                "no_error" => Ok(Require::NoError),
                "not_no_effect" => Ok(Require::NotNoEffect),
                "confirmed" => Ok(Require::Confirmed),
                other => Err(format!(
                    "require {other:?} is not one of \"confirmed\", \"not_no_effect\", \"no_error\""
                )),
            },
            Some(other) => Err(format!("require must be a string, not {other}")),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Require::NoError => "no_error",
            Require::NotNoEffect => "not_no_effect",
            Require::Confirmed => "confirmed",
        }
    }

    /// Why a done step stops the batch under this guard, or None.
    fn unmet(self, body: &Value) -> Option<String> {
        let outcome = body.get("outcome").and_then(Value::as_str);
        let reason = body.get("outcome_reason").and_then(Value::as_str).unwrap_or_default();
        match (self, outcome) {
            (Require::NoError, _) => None,
            (Require::Confirmed, Some("confirmed")) => None,
            (Require::Confirmed, Some(o)) => {
                Some(format!("it required confirmed, but its outcome is {o}: {reason}"))
            }
            (Require::Confirmed, None) => Some(
                "it required confirmed, but it reports no outcome (nothing of it could be read back)"
                    .into(),
            ),
            (Require::NotNoEffect, Some("no_effect")) => {
                Some(format!("it required not_no_effect, but its outcome is no_effect: {reason}"))
            }
            (Require::NotNoEffect, _) => None,
        }
    }
}

/// An element named by what it is: its role, its label (the name, whole,
/// any case) and a text its name or value contains (any case).
#[derive(Clone, Debug, Default, PartialEq)]
struct Match {
    role: Option<String>,
    label: Option<String>,
    text: Option<String>,
}

fn lower(s: &str) -> String {
    s.trim().to_lowercase()
}

impl Match {
    fn parse(v: &Value) -> Result<Self, String> {
        let obj = v.as_object().ok_or_else(|| {
            "target must be an object such as {\"role\": \"button\", \"label\": \"Save\"}"
                .to_string()
        })?;
        if let Some(k) = obj.keys().find(|k| !matches!(k.as_str(), "role" | "label" | "text")) {
            return Err(format!("target takes role, label and text, not {k:?}"));
        }
        let get = |k: &str| -> Result<Option<String>, String> {
            match obj.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if !s.trim().is_empty() => Ok(Some(s.trim().to_string())),
                Some(_) => Err(format!("target {k} must be a non-empty string")),
            }
        };
        let m = Match { role: get("role")?, label: get("label")?, text: get("text")? };
        if m.role.is_none() && m.label.is_none() && m.text.is_none() {
            return Err("target needs a role, a label or a text".into());
        }
        Ok(m)
    }

    fn hits(&self, e: &Element) -> bool {
        self.role.as_deref().is_none_or(|r| e.role.eq_ignore_ascii_case(r))
            && self.label.as_deref().is_none_or(|l| lower(&e.name) == lower(l))
            && self.text.as_deref().is_none_or(|t| {
                let t = lower(t);
                e.name.to_lowercase().contains(&t) || e.value.to_lowercase().contains(&t)
            })
    }

    /// `role "button", label "Save"`.
    fn describe(&self) -> String {
        let mut parts = Vec::new();
        if let Some(r) = &self.role {
            parts.push(format!("role {}", outline::quote(r)));
        }
        if let Some(l) = &self.label {
            parts.push(format!("label {}", outline::quote(l)));
        }
        if let Some(t) = &self.text {
            parts.push(format!("text {}", outline::quote(t)));
        }
        parts.join(", ")
    }
}

/// Every element of `root` that `m` matches (small ids, in tree order).
fn find_all<'a>(root: &'a Element, m: &Match, out: &mut Vec<&'a Element>) {
    if m.hits(root) && ids::parse(&root.id).is_some() {
        out.push(root);
    }
    for c in &root.children {
        find_all(c, m, out);
    }
}

/// `[12] button "Save"`, as the outline names an element.
fn element_line(e: &Element) -> String {
    let name =
        if e.name.is_empty() { String::new() } else { format!(" {}", outline::quote(&e.name)) };
    format!("[{}] {}{name}", e.id, e.role)
}

/// What a `wait_for` watches.
#[derive(Clone, Debug, PartialEq)]
enum Subject {
    Id(u32),
    Match(Match),
}

/// What a `wait_for` waits until.
#[derive(Clone, Debug, PartialEq)]
enum Until {
    Appears,
    Disappears,
    ValueEquals(String),
    ValueContains(String),
}

#[derive(Clone, Debug, PartialEq)]
struct WaitFor {
    subject: Subject,
    until: Until,
    timeout: Duration,
}

impl WaitFor {
    fn parse(map: &serde_json::Map<String, Value>) -> Result<Self, String> {
        const KEYS: &[&str] = &[
            "action",
            "element_id",
            "target",
            "until",
            "value_equals",
            "value_contains",
            "timeout_ms",
        ];
        if let Some(k) = map.keys().find(|k| !KEYS.contains(&k.as_str())) {
            return Err(format!(
                "wait_for takes element_id or target, until, value_equals or value_contains, and timeout_ms, not {k:?}"
            ));
        }
        let subject = match (map.get("element_id"), map.get("target")) {
            (Some(_), Some(_)) => {
                return Err("wait_for takes element_id or target, not both".into());
            }
            (Some(id), None) => {
                let raw =
                    id.as_str().map(str::to_string).or_else(|| id.as_u64().map(|n| n.to_string()));
                match raw.as_deref().and_then(ids::parse) {
                    Some(n) => Subject::Id(n),
                    None => {
                        return Err(format!(
                            "wait_for element_id {id} is not an id from get_ui_tree or an earlier state (such as \"12\")"
                        ));
                    }
                }
            }
            (None, Some(t)) => Subject::Match(Match::parse(t)?),
            (None, None) => {
                return Err(
                    "wait_for needs element_id or target ({\"role\": ..., \"label\": ..., \"text\": ...})"
                        .into(),
                );
            }
        };
        let text = |k: &str| -> Result<Option<String>, String> {
            match map.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err(format!("{k} must be a string")),
            }
        };
        let until = match (
            map.get("until").and_then(Value::as_str),
            text("value_equals")?,
            text("value_contains")?,
        ) {
            (_, Some(_), Some(_)) => {
                return Err("wait_for takes value_equals or value_contains, not both".into());
            }
            (Some(_), Some(_), _) | (Some(_), _, Some(_)) => {
                return Err("wait_for takes until or a value to wait for, not both".into());
            }
            (_, Some(v), None) => Until::ValueEquals(v),
            (_, None, Some(v)) if v.is_empty() => {
                return Err("value_contains must not be empty".into());
            }
            (_, None, Some(v)) => Until::ValueContains(v),
            (None | Some("appears"), None, None) => Until::Appears,
            (Some("disappears"), None, None) => Until::Disappears,
            (Some(other), None, None) => {
                return Err(format!("until {other:?} is not \"appears\" or \"disappears\""));
            }
        };
        if map.get("until").is_some_and(|u| !u.is_string()) {
            return Err("until must be \"appears\" or \"disappears\"".into());
        }
        let timeout = match map.get("timeout_ms") {
            None | Some(Value::Null) => WAIT_FOR_DEFAULT,
            Some(v) => match v.as_f64() {
                Some(ms) if (0.0..=WAIT_MAX.as_millis() as f64).contains(&ms) => {
                    Duration::from_millis(ms.round() as u64)
                }
                _ => {
                    return Err(format!(
                        "timeout_ms is a number of ms from 0 to {}",
                        WAIT_MAX.as_millis()
                    ));
                }
            },
        };
        Ok(WaitFor { subject, until, timeout })
    }

    /// What it waits for, in words.
    fn describe(&self) -> String {
        let who = match &self.subject {
            Subject::Id(n) => format!("element [{n}]"),
            Subject::Match(m) => format!("an element with {}", m.describe()),
        };
        match &self.until {
            Until::Appears => format!("{who} to appear"),
            Until::Disappears => format!("{who} to disappear"),
            Until::ValueEquals(v) => format!("{who} to have the value {}", outline::quote(v)),
            Until::ValueContains(v) => format!("{who}'s value to contain {}", outline::quote(v)),
        }
    }
}

/// One step of a batch, checked before any runs.
enum Plan {
    Act { tool: &'static tools::Tool, args: Value, require: Require, target: Option<Match> },
    Wait { ms: u64 },
    WaitFor(WaitFor),
}

impl Plan {
    fn parse(action: &Value, window_id: &str, batch: &Value) -> Result<Self, String> {
        let map = action.as_object().ok_or_else(|| {
            "each action is an object such as {\"action\": \"click\", ...}".to_string()
        })?;
        let name = map.get("action").and_then(Value::as_str).ok_or("it has no \"action\"")?;
        if name != "wait_for" && !BATCHABLE.contains(&name) {
            return Err(format!(
                "{name:?} cannot run in a batch (it runs click, type_text, press_key, scroll, drag, set_value, perform_action, wait and wait_for)"
            ));
        }
        if matches!(name, "wait" | "wait_for") && map.contains_key("require") {
            return Err(format!("require is for acting steps; {name} has its own condition"));
        }
        match name {
            "wait" => {
                let ms = match (map.get("ms"), map.get("duration")) {
                    (Some(ms), _) => ms.as_f64(),
                    (None, Some(s)) => s.as_f64().map(|s| s * 1000.0),
                    (None, None) => Some(WAIT_DEFAULT.as_millis() as f64),
                };
                match ms {
                    Some(ms) if (0.0..=WAIT_MAX.as_millis() as f64).contains(&ms) => {
                        Ok(Plan::Wait { ms: ms.round() as u64 })
                    }
                    _ => Err(format!("a wait is 0 to {} ms", WAIT_MAX.as_millis())),
                }
            }
            "wait_for" => Ok(Plan::WaitFor(WaitFor::parse(map)?)),
            _ => {
                let tool = tools::find(name).ok_or_else(|| format!("unknown action {name:?}"))?;
                let require = Require::parse(map.get("require"))?;
                let target = map.get("target").map(Match::parse).transpose()?;
                if target.is_some() {
                    if !TAKES_ELEMENT.contains(&name) {
                        return Err(format!(
                            "{name} takes no element, so it takes no target (target works on {})",
                            TAKES_ELEMENT.join(", ")
                        ));
                    }
                    if ["element_id", "x", "y"].iter().any(|k| map.contains_key(*k)) {
                        return Err("give target or element_id (or x and y), not both".into());
                    }
                }
                if name == "perform_action" && !map.get("perform").is_some_and(Value::is_string) {
                    return Err(
                        "perform_action names its accessibility action as \"perform\" (such as \"perform\": \"press\"), since \"action\" names the step"
                            .into(),
                    );
                }
                let mut args = action.clone();
                if let Some(step) = args.as_object_mut() {
                    for key in ["action", "require", "target"] {
                        step.remove(key);
                    }
                    if let Some(perform) = step.remove("perform") {
                        step.insert("action".into(), perform);
                    }
                    step.insert("window_id".into(), json!(window_id));
                    if let Some(settle) = batch.get("settle") {
                        step.entry("settle").or_insert(settle.clone());
                    }
                }
                Ok(Plan::Act { tool, args, require, target })
            }
        }
    }

    fn name(&self) -> &'static str {
        match self {
            Plan::Act { tool, .. } => tool.name,
            Plan::Wait { .. } => "wait",
            Plan::WaitFor(_) => "wait_for",
        }
    }

    /// The longest this step waits on purpose.
    fn waits(&self) -> Duration {
        match self {
            Plan::Act { .. } => Duration::ZERO,
            Plan::Wait { ms } => Duration::from_millis(*ms),
            Plan::WaitFor(w) => w.timeout,
        }
    }
}

/// What one probe of a `wait_for` found.
enum Probe {
    /// The condition holds (in words).
    Met(String),
    /// Not yet (what the window shows now, in words).
    Not(String),
}

/// What the agent's last screenshot of the window was, and the pixel
/// baseline the batch's steps compare with (the previous step's capture).
struct Pixel {
    key: (String, String),
    agent: Option<(Geometry, u64)>,
    step: Option<(Geometry, u64)>,
}

impl Engine {
    /// `batch` (see the module notes).
    pub(super) fn batch(
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
        let names: Vec<Value> =
            actions.iter().map(|a| a.get("action").cloned().unwrap_or(Value::Null)).collect();
        // Every step is checked before any runs: a malformed batch does nothing.
        let mut plans = Vec::with_capacity(actions.len());
        for (index, action) in actions.iter().enumerate() {
            match Plan::parse(action, &window_id, args) {
                Ok(plan) => plans.push(plan),
                Err(why) => {
                    let failure = ToolOutput::error(
                        "invalid_arguments",
                        format!("action {index}: {why}. Nothing in this batch ran."),
                    );
                    let mut steps: Vec<Value> = names
                        .iter()
                        .take(index)
                        .enumerate()
                        .map(|(i, name)| json!({"step": i, "action": name, "status": "not_run"}))
                        .collect();
                    let name = names.get(index).cloned().unwrap_or(Value::Null);
                    let stopped = stop_entry(index, &name, &failure);
                    steps.push(failed_entry(index, &name, &failure));
                    return Ok((reply(0, &names, steps, Some(stopped)), None));
                }
            }
        }
        let planned: Duration = plans.iter().map(Plan::waits).sum();
        if planned > BATCH_TIME_MAX {
            return Err(ToolOutput::error(
                "invalid_arguments",
                format!(
                    "this batch's waits and wait_for timeouts add up to {} s; a batch runs at most {} s. Split it, or give wait_for a shorter timeout_ms.",
                    planned.as_secs(),
                    BATCH_TIME_MAX.as_secs()
                ),
            ));
        }

        let start = (self.clock)();
        let opts = Look::from_args(args).outline_options();
        // What changed during each step is read against the window as it was
        // before the step: the agent's last look, then each step's.
        let mut prev = self.last_seen(&ctx.session, &window_id);
        let key = (ctx.session.clone(), format!("w:{window_id}"));
        let agent = lock(&self.seen).get(&key).copied();
        let mut pixel = Pixel { key, agent, step: agent };
        let mut steps: Vec<Value> = Vec::new();
        let mut stopped: Option<Value> = None;
        let mut acted_on: Option<TargetApp> = None;
        let mut completed = 0;
        for (index, plan) in plans.iter().enumerate() {
            let name = json!(plan.name());
            // Checkpoint: the person's Stop ends the batch between two steps.
            if let Err(out) = self.stops.check(&ctx.session) {
                stopped = Some(stop_entry(index, &name, &out));
                break;
            }
            let elapsed = (self.clock)().saturating_sub(start);
            if elapsed >= BATCH_TIME_MAX {
                let out = ToolOutput::error(
                    "batch_time_limit",
                    format!(
                        "the batch reached its {} s limit before this step",
                        BATCH_TIME_MAX.as_secs()
                    ),
                );
                stopped = Some(stop_entry(index, &name, &out));
                break;
            }
            let ran = match plan {
                Plan::Act { tool, args: step, target, require } => self.batch_act(
                    ctx,
                    tool,
                    step,
                    *require,
                    target.as_ref(),
                    &window_id,
                    &mut prev,
                    &mut pixel,
                    &opts,
                ),
                Plan::Wait { ms } => {
                    (self.sleep)(Duration::from_millis(*ms));
                    Ok((json!({"waited_ms": ms}), None))
                }
                Plan::WaitFor(w) => self.batch_wait_for(
                    ctx,
                    w,
                    &window_id,
                    BATCH_TIME_MAX - elapsed,
                    &mut prev,
                    &opts,
                ),
            };
            match ran {
                Ok((body, app)) => {
                    completed += 1;
                    acted_on = app.or(acted_on);
                    let mut entry = json!({"step": index, "action": name, "status": "done"});
                    if let (Some(e), Some(b)) = (entry.as_object_mut(), body.as_object()) {
                        for (k, v) in b {
                            e.entry(k.clone()).or_insert(v.clone());
                        }
                    }
                    if let Plan::Act { require, .. } = plan
                        && *require != Require::NoError
                    {
                        set_key(&mut entry, "require", json!(require.as_str()));
                        if let Some(why) = require.unmet(&entry) {
                            set_key(&mut entry, "require_met", json!(false));
                            let out = ToolOutput::error(
                                "requirement_not_met",
                                format!("step {index} ({}) acted, but {why}", plan.name()),
                            );
                            stopped = Some(stop_entry(index, &name, &out));
                            steps.push(entry);
                            break;
                        }
                        set_key(&mut entry, "require_met", json!(true));
                    }
                    steps.push(entry);
                }
                Err(failure) => {
                    stopped = Some(stop_entry(index, &name, &failure));
                    steps.push(failed_entry(index, &name, &failure));
                    break;
                }
            }
        }
        pixel.restore(self);
        let mut out = reply(completed, &names, steps, stopped);
        // The batch's own state, once, at its end: compared with what the
        // agent saw before the batch (its last look and screenshot).
        if let Some(app) = &acted_on
            && args.get("observe").and_then(Value::as_bool) != Some(false)
        {
            // No second settle after the last step's own: this state is
            // captured at once (the Anthropic reference mode keeps its delay).
            let mode = match self.settle_mode(args) {
                SettleMode::Anthropic => SettleMode::Anthropic,
                _ => SettleMode::Openai,
            };
            self.attach_state(ctx, &window_id, app, &mut out, mode, false, None);
        }
        Ok((out, acted_on))
    }

    /// One acting step of a batch, as its own call would run, with its own
    /// settle and outcome. The body as the step's entry shows it.
    #[allow(clippy::too_many_arguments)] // each argument is one fact of the step
    fn batch_act(
        &self,
        ctx: &CallContext,
        tool: &tools::Tool,
        step: &Value,
        require: Require,
        target: Option<&Match>,
        window_id: &str,
        prev: &mut Option<outline::Outline>,
        pixel: &mut Pixel,
        opts: &outline::Options,
    ) -> Result<(Value, Option<TargetApp>), ToolOutput> {
        let name = tool.name;
        let audited = |out: ToolOutput, app: Option<&TargetApp>| {
            self.write_audit(ctx, name, app, &out);
            out
        };
        let mut step = step.clone();
        let mut resolved = None;
        if let Some(m) = target {
            let window = self.window(window_id)?;
            let app = self.app_of(&window);
            // The window is read only where the agent may look.
            let config = self.config();
            self.authorize(&config, ctx, Access::Observe, Some(&app), false)
                .map_err(|e| audited(e, Some(&app)))?;
            let (n, line, tree) =
                self.resolve_target(ctx, &window, m).map_err(|e| audited(e, Some(&app)))?;
            set_key(&mut step, "element_id", json!(n.to_string()));
            resolved = Some(json!({"element_id": n.to_string(), "matched": line}));
            // The read that found the target is the elements' baseline too.
            if prev.is_none() {
                *prev = Some(self.baseline_from(ctx, window_id, tree, opts));
            }
        }
        // No earlier look at the window's elements (the agent acted at once,
        // as the instructions ask): read them once before the action, so its
        // outcome can be decided by comparing, and the agent is not sent to
        // look again (every look is a model turn). A read that fails or is
        // not allowed leaves the step as before: a first look after it.
        if prev.is_none() {
            *prev = self.baseline(ctx, window_id, opts);
        }
        let windows_before = self.window_ids_over_target(window_id);
        let world_before = self.desktop.world();
        let watch = self.desktop.watch(window_id).filter(|w| w.listening());
        let (mut done, app) = self.dispatch(tool, ctx, &step).map_err(|e| audited(e, None))?;
        self.write_audit(ctx, name, app.as_ref(), &done);
        if done.is_error {
            return Err(done);
        }
        if done.body.get("evidence").is_some()
            && let Some(app) = &app
        {
            // Its pixels compare with the previous step's capture (or the
            // agent's screenshot before the batch).
            let had_pixels = pixel.step.is_some();
            // Only a step whose outcome needs a real settle waits for one: a
            // required confirmed or not_no_effect (read back and compared after
            // the settle); else the mode asked for (the step's or the call's
            // `settle`, or the setting), so `anthropic` keeps its delay.
            let mode = if require != Require::NoError {
                SettleMode::Adaptive
            } else {
                self.settle_mode(&step)
            };
            pixel.before_settle(self);
            let settled = self.attach_state(
                ctx,
                window_id,
                app,
                &mut done,
                mode,
                name == "type_text",
                watch.as_deref(),
            );
            pixel.after_settle(self);
            let state = done.body.as_object_mut().and_then(|b| b.remove("state"));
            let (evidence, text, now) = self.step_changes(
                state,
                prev.as_ref(),
                had_pixels,
                window_id,
                windows_before.as_deref(),
                opts,
            );
            if let Some(evidence) = evidence {
                set_key(&mut done.body, "state", json!({"changes": evidence}));
            }
            let signals = watch.as_ref().map(|w| w.signals());
            drop(watch);
            let outside = world_before.and_then(|before| {
                let after = self.desktop.world()?;
                let mut changes = after.changes_since(&before);
                let raised = parse_delivery(&step).ok() == Some(Delivery::Foreground)
                    && after.front_pid.is_some()
                    && self
                        .desktop
                        .window(window_id)
                        .ok()
                        .flatten()
                        .is_some_and(|w| Some(w.pid) == after.front_pid);
                if raised {
                    changes.retain(|c| c != crate::desktop::FRONT_APP_CHANGED);
                }
                Some(changes)
            });
            let responsive = settled.and_then(|_| self.desktop.responsive(window_id));
            self.attach_outcome(&mut done, settled, signals, outside, responsive);
            if let Some(body) = done.body.as_object_mut() {
                body.remove("state");
            }
            set_key(&mut done.body, "changes", json!(text));
            if let Some(now) = now {
                *prev = Some(now);
            }
        } else if let Some(body) = done.body.as_object_mut() {
            body.remove("shows");
            body.remove("expect");
        }
        if let Some(resolved) = resolved {
            set_key(&mut done.body, "target", resolved);
        }
        Ok((done.body, app))
    }

    /// The one element of the window `m` matches now, as its small id and
    /// its outline line; recorded as shown, so the action's use-time check
    /// compares it with the element it reaches.
    fn resolve_target(
        &self,
        ctx: &CallContext,
        window: &Window,
        m: &Match,
    ) -> Result<(u32, String, crate::desktop::UiTree), ToolOutput> {
        let tree = self.read_for_match(ctx, &window.id)?;
        let mut hits = Vec::new();
        find_all(&tree.root, m, &mut hits);
        let what = m.describe();
        match hits.as_slice() {
            [] => Err(ToolOutput::error(
                "target_not_found",
                format!(
                    "no element of window {} matches {what}{}, so nothing was done. Read the window (get_ui_tree) for its roles and labels, or wait_for the element first.",
                    window.id,
                    if tree.truncated { " in the part of it one read covers" } else { "" }
                ),
            )),
            [one] if !tree.truncated => {
                let n = ids::parse(&one.id).unwrap_or_default();
                self.record_shown(&ctx.session, &window.id, &[n]);
                let line = element_line(one);
                Ok((n, line, tree))
            }
            [_] => Err(ToolOutput::error(
                "ambiguous_element",
                format!(
                    "window {} has more elements than one read covers, so it cannot be told that only one matches {what}; nothing was done. Use its element_id.",
                    window.id
                ),
            )),
            many => {
                let listed: Vec<String> =
                    many.iter().take(AMBIGUOUS_LISTED).map(|e| element_line(e)).collect();
                let more = many.len().saturating_sub(AMBIGUOUS_LISTED);
                Err(ToolOutput::error(
                    "ambiguous_element",
                    format!(
                        "{} elements of window {} match {what} ({}{}), so nothing was done: a batch never picks one. Add a label or text only one has, or use its element_id.",
                        many.len(),
                        window.id,
                        listed.join(", "),
                        if more > 0 { format!(", {more} more") } else { String::new() }
                    ),
                ))
            }
        }
    }

    /// The window's elements just before a step, for a step with no earlier
    /// look to compare with: one read at the same options the step's own
    /// state is read with ([`Self::attach_state`]), so the two compare line
    /// for line. Only where the agent may look; None when the read fails.
    /// It is not shown to the agent, so its next look is unchanged.
    fn baseline(
        &self,
        ctx: &CallContext,
        window_id: &str,
        opts: &outline::Options,
    ) -> Option<outline::Outline> {
        let window = self.window(window_id).ok()?;
        let app = self.app_of(&window);
        let config = self.config();
        self.authorize(&config, ctx, Access::Observe, Some(&app), false).ok()?;
        let tree = self
            .walk_tree_for(
                Some(&ctx.session),
                window_id,
                TreeOptions { menus: false, ..TreeOptions::default() },
            )
            .ok()?;
        Some(self.baseline_from(ctx, window_id, tree, opts))
    }

    /// An outline of `tree` as a step's state would give it (frames in the
    /// session's screenshot pixels where it has a capture of the window).
    fn baseline_from(
        &self,
        ctx: &CallContext,
        window_id: &str,
        mut tree: crate::desktop::UiTree,
        opts: &outline::Options,
    ) -> outline::Outline {
        let seen =
            lock(&self.seen).get(&(ctx.session.clone(), format!("w:{window_id}"))).map(|(g, _)| *g);
        if let Some(geometry) = seen {
            super::rewrite_frames(&mut tree.root, &geometry);
        }
        outline::build(&tree.root, tree.truncated, opts)
    }

    /// The window read for a match, whole where one read can cover it: a
    /// read cut short at the default limit is read again wider.
    fn read_for_match(
        &self,
        ctx: &CallContext,
        window_id: &str,
    ) -> Result<crate::desktop::UiTree, ToolOutput> {
        let read = |max_nodes| {
            self.walk_tree_for(
                Some(&ctx.session),
                window_id,
                TreeOptions { max_nodes, menus: false, ..TreeOptions::default() },
            )
            .map_err(|e| ToolOutput::desktop(&e))
        };
        let tree = read(TreeOptions::default().max_nodes)?;
        if tree.truncated { read(WIDE_READ) } else { Ok(tree) }
    }

    /// A `wait_for` step: reads the window until its condition holds, again
    /// on each accessibility signal the app sends (and every
    /// [`RECHECK_LISTENING`] or, unwatched, [`RECHECK_POLL`]), within its
    /// timeout and what is left of the batch's time.
    fn batch_wait_for(
        &self,
        ctx: &CallContext,
        w: &WaitFor,
        window_id: &str,
        left: Duration,
        prev: &mut Option<outline::Outline>,
        opts: &outline::Options,
    ) -> Result<(Value, Option<TargetApp>), ToolOutput> {
        let config = self.config();
        let window = self.window(window_id)?;
        let app = self.app_of(&window);
        self.authorize(&config, ctx, Access::Observe, Some(&app), false)?;
        let capped = w.timeout > left;
        let timeout = w.timeout.min(left);
        let watch = self.desktop.watch(window_id).filter(|w| w.listening());
        let recheck = if watch.is_some() { RECHECK_LISTENING } else { RECHECK_POLL };
        let start = (self.clock)();
        let mut reads = 0u32;
        let mut woken = 0u32;
        let mut first = true;
        let (met, tree) = loop {
            // Checkpoint: the person's Stop ends the wait.
            self.stops.check(&ctx.session)?;
            let config = self.config();
            let window = self.still_allowed(&config, ctx, window_id, &app)?;
            let seen = watch.as_ref().map(|w| w.signals().total()).unwrap_or(0);
            reads += 1;
            let (probe, tree) = self.probe(ctx, &window, w, first)?;
            first = false;
            let now = match probe {
                Probe::Met(what) => break (what, tree),
                Probe::Not(now) => now,
            };
            let elapsed = (self.clock)().saturating_sub(start);
            if elapsed >= timeout {
                let limit = if capped {
                    format!(" (cut to what was left of the batch's {} s)", BATCH_TIME_MAX.as_secs())
                } else {
                    String::new()
                };
                let message = format!(
                    "waited {} ms{limit} for {}, reading the window {reads} times; {now}. The steps after it did not run.",
                    elapsed.as_millis(),
                    w.describe(),
                );
                return Err(ToolOutput::error("wait_timeout", message));
            }
            if self.wait_change(watch.as_deref(), seen, recheck.min(timeout - elapsed)) {
                woken += 1;
            }
        };
        let waited = (self.clock)().saturating_sub(start);
        let new = outline::build(&tree.root, tree.truncated, opts);
        let text = match prev.as_ref() {
            Some(old) => step_diff(old, &new, opts, Vec::new()).1,
            None => "no earlier look at the window to compare with".into(),
        };
        *prev = Some(new);
        self.write_audit(ctx, "wait_for", Some(&app), &ToolOutput::ok(json!({"met": met})));
        Ok((
            json!({
                "met": met,
                "waited_ms": waited.as_millis() as u64,
                "reads": reads,
                "woken_by_signals": woken,
                "watched": watch.is_some(),
                "changes": text,
            }),
            Some(app),
        ))
    }

    /// Waits up to `slice` for the app to signal a change past `seen`; after
    /// one, lets the burst end (at most [`BURST_MAX`]). Without a watch that
    /// can block, the rest of `slice` passes. True when a signal woke it.
    pub(super) fn wait_change(
        &self,
        watch: Option<&dyn Watch>,
        seen: u32,
        slice: Duration,
    ) -> bool {
        let t0 = (self.clock)();
        let woke = watch.is_some_and(|w| w.wait_for_signal(seen, slice));
        if let (true, Some(w)) = (woke, watch) {
            let quiet = Duration::from_millis(QUIET_MS);
            let mut total = w.signals().total();
            while (self.clock)().saturating_sub(t0) < BURST_MAX && w.wait_for_signal(total, quiet) {
                total = w.signals().total();
            }
        } else {
            let spent = (self.clock)().saturating_sub(t0);
            if spent < slice {
                (self.sleep)(slice - spent);
            }
        }
        woke
    }

    /// One read of the window for a `wait_for`: whether its condition holds.
    fn probe(
        &self,
        ctx: &CallContext,
        window: &Window,
        w: &WaitFor,
        first: bool,
    ) -> Result<(Probe, crate::desktop::UiTree), ToolOutput> {
        let tree = self.read_for_match(ctx, &window.id)?;
        let element: Option<Element> = match &w.subject {
            Subject::Id(n) => {
                let resolved = lock(&self.observe.ids).window(&window.id).map(|r| r.resolve(*n));
                match resolved {
                    Some(ids::Resolved::Current(_)) | Some(ids::Resolved::Carried(_)) => {
                        // The id is the element the agent was shown under it.
                        self.check_shown(&ctx.session, window, *n)?;
                        lock(&self.observe.ids)
                            .window(&window.id)
                            .and_then(|r| r.element(*n))
                            .cloned()
                    }
                    Some(ids::Resolved::Gone(_)) => None,
                    _ if first => {
                        return Err(ToolOutput::error(
                            "stale_element",
                            format!(
                                "element [{n}] is not in window {}: ids come from its get_ui_tree or an action's state. Call get_ui_tree on window {} for its ids.",
                                window.id, window.id
                            ),
                        ));
                    }
                    _ => None,
                }
            }
            Subject::Match(m) => {
                let mut hits = Vec::new();
                find_all(&tree.root, m, &mut hits);
                match hits.as_slice() {
                    [] => None,
                    [one] => Some((*one).clone()),
                    many if w.until == Until::Disappears => {
                        let line = many.first().map(|e| element_line(e)).unwrap_or_default();
                        return Ok((
                            Probe::Not(format!("{} still match (such as {line})", many.len())),
                            tree,
                        ));
                    }
                    many => {
                        let listed: Vec<String> =
                            many.iter().take(AMBIGUOUS_LISTED).map(|e| element_line(e)).collect();
                        return Err(ToolOutput::error(
                            "ambiguous_element",
                            format!(
                                "{} elements of window {} match {} ({}), so the wait cannot tell which one it is for; a batch never picks one. Add a label or text only one has, or use its element_id.",
                                many.len(),
                                window.id,
                                m.describe(),
                                listed.join(", ")
                            ),
                        ));
                    }
                }
            }
        };
        // A matched element is now shown to the agent: a later step may use
        // its id.
        if let Some(e) = &element
            && let Some(n) = ids::parse(&e.id)
        {
            self.record_shown(&ctx.session, &window.id, &[n]);
        }
        let probe = match (&w.until, &element) {
            (Until::Appears, Some(e)) => Probe::Met(format!("appeared: {}", element_line(e))),
            (Until::Appears, None) => Probe::Not("no element matched".into()),
            (Until::Disappears, None) if tree.truncated => Probe::Not(
                "the window has more elements than one read covers, so it could not be read as gone"
                    .into(),
            ),
            (Until::Disappears, None) => Probe::Met(match &w.subject {
                Subject::Id(n) => format!("gone: element [{n}] is no longer in the window"),
                Subject::Match(m) => format!("gone: no element matches {}", m.describe()),
            }),
            (Until::Disappears, Some(e)) => Probe::Not(format!("still there: {}", element_line(e))),
            (Until::ValueEquals(_) | Until::ValueContains(_), None) => {
                Probe::Not("no element matched".into())
            }
            (Until::ValueEquals(v), Some(e)) if e.value == *v => {
                Probe::Met(format!("{} = {}", element_line(e), outline::quote(&outline::clip(&e.value, 120))))
            }
            (Until::ValueContains(v), Some(e)) if e.value.contains(v.as_str()) => {
                Probe::Met(format!("{} = {}", element_line(e), outline::quote(&outline::clip(&e.value, 120))))
            }
            (_, Some(e)) => Probe::Not(format!(
                "{}'s value is {}{}",
                element_line(e),
                outline::quote(&outline::clip(&e.value, 120)),
                if e.value.ends_with('…') {
                    " (a long value is read cut short, at about 2000 characters on macOS, so text past that cannot match: wait on a shorter element or value)"
                } else {
                    ""
                }
            )),
        };
        Ok((probe, tree))
    }

    /// What changed during one step: the evidence an outcome is decided
    /// from (as [`Self::present`] gives a single call's state), a short
    /// text of it, and the outline the next step compares with.
    fn step_changes(
        &self,
        state: Option<Value>,
        prev: Option<&outline::Outline>,
        had_pixels: bool,
        window_id: &str,
        windows_before: Option<&[String]>,
        opts: &outline::Options,
    ) -> (Option<Value>, String, Option<outline::Outline>) {
        let windows = windows_before.map(|b| self.window_changes(window_id, b)).unwrap_or_default();
        let Some(Value::Object(mut state)) = state else {
            return (None, "the window could not be read after this step".into(), None);
        };
        let Some(root) =
            state.remove("root").and_then(|r| serde_json::from_value::<Element>(r).ok())
        else {
            let why = state
                .get("reason")
                .and_then(Value::as_str)
                .map(|r| format!("the window could not be read after this step: {r}"))
                .unwrap_or_else(|| "the window could not be read after this step".into());
            return (None, why, None);
        };
        let truncated = state.get("truncated").and_then(Value::as_bool).unwrap_or(false);
        let pixels = match (had_pixels, state.get("unchanged")) {
            (true, Some(Value::Bool(true))) => Pixels::Same,
            (true, Some(Value::Bool(false))) => Pixels::Changed,
            _ => Pixels::Unknown,
        };
        let new = outline::build(&root, truncated, opts);
        let mut evidence = json!({
            "windows_opened": windows.iter().filter(|l| l.starts_with('+')).count(),
            "windows_closed": windows.iter().filter(|l| l.starts_with('-')).count(),
            "pixels": pixels.as_str(),
            "elements_read": if truncated { "partial" } else { "all" },
        });
        let pixels_text = match pixels {
            Pixels::Changed => "its pixels changed",
            Pixels::Same => "its pixels stayed the same",
            _ => "its pixels were not compared",
        };
        let text = match prev {
            Some(old) => {
                let (changes, text) = step_diff(old, &new, opts, windows);
                set_key(&mut evidence, "added", json!(changes.added.len()));
                set_key(
                    &mut evidence,
                    "changed",
                    json!(changes.changed.len() + changes.unfolded.len() + changes.folded.len()),
                );
                set_key(&mut evidence, "removed", json!(changes.removed.len()));
                set_key(&mut evidence, "renumbered", json!(changes.renumbered.len()));
                set_key(&mut evidence, "focus_moved", json!(changes.focus.is_some()));
                format!("{text}\n({pixels_text})")
            }
            None => {
                set_key(&mut evidence, "first_look", json!(true));
                let mut lines = windows;
                lines.push(format!(
                    "no earlier look at the window's elements to compare with ({pixels_text})"
                ));
                lines.join("\n")
            }
        };
        (Some(evidence), text, Some(new))
    }
}

/// The changes from `old` to `new` and at most [`STEP_DIFF_LINES`] lines of
/// them (the windows that opened or closed first).
fn step_diff(
    old: &outline::Outline,
    new: &outline::Outline,
    opts: &outline::Options,
    windows: Vec<String>,
) -> (diff::Changes, String) {
    let changes = diff::compute(old, new, opts);
    let mut lines = windows;
    match diff::render(old, new, &changes, opts) {
        Some(d) => lines.extend(d.lines().map(str::to_string)),
        None if lines.is_empty() => lines.push("no change in the window's elements".into()),
        None => {}
    }
    let more = lines.len().saturating_sub(STEP_DIFF_LINES);
    lines.truncate(STEP_DIFF_LINES);
    if more > 0 {
        lines.push(format!("... {more} more (the batch's state shows the window whole)"));
    }
    (changes, lines.join("\n"))
}

impl Pixel {
    fn put(&self, e: &Engine, value: Option<(Geometry, u64)>) {
        let mut seen = lock(&e.seen);
        match value {
            Some(v) => seen.insert(self.key.clone(), v),
            None => seen.remove(&self.key),
        };
    }

    /// The step's capture compares with the previous step's.
    fn before_settle(&self, e: &Engine) {
        self.put(e, self.step);
    }

    /// The step's capture is the next step's baseline; the agent's own
    /// screenshot stays what pixel coordinates map through and what the
    /// batch's state compares with.
    fn after_settle(&mut self, e: &Engine) {
        self.step = lock(&e.seen).get(&self.key).copied().or(self.step);
        self.put(e, self.agent);
    }

    fn restore(&self, e: &Engine) {
        self.put(e, self.agent);
    }
}

/// A step that failed: its error, as the agent reads it.
fn failed_entry(index: usize, name: &Value, failure: &ToolOutput) -> Value {
    json!({
        "step": index,
        "action": name,
        "status": "failed",
        "code": failure.code,
        // Errors carry their text as `error` (ToolOutput::error); without it
        // an agent sees only a code and gives up.
        "message": failure.body.get("error").or_else(|| failure.body.get("message")).cloned(),
    })
}

/// Which step stopped the batch, and why.
fn stop_entry(index: usize, name: &Value, out: &ToolOutput) -> Value {
    json!({
        "step": index,
        "action": name,
        "code": out.code,
        "reason": out.body.get("error").or_else(|| out.body.get("message")).cloned(),
    })
}

/// The batch's reply: every step, with the ones after a stop `not_run`.
fn reply(
    completed: usize,
    names: &[Value],
    mut steps: Vec<Value>,
    stopped: Option<Value>,
) -> ToolOutput {
    for (index, name) in names.iter().enumerate().skip(steps.len()) {
        steps.push(json!({"step": index, "action": name, "status": "not_run"}));
    }
    let mut body = json!({
        "completed": completed,
        "of": names.len(),
        "stopped": stopped.is_some(),
        "results": steps,
    });
    if let Some(stopped) = stopped {
        set_key(&mut body, "stopped_at", stopped);
    }
    ToolOutput::ok(body)
}
