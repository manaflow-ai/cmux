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
        // After the tab verbs: `select` with words is `select SELECTOR VALUE`.
        (
            "hover" | "scroll-into-view" | "scrollintoview" | "scrollinto" | "check" | "uncheck"
            | "select" | "press" | "key" | "scroll",
            _,
        ) => input_verb(verb, rest, &mut params).ok_or_else(usage)??,
        _ => return Err(usage()),
    };
    let flagged = [
        "snapshot",
        "tabs",
        "new-tab",
        "select",
        "switch",
        "close",
        "hover",
        "scroll-into-view",
        "scrollintoview",
        "scrollinto",
        "check",
        "uncheck",
        "press",
        "key",
        "scroll",
    ];
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

/// Positional words and `--flags` in any order; a valued flag takes the next word.
fn words_and_options(
    args: &[String],
    valued: &[&str],
    flags: &[&str],
) -> Result<(Vec<String>, Options), UsageError> {
    let (mut words, mut options) = (Vec::new(), Vec::new());
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        match arg.strip_prefix("--") {
            Some(name) => {
                options.push(arg.clone());
                if valued.contains(&name) && index + 1 < args.len() {
                    options.push(args[index + 1].clone());
                    index += 1;
                }
            }
            None => words.push(arg.clone()),
        }
        index += 1;
    }
    Ok((words, Options::parse(&options, valued, flags)?))
}

/// `hover|check|uncheck|scroll-into-view SELECTOR`, `select SELECTOR VALUE`,
/// `press KEY`, `scroll [SELECTOR|DY] [--dx N] [--dy N]`. Each positional
/// also takes the old CLI's flag (`--selector`, `--value`, `--key`). None is
/// a usage error.
fn input_verb(
    verb: &str,
    args: &[String],
    params: &mut Map<String, Value>,
) -> Option<Result<&'static str, UsageError>> {
    let (words, options) =
        match words_and_options(args, &["selector", "value", "key", "dx", "dy"], &[]) {
            Ok(parsed) => parsed,
            Err(error) => return Some(Err(error)),
        };
    let mut words = words.into_iter();
    let mut take = |flag: &str| options.value(flag).map(str::to_owned).or_else(|| words.next());
    let (method, needs): (&'static str, &[&str]) = match verb {
        "hover" => ("browser.page.hover", &["selector"]),
        "check" => ("browser.page.check", &["selector"]),
        "uncheck" => ("browser.page.uncheck", &["selector"]),
        "select" => ("browser.page.select", &["selector", "value"]),
        "press" | "key" => ("browser.page.press", &["key"]),
        "scroll" => ("browser.page.scroll", &[]),
        _ => ("browser.page.scroll_into_view", &["selector"]),
    };
    for key in needs {
        params.insert((*key).into(), json!(take(key)?));
    }
    if method == "browser.page.press"
        && let Some(selector) = options.value("selector")
    {
        params.insert("selector".into(), json!(selector));
    }
    if method == "browser.page.scroll" {
        // The old `scroll N` scrolled by N down; any other word is a selector.
        let mut dy = options.value("dy").map(str::to_owned);
        let mut selector = options.value("selector").map(str::to_owned);
        if let Some(word) = words.next() {
            match word.parse::<f64>() {
                Ok(_) if dy.is_none() => dy = Some(word),
                _ if selector.is_none() => selector = Some(word),
                _ => return None,
            }
        }
        if let Some(selector) = selector {
            params.insert("selector".into(), json!(selector));
        }
        for (key, offset) in [("dx", options.value("dx").map(str::to_owned)), ("dy", dy)] {
            let Some(offset) = offset else { continue };
            let offset: f64 = offset.parse().ok().filter(|offset: &f64| offset.is_finite())?;
            params.insert(key.into(), json!(offset));
        }
        if !params.contains_key("dx") && !params.contains_key("dy") {
            return None;
        }
    } else if options.value("dx").or(options.value("dy")).is_some() {
        return None;
    }
    if words.next().is_some() {
        return None;
    }
    Some(Ok(method))
}
