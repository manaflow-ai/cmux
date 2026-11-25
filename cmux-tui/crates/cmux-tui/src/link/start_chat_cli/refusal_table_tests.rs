//! Every refusal the cmux platform answers a workspace's machine or a composer reservation with
//! reaches the line the App reads (`ensure`, `reserve`) intact: its code, whether it is final,
//! retried or waited out, and a rate limit's window. The
//! client half of cmux-platform#1254's table test: each row of
//! [`cmux_cloud_machine::refusals::PLATFORM`] goes out of a loopback platform as an HTTP status,
//! a body and a Retry-After header, through [`crate::cli::Platform`]'s call, to the line the App
//! reads. A row added to the table later is driven with no edit here.

use std::io::{Read, Write};
use std::net::TcpListener;

use cmux_cloud_machine::refusals::{self, Handling, PLATFORM, Refusal};
use serde_json::{Value, json};

use super::{Ensure, Flags, reservations};

/// What a rate limit's Retry-After asks for: not the platform's 60 s default, so a dropped
/// header shows.
const WINDOW_S: u64 = 120;

/// A platform on a loopback port that answers one request with `status`, `headers` and `body`.
fn answering(status: u16, headers: String, body: String) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let origin = format!("http://{}", listener.local_addr().expect("addr"));
    std::thread::spawn(move || {
        let Ok((mut stream, _)) = listener.accept() else { return };
        let mut seen = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            let n = stream.read(&mut chunk).unwrap_or(0);
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
        let _ = stream.write_all(
            format!(
                "HTTP/1.1 {status} X\r\n{headers}content-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        );
    });
    origin
}

/// A loopback platform that answers `refusal` as cmux-platform#1192 does: its status, its code,
/// its `retryable`, a 503's `cause`, and a rate limit's window only in Retry-After.
fn refusing(refusal: &Refusal) -> String {
    let mut body = json!({
        "_tag": "CloudRefusal", "code": refusal.code, "message": "refused", "retryable": refusal.retryable,
    });
    if refusal.status == 503 {
        body["cause"] = json!("provider: refused");
    }
    let headers =
        if refusal.status == 429 { format!("retry-after: {WINDOW_S}\r\n") } else { String::new() };
    answering(refusal.status, headers, body.to_string())
}

/// A fresh UUID-shaped key.
fn key() -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let next = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("0000000B-0000-4000-8000-{next:012X}")
}

fn flags(words: &[&str]) -> Flags {
    Flags::parse(&words.iter().map(|word| word.to_string()).collect::<Vec<_>>()).expect("flags")
}

/// `ensure`'s line when the platform refuses the workspace's machine with `refusal`.
fn ensure_line(refusal: &Refusal) -> Value {
    let origin = refusing(refusal);
    let key = key();
    let words =
        ["--workspace", "ws-1", "--key", &key, "--repo", "manaflow-ai/cmux", "--platform", &origin];
    Ensure::of(&flags(&words)).expect("ensure").run(&mut "cmux-credential\n".as_bytes())
}

/// `reserve`'s line when the platform refuses the composer's reservation with `refusal`.
fn reserve_line(refusal: &Refusal) -> Value {
    let request = json!({"composeKey": key().to_lowercase(), "platform": refusing(refusal)});
    reservations::run(
        &flags(&["--request", &request.to_string()]),
        reservations::Action::Reserve,
        &mut "cmux-credential\n\n".as_bytes(),
    )
    .expect("reserve")
}

fn assert_reaches_the_line(refusal: &Refusal, line: &Value) {
    let name = format!("{} {}", refusal.status, refusal.code);
    let handling = refusals::handling(refusal.status, Some(refusal.code), Some(refusal.retryable));
    assert_eq!(line["ok"], json!(false), "{name}: {line}");
    assert_eq!(line["error_code"], json!(refusal.code), "{name}: {line}");
    assert_eq!(line["handling"], json!(handling), "{name}: {line}");
    assert_eq!(line["retryable"], json!(handling != Handling::Final), "{name}: {line}");
    let window = if handling == Handling::RetryAfter { json!(WINDOW_S) } else { Value::Null };
    assert_eq!(line["retry_after_s"], window, "{name}: {line}");
}

#[test]
fn every_platform_refusal_reaches_the_start_answer_with_its_handling() {
    for refusal in PLATFORM {
        assert_reaches_the_line(refusal, &ensure_line(refusal));
        assert_reaches_the_line(refusal, &reserve_line(refusal));
    }
}

/// A code the platform's table lacks still says, in its body, whether it may be retried: the
/// workspace route's placement outage (a documented 503) is retried, and the same code marked
/// final is not. The flag is read whether or not the code has a row.
#[test]
fn a_refusal_outside_the_table_keeps_its_bodys_retryable() {
    for retryable in [true, false] {
        let outage = Refusal { code: "machine.placement_unavailable", status: 503, retryable };
        assert!(refusals::platform(outage.code).is_none(), "the row is in the table now");
        assert_reaches_the_line(&outage, &ensure_line(&outage));
        assert_reaches_the_line(&outage, &reserve_line(&outage));
    }
}
