use axum::{
    Json, Router,
    http::HeaderMap,
    routing::{get, post},
};
use serde_json::{Value, json};

#[tokio::test]
async fn hub_cli_drives_the_platform() {
    let app = Router::new()
        .route("/v1/hub/actions", get(async || Json(json!({"actions": [{"name": "stripe.refund.create"}]}))))
        .route("/v1/hub/approvals", get(async || Json(json!({"approvals": [{"id": "hcall_0123456789abcdef01234567"}]}))))
        .route("/v1/hub/audit", get(async || Json(json!({"audit": [{"seq": 41}]}))))
        .route("/v1/hub/calls", post(async |headers: HeaderMap, Json(body): Json<Value>| {
            assert_eq!(headers["authorization"], "Bearer mock-hub-token");
            assert_eq!(body, json!({"action":"stripe.refund.create","args":{"charge":"ch_demo","amount":4200},
                                   "connection":"hubc_0123456789abcdef01234567","invocationId":"refund-demo-123"}));
            Json(json!({"call": {"status":"approval_required"}}))
        }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    for (command, pointer, expected) in [
        ("actions", "/actions/0/name", json!("stripe.refund.create")),
        (
            "call stripe.refund.create --charge ch_demo --amount 4200 --connection hubc_0123456789abcdef01234567 --invocation-id refund-demo-123",
            "/call/status",
            json!("approval_required"),
        ),
        ("approvals", "/approvals/0/id", json!("hcall_0123456789abcdef01234567")),
        ("audit", "/audit/0/seq", json!(41)),
    ] {
        let output = tokio::process::Command::new(super::bin())
            .args(["hub", "--json"])
            .args(command.split_whitespace())
            .env("CMUX_PLATFORM_URL", &origin)
            .env("CMUX_CLOUD_ACCESS_TOKEN", "mock-hub-token")
            .output()
            .await
            .unwrap();
        assert!(output.status.success(), "{command}: {output:?}");
        let result: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(result.pointer(pointer), Some(&expected), "{command}: {result}");
    }
    server.abort();
}
