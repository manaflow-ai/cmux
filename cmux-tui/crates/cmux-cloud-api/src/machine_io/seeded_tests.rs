//! Seeded secrets through `cmux cloud machine-io` on the wire (cmux_egress::capture): the
//! credential goes only in `Authorization`, and a written file's bytes and a command go only in a
//! body, never in a URL (the cmux API Worker's invocation log records every URL).
//! tests/egress_seeded.json names this test for the `cmux_cloud_api::machine_io` gate site.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_egress::capture;
use serde_json::json;

use super::{Request, http_client, perform};

const HOST: &str = "cloud-api.cmux.dev";
const MACHINE: &str = "vm_seeded0123456789abcd";

fn seeded(op: &str, route: &str, extra: serde_json::Value) -> Request {
    let mut request = json!({
        "api": format!("https://{HOST}"),
        "credential": "SEEDmachineioCredential-5e2c",
        "team": "team-seeded",
        "machine": MACHINE,
        "op": op,
        "route": route,
    });
    if let (Some(fields), Some(more)) = (request.as_object_mut(), extra.as_object()) {
        fields.extend(more.clone());
    }
    serde_json::from_value(request).unwrap()
}

#[test]
fn seeded_secrets_ride_only_in_authorization_and_bodies() {
    capture::install().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let client = http_client().unwrap();
    let data = "SEEDfileBytes-91af";
    let command = "echo SEEDcommand-4d07";
    let requests = [
        seeded(
            "write",
            "proxy",
            json!({"path": "/tmp/seeded", "data_base64": BASE64.encode(data)}),
        ),
        seeded("exec", "proxy", json!({"command": command, "timeout_ms": 1000})),
        // Auto: the mint goes to the cmux API too (the capture server's `{}` is no session,
        // so the call ends on the proxy).
        seeded("exec", "auto", json!({"command": command, "timeout_ms": 1000})),
    ];
    for request in &requests {
        runtime.block_on(perform(&client, request, super::now_ms));
    }

    let sent = capture::requests_to(HOST);
    assert!(sent.len() >= requests.len(), "{sent:?}");
    let credential = capture::leaks("SEEDmachineioCredential-5e2c");
    assert!(!credential.is_empty());
    assert!(credential.iter().all(|p| p.ends_with(": header authorization")), "{credential:?}");
    // A file's bytes travel base64-encoded (`dataBase64`); the command as text.
    for secret in [BASE64.encode(data).as_str(), "SEEDcommand-4d07"] {
        let places = capture::leaks(secret);
        assert!(!places.is_empty(), "{secret} was never sent");
        assert!(places.iter().all(|p| p.ends_with(": body")), "{secret}: {places:?}");
    }
}
