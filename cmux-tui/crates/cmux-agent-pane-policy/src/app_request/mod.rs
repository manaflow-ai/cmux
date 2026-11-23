//! The page's requests to the app (`AgentPaneRequest.init(body:)`): which method, which params,
//! with the caps and id checks each carries. The answer is JSON the host maps to its request
//! enum: `{"case": name, "_0": ..., "label": ...}`, or `{"delegate": true}` for a method whose
//! decoder still lives in the host (it needs a host type).

mod ids;
mod page;
mod reply;
mod url;
mod value;

use serde_json::{Map, Value, json};

use value::Params;

/// What decoding a body came to.
pub enum Decoded {
    /// A request, or `unsupported`.
    Case(Value),
    /// The host's own decoder owns this method.
    Delegate,
}

impl Decoded {
    /// The JSON the host reads.
    pub fn into_json(self) -> Value {
        match self {
            Self::Case(value) => value,
            Self::Delegate => json!({"delegate": true}),
        }
    }
}

/// A request case with no payload.
pub(crate) fn case(name: &str) -> Value {
    json!({"case": name})
}

/// A request case with its labelled payload.
pub(crate) fn case_with<const N: usize>(name: &str, fields: [(&str, Value); N]) -> Value {
    let mut object = Map::new();
    object.insert("case".to_owned(), json!(name));
    for (key, value) in fields {
        object.insert(key.to_owned(), value);
    }
    Value::Object(object)
}

/// The `unsupported(method)` case.
pub(crate) fn unsupported(method: &str) -> Value {
    case_with("unsupported", [("_0", json!(method))])
}

/// Decodes the page's request `body` (`home` is the user's home folder, for `~`).
pub fn decode(body: &Value, home: &str) -> Decoded {
    let Some(object) = body.as_object() else { return Decoded::Case(unsupported("")) };
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        return Decoded::Case(unsupported(""));
    };
    let params = Params(object.get("params").and_then(Value::as_object));
    reply::decode(method, params)
        .or_else(|| page::decode(method, params, home))
        .unwrap_or(Decoded::Delegate)
}

#[cfg(test)]
mod tests;
