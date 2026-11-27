//! Where links open: Swift `LinkRouting`, `TerminalLinkOpener` (rules,
//! targets, launches), `BrowserLinkClickSetting`, `LinkPlacement`,
//! `SSHLinkHostsSetting` and the `BrowserExternalURLPatternMatcher` rules
//! ([`crate::link_rules`]). A read takes the settings `root` and answers the
//! setting with `problems` (`[{path, message}]`). The app splits each URL with
//! Foundation and passes `url` (absolute string), `scheme`, `host` and
//! `signInPage` (its `SignInPage` test).
//!
//! - `link_rules.routing` `{root}` answers `{routing, problems}`.
//! - `link_rules.opener` `{root}` answers `{opener, problems}`.
//! - `link_rules.clicks` `{root}` answers `{clicks, problems}`.
//! - `link_rules.placement` `{root}` answers `{placement, problems}`.
//! - `link_rules.ssh_hosts` `{root}` answers `{hosts}`;
//!   `link_rules.ssh_allow` `{root, host}` answers `{hosts}` to write, or `{}`.
//! - `link_rules.target` `{routing, url, scheme, host, signInPage, otherTarget?, explicit?}`
//!   answers `{target}` (`cmuxBrowser` or `system`); `link_rules.opens_in_cmux`
//!   (same request) answers `{opensInCmux}`.
//! - `link_rules.normalized_host` `{host}` answers `{host}` (null: none).
//! - `link_rules.external_matches` `{patterns, url}` answers `{matches}`;
//!   `link_rules.normalized_patterns` `{patterns}` answers `{patterns}`;
//!   `link_rules.regex_accepts` `{expression}` answers `{accepts}`.
//! - `link_rules.opener_target` `{text}` answers `{target}` (null: none);
//!   `link_rules.opener_rule` `{text}` answers `{rule}` (null: none).
//! - `link_rules.decide` `{opener, url, callers, signInPage?, routing?}`
//!   answers `{target, rule}` (rule: the index, null for the default).
//! - `link_rules.launch` `{target, url}` answers `{launch}` (null: not an app).

use serde_json::{Value, json};

use super::{OpError, string};
use crate::link_rules::{self, Link, Opener, Problem, Routing, Rule, Target, pattern};

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "link_rules.routing" => routing(request),
        "link_rules.opener" => opener(request),
        "link_rules.clicks" => clicks(request),
        "link_rules.placement" => placement(request),
        "link_rules.ssh_hosts" => {
            root(request).map(|root| json!({ "hosts": link_rules::ssh_hosts(root) }))
        }
        "link_rules.ssh_allow" => ssh_allow(request),
        "link_rules.target" => target(request),
        "link_rules.opens_in_cmux" => opens_in_cmux(request),
        "link_rules.normalized_host" => {
            string(request, "host").map(|host| json!({ "host": link_rules::normalized_host(host) }))
        }
        "link_rules.external_matches" => external_matches(request),
        "link_rules.normalized_patterns" => strings(request, "patterns")
            .map(|patterns| json!({ "patterns": pattern::Matcher::new(&patterns).patterns() })),
        "link_rules.regex_accepts" => string(request, "expression")
            .map(|expression| json!({ "accepts": pattern::regex_accepts(expression) })),
        "link_rules.opener_target" => string(request, "text")
            .map(|text| json!({ "target": Target::parse(text).map(|target| target.json()) })),
        "link_rules.opener_rule" => string(request, "text")
            .map(|text| json!({ "rule": Rule::parse(text).map(|rule| rule.json()) })),
        "link_rules.decide" => decide(request),
        "link_rules.launch" => launch(request),
        _ => return None,
    })
}

fn root(request: &Value) -> Result<&Value, OpError> {
    request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))
}

fn problems(problems: &[Problem]) -> Value {
    Value::Array(problems.iter().map(Problem::json).collect())
}

fn strings(request: &Value, key: &str) -> Result<Vec<String>, OpError> {
    request
        .get(key)
        .and_then(Value::as_array)
        .and_then(|items| items.iter().map(|item| item.as_str().map(str::to_owned)).collect())
        .ok_or_else(|| OpError::Invalid(format!("expected an array of strings `{key}`")))
}

fn flag(request: &Value, key: &str) -> Result<bool, OpError> {
    match request.get(key) {
        None => Ok(false),
        Some(value) => {
            value.as_bool().ok_or_else(|| OpError::Invalid(format!("expected a bool `{key}`")))
        }
    }
}

/// A string member that may be missing or null ("").
fn optional_string<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(""),
        Some(value) => {
            value.as_str().ok_or_else(|| OpError::Invalid(format!("expected a string `{key}`")))
        }
    }
}

fn routing_member(request: &Value) -> Result<Routing, OpError> {
    match request.get("routing") {
        None => Ok(Routing::default()),
        Some(value) => Routing::from_json(value)
            .ok_or_else(|| OpError::Invalid("expected a `routing` object".to_owned())),
    }
}

fn link(request: &Value) -> Result<Link<'_>, OpError> {
    Ok(Link {
        url: string(request, "url")?,
        scheme: optional_string(request, "scheme")?,
        host: optional_string(request, "host")?,
        sign_in_page: flag(request, "signInPage")?,
    })
}

