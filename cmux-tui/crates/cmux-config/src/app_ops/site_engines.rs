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
mod tests {
    use serde_json::json;

    use crate::app_ops::call;

    #[test]
    fn ops_answer_the_wire_shapes() {
        let root =
            json!({"browser": {"siteEngines": {"*.Spotify.com/": "webkit", "x.com": "safari"}}});
        let reply = call("site_engines.read", &json!({ "root": root })).unwrap();
        assert_eq!(reply["rules"], json!({"spotify.com": "webkit"}));
        assert_eq!(
            reply["problems"],
            json!(["x.com: expected a site and \"chromium\" or \"webkit\""])
        );
        let reply = call("site_engines.read", &json!({ "root": {} })).unwrap();
        assert_eq!(reply, json!({"rules": null, "problems": []}));
        let reply =
            call("site_engines.normalized", &json!({"rules": {"HTTP://A.com/": "chromium"}}))
                .unwrap();
        assert_eq!(reply, json!({"rules": {"a.com": "chromium"}}));
        let request = json!({"rules": {"spotify.com": "webkit"}, "scheme": "https", "host": "open.spotify.com",
                             "path": "/track"});
        assert_eq!(call("site_engines.engine", &request).unwrap(), json!({"engine": "webkit"}));
        let request =
            json!({"rules": {"spotify.com": "webkit"}, "scheme": "file", "host": "", "path": "/"});
        assert_eq!(call("site_engines.engine", &request).unwrap(), json!({"engine": null}));
        assert!(call("site_engines.engine", &json!({"rules": {}})).is_err());
    }
}
