//! Every app a tool call names, resolved and checked before the call runs: the
//! Rust twin of the macOS helper's `CuaTargetGuard`
//! (`Packages/macOS/CmuxComputerUseHelper/Sources/CmuxCuaHelperCore/CuaTargetGuard.swift`),
//! whose tests `tests.rs` mirrors case for case.
//!
//! - Every `pid`, `window_id`, `bundle_id` / `app_bundle_id`, `app_name` (and
//!   `launch_app`'s `name`) is resolved here, never taken from the agent's
//!   words, and each resolved app must pass the never-allowed list
//!   ([`crate::policy::refusal`]). A window owned by another pid than the
//!   call's `pid` is checked too.
//! - `launch_app` is rewritten to launch the executable resolved here
//!   (Windows: `path`; Linux: `name` as an absolute path), so upstream never
//!   resolves the agent's name a second time (the Swift guard sets
//!   `bundle_id`). Its other launch selectors (`launch_path`, `path`,
//!   `aumid`), which upstream prefers over `name`, are refused, as are its
//!   `urls`: a `cmux:`, `cmux-…:` or `cmux+…:` URL as on macOS, and any other
//!   because upstream opens URLs in whichever app handles them (Linux opens
//!   them instead of the named app), which this guard cannot check.
//! - Each tool may carry only the selector keys this guard knows for it
//!   ([`selector_keys_for`]); another selector-like key (`launch_path`,
//!   `path`, `aumid`, `name`, `urls`, `url`, `tab_id`, `target_id`) is refused
//!   until reviewed, so a new upstream selector cannot pass unresolved.
//! - Upstream's loose name selectors (`app`, `window`) and unknown `scope`s or
//!   typed `target` kinds are refused: the guard cannot repeat their matching.
//! - Desktop input (`scope: desktop`, typed desktop targets) needs an explicit
//!   pid or window; an `element_token` needs its pid.
//! - `run_script` and `replay_trajectory` run tools from content the guard
//!   cannot see and are refused; `run_steps` / `run_actions` are walked step by
//!   step (a step with no target of its own inherits the batch's pid and
//!   window, as upstream's `batch_tools.rs` does). A `launch_app` step, or a
//!   launch selector anywhere in a batch, is refused: launch it on its own.

use async_trait::async_trait;
use serde_json::{Map, Value};

use crate::approval::Target;
use crate::policy;
use crate::worker::driver::CallError;

/// How the guard learns which app a pid, window or name is (never the agent's words).
#[async_trait]
pub trait TargetResolver: Send + Sync {
    async fn app_for_pid(&self, pid: u32) -> Option<Target>;
    async fn app_for_window(&self, window_id: u32) -> Option<Target>;
    async fn app_named(&self, name: &str) -> Option<Target>;
    async fn app_for_bundle_id(&self, bundle_id: &str) -> Option<Target>;
}

/// The apps one call targets, distinct, in the order the call names them,
/// and the arguments to run it with (`launch_app` rewritten to the resolved
/// executable; every other call unchanged).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checked {
    pub targets: Vec<Target>,
    pub arguments: Value,
}

impl Checked {
    fn record(&mut self, target: Target) {
        if !self.targets.iter().any(|known| known.key() == target.key()) {
            self.targets.push(target);
        }
    }
}

/// Tools that run other tools from content outside their arguments.
pub const OPAQUE_DISPATCH_TOOLS: [&str; 2] = policy::OPAQUE_TOOLS;
/// Tools that run nested tool calls given in their arguments (`run_actions` is
/// upstream's hidden alias of `run_steps`).
pub const BATCH_TOOLS: [&str; 2] = ["run_steps", "run_actions"];
const TYPED_TARGET_TOOLS: [&str; 8] =
    ["move_cursor", "click", "drag", "scroll", "type_text", "press_key", "hotkey", "type_text_chars"];
const DESKTOP_INPUT_TOOLS: [&str; 10] = [
    "click",
    "double_click",
    "right_click",
    "drag",
    "scroll",
    "move_cursor",
    "press_key",
    "hotkey",
    "type_text",
    "type_text_chars",
];
/// Keys that make a batch step's target its own (no inherited pid / window).
const STEP_TARGET_KEYS: [&str; 9] =
    ["pid", "window_id", "target", "scope", "app", "window", "bundle_id", "app_bundle_id", "app_name"];
