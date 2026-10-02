//! Test entry: one raw resource-protocol message in, one response out.

use std::sync::Arc;

use serde_json::Value;

use super::{handle_parsed_resource_request, parse_resource_request};
use crate::Mux;
use crate::resource::ResourceError;

pub(crate) fn handle_resource_message(
    mux: &Arc<Mux>,
    message: &str,
) -> Result<Value, ResourceError> {
    let request = parse_resource_request(message)?;
    handle_parsed_resource_request(mux, request)
}
