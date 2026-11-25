//! `_acpmux/attach` `alsoKinds`: exact record kinds a client wants when this daemon serves them,
//! sent before it knows the daemon's capabilities.
//!
//! The phone's cold chat open sent its first attach only after `initialize` answered, because the
//! attach's `kinds` depend on a capability (`elevation-cards-v1`: an older peer refuses an attach
//! with more than 8 kinds). That cost a whole round trip before the chat's first page: on a
//! 30 ms relay, the open was initialize, then attach, after the link and pairing (optimum-ledger
//! rows 95 and 105). Now the phone writes the attach right behind `initialize` and the first
//! watch page with the kinds every daemon takes in `kinds` and the capability-gated ones in
//! `alsoKinds`. This daemon adds those to `kinds` before anything reads them, here or on a peer;
//! a daemon without [`CAPABILITY`] ignores the field, and the phone, seeing no [`CAPABILITY`] in
//! the `initialize` it already waited for, reads the chat again with today's kinds.

use serde_json::Value;

/// The capability id that says this daemon takes `alsoKinds` on `_acpmux/attach`.
pub const CAPABILITY: &str = "attach-also-kinds-v1";

/// The most `alsoKinds` entries taken (the rest are ignored): `kinds` stays bounded as before.
const MAX_ALSO: usize = 8;

/// Folds `params.alsoKinds` into `params.kinds` and removes it. An attach that names no `kinds`
/// (every record) or a single category string keeps them as they are; a malformed `alsoKinds`
/// is dropped, so it can never fail a read the client would get without it.
pub(super) fn fold(params: &mut Value) {
    let Some(map) = params.as_object_mut() else {
        return;
    };
    let Some(also) = map.remove("alsoKinds") else {
        return;
    };
    let Some(also) = also.as_array() else {
        return;
    };
    let Some(Value::Array(kinds)) = map.get_mut("kinds") else {
        return;
    };
    for kind in also.iter().take(MAX_ALSO) {
        let Some(name) = kind.as_str().filter(|k| !k.is_empty()) else {
            continue;
        };
        if !kinds.iter().any(|k| k.as_str() == Some(name)) {
            kinds.push(Value::String(name.to_owned()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn also_kinds_join_kinds_once_and_leave_the_params() {
        let mut p = json!({"sessionId": "s", "kinds": ["transcript", "bookmarks"],
                           "alsoKinds": ["elevation_request", "elevation_decision", "bookmarks"]});
        fold(&mut p);
        assert_eq!(
            p,
            json!({"sessionId": "s",
                   "kinds": ["transcript", "bookmarks", "elevation_request", "elevation_decision"]})
        );
    }

    #[test]
    fn no_kinds_or_a_bad_also_reads_as_without_it() {
        let mut every = json!({"sessionId": "s", "alsoKinds": ["elevation_request"]});
        fold(&mut every);
        assert_eq!(every, json!({"sessionId": "s"}));
        let mut bad = json!({"kinds": ["transcript"], "alsoKinds": "elevation_request"});
        fold(&mut bad);
        assert_eq!(bad, json!({"kinds": ["transcript"]}));
        let mut odd = json!({"kinds": ["transcript"], "alsoKinds": [1, "", "x"]});
        fold(&mut odd);
        assert_eq!(odd, json!({"kinds": ["transcript", "x"]}));
    }

    #[test]
    fn also_kinds_are_bounded() {
        let many: Vec<String> = (0..20).map(|i| format!("k{i}")).collect();
        let mut p = json!({"kinds": [], "alsoKinds": many});
        fold(&mut p);
        assert_eq!(p["kinds"].as_array().map(Vec::len), Some(MAX_ALSO));
    }
}
