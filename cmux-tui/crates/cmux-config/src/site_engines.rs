//! `browser.siteEngines`: sites that open in a set engine whatever
//! `browser.defaultEngine` says. One object of site pattern to engine
//! (`chromium` or `webkit`). A pattern is a host, optionally with a path
//! prefix: `spotify.com` matches it and every subdomain; `amazon.com/gp/video`
//! matches only paths at or under `/gp/video`. A leading `*.`, a scheme and
//! trailing slashes are ignored. The most specific pattern wins (the longest
//! host, then the longest path). Only `http` and `https` pages match.
//!
//! The one copy of the rule: the daemon (cmux-tui-core `browser_site_engines`)
//! and the app (CmuxNextSettings `BrowserSiteEngines`, through
//! `app_ops` `site_engines.*`) both ask it. The caller parses the URL (the app
//! with Foundation's `URL`, the daemon with `url::Url`) and hands its scheme,
//! host and path.

use serde_json::{Map, Value};

/// The setting's dotted key.
pub const KEY: &str = "browser.siteEngines";

/// The engines a rule may name.
pub const ENGINES: [&str; 2] = ["chromium", "webkit"];

/// The engine (`chromium` or `webkit`) the most specific rule of `rules`
/// gives a page, `None` when no rule matches (the default engine decides).
/// Patterns are normalized here, so raw and normalized rules answer alike; a
/// rule whose engine is not one of [`ENGINES`] or whose pattern has no host is
/// left out.
pub fn engine(
    rules: &Map<String, Value>,
    scheme: &str,
    host: &str,
    path: &str,
) -> Option<&'static str> {
    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let mut host = host.to_lowercase();
    if host.ends_with('.') {
        host.pop();
    }
    if host.is_empty() {
        return None;
    }
    let path = if path.is_empty() { "/".to_owned() } else { path.to_lowercase() };
    let mut best: Option<((usize, usize), &'static str)> = None;
    for (pattern, engine) in rules {
        let Some(engine) = engine.as_str().and_then(known_engine) else { continue };
        let Some(pattern) = normalize(pattern) else { continue };
        let (pattern_host, pattern_path) = split(&pattern);
        if host != pattern_host && !host.ends_with(&format!(".{pattern_host}")) {
            continue;
        }
        if let Some(prefix) = pattern_path
            && path != prefix
            && !path.starts_with(&format!("{prefix}/"))
        {
            continue;
        }
        let rank = (pattern_host.chars().count(), pattern_path.map_or(0, |p| p.chars().count()));
        if best.is_some_and(|(current, _)| current >= rank) {
            continue;
        }
        best = Some((rank, engine));
    }
    best.map(|(_, engine)| engine)
}

/// Rules with every pattern normalized; a pattern with no host, or an engine
/// that is not one of [`ENGINES`], is dropped.
pub fn normalized(rules: &Map<String, Value>) -> Map<String, Value> {
    rules
        .iter()
        .filter_map(|(pattern, engine)| {
            let engine = engine.as_str().and_then(known_engine)?;
            Some((normalize(pattern)?, Value::String(engine.to_owned())))
        })
        .collect()
}

/// One refused entry or value of the setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub message: String,
}

/// Reads `browser.siteEngines` from a settings root: `None` when the key is
/// missing (the default holds, no problem); otherwise the normalized rules
/// and a problem for each refused entry. A value that is not an object is
/// the default (`None`) with one problem.
pub fn read(root: &Value) -> (Option<Map<String, Value>>, Vec<Problem>) {
    let Some(value) =
        root.get("browser").and_then(Value::as_object).and_then(|b| b.get("siteEngines"))
    else {
        return (None, Vec::new());
    };
    let Some(members) = value.as_object() else {
        let message = "expected an object of site to \"chromium\" or \"webkit\"".to_owned();
        return (None, vec![Problem { message }]);
    };
    let mut problems = Vec::new();
    let mut accepted = Map::new();
    for (pattern, engine) in members {
        if engine.as_str().and_then(known_engine).is_none() || normalize(pattern).is_none() {
            let message = format!("{pattern}: expected a site and \"chromium\" or \"webkit\"");
            problems.push(Problem { message });
            continue;
        }
        accepted.insert(pattern.clone(), engine.clone());
    }
    (Some(normalized(&accepted)), problems)
}

fn known_engine(engine: &str) -> Option<&'static str> {
    ENGINES.into_iter().find(|known| *known == engine)
}

/// `HTTPS://*.Open.Spotify.com/` is `open.spotify.com`; `None` for a pattern
/// with no host.
pub fn normalize(pattern: &str) -> Option<String> {
    let mut text = pattern.trim().to_lowercase();
    if let Some((_, rest)) = text.split_once("://") {
        text = rest.to_owned();
    }
    if let Some(rest) = text.strip_prefix("*.") {
        text = rest.to_owned();
    }
    while text.ends_with('/') {
        text.pop();
    }
    let (host, _) = split(&text);
    (!host.is_empty() && !host.contains(' ')).then_some(text)
}

/// The host and the path prefix (`/gp/video`) of a normalized pattern.
fn split(pattern: &str) -> (&str, Option<&str>) {
    match pattern.find('/').and_then(|index| pattern.split_at_checked(index)) {
        Some((host, "/")) => (host, None),
        Some((host, path)) => (host, Some(path)),
        None => (pattern, None),
    }
}

#[cfg(test)]
#[path = "site_engines_tests.rs"]
mod tests;