fn routing(request: &Value) -> Result<Value, OpError> {
    let (setting, found) = Routing::read(root(request)?);
    Ok(json!({ "routing": setting.json(), "problems": problems(&found) }))
}

fn opener(request: &Value) -> Result<Value, OpError> {
    let (setting, found) = Opener::read(root(request)?);
    Ok(json!({ "opener": setting.json(), "problems": problems(&found) }))
}

fn clicks(request: &Value) -> Result<Value, OpError> {
    let (setting, found) = link_rules::read_clicks(root(request)?);
    Ok(json!({ "clicks": setting, "problems": problems(&found) }))
}

fn placement(request: &Value) -> Result<Value, OpError> {
    let (setting, found) = link_rules::read_placement(root(request)?);
    Ok(json!({ "placement": setting, "problems": problems(found.as_slice()) }))
}

fn ssh_allow(request: &Value) -> Result<Value, OpError> {
    let host = string(request, "host")?;
    Ok(match link_rules::ssh_hosts_allowing(root(request)?, host) {
        Some(hosts) => json!({ "hosts": hosts }),
        None => json!({}),
    })
}

fn target(request: &Value) -> Result<Value, OpError> {
    let setting = routing_member(request)?;
    let chosen =
        setting.target(link(request)?, flag(request, "otherTarget")?, flag(request, "explicit")?);
    Ok(json!({ "target": chosen.name() }))
}

fn opens_in_cmux(request: &Value) -> Result<Value, OpError> {
    let setting = routing_member(request)?;
    Ok(json!({ "opensInCmux": setting.opens_in_cmux(link(request)?, flag(request, "explicit")?) }))
}

fn external_matches(request: &Value) -> Result<Value, OpError> {
    let patterns = strings(request, "patterns")?;
    Ok(json!({ "matches": pattern::matches(&patterns, string(request, "url")?) }))
}

fn decide(request: &Value) -> Result<Value, OpError> {
    let setting = request
        .get("opener")
        .and_then(Opener::from_json)
        .ok_or_else(|| OpError::Invalid("expected an `opener` object".to_owned()))?;
    let callers = match request.get("callers") {
        None => Vec::new(),
        Some(_) => strings(request, "callers")?,
    };
    let keeps = request.get("routing").is_some()
        && routing_member(request)?.keeps_sign_in_page_in_cmux(flag(request, "signInPage")?);
    let (chosen, rule) = setting.decide(string(request, "url")?, &callers, keeps);
    Ok(json!({ "target": chosen.json(), "rule": rule }))
}

fn launch(request: &Value) -> Result<Value, OpError> {
    let chosen = match request.get("target") {
        Some(Value::String(text)) => Target::parse(text),
        Some(other) => Target::from_json(other),
        None => None,
    }
    .ok_or_else(|| OpError::Invalid("expected a `target`".to_owned()))?;
    Ok(json!({ "launch": chosen.launch(string(request, "url")?) }))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::call;

    #[test]
    fn ops_answer_on_the_wire() {
        let root = json!({ "browser": { "hostsToOpenInEmbeddedBrowser": "x" } });
        let reply = call("link_rules.routing", &json!({ "root": root })).unwrap();
        assert_eq!(reply["problems"][0]["path"], "browser.hostsToOpenInEmbeddedBrowser");

        let routing = json!({ "embeddedHosts": ["*.example.com"] });
        let target = |url: &str, host: &str| {
            call(
                "link_rules.target",
                &json!({ "routing": routing, "url": url, "scheme": "https", "host": host }),
            )
            .unwrap()["target"]
                .clone()
        };
        assert_eq!(target("https://app.example.com/", "app.example.com"), "cmuxBrowser");
        assert_eq!(target("https://github.com/", "github.com"), "system");

        let reply = call(
            "link_rules.decide",
            &json!({
                "opener": { "default": "cmux", "rules": ["caller:aws -> chrome@Profile 1"] },
                "url": "https://signin.aws.amazon.com/", "callers": ["aws", "zsh"],
            }),
        )
        .unwrap();
        assert_eq!(
            reply,
            json!({ "target": { "kind": "app", "app": "Google Chrome",
                                              "profile": "Profile 1" }, "rule": 0 })
        );

        let reply = call(
            "link_rules.launch",
            &json!({ "target": reply["target"], "url": "https://x.example/" }),
        )
        .unwrap();
        assert_eq!(
            reply["launch"]["arguments"],
            json!(["--profile-directory=Profile 1", "https://x.example/"])
        );

        assert_eq!(
            call("link_rules.regex_accepts", &json!({ "expression": "(a+)+" })).unwrap(),
            json!({ "accepts": false })
        );
        assert_eq!(
            call(
                "link_rules.external_matches",
                &json!({ "patterns": ["billing"], "url": "https://x/billing" })
            )
            .unwrap(),
            json!({ "matches": true })
        );
        assert_eq!(
            call("link_rules.placement", &json!({ "root": {} })).unwrap(),
            json!({ "placement": "split-right", "problems": [] })
        );
        assert_eq!(
            call("link_rules.opener_target", &json!({ "text": "netscape" })).unwrap(),
            json!({ "target": null })
        );
        assert!(call("link_rules.target", &json!({})).is_err());
    }
}
