//! `--until` and `--match`: how `cmux events` and `cmux agents events` end
//! at the first event an agent waits for, instead of streaming until killed
//! (or long-polling a batch the agent then greps).
//!
//! `--until NAME` names the event: exactly (`workspace.created`), or by a
//! prefix that ends in `*` (`workspace.*`). `--match PATH=VALUE`, repeatable,
//! compares the event's JSON field at a dotted PATH (`workspace_id`,
//! `payload.notification_id`; a number steps into an array) with VALUE: a
//! string field by its text, any other by its JSON text (`true`, `3`,
//! `null`). An event matches when every condition holds; either flag alone
//! is enough to wait.

use serde_json::Value;

use super::UsageError;

/// The event an `--until` / `--match` wait ends on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct EventMatch {
    /// `--until`: an exact name, or a prefix when it ends in `*`.
    name: Option<String>,
    /// `--match`: the path's steps and the value it must have.
    fields: Vec<(Vec<String>, String)>,
}

impl EventMatch {
    /// `None` when neither `--until` nor `--match` was given. `command`
    /// prefixes the usage errors (`events`, `agents events`).
    pub(in crate::cli) fn new(
        command: &str,
        until: Option<&str>,
        matches: &[&str],
    ) -> Result<Option<Self>, UsageError> {
        if until.is_none() && matches.is_empty() {
            return Ok(None);
        }
        let usage = |message: &str| UsageError::new(format!("{command}: {message}"));
        let name = match until {
            None => None,
            Some(text) => {
                let stem = text.strip_suffix('*').unwrap_or(text);
                if text.is_empty() || stem.contains('*') {
                    return Err(usage(
                        "--until takes an event name, or a prefix ending in * (workspace.*)",
                    ));
                }
                Some(text.to_owned())
            }
        };
        let mut fields = Vec::with_capacity(matches.len());
        for text in matches {
            let parsed = text.split_once('=').and_then(|(path, value)| {
                let steps = path.split('.').map(str::to_owned).collect::<Vec<_>>();
                (!steps.iter().any(String::is_empty)).then(|| (steps, value.to_owned()))
            });
            match parsed {
                Some(field) => fields.push(field),
                None => {
                    return Err(usage(&format!(
                        "--match takes PATH=VALUE (workspace_id=ws_1, payload.state=idle), not {text:?}"
                    )));
                }
            }
        }
        Ok(Some(Self { name, fields }))
    }

    /// Whether `event`, named `name`, is the one waited for.
    pub(in crate::cli) fn matches(&self, name: Option<&str>, event: &Value) -> bool {
        if let Some(pattern) = &self.name {
            let Some(name) = name else { return false };
            let hit = match pattern.strip_suffix('*') {
                Some(prefix) => name.starts_with(prefix),
                None => name == pattern,
            };
            if !hit {
                return false;
            }
        }
        self.fields
            .iter()
            .all(|(path, want)| lookup(event, path).is_some_and(|value| same(value, want)))
    }

    /// What the wait waits for, for a timeout record:
    /// `{"name": "workspace.*", "match": {"payload.state": "idle"}}`.
    pub(in crate::cli) fn describe(&self) -> Value {
        let mut out = serde_json::Map::new();
        if let Some(name) = &self.name {
            out.insert("name".into(), Value::String(name.clone()));
        }
        if !self.fields.is_empty() {
            let fields = self
                .fields
                .iter()
                .map(|(path, value)| (path.join("."), Value::String(value.clone())))
                .collect();
            out.insert("match".into(), Value::Object(fields));
        }
        Value::Object(out)
    }
}

fn lookup<'a>(event: &'a Value, path: &[String]) -> Option<&'a Value> {
    path.iter().try_fold(event, |value, step| match value {
        Value::Object(map) => map.get(step),
        Value::Array(items) => step.parse::<usize>().ok().and_then(|index| items.get(index)),
        _ => None,
    })
}

fn same(value: &Value, want: &str) -> bool {
    match value {
        Value::String(text) => text == want,
        // Not a string: `want` read as JSON (`3`, `true`, `null`).
        other => serde_json::from_str::<Value>(want).is_ok_and(|parsed| &parsed == other),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::EventMatch;

    fn wait(until: Option<&str>, matches: &[&str]) -> EventMatch {
        match EventMatch::new("events", until, matches) {
            Ok(Some(wait)) => wait,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_name_matches_exactly_or_by_a_star_prefix() {
        let event = json!({"name": "workspace.created"});
        assert!(wait(Some("workspace.created"), &[]).matches(Some("workspace.created"), &event));
        assert!(!wait(Some("workspace.create"), &[]).matches(Some("workspace.created"), &event));
        assert!(wait(Some("workspace.*"), &[]).matches(Some("workspace.created"), &event));
        assert!(wait(Some("*"), &[]).matches(Some("anything"), &event));
        assert!(!wait(Some("tab.*"), &[]).matches(Some("workspace.created"), &event));
        assert!(!wait(Some("workspace.*"), &[]).matches(None, &event));
    }

    #[test]
    fn fields_match_by_dotted_path_and_every_one_must_hold() {
        let event = json!({
            "workspace_id": "ws_1",
            "payload": {"state": "idle", "count": 3, "ok": true, "gone": null, "ids": ["a", "b"]},
        });
        let hits = [
            "workspace_id=ws_1",
            "payload.state=idle",
            "payload.count=3",
            "payload.ok=true",
            "payload.gone=null",
            "payload.ids.1=b",
        ];
        for one in hits {
            assert!(wait(None, &[one]).matches(None, &event), "{one}");
        }
        assert!(wait(None, &hits).matches(None, &event));
        for miss in ["workspace_id=ws_2", "payload.state.deeper=x", "payload.ids.9=a", "nope=1"] {
            assert!(!wait(None, &[miss]).matches(None, &event), "{miss}");
        }
        assert!(!wait(None, &["workspace_id=ws_1", "payload.state=busy"]).matches(None, &event));
        // An empty value matches an empty string.
        assert!(wait(None, &["e="]).matches(None, &json!({"e": ""})));
    }

    #[test]
    fn bad_flags_name_the_form_they_take() {
        assert_eq!(EventMatch::new("events", None, &[]).ok(), Some(None));
        for (until, matches) in [
            (Some(""), vec![]),
            (Some("a*b"), vec![]),
            (None, vec!["noequals"]),
            (None, vec![".a=1"]),
        ] {
            let error = EventMatch::new("events", until, &matches).err().map(|error| error.0);
            assert!(
                error.as_deref().is_some_and(|text| text.starts_with("events: --")),
                "{error:?}"
            );
        }
    }

    #[test]
    fn describe_says_what_the_wait_was_for() {
        let wait = wait(Some("workspace.*"), &["payload.state=idle"]);
        assert_eq!(
            wait.describe(),
            json!({"name": "workspace.*", "match": {"payload.state": "idle"}})
        );
    }
}
