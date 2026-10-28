//! The request shape of every framed v12 command, from spec/sdk-schema.json
//! at build time (build-support/request_shapes.rs; p05-ipc design 3.7,
//! "Fuzzing"; task 182). Built only with the `fuzzing` feature, which only
//! the cmux-tui/fuzz workspace turns on: its `dispatch_structured` target
//! walks these shapes to write request bodies the schema allows, the
//! structure-aware generator MojoLPM derives from mojom (chromium
//! mojo/public/tools/fuzzers/mojolpm.h).
//!
//! The shapes are an arena: a child is an index into [`RequestShapes::shape`],
//! so a named type is one node however often it is used, and a recursive
//! type is finite. A shape describes what the schema allows; a generator
//! decides how far it strays from it.

use crate::methods::MethodId;

/// A literal value the schema fixes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Literal {
    Bool(bool),
    Int(i64),
    Text(&'static str),
}

/// One JSON shape.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shape {
    /// Any JSON value (`opaque_json`, or a kind the reader does not know).
    Any,
    Bool,
    /// An integer in `min..=max`.
    Unsigned {
        min: u64,
        max: u64,
    },
    /// An integer in `min..=max`.
    Signed {
        min: i64,
        max: i64,
    },
    Float,
    /// A string of at most `max_bytes` UTF-8 bytes, when bounded.
    Text {
        max_bytes: Option<u64>,
    },
    Literal(Literal),
    /// One of these strings.
    Enum(&'static [&'static str]),
    /// An array of shape `items`, `min` to `max` long.
    Array {
        items: u32,
        min: u64,
        max: Option<u64>,
    },
    /// An object of any keys whose values have shape `values`.
    Map {
        values: u32,
    },
    /// An object of these members; `open` allows other members.
    Object {
        fields: &'static [Field],
        open: bool,
    },
    /// Exactly one of these shapes (a tagged variant carries its tag as a
    /// literal member).
    OneOf(&'static [u32]),
}

/// One member of an object shape.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Field {
    pub name: &'static str,
    pub shape: u32,
    pub required: bool,
    pub nullable: bool,
}

/// A framed command: its id, wire name and the shape of its request
/// members (an object whose members sit next to `id` and `cmd` on the line).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RequestShape {
    pub method_id: MethodId,
    pub name: &'static str,
    pub params: u32,
}

/// Every request shape of one schema build.
#[derive(Debug)]
pub struct RequestShapes {
    shapes: &'static [Shape],
    /// Sorted by method id.
    requests: &'static [RequestShape],
}

include!(concat!(env!("OUT_DIR"), "/request_shapes.rs"));

impl RequestShapes {
    /// The shapes of the schema this binary was built from.
    pub fn schema() -> &'static RequestShapes {
        &SHAPES
    }

    /// The shape at arena index `index`.
    pub fn shape(&self, index: u32) -> Option<&'static Shape> {
        self.shapes.get(usize::try_from(index).ok()?)
    }

    /// The request shape of method `id`; `None` for an id without one (a v2
    /// operation, until its params get a reader here).
    pub fn request(&self, id: MethodId) -> Option<&'static RequestShape> {
        let requests = self.requests;
        let at = requests.binary_search_by_key(&id, |request| request.method_id).ok()?;
        requests.get(at)
    }

    /// Every request shape, in method id order.
    pub fn requests(&self) -> &'static [RequestShape] {
        self.requests
    }
}
