//! OpenCode asked to ask (`hub/policy_mode.rs`). OpenCode has no mode that
//! asks: every agent starts from `"*": "allow"`. A chat whose permission
//! policy is narrower than approve-all starts its OpenCode with
//! `OPENCODE_CONFIG_CONTENT` whose top-level `permission` is `{"*": "ask"}`.
//! OpenCode (v1.19.0 `config/config.ts` `loadInstanceState`) merges that
//! config over the global, `OPENCODE_CONFIG`, project and config-directory
//! ones; `agent/agent.ts` appends its rules after the built-in defaults
//! (`Permission.fromConfig`: `"*": "ask"` is one rule for every permission and
//! every pattern), and `permission/index.ts` `evaluate` takes the last rule
//! that matches. So every tool call asks, as an ACP `session/request_permission`
//! that the chat's policy answers. Best effort: see `web_modes::REFUSED_FAMILIES`
//! for what can still come after it.

use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};
use serde_json::value::RawValue;

/// A spawn-only profile marker: the hub's spawn profile (`hub/spawn.rs`) sets
/// it for an OpenCode chat whose policy is narrower than approve-all, so it is
/// part of the session pool's key (a pooled agent started without it never
/// serves such a chat) and of what the chat's agent was started with.
/// `agent/command.rs` removes it and sets [`CONFIG_ENV`] instead.
pub(crate) const MARKER: &str = "ACPMUX_OPENCODE_ASK";
/// The config OpenCode merges over its own files.
pub(crate) const CONFIG_ENV: &str = "OPENCODE_CONFIG_CONTENT";
/// The `permission` acpmux passes: ask before every tool.
const ASK_ALL: &str = r#"{"*":"ask"}"#;

/// `existing` (the config the agent would get otherwise: its profile's, else
/// the inherited one) with its `permission` replaced by [`ASK_ALL`], every
/// other key kept as written (its order and text: a nested `permission`, such
/// as an agent's, is order-sensitive). `None` when `existing` is not a JSON
/// object (OpenCode also reads JSONC): it is kept as it is.
pub(crate) fn asking_config(existing: Option<&str>) -> Option<String> {
    let entries = match existing.filter(|text| !text.trim().is_empty()) {
        None => Vec::new(),
        Some(text) => serde_json::from_str::<Entries>(text).ok()?.0,
    };
    let mut out = String::from("{");
    for (key, value) in entries.iter().filter(|(key, _)| key != "permission") {
        out.push_str(&serde_json::to_string(key).ok()?);
        out.push(':');
        out.push_str(value.get());
        out.push(',');
    }
    out.push_str(r#""permission":"#);
    out.push_str(ASK_ALL);
    out.push('}');
    Some(out)
}

/// A JSON object's entries in their order, each value as written.
struct Entries(Vec<(String, Box<RawValue>)>);

impl<'de> Deserialize<'de> for Entries {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Ordered;
        impl<'de> Visitor<'de> for Ordered {
            type Value = Entries;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a JSON object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Entries, A::Error> {
                let mut entries = Vec::new();
                while let Some(entry) = map.next_entry::<String, Box<RawValue>>()? {
                    entries.push(entry);
                }
                Ok(Entries(entries))
            }
        }
        d.deserialize_map(Ordered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn parsed(text: &str) -> Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn no_config_becomes_one_that_asks_for_everything() {
        for existing in [None, Some(""), Some("  ")] {
            let config = asking_config(existing).unwrap();
            assert_eq!(parsed(&config), json!({"permission": {"*": "ask"}}), "{existing:?}");
        }
    }

    #[test]
    fn a_config_keeps_every_key_but_its_permission_in_order_and_as_written() {
        let own = r#"{"model":"own/model","permission":{"*":"allow"},"agent":{"build":{"permission":{"edit":"allow","*":"ask"}}}}"#;
        assert_eq!(
            asking_config(Some(own)).unwrap(),
            r#"{"model":"own/model","agent":{"build":{"permission":{"edit":"allow","*":"ask"}}},"permission":{"*":"ask"}}"#
        );
        // A permission given as one string is replaced too.
        let one = asking_config(Some(r#"{"permission":"allow"}"#)).unwrap();
        assert_eq!(parsed(&one), json!({"permission": {"*": "ask"}}));
    }

    #[test]
    fn a_config_that_is_not_a_json_object_is_not_touched() {
        for text in ["not json", "[1]", "\"text\"", "{\"a\": 1, // note\n}"] {
            assert_eq!(asking_config(Some(text)), None, "{text:?}");
        }
    }
}
