//! `cmux usage upload|delete-shared`: the second opt-in, sharing this machine's usage record
//! (cmux-usage) with the person's cmux team on the platform (`POST|DELETE /v1/usage/records`,
//! cmux-platform `src/api/UsageSharing.ts`).
//!
//! What goes and how far it got is cmux-usage's `share` module (the cursor, the batches, the
//! install id); this file only gets a token and makes the calls. An upload needs the usage
//! folder's `share` marker, which only the app writes from this Mac's own consent
//! (`usage-set-sharing`), so a synced settings file or an agent editing it cannot make a machine
//! upload. `--dry-run` reads only local files and works with sharing off.
//!
//! The token: from a terminal, the app's `auth.token` (the same short-lived install token `cmux
//! auth token` prints), and the platform that belongs to the API that issued it
//! (`CMUX_PLATFORM_URL` overrides). The app itself runs `cmux usage upload --credential-stdin`
//! with `{"platform", "credential"}` on stdin, as it runs its other Cloud subcommands, so the
//! token never goes in argv or the environment. Nothing here prints or logs the token.

use std::io::Read as _;
use std::time::Duration;

use cmux_usage::UsageDir;
use cmux_usage::share::{MAX_BODY_BYTES, MAX_RECORDS, Pending, Stop};
use serde_json::{Value, json};

use super::machine_join::{CallError, Platform};
use super::usage_recording::print;
use super::{GlobalArgs, OutputMode};

const RECORDS_PATH: &str = "/v1/usage/records";
const PLATFORM_ENV: &str = "CMUX_PLATFORM_URL";
/// Each call's deadline; a 1 MiB batch is the largest.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
/// The app bounds its token mint at 25 s.
const AUTH_TOKEN_TIMEOUT: Duration = Duration::from_secs(30);
/// The most stdin `--credential-stdin` reads.
const STDIN_LIMIT: u64 = 64 * 1024;

/// A failed step: its error code, message and exit code.
struct Refusal {
    code: &'static str,
    message: String,
    exit: i32,
}

impl Refusal {
    fn print(&self, output: OutputMode) -> i32 {
        super::app::failure(self.code, &format!("cmux: {}", self.message), output, self.exit)
    }
}

/// Where to send and as whom.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Access {
    platform: String,
    credential: String,
}

/// `cmux usage upload`.
pub(super) fn upload(
    output: OutputMode,
    global: &GlobalArgs,
    dir: &UsageDir,
    dry_run: bool,
    credential_stdin: bool,
) -> i32 {
    let messages = &crate::localization::catalog().usage_recording;
    let dir_text = dir.path().display().to_string();
    if !(dry_run || dir.is_enabled() && dir.is_sharing()) {
        return Refusal {
            code: "usage.not_sharing",
            message: messages.not_sharing.into(),
            exit: 3,
        }
        .print(output);
    }
    let pending = Pending::read(dir);
    let count = pending.as_ref().map_or(0, Pending::count);
    if dry_run {
        let install = pending.as_ref().map(|p| p.install.clone());
        let sample = pending.as_ref().and_then(Pending::sample);
        let value = json!({
            "dry_run": true, "dir": dir_text, "install": install, "pending": count,
            "sample": sample.as_deref().and_then(|line| serde_json::from_str::<Value>(line).ok()),
            "sharing": dir.is_enabled() && dir.is_sharing(),
        });
        let human = match (count, &install, &sample) {
            (1.., Some(install), Some(sample)) => messages
                .dry_run
                .replace("{count}", &count.to_string())
                .replace("{dir}", &dir_text)
                .replace("{install}", install)
                .replace("{sample}", sample),
            _ => messages.nothing_pending.replace("{dir}", &dir_text),
        };
        return print(output, &value, &human);
    }
    let Some(pending) = pending.filter(|p| p.count() > 0) else {
        let value =
            json!({ "dir": dir_text, "sent": 0, "batches": 0, "accepted": 0, "duplicates": 0 });
        return print(output, &value, &messages.nothing_pending.replace("{dir}", &dir_text));
    };
    let platform = match access(global, credential_stdin).and_then(|access| connect(&access)) {
        Ok(platform) => platform,
        Err(refusal) => return refusal.print(output),
    };
    let install = pending.install.clone();
    let (mut accepted, mut duplicates) = (0u64, 0u64);
    let sent = pending.send(dir, (MAX_RECORDS, MAX_BODY_BYTES), |batch| {
        let answer = platform.post_text(RECORDS_PATH, batch.body.clone())?;
        let field = |key: &str| answer.get(key).and_then(Value::as_u64).unwrap_or(0);
        accepted += field("accepted");
        duplicates += field("duplicates");
        Ok::<(), CallError>(())
    });
    match sent.stopped {
        None => {
            let value = json!({
                "dir": dir_text, "install": install, "sent": sent.records, "batches": sent.batches,
                "accepted": accepted, "duplicates": duplicates,
            });
            let human = messages
                .uploaded
                .replace("{records}", &sent.records.to_string())
                .replace("{batches}", &sent.batches.to_string())
                .replace("{accepted}", &accepted.to_string())
                .replace("{duplicates}", &duplicates.to_string());
            print(output, &value, &human)
        }
        Some(Stop::Send(error)) => Refusal {
            code: refusal_code(&error),
            message: messages
                .upload_refused
                .replace("{records}", &sent.records.to_string())
                .replace("{reason}", &reason(&error)),
            exit: 1,
        }
        .print(output),
        Some(Stop::Cursor(error)) => Refusal {
            code: "usage.cursor_failed",
            message: messages
                .cursor_failed
                .replace("{records}", &sent.records.to_string())
                .replace("{error}", &error.to_string()),
            exit: 1,
        }
        .print(output),
    }
}