const MAX_DEPTH: usize = 16;
/// Keys upstream (cua-driver-rs v0.34.0) reads to choose an app, window, tab
/// or launch target beyond the ones [`Guard::check_targets`] resolves.
const SELECTOR_KEYS: [&str; 8] = ["launch_path", "path", "aumid", "name", "urls", "url", "tab_id", "target_id"];
/// Launch selectors refused anywhere in a batch.
const BATCH_REFUSED_KEYS: [&str; 3] = ["launch_path", "aumid", "urls"];

/// The [`SELECTOR_KEYS`] a tool may carry. `launch_app`'s `name` is resolved
/// and its `urls` checked here; the rest only choose inside an app the call
/// already targets (a drag's point `path`, a browser tab of its pid, a
/// browser profile name). Every other tool carries none.
pub fn selector_keys_for(tool: &str) -> &'static [&'static str] {
    match tool {
        "launch_app" => &["name", "urls"],
        "parallel_mouse_drag" => &["path"],
        "browser_navigate" => &["url"],
        "browser_pointer" => &["tab_id", "target_id"],
        "browser_prepare" => &["name"],
        _ => &[],
    }
}

/// Whether `tool` runs nested steps.
pub fn is_batch(tool: &str) -> bool {
    BATCH_TOOLS.contains(&tool)
}

/// Checks `tool`'s arguments and returns every app it targets.
pub async fn check(
    tool: &str,
    arguments: &Value,
    resolver: &dyn TargetResolver,
    allow_terminals: &[String],
) -> Result<Checked, CallError> {
    let Some(object) = arguments.as_object() else {
        return Err(CallError::new("bad_request", "Computer Use arguments must be a JSON object"));
    };
    check_dispatch(tool)?;
    let guard = Guard { resolver, allow_terminals };
    let mut checked = Checked { targets: Vec::new(), arguments: arguments.clone() };
    if is_batch(tool) {
        guard.check_batch(object, &mut checked).await?;
        return Ok(checked);
    }
    check_selector_keys(tool, object)?;
    guard.check_targets(object, Some(tool), &mut checked).await?;
    if tool == "launch_app" {
        check_urls(object)?;
        let launched = guard.check_launch(object, &mut checked).await?;
        checked.arguments = Value::Object(rewrite_launch(object, &launched, cfg!(windows))?);
        return Ok(checked);
    }
    if tool == "browser_navigate" {
        check_navigate_url(object)?;
    }
    if let Some(value) = present(object, "app_name") {
        let reference = value.as_str().filter(|text| !text.is_empty()).ok_or_else(|| unresolved("app_name"))?;
        let app = resolver.app_named(reference).await;
        guard.admit(app, reference, &mut checked)?;
    }
    Ok(checked)
}

/// Refuses a selector key `tool` may not carry ([`selector_keys_for`]).
fn check_selector_keys(tool: &str, object: &Map<String, Value>) -> Result<(), CallError> {
    let allowed = selector_keys_for(tool);
    match SELECTOR_KEYS.iter().find(|key| present(object, key).is_some() && !allowed.contains(key)) {
        Some(key) => Err(CallError::new(
            "target_unsupported",
            format!("Computer Use cannot check `{key}` on {tool}: name the app by pid and window_id (list_apps, list_windows)"),
        )),
        None => Ok(()),
    }
}

/// Whether `url` opens cmux (`cmux:`, `cmux-…:`, `cmux+…:`).
fn opens_cmux(url: &str) -> bool {
    url.split_once(':').is_some_and(|(scheme, _)| {
        let scheme = scheme.trim().to_ascii_lowercase();
        scheme == "cmux" || scheme.starts_with("cmux-") || scheme.starts_with("cmux+")
    })
}

fn cmux_refused() -> CallError {
    CallError::new("target_refused", "Computer Use is not allowed to use cmux for safety reasons")
}

