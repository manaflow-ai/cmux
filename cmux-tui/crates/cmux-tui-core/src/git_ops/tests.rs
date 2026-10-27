//! A routing-table bug that sends git_ops an operation it does not serve
//! is answered as an internal failure, not a trapped daemon.

use serde_json::json;

use crate::resource_router::parse_resource_request;
use crate::{Mux, SurfaceOptions};

#[test]
fn an_operation_git_ops_does_not_serve_is_an_internal_operation_failure() {
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "git-unrouted",
        "operation": "notification.create",
        "idempotency_key": "git-unrouted",
        "params": {
            "machine": "current",
            "session": "current",
            "title": "t",
            "body": "b",
            "level": "info",
        },
    });
    let request = parse_resource_request(&request.to_string()).unwrap();
    assert!(!super::handles(request.envelope.operation));
    let mux = Mux::new_for_test("git-unrouted", SurfaceOptions::default());
    let error = super::dispatch(&mux, request).unwrap_err();
    assert_eq!(error.code, "operation.failed", "{error:?}");
    assert_eq!(error.details["operation"], "notification.create", "{error:?}");
    assert_eq!(error.details["extra"]["code"], "internal", "{error:?}");
}
