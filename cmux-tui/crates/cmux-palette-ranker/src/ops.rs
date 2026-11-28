//! The palette operations beside ranking that the C ABI answers statelessly: a request whose
//! `operation` names one of them is answered here, and its handle only holds the response bytes.
//!
//! - `navReduce`: one navigation step ([`crate::nav::ReduceRequest`] to
//!   [`crate::nav::ReduceReply`]).
//! - `scopeGraph`: applies the user's prefix choices (`assigned`) to scope descriptors and
//!   registers them (`{"root", "scopes", "assigned"}`) into a [`crate::scope_graph::Graph`],
//!   with what was refused.

use crate::ffi::{ERR_INVALID, OK};
use crate::scope_graph::{Descriptor, Graph, apply_assigned};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Deserialize)]
struct GraphRequest {
    root: Descriptor,
    #[serde(default)]
    scopes: Vec<Descriptor>,
    /// The user's prefix choices, applied before registration.
    #[serde(default)]
    assigned: HashMap<String, Option<String>>,
}

fn reply<T: Serialize>(answer: &T) -> (i32, Vec<u8>) {
    match serde_json::to_vec(answer) {
        Ok(bytes) => (OK, bytes),
        Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
    }
}

fn read<'a, T: Deserialize<'a>>(
    request: &'a [u8],
    answer: impl FnOnce(T) -> (i32, Vec<u8>),
) -> (i32, Vec<u8>) {
    match serde_json::from_slice(request) {
        Ok(request) => answer(request),
        Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
    }
}

/// The answer to `operation`, or none when it is a ranking operation.
pub(crate) fn answer(operation: &str, request: &[u8]) -> Option<(i32, Vec<u8>)> {
    Some(match operation {
        "navReduce" => read(request, |request| reply(&crate::nav::answer(request))),
        "scopeGraph" => read(request, |request: GraphRequest| {
            reply(&Graph::build(request.root, apply_assigned(&request.assigned, request.scopes)))
        }),
        _ => return None,
    })
}
