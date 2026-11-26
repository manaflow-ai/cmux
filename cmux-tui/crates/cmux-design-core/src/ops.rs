//! The JSON op dispatch: `AREA.NAME` goes to that area's `call(NAME, request)`.
//!
//! Each area module owns its own op table, so a new op touches only its module.

use serde_json::Value;

/// Why an op gave no reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    /// No such op.
    Unknown,
    /// The request is not the JSON the op takes.
    Invalid(String),
}

/// An area's reply.
pub type OpResult = Result<Value, OpError>;

/// Reads a request into the op's typed form.
pub fn parse<T: serde::de::DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    T::deserialize(request).map_err(|e| OpError::Invalid(e.to_string()))
}

/// Writes a typed reply.
pub fn reply<T: serde::Serialize>(value: &T) -> OpResult {
    serde_json::to_value(value).map_err(|e| OpError::Invalid(e.to_string()))
}

/// Runs the op `op` (`AREA.NAME`) on `request`.
pub fn call(op: &str, request: &Value) -> OpResult {
    let Some((area, name)) = op.split_once('.') else {
        return Err(OpError::Unknown);
    };
    match area {
        "core" => core(name, request),
        "dialog" => crate::dialog::call(name, request),
        "hover" => crate::hover::call(name, request),
        "launch" => crate::launch::call(name, request),
        "menu" => crate::menu::call(name, request),
        "motion" => crate::motion::call(name, request),
        "overlay" => crate::overlay::call(name, request),
        "toast" => crate::toast::call(name, request),
        "tokens" => crate::tokens::call(name, request),
        "wallpaper" => crate::wallpaper::call(name, request),
        "window" => crate::window::call(name, request),
        _ => Err(OpError::Unknown),
    }
}

/// `core.echo`: the request back (the app's link check).
fn core(name: &str, request: &Value) -> OpResult {
    match name {
        "echo" => Ok(request.clone()),
        _ => Err(OpError::Unknown),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn echo_returns_the_request() {
        let request = json!({"a": 1});
        assert_eq!(call("core.echo", &request), Ok(request));
    }

    #[test]
    fn unknown_ops_and_areas_are_unknown() {
        for op in ["", "core", "core.nope", "nope.echo", ".echo"] {
            assert_eq!(call(op, &json!({})), Err(OpError::Unknown), "{op}");
        }
    }
}
