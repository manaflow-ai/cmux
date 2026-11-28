//! `site_engines.*`: the app's `browser.siteEngines` (Swift
//! `BrowserSiteEngines`), on [`crate::site_engines`].
//! - `site_engines.read` `{root}` answers `{rules, problems}`: the normalized
//!   rules (null when the key is missing or not an object: the default holds)
//!   and one message per refused entry.
//! - `site_engines.normalized` `{rules}` answers `{rules}`.
//! - `site_engines.engine` `{rules, scheme, host, path}` answers `{engine}`
//!   (`chromium`, `webkit` or null).

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::site_engines;

/// Runs a `site_engines.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "site_engines.read" => {
            let (rules, problems) = site_engines::read(request.get("root").unwrap_or(&Value::Null));
            let problems: Vec<String> = problems.into_iter().map(|p| p.message).collect();
            Ok(json!({ "rules": rules, "problems": problems }))
        }
        "site_engines.normalized" => {
            rules(request).map(|rules| json!({ "rules": site_engines::normalized(rules) }))
        }
        "site_engines.engine" => (|| {
            let rules = rules(request)?;
            let engine = site_engines::engine(
                rules,
                string(request, "scheme")?,
                string(request, "host")?,
                string(request, "path")?,
            );
            Ok(json!({ "engine": engine }))
        })(),
        _ => return None,
    })
}

fn rules(request: &Value) -> Result<&Map<String, Value>, OpError> {
    request
        .get("rules")
        .and_then(Value::as_object)
        .ok_or_else(|| OpError::Invalid("expected an object `rules`".to_owned()))
}

#[cfg(test)]
#[path = "site_engines_tests.rs"]
mod tests;
