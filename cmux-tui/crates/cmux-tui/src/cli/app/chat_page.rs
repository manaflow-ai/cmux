//! `cmux app chat page --tab <tab> query [SELECTOR] [--style P,…] [--limit N]` and
//! `cmux app chat page --tab <tab> screenshot [--out FILE|-]`: what a conversation tab's chat page
//! shows, read in the running app (Release and Nightly too) without focusing, selecting or showing
//! the tab, so it works behind other windows and on a locked Mac, where Computer Use sees nothing
//! and `cmux browser <tab> eval` refuses a chat tab (it is no browser tab).
//!
//! The app's `agent.chat.page.query` answers the elements (tag, `data-*`, classes, text as drawn,
//! role, accessible label, rect, whether it is in the viewport, and the computed styles asked for);
//! this CLI masks every string in the answer with `acpmux::secret_scan::mask` before printing, as
//! `cmux agents chat read` masks a chat's text, so a key pasted into a chat does not reach an
//! agent's terminal. `agent.chat.page.screenshot` is the page's own surface with every text run,
//! image, canvas, video, frame and field greyed by the app before its pixels leave, the same rule
//! as a window capture's chat mask (AppWindowImage.swift's `ScreenshotMask.Rules.app`): layout,
//! colors and which controls show, never words.

use std::fmt::Write as _;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::super::OutputMode;
use super::page::{SCREENSHOT_TIMEOUT, save_screenshot};
use super::{AppCommand, GlobalArgs, Options, READ_TIMEOUT, UsageError};
use crate::localization::ChatPageMessages;

pub(super) const QUERY_METHOD: &str = "agent.chat.page.query";
pub(super) const SCREENSHOT_METHOD: &str = "agent.chat.page.screenshot";
/// The app's own bounds (AgentChatPageControl.swift).
const MAX_LIMIT: u64 = 1000;
const MAX_STYLES: usize = 64;

/// What `cmux app chat page` runs.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Request {
    Query(Value),
    Screenshot { params: Value, out: Option<String> },
}

/// `rest` starts with `chat page`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(crate::localization::catalog().app_control.chat_page.usage);
    let args = rest.get(2..).unwrap_or_default();
    let mut words = Vec::new();
    let mut flags = Vec::new();
    let valued = ["tab", "style", "limit", "out"];
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some(name) = arg.strip_prefix("--") {
            flags.push(arg.clone());
            if valued.contains(&name) && index + 1 < args.len() {
                flags.push(args[index + 1].clone());
                index += 1;
            }
        } else {
            words.push(arg.as_str());
        }
        index += 1;
    }
    let options = Options::parse(&flags, &valued, &[])?;
    let tab = options.value("tab").filter(|tab| !tab.is_empty()).ok_or_else(usage)?;
    let mut params = Map::new();
    params.insert("tab".into(), json!(tab));
    match words.as_slice() {
        ["query", selector @ ..] if selector.len() <= 1 => {
            if options.value("out").is_some() {
                return Err(usage());
            }
            if let Some(selector) = selector.first() {
                params.insert("selector".into(), json!(selector));
            }
            let styles: Vec<&str> = options
                .values("style")
                .into_iter()
                .flat_map(|list| list.split(','))
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .collect();
            if styles.len() > MAX_STYLES {
                return Err(usage());
            }
            if !styles.is_empty() {
                params.insert("styles".into(), json!(styles));
            }
            if let Some(limit) = options.value("limit") {
                let limit = limit
                    .parse::<u64>()
                    .ok()
                    .filter(|limit| (1..=MAX_LIMIT).contains(limit))
                    .ok_or_else(usage)?;
                params.insert("limit".into(), json!(limit));
            }
            Ok(AppCommand::ChatPage(Request::Query(Value::Object(params))))
        }
        ["screenshot"] => {
            if options.value("style").is_some() || options.value("limit").is_some() {
                return Err(usage());
            }
            let out = options.value("out").map(str::to_owned);
            Ok(AppCommand::ChatPage(Request::Screenshot { params: Value::Object(params), out }))
        }
        _ => Err(usage()),
    }
}

