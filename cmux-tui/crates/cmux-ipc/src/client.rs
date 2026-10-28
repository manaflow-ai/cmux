//! Typed client requests for the JSON-line wire (p05-ipc design 3.3, task
//! 028). build.rs writes one `<Command>Request` struct per command whose
//! schema `clients` lists `cli`, with its wire name, method id and capability
//! (build-support/client_requests.rs); nothing generated is committed.
//!
//! A caller fills the struct and asks for its line; it never spells a `"cmd"`
//! name or a field name, so a schema rename is a compile error in the caller,
//! as with Mojo's generated request structs
//! (mojo/public/tools/bindings/generators/cpp_templates/struct_declaration.tmpl).
//!
//! ```
//! use cmux_ipc::client::{ClientRequest, IdentifyRequest};
//! let line = IdentifyRequest::default().line(1);
//! assert_eq!(line.to_string(), r#"{"cmd":"identify","id":1}"#);
//! ```

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::methods::MethodId;

/// A value as it goes on the wire.
pub trait WireValue {
    fn wire_value(&self) -> Value;
}

/// A generated struct: writes its fields into a JSON object.
pub trait WireObject {
    fn insert_fields(&self, fields: &mut Map<String, Value>);
}

/// A command request a client sends.
pub trait ClientRequest: WireObject {
    /// The wire name, a line's `cmd`.
    const CMD: &'static str;
    /// The schema `method_id` (`family << 8 | ordinal`).
    const METHOD_ID: MethodId;
    /// The capability the daemon must advertise for the command, if any.
    const CAPABILITY: Option<&'static str>;

    /// The request line `{"id": id, "cmd": CMD, fields...}`.
    fn line(&self, id: impl Into<Value>) -> Value {
        let mut line = Map::new();
        line.insert("id".to_owned(), id.into());
        line.insert("cmd".to_owned(), Value::from(Self::CMD));
        self.insert_fields(&mut line);
        Value::Object(line)
    }
}

macro_rules! wire_value_from {
    ($($ty:ty),*) => {
        $(impl WireValue for $ty {
            fn wire_value(&self) -> Value {
                Value::from(*self)
            }
        })*
    };
}

wire_value_from!(bool, u8, u16, u32, u64, i8, i16, i32, i64, f32, f64);

impl WireValue for String {
    fn wire_value(&self) -> Value {
        Value::from(self.as_str())
    }
}

impl WireValue for Value {
    fn wire_value(&self) -> Value {
        self.clone()
    }
}

impl<T: WireValue> WireValue for Option<T> {
    fn wire_value(&self) -> Value {
        self.as_ref().map_or(Value::Null, WireValue::wire_value)
    }
}

impl<T: WireValue> WireValue for Vec<T> {
    fn wire_value(&self) -> Value {
        Value::Array(self.iter().map(WireValue::wire_value).collect())
    }
}

impl<T: WireValue> WireValue for BTreeMap<String, T> {
    fn wire_value(&self) -> Value {
        Value::Object(self.iter().map(|(key, value)| (key.clone(), value.wire_value())).collect())
    }
}

include!(concat!(env!("OUT_DIR"), "/client_requests.rs"));