/// `cmux usage delete-shared`: every record the caller shared, in every sharing team. The local
/// upload cursor stays, so sharing again does not send the deleted records back.
pub(super) fn delete_shared(
    output: OutputMode,
    global: &GlobalArgs,
    credential_stdin: bool,
) -> i32 {
    let messages = &crate::localization::catalog().usage_recording;
    let platform = match access(global, credential_stdin).and_then(|access| connect(&access)) {
        Ok(platform) => platform,
        Err(refusal) => return refusal.print(output),
    };
    match platform.delete(RECORDS_PATH) {
        Ok(answer) => {
            let deleted = answer.get("deleted").and_then(Value::as_u64).unwrap_or(0);
            let human = messages.deleted.replace("{deleted}", &deleted.to_string());
            print(output, &json!({ "deleted": deleted }), &human)
        }
        Err(error) => Refusal {
            code: refusal_code(&error),
            message: messages.delete_refused.replace("{reason}", &reason(&error)),
            exit: 1,
        }
        .print(output),
    }
}

fn connect(access: &Access) -> Result<Platform, Refusal> {
    Platform::new(access.platform.clone(), access.credential.clone(), CALL_TIMEOUT)
        .map_err(|failure| Refusal { code: "usage.internal", message: failure.message, exit: 1 })
}

/// The platform and token: from stdin with `--credential-stdin`, else from the app.
fn access(global: &GlobalArgs, credential_stdin: bool) -> Result<Access, Refusal> {
    let env = |key: &str| std::env::var(key).ok();
    if credential_stdin {
        let mut text = String::new();
        let read = std::io::stdin().lock().take(STDIN_LIMIT).read_to_string(&mut text);
        return read.ok().and_then(|_| access_from_stdin(&text)).ok_or_else(|| Refusal {
            code: "usage.invalid",
            message: crate::localization::catalog().usage_recording.bad_credential_stdin.into(),
            exit: 2,
        });
    }
    let mut stream = super::app::connect_command(global).map_err(|error| Refusal {
        code: "app.unreachable",
        message: error.get("message").and_then(Value::as_str).unwrap_or("").to_owned(),
        exit: 3,
    })?;
    let token = match super::app::request(&mut stream, "auth.token", json!({}), AUTH_TOKEN_TIMEOUT)
    {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            let text = |key: &str| error.get(key).and_then(Value::as_str).map(str::to_owned);
            let code = match text("code").as_deref() {
                Some("not_signed_in") => "not_signed_in",
                Some("no_team") => "no_team",
                _ => "auth.refused",
            };
            return Err(Refusal { code, message: text("message").unwrap_or_default(), exit: 3 });
        }
        Err(message) => return Err(Refusal { code: "app.transport", message, exit: 3 }),
    };
    access_from_token(&token, &env).ok_or_else(|| Refusal {
        code: "app.invalid_response",
        message: crate::localization::catalog().usage_recording.no_token.into(),
        exit: 1,
    })
}

/// `{"platform": URL, "credential": TOKEN}` from the app; the platform must be https (or
/// loopback).
pub(super) fn access_from_stdin(text: &str) -> Option<Access> {
    let value: Value = serde_json::from_str(text.trim()).ok()?;
    let platform = value.get("platform").and_then(Value::as_str)?;
    let credential = plain_token(value.get("credential").and_then(Value::as_str)?)?;
    let platform = cmux_cloud_api::session::secure_origin(platform.trim()).ok()?;
    Some(Access { platform, credential })
}

