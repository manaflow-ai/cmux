use super::*;
use cmux_cloud_wire::{CloudMachineDeleteOp, CloudMachineGetOp};

#[test]
fn a_refused_mutation_keeps_its_declared_code() {
    let body = br#"{"ok":false,"op":"cloud.machine.delete","error":{"code":"cloud.machine.not_found","message":"gone","retryable":false},"transaction":"t","idempotency_key":"ck_1","replayed":false,"stream":"s","sequence":3}"#;
    let answer = read_answer::<CloudMachineDeleteOp>(200, None, body).unwrap();
    let error = answer.into_result().unwrap_err();
    assert_eq!(error.code.as_deref(), Some("cloud.machine.not_found"));
    assert_eq!(error.message, "gone");
}

#[test]
fn a_refused_request_reads_as_an_api_error() {
    let body = br#"{"_tag":"Unauthorized","code":"auth.required","message":"sign in"}"#;
    let error = read_answer::<CloudMachineGetOp>(401, None, body).unwrap_err();
    assert_eq!(error.status, Some(401));
    assert_eq!(error.code.as_deref(), Some("auth.required"));
}

#[tokio::test]
async fn a_required_key_is_checked_before_sending() {
    crate::test_tls();
    let http = reqwest::Client::new();
    let params = serde_json::from_value(serde_json::json!({"machine": "vm_x"})).unwrap();
    let error = call::<CloudMachineDeleteOp>(&http, "http://127.0.0.1:9", params, None, None)
        .await
        .unwrap_err();
    assert_eq!(error.code.as_deref(), Some("cloud.client.usage"));
}

/// A mutation whose catalog row refuses keys (`idempotency: none`).
struct OneTimeOp;

impl Op for OneTimeOp {
    const NAME: &'static str = "test.one_time";
    const CLASS: WireClass = WireClass::Mutation;
    const IDEMPOTENCY: WireIdempotency = WireIdempotency::None;
    const OWNER: &'static str = "test";
    const RISK: &'static str = "mutate-own";
    const PRINCIPALS: &'static [cmux_cloud_wire::WirePrincipal] = &[];
    type Params = serde_json::Value;
    type Result = serde_json::Value;
    type Error = <CloudMachineDeleteOp as Op>::Error;
}

#[tokio::test]
async fn a_key_for_a_mutation_that_refuses_keys_is_refused_before_sending() {
    crate::test_tls();
    let http = reqwest::Client::new();
    let error =
        call::<OneTimeOp>(&http, "http://127.0.0.1:9", serde_json::json!({}), Some("ck_1"), None)
            .await
            .unwrap_err();
    assert_eq!(error.code.as_deref(), Some("cloud.client.usage"));
    assert!(error.status.is_none(), "nothing was sent");
}

/// A rate limit's window as the platform asks for it: not the 60 s default, so a dropped
/// header or detail shows.
const WINDOW_S: u64 = 120;

/// A Cloud API on a loopback port that answers one request with `status`, `headers` and
/// `body`.
async fn answering(status: u16, headers: String, body: String) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let Ok((mut stream, _)) = listener.accept().await else { return };
        let mut seen = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            let n = stream.read(&mut chunk).await.unwrap_or(0);
            seen.extend_from_slice(&chunk[..n]);
            let text = String::from_utf8_lossy(&seen).to_ascii_lowercase();
            let done = text.find("\r\n\r\n").is_some_and(|end| {
                let length = text[..end]
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .and_then(|value| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                seen.len() >= end + 4 + length
            });
            if done || n == 0 {
                break;
            }
        }
        let _ = stream
                .write_all(
                    format!(
                        "HTTP/1.1 {status} X\r\n{headers}content-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await;
    });
    base_url
}

/// Every row of the platform's refusal table, as cmux-platform#1192 answers it, reaches the
/// client's [`ApiError`] intact over HTTP, both ways an op can be refused: a refused request
/// (the row's status, its body, a rate limit's window only in Retry-After) and a refused
/// mutation (HTTP 200, the window in `details.retry_after_ms`). The client half of
/// cmux-platform#1254's table test; a row added to the table later is driven with no edit.
#[tokio::test]
async fn every_platform_refusal_reaches_the_client_with_its_retry_fields() {
    use cmux_cloud_machine::refusals::{Handling, PLATFORM};
    crate::test_tls();
    let http = reqwest::Client::new();
    for row in PLATFORM {
        let name = format!("{} {}", row.status, row.code);
        let waits = row.handling() == Handling::RetryAfter;
        let window = waits.then(|| std::time::Duration::from_secs(WINDOW_S));

        // A refused request: the row's own status.
        let headers = if waits { format!("retry-after: {WINDOW_S}\r\n") } else { String::new() };
        let body = serde_json::json!({
            "_tag": "CloudRefusal", "code": row.code, "message": "refused",
            "retryable": row.retryable,
        });
        let base_url = answering(row.status, headers, body.to_string()).await;
        let error = call::<OneTimeOp>(&http, &base_url, serde_json::json!({}), None, None)
            .await
            .unwrap_err();
        assert_eq!(error.status, Some(row.status), "{name}");
        assert_eq!(error.code.as_deref(), Some(row.code), "{name}");
        assert_eq!(error.retryable, row.handling() != Handling::Final, "{name}");
        assert_eq!(error.retry_after, window, "{name}: the Retry-After header");

        // A refused mutation: HTTP 200, the op's error.
        let mut refusal = serde_json::json!({
            "code": row.code, "message": "refused", "retryable": row.retryable,
        });
        if waits {
            refusal["details"] = serde_json::json!({"retry_after_ms": WINDOW_S * 1000});
        }
        let envelope = serde_json::json!({
            "ok": false, "op": OneTimeOp::NAME, "error": refusal, "transaction": "t",
            "idempotency_key": "", "replayed": false, "stream": "s", "sequence": 1,
        });
        let base_url = answering(200, String::new(), envelope.to_string()).await;
        let error = call::<OneTimeOp>(&http, &base_url, serde_json::json!({}), None, None)
            .await
            .unwrap()
            .into_result()
            .unwrap_err();
        assert_eq!(error.code.as_deref(), Some(row.code), "{name}");
        assert_eq!(error.retryable, row.retryable, "{name}");
        assert_eq!(error.retry_after, window, "{name}: details.retry_after_ms");
    }
}

/// A rate limit whose answer is only its status and Retry-After waits that long, not the
/// platform's default.
#[tokio::test]
async fn a_header_only_rate_limit_waits_its_retry_after() {
    crate::test_tls();
    let http = reqwest::Client::new();
    let base_url = answering(429, format!("retry-after: {WINDOW_S}\r\n"), String::new()).await;
    let error =
        call::<OneTimeOp>(&http, &base_url, serde_json::json!({}), None, None).await.unwrap_err();
    assert!(error.retryable);
    assert_eq!(error.retry_after, Some(std::time::Duration::from_secs(WINDOW_S)));
}
