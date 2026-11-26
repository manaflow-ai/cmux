//! Composer reservations use the person's Stack session and selected team. A bind whose
//! answer was lost is retried with the same send key; it must never become a cold create.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{Flags, percent_segment, refused, valid_environment, valid_key};
use crate::cli::{Platform, PlatformCallError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Action {
    Reserve,
    Bind,
    Release,
}

pub(super) struct Call {
    pub(super) action: Action,
    pub(super) compose_key: String,
    pub(super) send_key: Option<String>,
    pub(super) environment: Option<String>,
    pub(super) platform: Option<String>,
    pub(super) team: Option<String>,
}

pub(super) type Transport<'a> = &'a dyn Fn(&Call, &str) -> Result<Value, PlatformCallError>;

impl Call {
    pub(super) fn bind_payload(&self) -> Value {
        let mut body = json!({"sendKey": self.send_key});
        if let Some(environment) = &self.environment {
            body.set("environment", json!(environment));
        }
        body
    }

    pub(super) fn post(&self, credential: &str) -> Result<Value, PlatformCallError> {
        let unreachable = PlatformCallError::Unreachable;
        let origin =
            crate::cli::platform_origin(self.platform.as_deref(), &|name| std::env::var(name).ok())
                .map_err(unreachable)?;
        let timeout = if self.action == Action::Release { 10 } else { 120 };
        let platform =
            Platform::new(origin, credential.to_string(), std::time::Duration::from_secs(timeout))
                .map_err(|error| unreachable(error.message))?
                .with_team(self.team.clone());
        let path = format!("/v1/machines/reservations/{}", percent_segment(&self.compose_key));
        match self.action {
            Action::Reserve => {
                let mut body = json!({"composeKey": self.compose_key});
                if let Some(environment) = &self.environment {
                    body.set("environment", json!(environment));
                }
                platform.post("/v1/machines/reservations", body)
            }
            Action::Bind => platform.post(&format!("{path}/bind"), self.bind_payload()),
            Action::Release => platform.delete(&path),
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    compose_key: String,
    environment: Option<String>,
    platform: Option<String>,
}

/// `reserve|release --request JSON`, stdin the session credential then the install token: the
/// reservation names the install token's team ([`super::spare_warm::install_team`]), the spare warm's team.
pub(super) fn run(
    flags: &Flags,
    action: Action,
    stdin: &mut dyn std::io::BufRead,
) -> Option<Value> {
    run_with(flags, action, stdin, &|call, credential| call.post(credential))
}

pub(super) fn run_with(
    flags: &Flags,
    action: Action,
    stdin: &mut dyn std::io::BufRead,
    transport: Transport<'_>,
) -> Option<Value> {
    let request: Request = match serde_json::from_str(flags.one("--request")?) {
        Ok(request) => request,
        Err(error) => return Some(refused("bad_request", error)),
    };
    if !valid_key(&request.compose_key)
        || request.environment.as_deref().is_some_and(|id| !valid_environment(id))
    {
        return Some(refused("bad_request", "invalid composer reservation"));
    }
    let mut credential = String::new();
    if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
        return Some(refused("unauthorized", "no session credential on stdin"));
    }
    let mut install = String::new();
    let _ = stdin.read_line(&mut install);
    let call = Call {
        action,
        compose_key: request.compose_key.to_lowercase(),
        send_key: None,
        environment: request.environment,
        platform: request.platform,
        team: super::spare_warm::install_team(&install),
    };
    let result = transport(&call, credential.trim());
    if action == Action::Reserve && result.as_ref().is_ok_and(|body| machine(body).is_none()) {
        return Some(refused("bad_answer", "the cmux platform reserved no readable Cloud machine"));
    }
    Some(answer(result))
}

pub(super) fn answer(result: Result<Value, PlatformCallError>) -> Value {
    match result {
        Ok(Value::Object(mut body)) => {
            body.insert("ok".into(), json!(true));
            Value::Object(body)
        }
        Ok(Value::Null) => json!({"ok": true}),
        Ok(_) => refused("bad_answer", "the cmux platform answered with no reservation"),
        Err(PlatformCallError::Status { status, code, facts }) => {
            let mut line = refused(
                if code.is_empty() { "refused" } else { code },
                format!(
                    "the cmux platform refused the reservation ({status} {code}){}",
                    crate::cli::platform_refusal_reason(code, facts.as_ref())
                ),
            );
            super::with_handling(&mut line, status, code, facts);
            line
        }
        Err(PlatformCallError::Unreachable(reason)) => refused("unreachable", reason),
        Err(PlatformCallError::Unreadable(status)) => refused(
            "bad_answer",
            format!("the cmux platform answered {status} with no readable body"),
        ),
    }
}

/// Only a definitive response saying this reservation cannot bind permits a cold create.
pub(super) fn unbound(error: &PlatformCallError) -> bool {
    matches!(
        error,
        PlatformCallError::Status { status: 404, code: "lease.not_found", .. }
            | PlatformCallError::Status {
                status: 409,
                code: "reservation.expired" | "reservation.terminal",
                ..
            }
    )
}

/// Only CloudDO carriers can attach through the NEXT machine routes.
pub(super) fn machine(body: &Value) -> Option<&str> {
    body.get("machine").and_then(Value::as_str).filter(|id| {
        id.strip_prefix("vm_").is_some_and(|suffix| {
            suffix.len() == 20
                && suffix.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
    })
}