/// `browser_navigate`'s `url` never opens cmux through the browser's protocol handler
/// (review 3 #4); the browser itself is the call's checked target.
fn check_navigate_url(object: &Map<String, Value>) -> Result<(), CallError> {
    match present(object, "url").and_then(Value::as_str) {
        Some(url) if opens_cmux(url) => Err(cmux_refused()),
        _ => Ok(()),
    }
}

/// `launch_app`'s `urls`: the Swift guard's `cmux:`, `cmux-…:`, `cmux+…:`
/// refusal, then every other URL (opened in an app this guard cannot resolve).
fn check_urls(object: &Map<String, Value>) -> Result<(), CallError> {
    let Some(urls) = present(object, "urls") else { return Ok(()) };
    let urls = urls.as_array().ok_or_else(|| CallError::new("bad_request", "launch_app urls must be a list of strings"))?;
    for url in urls {
        let url = url.as_str().ok_or_else(|| CallError::new("bad_request", "launch_app urls must be a list of strings"))?;
        if opens_cmux(url) {
            return Err(cmux_refused());
        }
    }
    if urls.is_empty() {
        return Ok(());
    }
    Err(CallError::new(
        "target_unsupported",
        "Computer Use cannot check which app opens launch_app urls: launch the app by name, then open the URL in it",
    ))
}

/// The arguments that launch exactly `launched` (an absolute executable).
/// Windows: `path`, which upstream prefers over `name`; Linux: `name`, which
/// upstream runs as a command split at whitespace, so a path with whitespace
/// cannot be launched exactly and is refused.
fn rewrite_launch(object: &Map<String, Value>, launched: &Target, windows: bool) -> Result<Map<String, Value>, CallError> {
    let executable = launched.executable.clone().ok_or_else(|| unresolved(&launched.name))?;
    let mut rewritten = object.clone();
    rewritten.remove("app_name");
    if windows {
        rewritten.remove("name");
        rewritten.insert("path".into(), Value::from(executable));
    } else {
        if executable.contains(char::is_whitespace) {
            return Err(CallError::new(
                "target_unsupported",
                format!("Computer Use cannot launch {executable} exactly (its path has a space): launch it another way"),
            ));
        }
        rewritten.insert("name".into(), Value::from(executable));
    }
    Ok(rewritten)
}

struct Guard<'a> {
    resolver: &'a dyn TargetResolver,
    allow_terminals: &'a [String],
}

