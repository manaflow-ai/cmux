//! A Cloud machine's short-lived client session (shared by `cmux machine access` and
//! [`crate::machine_io`]): the mint `POST /v1/cloud/machines/{machine}/client-session`, its
//! checks, the provider's `exec-await` answer and the refusal codes a caller may print. Moved
//! from the cmux CLI's `cloud_client_session.rs` unchanged.

use std::time::Duration;

use cmux_cloud_client::machine::{Machine, Scope};
use serde_json::{Value, json};

pub const IDENTITY_HEADER: &str = "x-freestyle-identity-access-token";
pub const TEAM_HEADER: &str = "x-cmux-team";
const MINT_TIMEOUT: Duration = Duration::from_secs(30);

pub fn valid_machine(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// `https://…`, or `http://` only to this machine (a local API in development); no trailing slash.
/// Errors never echo the URL (it could hold a secret someone pasted into it).
pub fn secure_origin(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "the cmux API is not a URL".to_owned())?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(
            "the cmux API URL must be a bare origin (no user, path, query or fragment)".into()
        );
    }
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err("the cmux API is not https: a credential never goes over plain http".into());
    }
    Ok(url.origin().ascii_serialization())
}

/// One minted session (the server's `value`).
#[derive(Debug, serde::Deserialize)]
pub struct Session {
    pub machine: String,
    pub vm_id: String,
    pub linux_user: String,
    pub token: String,
    pub expires_at: u64,
    pub api_base_url: String,
    pub ssh: Option<SshLine>,
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub struct SshLine {
    pub host: String,
    pub user: String,
}

/// A checked `exec-await` answer (Freestyle's `ExecResponse`: every field optional and nullable).
#[derive(Debug, PartialEq, Eq)]
pub struct ExecAnswer {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// The answer, or an error when it is not an object or a field has the wrong type. A missing or
/// null `statusCode` means the guest killed the command at its deadline: 124, as `timeout` says.
pub fn exec_answer(body: Option<Value>) -> Result<ExecAnswer, String> {
    let unreadable = || "the machine's answer is not readable".to_owned();
    let body = body.filter(Value::is_object).ok_or_else(unreadable)?;
    let text = |key: &str| match body.get(key) {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(_) => Err(unreadable()),
    };
    let exit_code = match body.get("statusCode") {
        None | Some(Value::Null) => 124,
        Some(code) => code
            .as_i64()
            .and_then(|c| i32::try_from(c).ok())
            .ok_or("the machine's answer has no readable exit status")?,
    };
    Ok(ExecAnswer { exit_code, stdout: text("stdout")?, stderr: text("stderr")? })
}

/// Why a mint gave no session: the HTTP status (0: no answer, or an answer that is not a
/// session) and the refusal code from [`KNOWN_CODES`] (empty for any other), with a message that
/// carries neither secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MintRefusal {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
}

/// `POST {api}/v1/cloud/machines/{machine}/client-session` as `credential` on `machine`'s own
/// backend and team (a handle another scope named is refused before sending), checked by
/// [`checked_session`]. Shared by `cloud client-session` and `cloud machine-io`.
pub async fn mint_session(
    client: &reqwest::Client,
    scope: &Scope,
    credential: &str,
    machine: &Machine,
    ttl: Option<u64>,
) -> Result<Session, MintRefusal> {
    let refused =
        |status: u16, code: &'static str, message: String| MintRefusal { status, code, message };
    let url = scope
        .route(machine, "/client-session")
        .map_err(|foreign| refused(0, "", foreign.to_string()))?;
    let mut request = client
        .post(url)
        .bearer_auth(credential)
        .timeout(MINT_TIMEOUT)
        .json(&ttl.map_or_else(|| json!({}), |ttl| json!({ "ttl_seconds": ttl })));
    if let Some(team) = scope.team() {
        request = request.header(TEAM_HEADER, team);
    }
    let response = request
        .send()
        .await
        .map_err(|e| refused(0, "", format!("the cmux API did not answer: {}", e.without_url())))?;
    let status = response.status();
    /// A session grant is a few hundred bytes; more is not one.
    const MINT_ANSWER_BYTES: usize = 1024 * 1024;
    let body = crate::http::bounded_json(response, MINT_ANSWER_BYTES).await.ok_or_else(|| {
        refused(
            status.as_u16(),
            "",
            format!("the cmux API answered {status} with no readable body"),
        )
    })?;
    if !status.is_success() || body.get("ok") != Some(&Value::Bool(true)) {
        // Only a code this command knows, printed from its own table: nothing the answer
        // carries (a credential a proxy or a broken server echoed) reaches the terminal.
        let code = body.get("error").and_then(|e| e.get("code")).and_then(Value::as_str);
        let code = known_code(code);
        // A credential that happens to spell a known code is still never printed.
        let code = if code.contains(credential) { "" } else { code };
        let message = format!("the cmux API refused the client session: {status} {code}");
        return Err(refused(status.as_u16(), code, message));
    }
    let session: Session = serde_json::from_value(body.get("value").cloned().unwrap_or_default())
        .map_err(|_| {
        refused(0, "", "the cmux API's answer is not a client session".to_owned())
    })?;
    checked_session(session, machine.id(), credential).map_err(|message| refused(0, "", message))
}

/// The session when it is for `machine`, every field this command prints is plain (no secret can
/// hide in it), and the token goes only to the provider's API: https on freestyle.sh, or this
/// machine (a fake in development), with no user, query or fragment.
pub fn checked_session(
    session: Session,
    machine: &str,
    credential: &str,
) -> Result<Session, String> {
    let bad = |what: &str| Err(format!("the cmux API's answer has an unusable {what}"));
    if session.machine != machine {
        return bad("machine");
    }
    // Neither secret is in any field this command prints, and the token is not the credential.
    let secret_free = |v: &str| !v.contains(session.token.as_str()) && !v.contains(credential);
    // The expiry is printed too (milliseconds in JSON, seconds for people): a numeric secret could hide in it.
    let expiry_ms = session.expires_at.to_string();
    let expiry_s = session.expires_at.checked_div(1000).unwrap_or_default().to_string();
    let mut printed = vec![
        session.machine.as_str(),
        session.vm_id.as_str(),
        session.linux_user.as_str(),
        session.api_base_url.as_str(),
        expiry_ms.as_str(),
        expiry_s.as_str(),
    ];
    if let Some(ssh) = &session.ssh {
        printed.extend([ssh.host.as_str(), ssh.user.as_str()]);
    }
    if session.token.contains(credential) || !printed.into_iter().all(secret_free) {
        return bad("token");
    }
    let plain = |v: &str, extra: &[u8], max: usize| {
        !v.is_empty()
            && v.len() <= max
            && v.bytes().all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
            && !v.contains(session.token.as_str())
            && !v.contains(credential)
    };
    if session.token.is_empty() || !plain(&session.vm_id, b"-_", 64) {
        return bad("VM id");
    }
    let user_ok =
        session.linux_user.bytes().next().is_some_and(|b| b.is_ascii_lowercase() || b == b'_')
            && plain(&session.linux_user, b"-_", 32)
            && session.linux_user.bytes().all(|b| !b.is_ascii_uppercase());
    if !user_ok {
        return bad("Linux user");
    }
    if let Some(ssh) = &session.ssh {
        let host_ok =
            plain(&ssh.host, b"-.", 253) && ssh.host.bytes().all(|b| !b.is_ascii_uppercase());
        if !host_ok || ssh.user != format!("{}+{}", session.vm_id, session.linux_user) {
            return bad("SSH line");
        }
    }
    let url = reqwest::Url::parse(&session.api_base_url)
        .map_err(|_| "the cmux API's answer has an unusable provider API".to_owned())?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let freestyle = url.scheme() == "https"
        && url.host_str().is_some_and(|h| h == "freestyle.sh" || h.ends_with(".freestyle.sh"));
    let bare = url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    if !bare || !(freestyle || (local && matches!(url.scheme(), "http" | "https"))) {
        return bad("provider API");
    }
    Ok(session)
}

/// The cmux API's client-session refusal codes. `known_code` prints only these and the codes of
/// cmux-platform's Cloud refusal table ([`cmux_cloud_machine::refusals::PLATFORM`]: the VM limit,
/// a rate limit, a machine's state), each from its own table.
const KNOWN_CODES: [&str; 19] = [
    // The machine exec route's refusals (cmux-platform MachineGuest.ts GUEST_REFUSAL).
    "vm_not_found",
    "vm_forbidden",
    "vm_not_running",
    "vm_unavailable",
    "vm_busy",
    "vm_output_too_large",
    "auth.unauthenticated",
    "auth.forbidden",
    "owner.unreachable",
    "cloud.machine.not_found",
    "cloud.machine.paused",
    "cloud.machine.not_running",
    "cloud.plan.required",
    "cloud.rate_limited",
    "cloud.provider.unsupported",
    "cloud.provider.unavailable",
    "validation.invalid",
    "team.not_member",
    "auth.sso_required",
];

/// The table's copy of `code` when the code is one this command knows, else nothing.
pub fn known_code(code: Option<&str>) -> &'static str {
    code.and_then(|c| {
        KNOWN_CODES
            .iter()
            .copied()
            .find(|known| *known == c)
            .or_else(|| cmux_cloud_machine::refusals::platform_code(c))
    })
    .unwrap_or("")
}

/// `text` with every occurrence of the token and the credential replaced.
pub fn redact(text: &str, token: &str, credential: &str) -> String {
    let mut text = text.to_owned();
    for secret in [token, credential] {
        if !secret.is_empty() {
            text = text.replace(secret, "[redacted]");
        }
    }
    text
}
