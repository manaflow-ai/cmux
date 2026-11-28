//! `browser.siteEngines`: sites that open in a set engine whatever
//! `browser.defaultEngine` says. The default is empty: cmux's Chromium plays
//! Widevine media, so protected-media sites stay in it; a person can still pin
//! a site to WebKit with a rule. This is the daemon's copy of CmuxNextSettings
//! `BrowserSiteEngines`; both run `tests/fixtures/browser_site_engines.json`,
//! so a tab an agent opens gets the same engine as one the person opens.

use std::sync::Arc;

use serde_json::{Map, Value};

use crate::Mux;

/// The setting's dotted key.
pub(crate) const SITE_ENGINES_SETTING: &str = "browser.siteEngines";

/// The frontend engine tag (`cef`, `webkit`) the person's
/// `browser.siteEngines` give `url`, `None` when no rule matches.
pub(crate) fn site_engine_for(mux: &Arc<Mux>, url: &str) -> Option<&'static str> {
    let target = cmux_config::Target::Key(SITE_ENGINES_SETTING.to_string());
    let value = mux.with_settings(|state| state.get(&target).row.and_then(|row| row.value))?;
    site_engine(value.as_object()?, url)
}

/// The frontend engine tag the most specific rule of `rules` gives `url`:
/// a pattern is a host (matching it and its subdomains), optionally with a
/// path prefix; the longest host wins, then the longest path. Only http and
/// https pages match; a rule whose engine is not `chromium` or `webkit` is
/// left out.
pub(crate) fn site_engine(rules: &Map<String, Value>, url: &str) -> Option<&'static str> {
    let parsed = url::Url::parse(url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    let mut host = parsed.host_str()?.to_ascii_lowercase();
    if host.ends_with('.') {
        host.pop();
    }
    let path = parsed.path().to_ascii_lowercase();
    let mut best: Option<((usize, usize), &'static str)> = None;
    for (pattern, engine) in rules {
        let Some(engine) = engine.as_str().and_then(engine_tag) else { continue };
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
        let rank =
            (pattern_host.chars().count(), pattern_path.map_or(0, |path| path.chars().count()));
        if best.is_some_and(|(current, _)| current >= rank) {
            continue;
        }
        best = Some((rank, engine));
    }
    best.map(|(_, engine)| engine)
}

fn engine_tag(engine: &str) -> Option<&'static str> {
    match engine {
        "chromium" => Some("cef"),
        "webkit" => Some("webkit"),
        _ => None,
    }
}

/// `HTTPS://*.Open.Spotify.com/` is `open.spotify.com`; `None` for a pattern
/// with no host.
fn normalize(pattern: &str) -> Option<String> {
    let mut text = pattern.trim().to_lowercase();
    if let Some(index) = text.find("://") {
        text = text[index + 3..].to_string();
    }
    if let Some(rest) = text.strip_prefix("*.") {
        text = rest.to_string();
    }
    while text.ends_with('/') {
        text.pop();
    }
    let (host, _) = split(&text);
    (!host.is_empty() && !host.contains(' ')).then_some(text)
}

/// The host and the path prefix (`/gp/video`) of a normalized pattern.
fn split(pattern: &str) -> (&str, Option<&str>) {
    match pattern.find('/') {
        Some(index) if &pattern[index..] != "/" => (&pattern[..index], Some(&pattern[index..])),
        Some(index) => (&pattern[..index], None),
        None => (pattern, None),
    }
}

#[cfg(test)]
#[path = "browser_site_engines_tests.rs"]
mod tests;
