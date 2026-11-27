//! `cmux automation webhook fire TRIGGER --secret S [--event NAME] [--body JSON]`: one signed
//! delivery to a `--source webhook` Cloud trigger, as any sender would make it (cmux-platform
//! src/server/triggers/Webhook.ts): `x-cmux-webhook-delivery`, `x-cmux-webhook-timestamp` and
//! `x-cmux-webhook-signature: sha256=HMAC-SHA256(secret, timestamp "\n" delivery "\n" body)`.
//!
//! The trigger URL needs no sign-in; the secret is the authority. It prints what the platform
//! answered: the run it queued, or why it started nothing (`condition_unmet`, `cooldown`, ...).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::automation_webhook::{TRIGGERS_PATH, trigger_id};
use super::{Args, Failure, Out, Outcome, OutputMode, messages, usage};

const TIMEOUT: Duration = Duration::from_secs(30);
/// `CMUX_WEBHOOK_SECRET` keeps the secret out of the process list.
const SECRET_ENV: &str = "CMUX_WEBHOOK_SECRET";
const MAX_BODY_BYTES: usize = 64 * 1024;

/// A checked fire: where it goes and the exact bytes it signs.
#[derive(Debug, PartialEq)]
pub(super) struct Shot {
    pub trigger: String,
    pub secret: String,
    pub body: Vec<u8>,
    pub platform: Option<String>,
}

pub(super) fn shot(args: &[String], env: &dyn Fn(&str) -> Option<String>) -> Result<Shot, Failure> {
    let a = Args::parse(args, &["secret", "event", "body", "platform"], &[])?;
    let m = messages();
    let trigger = trigger_id(a.one_word("TRIGGER")?)?.to_owned();
    let secret = match a.value("secret").map(str::to_owned).or_else(|| env(SECRET_ENV)) {
        Some(secret) if !secret.trim().is_empty() => secret.trim().to_owned(),
        _ => return usage(m.webhook_fire_no_secret),
    };
    let mut body = match a.value("body") {
        Some(text) => match serde_json::from_str::<Value>(text) {
            Ok(v @ Value::Object(_)) => v,
            _ => return usage(m.webhook_fire_bad_body.replace("{value}", text)),
        },
        None => json!({}),
    };
    if let Some(event) = a.value("event") {
        if !super::automation_webhook::hook_event_ok(event) {
            return usage(m.webhook_bad_hook_event.replace("{value}", event));
        }
        if let Some(fields) = body.as_object_mut() {
            fields.insert("event".into(), json!(event));
        }
    }
    let body = serde_json::to_vec(&body).unwrap_or_default();
    if body.len() > MAX_BODY_BYTES {
        return usage(m.webhook_fire_bad_body.replace("{value}", "over 64 KiB"));
    }
    Ok(Shot { trigger, secret, body, platform: a.value("platform").map(str::to_owned) })
}

/// The cmux form's headers for `body` at `timestamp` (Unix seconds) with `delivery`.
pub(super) fn signed_headers(
    secret: &str,
    timestamp: u64,
    delivery: &str,
    body: &[u8],
) -> [(&'static str, String); 3] {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, secret.as_bytes());
    let mut ctx = ring::hmac::Context::with_key(&key);
    ctx.update(format!("{timestamp}\n{delivery}\n").as_bytes());
    ctx.update(body);
    let hex: String = ctx.sign().as_ref().iter().map(|b| format!("{b:02x}")).collect();
    [
        ("x-cmux-webhook-delivery", delivery.to_owned()),
        ("x-cmux-webhook-timestamp", timestamp.to_string()),
        ("x-cmux-webhook-signature", format!("sha256={hex}")),
    ]
}

/// What the platform answered, as one line.
pub(super) fn answer_line(answer: &Value) -> String {
    let m = messages();
    let text = |key: &str| answer.get(key).and_then(Value::as_str).unwrap_or("");
    if answer.get("accepted").and_then(Value::as_bool) == Some(true) {
        let mut line = m
            .webhook_fire_accepted
            .replace("{delivery}", text("id"))
            .replace("{state}", text("state"));
        if answer.get("duplicate").and_then(Value::as_bool) == Some(true) {
            line.push_str(m.webhook_fire_duplicate);
        }
        line
    } else {
        m.webhook_fire_ignored.replace("{reason}", text("reason"))
    }
}

pub(super) fn fire(args: &[String], out: &Out) -> Outcome {
    let env = |key: &str| std::env::var(key).ok();
    let shot = shot(args, &env)?;
    let origin = match crate::cli::platform_origin(shot.platform.as_deref(), &env) {
        Ok(origin) => origin,
        Err(message) => return usage(message),
    };
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let delivery = format!("cli-{}", uuid::Uuid::new_v4().simple());
    let headers = signed_headers(&shot.secret, timestamp, &delivery, &shot.body);
    let url = format!("{origin}{TRIGGERS_PATH}/{}/webhook", shot.trigger);
    match post(&url, &headers, shot.body) {
        Ok((status, answer)) => {
            let ok = (200..300).contains(&status);
            match out.mode {
                OutputMode::Json | OutputMode::JsonLines => {
                    out.value(&json!({"status": status, "delivery": delivery, "answer": answer}));
                }
                OutputMode::Quiet => {}
                OutputMode::Human => println!("{}", answer_line(&answer)),
            }
            let started = answer.get("accepted").and_then(Value::as_bool) == Some(true);
            Ok(if ok && started { 0 } else { 1 })
        }
        Err(reason) => Ok(out.error(
            &json!({
                "code": "automation.webhook.unreachable",
                "message": messages().webhook_fire_unreachable.replace("{reason}", &reason),
                "details": {"delivery": delivery},
                "retryable": true,
            }),
            3,
            true,
        )),
    }
}

fn post(url: &str, headers: &[(&str, String)], body: Vec<u8>) -> Result<(u16, Value), String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let space = cmux_build_space::headers().map_err(|e| e.to_string())?;
    let client = cmux_egress::client_builder("cmux_tui::cli::automation_webhook_fire")
        .default_headers(space)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    runtime.block_on(async {
        let mut request = client
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(TIMEOUT)
            .body(body);
        for (name, value) in headers {
            request = request.header(*name, value.as_str());
        }
        let response = request.send().await.map_err(|e| e.without_url().to_string())?;
        let status = response.status().as_u16();
        let bytes = response.bytes().await.map_err(|e| e.without_url().to_string())?;
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
    })
}

#[cfg(test)]
#[path = "automation_webhook_fire_tests.rs"]
mod tests;
