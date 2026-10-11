//! `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
//! cmux app hosts, sent as `browser.page.*` app control methods. Kept out of
//! app.rs for its line budget.

use serde_json::{Map, Value, json};

use super::{AppCommand, Options, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT};

/// `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
/// app hosts (`page` is the focused tab). A daemon browser (`browser_…`) is
/// the mux grammar's.
pub(super) fn parse_page(target: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.browser_page_usage);
    let Some((verb, rest)) = args.split_first() else { return Err(usage()) };
    let mut params = Map::new();
    if target != "page" {
        params.insert("tab".into(), json!(target));
    }
    let words: Vec<&String> = rest.iter().filter(|arg| !arg.starts_with("--")).collect();
    let mut timeout = READ_TIMEOUT;
    let method = match (verb.as_str(), words.as_slice()) {
        ("navigate" | "goto" | "open", [url]) => {
            params.insert("url".into(), json!(url));
            "browser.page.navigate"
        }
        ("back", []) => "browser.page.back",
        ("forward", []) => "browser.page.forward",
        ("reload", []) => "browser.page.reload",
        ("state" | "url" | "title", []) => "browser.page.state",
        ("eval", [script]) => {
            params.insert("script".into(), json!(script));
            "browser.page.eval"
        }
        ("snapshot", _) => {
            let options = Options::parse(rest, &["selector", "max-depth"], &["interactive"])?;
            if let Some(selector) = options.value("selector") {
                params.insert("selector".into(), json!(selector));
            }
            if let Some(depth) = options.value("max-depth") {
                let depth: u32 = depth.parse().map_err(|_| usage())?;
                params.insert("max_depth".into(), json!(depth));
            }
            if options.flag("interactive") {
                params.insert("interactive".into(), json!(true));
            }
            "browser.page.snapshot"
        }
        ("click" | "focus" | "text" | "value", [selector]) => {
            params.insert("selector".into(), json!(selector));
            match verb.as_str() {
                "click" => "browser.page.click",
                "focus" => "browser.page.focus",
                "text" => "browser.page.text",
                _ => "browser.page.value",
            }
        }
        ("fill" | "type", [selector, text]) => {
            params.insert("selector".into(), json!(selector));
            params.insert("text".into(), json!(text));
            if verb == "fill" { "browser.page.fill" } else { "browser.page.type" }
        }
        ("tabs", []) => {
            if Options::parse(rest, &[], &["all"])?.flag("all") {
                params.insert("all".into(), json!(true));
            }
            "browser.page.tabs"
        }
        // These run the app's tab actions and wait for them unless `--no-wait`,
        // as `action run` does.
        ("new-tab", [] | [_]) | ("select" | "switch" | "close", []) => {
            if let [url] = words.as_slice() {
                params.insert("url".into(), json!(url));
            }
            let flags: Vec<String> =
                rest.iter().filter(|arg| arg.starts_with("--")).cloned().collect();
            if Options::parse(&flags, &[], &["wait", "no-wait"])?.flag("no-wait") {
                params.insert("wait".into(), json!(false));
            } else {
                timeout = WAITING_RUN_TIMEOUT;
            }
            match verb.as_str() {
                "new-tab" => "browser.page.new_tab",
                "close" => "browser.page.close",
                _ => "browser.page.select_tab",
            }
        }
        _ => return Err(usage()),
    };
    let flagged = ["snapshot", "tabs", "new-tab", "select", "switch", "close"];
    if !flagged.contains(&verb.as_str()) && words.len() != rest.len() {
        return Err(usage());
    }
    Ok(AppCommand::Call {
        method,
        params: Value::Object(params),
        timeout: Some(timeout),
        pick: None,
    })
}
