//! `browser.siteEngines` for tabs the daemon opens: the rule is cmux-config's
//! [`cmux_config::site_engines`], the one the app asks too (CmuxNextSettings
//! `BrowserSiteEngines`, through `site_engines.*`), so a tab an agent opens
//! gets the same engine as one the person opens.

use std::sync::Arc;

use serde_json::{Map, Value};

use crate::Mux;

/// The setting's dotted key.
pub(crate) const SITE_ENGINES_SETTING: &str = cmux_config::site_engines::KEY;

/// The frontend engine tag (`cef`, `webkit`) the person's
/// `browser.siteEngines` give `url`, `None` when no rule matches.
pub(crate) fn site_engine_for(mux: &Arc<Mux>, url: &str) -> Option<&'static str> {
    let target = cmux_config::Target::Key(SITE_ENGINES_SETTING.to_string());
    let value = mux.with_settings(|state| state.get(&target).row.and_then(|row| row.value))?;
    site_engine(value.as_object()?, url)
}

/// The frontend engine tag the most specific rule of `rules` gives `url`.
pub(crate) fn site_engine(rules: &Map<String, Value>, url: &str) -> Option<&'static str> {
    let parsed = url::Url::parse(url).ok()?;
    let engine = cmux_config::site_engines::engine(
        rules,
        parsed.scheme(),
        parsed.host_str()?,
        parsed.path(),
    )?;
    engine_tag(engine)
}

fn engine_tag(engine: &str) -> Option<&'static str> {
    match engine {
        "chromium" => Some("cef"),
        "webkit" => Some("webkit"),
        _ => None,
    }
}

#[cfg(test)]
#[path = "browser_site_engines_tests.rs"]
mod tests;
