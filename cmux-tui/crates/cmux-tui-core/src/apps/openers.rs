//! Link handlers (`cmux.opener/1`): a link the person clicks goes to the
//! installed app whose opener matches it, before cmux opens it itself.
//!
//! An app declares the links it takes on its implementation:
//! `options.urls` holds URL patterns where `*` is any run of characters
//! (`https://jira.example/browse/*`), and `schemes` takes every link of a
//! scheme (`jira`). The match is case-insensitive. When several apps match,
//! the most specific pattern wins: the one with the most literal
//! characters; a scheme alone counts as no literal text. A tie goes to the
//! lowest app id, so the choice never depends on install order.
//!
//! Only installed, enabled and visible apps with a script are asked. The
//! lookup reads the supervisor's catalog on every click, so a saved
//! manifest (`local_reload.rs`, which emits `apps-changed`) changes where
//! links go with no relaunch. The opener's export runs on the `apps-run`
//! path (`runs.rs`) with `{url}`; `apps-open-link` answers
//! `{handled: true, app}`, or `{handled: false}` (with `app` and `error`
//! when the opener failed) so the caller opens the link the usual way.

use serde_json::{Value, json};

use super::mirror::Origin;
use super::supervisor::{HostKey, Inner, Out, Responder, Supervisor};

pub(super) const INTERFACE: &str = "cmux.opener/1";

/// How specific a match of `pattern` on `text` is (its literal characters),
/// or `None` when it does not match. `*` matches any run of characters.
fn pattern_score(pattern: &str, text: &str) -> Option<usize> {
    let (pattern, text) = (pattern.to_lowercase(), text.to_lowercase());
    let mut parts = pattern.split('*');
    let mut rest = text.strip_prefix(parts.next().unwrap_or_default())?;
    let parts: Vec<&str> = parts.collect();
    match parts.split_last() {
        // No `*`: the whole text is the literal.
        None if !rest.is_empty() => return None,
        None => {}
        // Each middle part at its first place after the last (leftmost leaves the most room), then the suffix.
        Some((last, middle)) => {
            for part in middle {
                rest = rest.split_once(part)?.1;
            }
            if !rest.ends_with(last) {
                return None;
            }
        }
    }
    Some(pattern.chars().filter(|c| *c != '*').count())
}

/// The score of an opener implementation for `url`: its best URL pattern,
/// else 0 when its `schemes` list the link's scheme.
fn implementation_score(entry: &Value, url: &str) -> Option<usize> {
    let strings = |value: Option<&Value>| -> Vec<String> {
        value
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect()
    };
    let by_pattern = strings(entry.pointer("/options/urls"))
        .iter()
        .filter_map(|pattern| pattern_score(pattern, url))
        .max();
    let scheme = url.split_once(':').map(|(scheme, _)| scheme.to_ascii_lowercase());
    let by_scheme = scheme
        .filter(|scheme| strings(entry.get("schemes")).iter().any(|s| s == scheme))
        .map(|_| 0);
    by_pattern.or(by_scheme)
}

/// The opener for `url` as `(app, export)`: the most specific match among
/// installed, enabled, visible apps with a script, ties to the lowest id.
pub(super) fn opener_locked(inner: &Inner, url: &str) -> Option<(String, String)> {
    inner
        .mirror
        .apps
        .iter()
        .filter(|(_, record)| record.installed && record.enabled && !record.hidden)
        .filter_map(|(app, _)| {
            let package = inner.catalog.packages.get(app).filter(|p| p.has_runtime())?;
            let entry = package.manifest.get("implements")?.get(INTERFACE)?;
            let export = entry.get("export")?.as_str()?.to_string();
            Some((implementation_score(entry, url)?, app.clone(), export))
        })
        .min_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)))
        .map(|(_, app, export)| (app, export))
}

impl Supervisor {
    /// The app and export a click on `url` goes to now, if any.
    pub fn opener_for(&self, url: &str) -> Option<(String, String)> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        opener_locked(&inner, url)
    }

    /// `apps-open-link`: runs the matching opener's export with `{url}` on
    /// the `apps-run` path. Answers `{handled: false}` at once when no app
    /// takes the link, safe mode is on or there is no app host.
    pub fn open_link(&self, url: String, _origin: Origin, respond: Responder) {
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match opener_locked(&inner, &url) {
                Some((app, export))
                    if inner.safe_mode.is_none() && self.config.host_binary.is_some() =>
                {
                    let answered = app.clone();
                    let respond: Responder = Box::new(move |result| {
                        respond(Ok(match result {
                            Ok(_) => json!({ "handled": true, "app": answered }),
                            Err(error) => {
                                json!({ "handled": false, "app": answered, "error": error.message })
                            }
                        }))
                    });
                    let key = HostKey { app, preview: false };
                    self.start_run_locked(
                        &mut inner,
                        &key,
                        export,
                        json!({ "url": url }),
                        None,
                        respond,
                    )
                }
                _ => vec![Out::Respond(respond, Ok(json!({ "handled": false })))],
            }
        };
        self.emit(outs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_star_matches_any_run_and_literal_text_scores() {
        assert_eq!(
            pattern_score("https://jira.example/*", "https://jira.example/browse/X-1"),
            Some(21)
        );
        assert_eq!(
            pattern_score("https://*.example/browse/*", "https://JIRA.example/browse/x"),
            Some(24)
        );
        assert_eq!(pattern_score("https://jira.example/*", "https://jira.example.evil/x"), None);
        assert_eq!(pattern_score("https://jira.example/*", "http://jira.example/x"), None);
        assert_eq!(pattern_score("*", "anything"), Some(0));
        assert_eq!(pattern_score("a*b*c", "aXbYbZc"), Some(3));
    }

    #[test]
    fn a_scheme_takes_every_link_of_it_below_any_pattern() {
        let entry =
            json!({ "export": "open", "schemes": ["jira"], "options": { "urls": ["jira://x/*"] } });
        assert_eq!(implementation_score(&entry, "JIRA://y"), Some(0));
        assert_eq!(implementation_score(&entry, "jira://x/1"), Some(9));
        assert_eq!(implementation_score(&entry, "https://x"), None);
    }
}