/// The app's `auth.token` answer as an [`Access`]: `CMUX_PLATFORM_URL` when set, else the
/// platform of the deployment whose API issued the token, else production.
pub(super) fn access_from_token(
    token: &Value,
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<Access> {
    let credential = plain_token(token.get("access_token").and_then(Value::as_str)?)?;
    let from_api = token
        .get("api_origin")
        .and_then(Value::as_str)
        .and_then(|api| cmux_cloud_environment::Environment::parse(api).ok())
        .map(|environment| environment.configuration().platform_origin);
    let raw = env(PLATFORM_ENV)
        .filter(|raw| !raw.trim().is_empty())
        .or(from_api)
        .unwrap_or_else(|| cmux_cloud_environment::PRODUCTION_PLATFORM.to_owned());
    let platform = cmux_cloud_api::session::secure_origin(raw.trim()).ok()?;
    Some(Access { platform, credential })
}

fn plain_token(token: &str) -> Option<String> {
    (!token.is_empty() && !token.contains(char::is_whitespace)).then(|| token.to_owned())
}

/// The error code a refusal prints: the platform's own code when it gave a known one.
fn refusal_code(error: &CallError) -> &'static str {
    match error {
        CallError::Status { code, .. } if !code.is_empty() => code,
        CallError::Status { .. } | CallError::Unreadable(_) => "usage.refused",
        CallError::Unreachable(_) => "usage.unreachable",
    }
}

/// What the platform answered, for the message: its status and code, or why there was none.
fn reason(error: &CallError) -> String {
    match error {
        CallError::Status { status, code } => format!("{status} {code}").trim_end().to_owned(),
        CallError::Unreadable(status) => format!("{status}"),
        CallError::Unreachable(why) => why.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdin_access_takes_an_https_platform_and_a_plain_token() {
        assert_eq!(
            access_from_stdin(r#"{"platform":"https://p.example/","credential":"tok"}"#),
            Some(Access { platform: "https://p.example".into(), credential: "tok".into() })
        );
        assert_eq!(
            access_from_stdin(r#"{"platform":"http://p.example","credential":"tok"}"#),
            None
        );
        assert_eq!(
            access_from_stdin(r#"{"platform":"https://p.example","credential":"a b"}"#),
            None
        );
        assert_eq!(access_from_stdin(r#"{"platform":"https://p.example"}"#), None);
        assert_eq!(access_from_stdin("tok"), None);
    }

    #[test]
    fn the_platform_follows_the_api_that_issued_the_token() {
        let none = |_: &str| None;
        let token = |api: &str| json!({ "access_token": "tok", "api_origin": api });
        let dev = access_from_token(&token(cmux_cloud_environment::DEVELOPMENT_API), &none);
        assert_eq!(
            dev.map(|a| a.platform),
            Some(cmux_cloud_environment::DEVELOPMENT_PLATFORM.to_owned())
        );
        let prod = access_from_token(&token(cmux_cloud_environment::PRODUCTION_API), &none);
        assert_eq!(
            prod.map(|a| a.platform),
            Some(cmux_cloud_environment::PRODUCTION_PLATFORM.to_owned())
        );
        let unknown = access_from_token(&token("https://elsewhere.example"), &none);
        assert_eq!(
            unknown.map(|a| a.platform),
            Some(cmux_cloud_environment::PRODUCTION_PLATFORM.to_owned())
        );
        let env = |key: &str| (key == PLATFORM_ENV).then(|| "https://mine.example".to_owned());
        let overridden = access_from_token(&token(cmux_cloud_environment::DEVELOPMENT_API), &env);
        assert_eq!(overridden.map(|a| a.platform), Some("https://mine.example".to_owned()));
        assert_eq!(access_from_token(&json!({ "api_origin": "x" }), &none), None);
    }

    #[test]
    fn a_refusal_names_the_platform_code() {
        let invalid = CallError::Status { status: 400, code: "usage.invalid" };
        assert_eq!(refusal_code(&invalid), "usage.invalid");
        assert_eq!(reason(&invalid), "400 usage.invalid");
        let bare = CallError::Status { status: 502, code: "" };
        assert_eq!(refusal_code(&bare), "usage.refused");
        assert_eq!(reason(&bare), "502");
        assert_eq!(refusal_code(&CallError::Unreachable("dns".into())), "usage.unreachable");
    }
}
