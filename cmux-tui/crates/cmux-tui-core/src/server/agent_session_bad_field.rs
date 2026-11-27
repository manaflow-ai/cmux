//! Which param an `agent-session-start`, `-prewarm` or `-credentials` bad request refused
//! (ask-c30064eeff): a Codex Cloud start from the CLI failed `agent_session.bad_request` with no
//! word of which param, so nobody could tell a credential from a folder. The refusal's
//! `data.field` (and its text) names the param: the first out of bounds, or the field serde
//! named as unknown or missing. Never a value: serde's other errors (a wrong type) quote the value
//! they read, so those name no field at all.

use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

use super::{MessageWriter, Refusal, refuse, refuse_with_data};

/// `params` decoded, or the field serde refused by name (none when it named no field).
pub(super) fn decode<T: DeserializeOwned>(params: Map<String, Value>) -> Result<T, Option<String>> {
    serde_json::from_value(Value::Object(params)).map_err(|error| decode_field(&error))
}

/// The field of serde's `unknown field `x`, expected ...` or `missing field `x``, when it is a
/// param name. The name's closing backtick must end the text or come before `,`: a caller's key
/// holding a backtick would otherwise be cut at it and read as a shorter name.
fn decode_field(error: &serde_json::Error) -> Option<String> {
    let text = error.to_string();
    ["unknown field `", "missing field `"].iter().find_map(|lead| {
        let (name, rest) = text.split_once(lead)?.1.split_once('`')?;
        (param_name(name) && (rest.is_empty() || rest.starts_with(','))).then(|| name.to_owned())
    })
}

/// A param's name: 1 to 64 ASCII letters, digits or `_` (a caller's own key may be anything).
fn param_name(name: &str) -> bool {
    (1..=64).contains(&name.len()) && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// `agent_session.bad_request` naming `field` in `data.field`; a bare one without a field.
pub(super) fn refuse_field(writer: &MessageWriter, id: Option<Value>, field: Option<&str>) -> bool {
    match field.filter(|field| param_name(field)) {
        Some(field) => refuse_with_data(writer, id, Refusal::BadRequest, json!({"field": field})),
        None => refuse(writer, id, Refusal::BadRequest),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize, Debug)]
    #[serde(deny_unknown_fields)]
    #[allow(dead_code)]
    struct Params {
        surface: u64,
        #[serde(default)]
        model: Option<String>,
    }

    fn field(params: Value) -> Option<String> {
        decode::<Params>(params.as_object().cloned().unwrap_or_default()).unwrap_err()
    }

    #[test]
    fn serde_names_an_unknown_or_missing_field_and_never_a_value() {
        assert_eq!(field(json!({"surface": 1, "extra": "secret"})).as_deref(), Some("extra"));
        assert_eq!(field(json!({"model": "m"})).as_deref(), Some("surface"));
        assert_eq!(
            field(json!({"surface": 1, "model": 42})),
            None,
            "a wrong type quotes the value"
        );
        assert_eq!(field(json!({"surface": 1, "a`b c": 1})), None, "not a param name");
    }
}
