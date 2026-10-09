//! The trusted-local rule of the connection-owned resource operations.

use serde_json::json;

use super::{Mux, ResourceError, ResourceOperation};

/// `Ok` for a local Unix connection; every other transport is refused with
/// `operation.failed` naming the authority it lacks.
pub(super) fn trusted_local_resource_client(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
) -> Result<(), ResourceError> {
    if mux.control_clients.is_unix(client) {
        Ok(())
    } else {
        let operation = operation.wire_name().to_owned();
        Err(ResourceError::operation_failed(
            operation,
            "operation requires a trusted local connection",
            json!({"required_authority":"trusted_local"}),
        ))
    }
}