/// Calls the app and prints the masked elements, or saves the masked picture.
pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, request: Request) -> i32 {
    let (method, params, timeout): (&str, &Value, Duration) = match &request {
        Request::Query(params) => (QUERY_METHOD, params, READ_TIMEOUT),
        Request::Screenshot { params, .. } => (SCREENSHOT_METHOD, params, SCREENSHOT_TIMEOUT),
    };
    match super::wait::request(global, stream, method, params, Some(timeout)) {
        Ok(Ok(result)) => match request {
            Request::Screenshot { out, .. } => {
                save_screenshot(result, out.as_deref(), global.output)
            }
            Request::Query(_) => {
                let masked = masked(result);
                match global.output {
                    OutputMode::Human => {
                        print!(
                            "{}",
                            human(&masked, &crate::localization::catalog().app_control.chat_page)
                        );
                        0
                    }
                    _ => super::super::wire::print_local_success(&masked, global.output),
                }
            }
        },
        Ok(Err(mut error)) => {
            if super::error_code(&error) == Some("method_not_found") {
                super::skew::annotate(stream, method, &mut error);
            }
            super::super::wire::print_local_error(&error, global.output, 1)
        }
        Err(error) => super::super::wire::print_local_error(&error, global.output, 3),
    }
}

/// A `browser.page.*` refusal of a chat tab (the app's `data.kind` is `conversation`) names the
/// command that reads one, so the caller is not left at "not a browser tab".
pub(super) fn explain_chat_tab(method: &str, error: &mut Value) {
    if !method.starts_with("browser.page.") || error["data"]["kind"] != "conversation" {
        return;
    }
    let Some(tab) = error["data"]["tab"].as_str().map(str::to_owned) else { return };
    let hint =
        crate::localization::catalog().app_control.chat_page.browser_hint.replace("{tab}", &tab);
    if let Some(Value::String(message)) = error.get_mut("message") {
        message.push_str(". ");
        message.push_str(&hint);
    }
}

/// `value` with every string masked for secrets (`acpmux::secret_scan::mask`): text, labels,
/// `data-*` values, classes and style values alike, so nothing the page drew reaches the caller
/// unmasked whatever member it comes in. Object keys are names the page's code chose, kept.
pub(super) fn masked(value: Value) -> Value {
    match value {
        Value::String(text) => Value::String(acpmux::secret_scan::mask(&text)),
        Value::Array(items) => Value::Array(items.into_iter().map(masked).collect()),
        Value::Object(members) => {
            Value::Object(members.into_iter().map(|(key, value)| (key, masked(value))).collect())
        }
        other => other,
    }
}

/// One line per element: `tag.class…`, its role and label, `data-*`, its text, then its styles.
pub(super) fn human(answer: &Value, messages: &ChatPageMessages) -> String {
    let elements = answer["elements"].as_array().map(Vec::as_slice).unwrap_or_default();
    let mut out = String::new();
    let _ = writeln!(
        out,
        "{}",
        messages
            .header
            .replace("{tab}", answer["tab"].as_str().unwrap_or_default())
            .replace("{shown}", &elements.len().to_string())
            .replace("{count}", &answer["count"].as_u64().unwrap_or_default().to_string())
    );
    for element in elements {
        let mut line = element["tag"].as_str().unwrap_or("?").to_owned();
        for class in element["classes"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            let _ = write!(line, ".{class}");
        }
        if element["visible"] == Value::Bool(false) {
            let _ = write!(line, " {}", messages.offscreen);
        }
        if let Some(role) = element["role"].as_str() {
            let _ = write!(line, " role={role}");
        }
        if let Some(label) = element["label"].as_str() {
            let _ = write!(line, " label={label:?}");
        }
        for (key, value) in element["data"].as_object().into_iter().flatten() {
            let _ = write!(line, " data-{key}={}", value.as_str().unwrap_or_default());
        }
        let text = element["text"]
            .as_str()
            .unwrap_or_default()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if !text.is_empty() {
            let _ = write!(line, " {text:?}");
        }
        if let Some(styles) = element["style"].as_object() {
            let styles: Vec<String> = styles
                .iter()
                .map(|(name, value)| format!("{name}: {}", value.as_str().unwrap_or_default()))
                .collect();
            let _ = write!(line, " {{{}}}", styles.join("; "));
        }
        let _ = writeln!(out, "{line}");
    }
    out
}

#[cfg(test)]
#[path = "chat_page_tests.rs"]
mod tests;
