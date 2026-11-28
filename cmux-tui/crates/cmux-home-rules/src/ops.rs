//! The op table: `AREA.NAME` goes to that area's module.

use serde::de::DeserializeOwned;
use serde_json::Value;

/// Why an op gave no reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    /// No op of that name.
    Unknown,
    /// The request is not the JSON the op takes.
    Invalid(String),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpError::Unknown => f.write_str("unknown op"),
            OpError::Invalid(why) => write!(f, "invalid request: {why}"),
        }
    }
}

impl std::error::Error for OpError {}

/// The areas, in the order `ops.list` reports them.
pub const AREAS: &[&str] = &[
    "inbox",
    "compose",
    "chief_home",
    "chief_brain",
    "chief_settings",
    "cloud",
    "dock",
    "welcome",
    "mapping",
];

/// Runs the op `op` (`AREA.NAME`) on `request`.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    let Some((area, name)) = op.split_once('.') else {
        return Err(OpError::Unknown);
    };
    match area {
        "ops" => ops_call(name),
        "inbox" => crate::inbox::call(name, request),
        "compose" => crate::compose::call(name, request),
        "chief_home" => crate::chief_home::call(name, request),
        "chief_brain" => crate::chief_brain::call(name, request),
        "chief_settings" => crate::chief_settings::call(name, request),
        "cloud" => crate::cloud::call(name, request),
        "dock" => crate::dock::call(name, request),
        "welcome" => crate::welcome::call(name, request),
        "mapping" => crate::mapping::call(name, request),
        _ => Err(OpError::Unknown),
    }
}

/// Every op name, `AREA.NAME`, sorted within its area.
pub fn op_names() -> Vec<String> {
    let mut names = vec!["ops.list".to_owned()];
    for area in AREAS {
        let mut own: Vec<&str> = match *area {
            "inbox" => crate::inbox::OPS.to_vec(),
            "compose" => crate::compose::OPS.to_vec(),
            "chief_home" => crate::chief_home::OPS.to_vec(),
            "chief_brain" => crate::chief_brain::OPS.to_vec(),
            "chief_settings" => crate::chief_settings::OPS.to_vec(),
            "cloud" => crate::cloud::OPS.to_vec(),
            "dock" => crate::dock::OPS.to_vec(),
            "welcome" => crate::welcome::OPS.to_vec(),
            "mapping" => crate::mapping::OPS.to_vec(),
            _ => Vec::new(),
        };
        own.sort_unstable();
        names.extend(own.into_iter().map(|name| format!("{area}.{name}")));
    }
    names
}

fn ops_call(name: &str) -> Result<Value, OpError> {
    match name {
        "list" => Ok(Value::from(op_names())),
        _ => Err(OpError::Unknown),
    }
}

/// Reads `request` as `T` (an area's request type).
pub fn parse<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    T::deserialize(request).map_err(|err| OpError::Invalid(err.to_string()))
}

/// Runs the op `op` on `bytes` (a JSON object, UTF-8) and writes its reply as JSON bytes: what
/// `cmux_home_call` (cmux-app-ffi `src/home.rs`) answers. Ops with a typed path read the request
/// straight into their request type and write their reply straight to bytes; the rest go through
/// [`call`]. Either way the reply is the same JSON (key order aside), and a request that is not a
/// JSON object is [`OpError::Invalid`].
pub fn call_json(op: &str, bytes: &[u8]) -> Result<Vec<u8>, OpError> {
    if let Some(("mapping", name)) = op.split_once('.')
        && let Some(reply) = crate::mapping::call_bytes(name, bytes)
    {
        return reply;
    }
    let request = match serde_json::from_slice::<Value>(bytes) {
        Ok(value @ Value::Object(_)) => value,
        Ok(_) => return Err(OpError::Invalid("the request is not a JSON object".into())),
        Err(err) => return Err(OpError::Invalid(err.to_string())),
    };
    let reply = call(op, &request)?;
    serde_json::to_vec(&reply).map_err(|err| OpError::Invalid(err.to_string()))
}

/// An op's typed path from bytes: `None` when `bytes` is not an object its request type reads
/// (a typed read also takes an array, and refuses duplicate keys the `Value` read keeps the last
/// of), so the `Value` path answers those as it always did.
pub fn typed_bytes<Req: DeserializeOwned, Rep: serde::Serialize>(
    bytes: &[u8],
    op: impl FnOnce(Req) -> Result<Rep, OpError>,
) -> Option<Result<Vec<u8>, OpError>> {
    if bytes.iter().find(|b| !b.is_ascii_whitespace()) != Some(&b'{') {
        return None;
    }
    let request: Req = serde_json::from_slice(bytes).ok()?;
    Some(op(request).and_then(|reply| {
        serde_json::to_vec(&reply).map_err(|err| OpError::Invalid(err.to_string()))
    }))
}

/// Writes `reply` as JSON.
pub fn reply<T: serde::Serialize>(reply: &T) -> Result<Value, OpError> {
    serde_json::to_value(reply).map_err(|err| OpError::Invalid(err.to_string()))
}