impl Guard<'_> {
    /// `launch_app`'s app: `name` and `app_name` (both checked; they must be
    /// one app), never `launch_path`, `path` or `aumid`.
    async fn check_launch(&self, object: &Map<String, Value>, checked: &mut Checked) -> Result<Target, CallError> {
        for key in ["launch_path", "path", "aumid"] {
            if present(object, key).is_some() {
                return Err(CallError::new(
                    "target_unsupported",
                    format!("Computer Use cannot check launch_app's `{key}`: give the app's name"),
                ));
            }
        }
        let mut launched: Option<Target> = None;
        for key in ["name", "app_name"] {
            let Some(value) = present(object, key) else { continue };
            let reference = value.as_str().filter(|text| !text.is_empty()).ok_or_else(|| unresolved(key))?;
            let app = self.resolver.app_named(reference).await;
            self.admit(app.clone(), reference, checked)?;
            let app = app.ok_or_else(|| unresolved(reference))?;
            if launched.as_ref().is_some_and(|known| known.key() != app.key()) {
                return Err(CallError::new("bad_request", "launch_app's name and app_name name different apps"));
            }
            launched = Some(app);
        }
        launched.ok_or_else(|| CallError::new("target_unresolved", "launch_app needs the app's name"))
    }

    /// Refuses an unresolved or never-allowed app; records an allowed one.
    fn admit(&self, app: Option<Target>, reference: &str, checked: &mut Checked) -> Result<(), CallError> {
        let app = app.ok_or_else(|| unresolved(reference))?;
        if let Some(reason) = policy::refusal(&app, self.allow_terminals) {
            return Err(CallError::new(
                "target_refused",
                format!("Computer Use is not allowed to use {} ({reason})", app.name),
            ));
        }
        checked.record(app);
        Ok(())
    }

    /// The pid, window, bundle id and element token targets of one argument
    /// object. `tool` is None for an object nested in a batch.
    async fn check_targets(
        &self,
        object: &Map<String, Value>,
        tool: Option<&str>,
        checked: &mut Checked,
    ) -> Result<(), CallError> {
        let fields = target_fields(object, tool)?;
        let has_pid = present(&fields, "pid").is_some();
        let has_window = present(&fields, "window_id").is_some();
        if let Some(value) = present(&fields, "pid") {
            let pid = positive(value, u64::from(i32::MAX.unsigned_abs())).ok_or_else(|| unresolved("pid"))?;
            let pid = u32::try_from(pid).map_err(|_| unresolved("pid"))?;
            let app = self.resolver.app_for_pid(pid).await;
            self.admit(app, &format!("pid {pid}"), checked)?;
        }
        if let Some(value) = present(&fields, "window_id") {
            let id = positive(value, u64::from(u32::MAX)).ok_or_else(|| unresolved("window_id"))?;
            let id = u32::try_from(id).map_err(|_| unresolved("window_id"))?;
            let app = self.resolver.app_for_window(id).await;
            self.admit(app, &format!("window {id}"), checked)?;
        }
        for key in ["bundle_id", "app_bundle_id"] {
            if let Some(value) = present(&fields, key) {
                let bundle = value.as_str().filter(|text| !text.is_empty()).ok_or_else(|| unresolved(key))?;
                let app = self.resolver.app_for_bundle_id(bundle).await;
                self.admit(app, bundle, checked)?;
            }
        }
        // A desktop input has an implicit, changing target: it needs an explicit
        // pid or window. In a batch the step's tool is not known here, so every
        // desktop scope needs one.
        let desktop = fields.get("scope").and_then(Value::as_str) == Some("desktop");
        if desktop && !has_pid && !has_window && tool.is_none_or(|tool| DESKTOP_INPUT_TOOLS.contains(&tool)) {
            return Err(CallError::new(
                "target_unresolved",
                "Computer Use desktop input needs an explicit app target: use list_apps or list_windows, then give pid or window_id",
            ));
        }
        // Upstream acts on an element token's own window, which this guard never resolved.
        if present(&fields, "element_token").is_some() && !has_pid {
            return Err(CallError::new(
                "target_unresolved",
                "Computer Use needs the pid with element_token: pass the pid of the window you read the token from",
            ));
        }
        Ok(())
    }

    /// Walks a batch: every step, its nested objects, and the batch's defaults.
    async fn check_batch(&self, batch: &Map<String, Value>, checked: &mut Checked) -> Result<(), CallError> {
        let defaults: Map<String, Value> =
            batch.iter().filter(|(key, _)| matches!(key.as_str(), "pid" | "window_id")).map(|(k, v)| (k.clone(), v.clone())).collect();
        // An explicit stack instead of recursion: async recursion needs boxing.
        let mut stack: Vec<(&Value, usize)> = Vec::new();
        let root = Value::Object(batch.clone());
        // Owned root kept alive for the walk.
        let root_ref: &Value = &root;
        stack.push((root_ref, 0));
        while let Some((value, depth)) = stack.pop() {
            if depth >= MAX_DEPTH {
                return Err(CallError::new("bad_request", "Computer Use batch arguments are nested too deeply"));
            }
            match value {
                Value::Object(object) => {
                    if let Some(tool) = object.get("tool").and_then(Value::as_str) {
                        check_dispatch(tool)?;
                    }
                    for key in object.keys() {
                        check_dispatch(key)?;
                    }
                    let launches = object.get("tool").and_then(Value::as_str) == Some("launch_app")
                        || object.contains_key("launch_app");
                    if launches || BATCH_REFUSED_KEYS.iter().any(|key| present(object, key).is_some()) {
                        return Err(CallError::new(
                            "tool_refused",
                            "Computer Use does not launch apps inside a batch: call launch_app on its own first",
                        ));
                    }
                    for key in ["app", "window"] {
                        if present(object, key).is_some() {
                            return Err(CallError::new(
                                "target_unsupported",
                                format!(
                                    "Computer Use batches must name each window by pid and window_id, not by `{key}`: use list_windows first"
                                ),
                            ));
                        }
                    }
                    // An untargeted step gets the batch's pid and window; an explicit step target stands alone.
                    let mut fields = object.clone();
                    if !STEP_TARGET_KEYS.iter().any(|key| present(object, key).is_some()) {
                        for (key, value) in &defaults {
                            fields.entry(key.clone()).or_insert_with(|| value.clone());
                        }
                    }
                    self.check_targets(&fields, None, checked).await?;
                    if let Some(reference) = present(object, "app_name") {
                        let reference =
                            reference.as_str().filter(|text| !text.is_empty()).ok_or_else(|| unresolved("app_name"))?;
                        let app = self.resolver.app_named(reference).await;
                        self.admit(app, reference, checked)?;
                    }
                    for (key, nested) in object {
                        if key != "app_name" {
                            stack.push((nested, depth + 1));
                        }
                    }
                }
                Value::Array(items) => {
                    for nested in items.iter().rev() {
                        stack.push((nested, depth + 1));
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }
}

/// The fields the driver targets with, as its `action_target.rs` normalizes
/// them (a typed `target` becomes pid and window_id, or a desktop scope).
fn target_fields(object: &Map<String, Value>, tool: Option<&str>) -> Result<Map<String, Value>, CallError> {
    for key in ["app", "window"] {
        if present(object, key).is_some() {
            return Err(unsupported_target());
        }
    }
    if let Some(scope) = present(object, "scope")
        && !matches!(scope.as_str(), Some("window" | "desktop"))
    {
        return Err(unsupported_target());
    }
    let Some(value) = object.get("target") else { return Ok(object.clone()) };
    let typed_ok = tool.is_none_or(|tool| TYPED_TARGET_TOOLS.contains(&tool));
    let conflicting = ["scope", "pid", "window_id"].iter().any(|key| object.contains_key(*key));
    let Some(target) = value.as_object().filter(|_| typed_ok && !conflicting) else {
        return Err(unsupported_target());
    };
    let mut fields = object.clone();
    fields.remove("target");
    match target.get("kind").and_then(Value::as_str) {
        Some("window") => {
            let keys_ok = target.len() == 3 && target.contains_key("pid") && target.contains_key("window_id");
            let pid_ok = target.get("pid").and_then(|pid| positive(pid, u64::from(i32::MAX.unsigned_abs()))).is_some();
            let window_ok = target.get("window_id").and_then(|id| positive(id, u64::from(u32::MAX))).is_some();
            if !(keys_ok && pid_ok && window_ok) {
                return Err(unsupported_target());
            }
            fields.insert("pid".into(), target["pid"].clone());
            fields.insert("window_id".into(), target["window_id"].clone());
        }
        Some("desktop") => {
            let keys_ok = target.len() == 2 && target.get("display_id").and_then(Value::as_str) == Some("primary");
            if !keys_ok {
                return Err(unsupported_target());
            }
            fields.insert("scope".into(), Value::from("desktop"));
        }
        // No app target kind upstream yet: a new kind is refused until reviewed.
        _ => return Err(unsupported_target()),
    }
    Ok(fields)
}

fn check_dispatch(tool: &str) -> Result<(), CallError> {
    if OPAQUE_DISPATCH_TOOLS.contains(&tool) {
        return Err(CallError::new(
            "tool_refused",
            format!("Computer Use does not allow {tool} in cmux: call the tools directly, or use run_steps with pid and window_id"),
        ));
    }
    Ok(())
}

/// A key's value, when present and not null.
fn present<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    object.get(key).filter(|value| !value.is_null())
}

/// A positive integer no larger than `max` (never a bool, string or fraction).
fn positive(value: &Value, max: u64) -> Option<u64> {
    value.as_u64().filter(|number| *number > 0 && *number <= max)
}

fn unsupported_target() -> CallError {
    CallError::new(
        "target_unsupported",
        "Computer Use cannot check this target shape: use pid and window_id, or target with kind window, pid and window_id",
    )
}

fn unresolved(reference: &str) -> CallError {
    CallError::new(
        "target_unresolved",
        format!("Computer Use cannot resolve {reference} to an app: use list_apps or list_windows to choose a current target"),
    )
}

#[cfg(test)]
mod tests;
