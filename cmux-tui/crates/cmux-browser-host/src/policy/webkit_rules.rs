//! The domain policy as WebKit content rule lists (classic cmux
//! BrowserReplContentRuleLists): an app WebKit tab cannot take the host's
//! request filter, so the host compiles each active policy layer into one
//! rule list and the app installs it on the tab (`tab.setContentRules`).
//! Separate lists per layer keep the layers' intersection: a request any
//! list blocks does not load.
//!
//! A list blocks every URL, lets the layer's allowed patterns through
//! (`ignore-previous-rules`), then blocks its prohibited patterns and, with
//! `block_ips`, IP literals. `data:`, `blob:` and `about:` always load, as
//! [`Policy::subresource_refusal`] says. Host checks a rule cannot express
//! (addresses a name resolves to) stay out of WebKit tabs, as in classic.
//! WebKit's `url-filter` is a small regex language without `|` or
//! repetition counts, so a pattern can need more than one filter.

use super::{DomainPattern, Layer, Policy};
use serde_json::{Value, json};

/// Escapes a literal for a `url-filter` regex.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if ".*+?^$()[]{}|\\/".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// A scheme glob (at most one `*`) as a regex.
fn scheme_regex(glob: &str) -> String {
    match glob.split_once('*') {
        None => escape(glob),
        Some((head, tail)) => format!("{}[a-z0-9+.-]*{}", escape(head), escape(tail)),
    }
}

/// The `url-filter`s that match the URLs `pattern` matches.
fn url_filters(pattern: &DomainPattern) -> Vec<String> {
    let host = if pattern.host == "*" {
        "[^/?#]*".to_owned()
    } else if let Some(base) = pattern.host.strip_prefix("*.") {
        format!("([^/?#@]*\\.)?{}", escape(base))
    } else if pattern.host.split('.').count() == 2 {
        // A root domain also covers www (DomainPattern::matches).
        format!("(www\\.)?{}", escape(&pattern.host))
    } else {
        escape(&pattern.host)
    };
    let schemes: Vec<(String, Option<&str>)> = match &pattern.scheme {
        Some(glob) => vec![(scheme_regex(glob), None)],
        None => vec![("http".into(), Some("80")), ("https".into(), Some("443"))],
    };
    let mut filters = Vec::new();
    for (scheme, default_port) in schemes {
        match &pattern.port {
            None => filters.push(format!("^{scheme}://{host}[:/?#]")),
            Some(port) => {
                filters.push(format!("^{scheme}://{host}:{}[/?#]", escape(port)));
                // A URL leaves out its scheme's default port.
                let implied = match pattern.scheme.as_deref() {
                    Some("http") => Some("80"),
                    Some("https") => Some("443"),
                    _ => default_port,
                };
                if implied == Some(port.as_str()) {
                    filters.push(format!("^{scheme}://{host}[/?#]"));
                }
            }
        }
    }
    filters
}

fn rule(action: &str, filter: &str) -> Value {
    json!({"trigger": {"url-filter": filter}, "action": {"type": action}})
}

/// One layer's rules, or `None` for an inactive layer.
fn layer_rules(layer: &Layer) -> Option<Vec<Value>> {
    if !layer.is_active() {
        return None;
    }
    let mut rules = Vec::new();
    if let Some(allowed) = &layer.allowed {
        rules.push(rule("block", ".*"));
        for pattern in allowed {
            for filter in url_filters(pattern) {
                rules.push(rule("ignore-previous-rules", &filter));
            }
        }
    }
    for pattern in &layer.prohibited {
        for filter in url_filters(pattern) {
            rules.push(rule("block", &filter));
        }
    }
    if layer.block_ips {
        rules.push(rule("block", "^[a-z][a-z0-9+.-]*://[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/?#]"));
        rules.push(rule("block", "^[a-z][a-z0-9+.-]*://\\["));
    }
    for scheme in ["data:", "blob:", "about:"] {
        rules.push(rule("ignore-previous-rules", &format!("^{scheme}")));
    }
    Some(rules)
}

impl Policy {
    /// The policy as WebKit content rule lists, one per active layer:
    /// `[{identifier, rules}]` (`identifier` is `base` or `agent`; the
    /// provider prefixes it with the session). Empty when no layer is active.
    pub fn content_rule_lists(&self) -> Vec<Value> {
        [("base", self.base()), ("agent", self.agent())]
            .into_iter()
            .filter_map(|(name, layer)| {
                layer_rules(layer).map(|rules| json!({"identifier": name, "rules": rules}))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::{Writer, parse_patterns};

    /// A url-filter evaluated as WebKit does (a regex over the whole URL,
    /// case-insensitive), with the `regex` crate's syntax being a superset.
    fn hits(filter: &str, url: &str) -> bool {
        regex::RegexBuilder::new(filter).case_insensitive(true).build().unwrap().is_match(url)
    }

    fn blocked(lists: &[Value], url: &str) -> bool {
        lists.iter().any(|list| {
            let mut blocked = false;
            for rule in list["rules"].as_array().unwrap() {
                if hits(rule["trigger"]["url-filter"].as_str().unwrap(), url) {
                    blocked = rule["action"]["type"] == "block";
                }
            }
            blocked
        })
    }

    fn policy(allowed: Option<&[&str]>, prohibited: &[&str], block_ips: bool) -> Policy {
        let list = |l: &[&str]| {
            parse_patterns(&l.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
        };
        let mut policy = Policy::default();
        let layer = Layer { allowed: allowed.map(list), prohibited: list(prohibited), block_ips };
        policy.set(Writer::Owner, layer, false).unwrap();
        policy
    }

    #[test]
    fn rules_block_what_the_policy_refuses() {
        let policy = policy(
            Some(&["example.com", "*.cdn.test", "https://secure.test:8443"]),
            &["ads.cdn.test"],
            false,
        );
        let lists = policy.content_rule_lists();
        assert_eq!(lists.len(), 1);
        for (url, refused) in [
            ("https://example.com/", false),
            ("http://www.example.com/a?b", false),
            ("https://example.com.evil.test/", true),
            ("https://img.cdn.test/x.png", false),
            ("https://cdn.test/", false),
            ("https://ads.cdn.test/x.js", true),
            ("https://secure.test:8443/", false),
            ("https://secure.test/", true),
            ("https://other.test/", true),
            ("data:text/plain,hi", false),
            ("about:blank", false),
        ] {
            let parsed = url::Url::parse(url).unwrap();
            assert_eq!(policy.subresource_refusal(&parsed).is_some(), refused, "policy on {url}");
            assert_eq!(blocked(&lists, url), refused, "rules on {url}");
        }
    }

    #[test]
    fn each_layer_is_its_own_list_and_ips_can_be_blocked() {
        let mut policy = policy(None, &["bad.test"], true);
        let agent = Layer {
            allowed: Some(parse_patterns(&["ok.test".into()]).unwrap()),
            ..Layer::default()
        };
        policy.set(Writer::Agent, agent, false).unwrap();
        let lists = policy.content_rule_lists();
        assert_eq!(
            lists.iter().map(|l| l["identifier"].clone()).collect::<Vec<_>>(),
            [json!("base"), json!("agent")]
        );
        assert!(blocked(&lists, "http://127.0.0.1:8080/"));
        assert!(blocked(&lists, "http://[::1]/"));
        assert!(blocked(&lists, "https://bad.test/"));
        assert!(blocked(&lists, "https://elsewhere.test/"), "the agent layer allows only ok.test");
        assert!(!blocked(&lists, "https://ok.test/"));
        assert!(Policy::default().content_rule_lists().is_empty());
    }
}
