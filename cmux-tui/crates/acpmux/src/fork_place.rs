//! New-session placement on a fork of the parent's Cloud machine (RFD 0168), behind the hidden
//! setting `cloud.autoCloud` (default off).
//!
//! A new chat started from a chat that runs on a Cloud machine is best placed on a running copy
//! of that machine, memory and disk (cmux-platform `POST /v1/machines/{id}/fork`, the
//! `cloud.machine.fork` call of cmux-cloud-api): the copy already holds the parent's checkout,
//! installs, warm build caches and running processes, so the new session starts with no clone,
//! install or cold build. This module is the decision only, a pure function of what the caller
//! knows; `_acpmux/place_chat` (`server/place.rs`) adds it to its reply as `fork`, next to the
//! budget's `placement`, which stays the fallback (the warm path: an existing machine with room,
//! or this machine), so a fork that is refused or fails never turns into a cold create.
//!
//! The daemon never forks: a fork is the machine creator's call (an agent key is refused), and
//! the creator's credential lives with the app, which carries out `fork` with
//! `cloud.machine.fork` and then starts the chat on the copy.

use serde_json::{Value, json};

/// The hidden setting that turns fork placement on. Absent, or anything but `true`, is off.
pub const SETTING: &str = "cloud.autoCloud";

/// The longest `clientKey` cmux-platform takes for a fork.
const MAX_CLIENT_KEY: usize = 128;

/// Whether `cloud.autoCloud` is on in the person's settings now.
pub fn enabled() -> bool {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return false;
    };
    on(&doc)
}

/// `cloud.autoCloud` in a settings document: only a JSON `true` turns it on.
pub fn on(doc: &Value) -> bool {
    crate::user_settings::value(doc, SETTING).and_then(|v| v.as_bool()) == Some(true)
}

/// The machine the starting chat runs on, as the caller knows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parent {
    /// The Cloud machine's id (`vm_...`).
    pub machine: String,
    /// The machine's `capabilities.fork` as the platform last answered it.
    pub fork: bool,
}

/// What fork placement says for one new chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ForkPlace {
    /// Fork `machine` under `client_key` and start the chat on the copy.
    Fork { machine: String, client_key: String },
    /// Keep the budget's placement (the warm path), for `why`.
    Warm { why: String },
}

/// The decision for one new chat. `None` when the setting is off: the reply says nothing and
/// placement is what it was. `key` names this start (a retry with the same key answers the same
/// copy, never a second one).
pub fn decide(enabled: bool, parent: Option<&Parent>, key: &str) -> Option<ForkPlace> {
    if !enabled {
        return None;
    }
    let Some(parent) = parent else {
        return Some(ForkPlace::Warm {
            why: "the chat that starts it does not run on a Cloud machine".into(),
        });
    };
    if !valid_machine(&parent.machine) {
        return Some(ForkPlace::Warm { why: "the parent machine's id is not a machine id".into() });
    }
    if !parent.fork {
        return Some(ForkPlace::Warm {
            why: format!("{} cannot be forked (its provider has no fork)", parent.machine),
        });
    }
    let key = key.trim();
    if key.is_empty() {
        return Some(ForkPlace::Warm { why: "the start has no key to fork under".into() });
    }
    let client_key: String = format!("autocloud-{key}").chars().take(MAX_CLIENT_KEY).collect();
    Some(ForkPlace::Fork { machine: parent.machine.clone(), client_key })
}

/// `parent` in a request's params: `{"machine": "vm_...", "fork": bool}`; `fork` absent is false.
pub fn parent_of(params: &Value) -> Option<Parent> {
    let p = params.get("parent")?;
    let machine = p.get("machine").and_then(Value::as_str)?.to_owned();
    let fork = p.get("fork").and_then(Value::as_bool) == Some(true);
    Some(Parent { machine, fork })
}

/// The decision as the reply's `fork` field.
pub fn to_json(place: &ForkPlace) -> Value {
    match place {
        ForkPlace::Fork { machine, client_key } => {
            json!({"at": "fork", "machine": machine, "clientKey": client_key})
        }
        ForkPlace::Warm { why } => json!({"at": "warm", "why": why}),
    }
}

/// A path-safe machine id: 1 to 64 of letters, digits, `_` and `-`.
fn valid_machine(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vm(fork: bool) -> Parent {
        Parent { machine: "vm_0123456789abcdefghij".into(), fork }
    }

    #[test]
    fn off_says_nothing_whatever_the_parent() {
        assert_eq!(decide(false, Some(&vm(true)), "s1"), None);
        assert_eq!(decide(false, None, "s1"), None);
    }

    #[test]
    fn on_with_a_forkable_cloud_parent_forks_it_under_the_starts_key() {
        assert_eq!(
            decide(true, Some(&vm(true)), "s1"),
            Some(ForkPlace::Fork {
                machine: "vm_0123456789abcdefghij".into(),
                client_key: "autocloud-s1".into()
            })
        );
    }

    #[test]
    fn on_without_a_way_to_fork_keeps_the_warm_path_and_says_why() {
        let warm = |d: Option<ForkPlace>| match d {
            Some(ForkPlace::Warm { why }) => why,
            other => panic!("{other:?}"),
        };
        assert!(warm(decide(true, None, "s1")).contains("not run on a Cloud machine"));
        assert!(warm(decide(true, Some(&vm(false)), "s1")).contains("cannot be forked"));
        assert!(warm(decide(true, Some(&vm(true)), "  ")).contains("no key"));
        let bad = Parent { machine: "../v1/teams".into(), fork: true };
        assert!(warm(decide(true, Some(&bad), "s1")).contains("not a machine id"));
    }

    #[test]
    fn a_long_key_is_cut_to_the_platforms_limit() {
        let Some(ForkPlace::Fork { client_key, .. }) =
            decide(true, Some(&vm(true)), &"k".repeat(300))
        else {
            panic!()
        };
        assert_eq!(client_key.chars().count(), MAX_CLIENT_KEY);
    }

    #[test]
    fn the_setting_is_on_only_for_a_json_true() {
        assert!(on(&json!({"cloud": {"autoCloud": true}})));
        assert!(on(&json!({"cloud.autoCloud": true})));
        for doc in
            [json!({}), json!({"cloud": {"autoCloud": "true"}}), json!({"cloud.autoCloud": false})]
        {
            assert!(!on(&doc), "{doc}");
        }
    }

    #[test]
    fn the_parent_and_the_reply_round_trip() {
        let p = parent_of(&json!({"parent": {"machine": "vm_a", "fork": true}})).unwrap();
        assert_eq!(p, Parent { machine: "vm_a".into(), fork: true });
        assert_eq!(parent_of(&json!({"parent": {"machine": "vm_a"}})).unwrap().fork, false);
        assert_eq!(parent_of(&json!({})), None);
        assert_eq!(
            to_json(&ForkPlace::Fork { machine: "vm_a".into(), client_key: "autocloud-k".into() }),
            json!({"at": "fork", "machine": "vm_a", "clientKey": "autocloud-k"})
        );
    }
}
