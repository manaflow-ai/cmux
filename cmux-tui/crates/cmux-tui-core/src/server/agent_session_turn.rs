//! Owner-only turn preparation on a configured new-platform workspace machine.
use super::*;
use serde::Serialize;

pub const CAPABILITY: &str = "agent-session-turn-rewind-v1";
const DEFAULT_PREPARE_WINDOW_MS: u64 = 120_000;
const MAX_PREPARE_WINDOW_MS: u64 = 600_000;

#[derive(Clone)]
pub struct CloudTurnConfig {
    workspace: String,
    machine: String,
}

impl CloudTurnConfig {
    /// Startup configuration only; never read from a prompt or session environment.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, &'static str> {
        let workspace = get("CMUX_PLATFORM_WORKSPACE_ID");
        let machine = get("CMUX_PLATFORM_MACHINE_ID");
        // The origin alone is also used by ordinary Cloud CLI clients. A workspace or machine
        // scope opts this daemon into fenced turns; partial configuration must never disable it.
        if workspace.is_none() && machine.is_none() {
            return Ok(None);
        }
        let invalid = "incomplete or invalid Cloud turn configuration";
        let workspace = workspace.ok_or(invalid)?;
        let machine = machine.ok_or(invalid)?;
        let origin =
            url::Url::parse(&get("CMUX_PLATFORM_ORIGIN").ok_or(invalid)?).map_err(|_| invalid)?;
        if origin.scheme() == "https"
            && origin.host_str().is_some()
            && origin.path() == "/"
            && origin.username().is_empty()
            && origin.password().is_none()
            && origin.query().is_none()
            && origin.fragment().is_none()
            && valid_id(&workspace)
            && valid_id(&machine)
        {
            Ok(Some(Self { workspace, machine }))
        } else {
            Err(invalid)
        }
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
}

pub(super) fn support(link: &AcpmuxLink) -> Result<bool, Refusal> {
    let initialized =
        link.call("initialize", json!({"protocolVersion":1}), CALL_TIMEOUT).map_err(Refusal::of)?;
    let capabilities = initialized
        .pointer("/_meta/acpmux/capabilities")
        .and_then(Value::as_array)
        .filter(|caps| caps.iter().all(Value::is_string))
        .ok_or(Refusal::Unavailable)?;
    Ok(capabilities.iter().any(|cap| cap.as_str() == Some(CAPABILITY)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Prepare {
    pub surface: SurfaceId,
    prompt_id: String,
    workspace: String,
    machine: String,
    generation: u64,
    attempt_id: String,
    authorization: Capability,
    #[serde(default)]
    deadline_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Abandon {
    pub surface: SurfaceId,
    prompt_id: String,
    workspace: String,
    machine: String,
    generation: u64,
    attempt_id: String,
    authorization: Capability,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Capability {
    capability: String,
    team: String,
    user: String,
    workspace: String,
    machine: String,
    generation: u64,
    session: String,
    turn: String,
    #[serde(rename = "expiresAt")]
    expires_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    purpose: Option<String>,
    #[serde(rename = "attemptId", skip_serializing_if = "Option::is_none")]
    attempt_id: Option<String>,
}

fn authorized(
    attachment: &Attachment,
    config: &CloudTurnConfig,
    proof: &Capability,
    prompt: &str,
    generation: u64,
    attempt: &str,
) -> bool {
    proof.workspace == config.workspace
        && proof.machine == config.machine
        && proof.session == attachment.session
        && proof.turn == prompt
        && proof.generation == generation
        && proof.purpose.as_deref() == Some("prepare")
        && proof.attempt_id.as_deref() == Some(attempt)
        && valid_id(attempt)
        && valid_id(&proof.team)
        && valid_id(&proof.user)
        && proof.capability.starts_with("trc_")
        && proof.capability.len() == 47
}

/// An explicit null or malformed envelope is an error, never an unfenced prompt.
pub(super) fn envelope<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<Capability>, D::Error> {
    Capability::deserialize(d).map(Some)
}

fn configured(attachment: &Attachment) -> Result<CloudTurnConfig, Refusal> {
    if attachment.author.is_some() {
        return Err(Refusal::NotTrusted);
    }
    if !attachment.cloud_turn_supported {
        return Err(Refusal::Unavailable);
    }
    let mux = attachment.mux.upgrade().ok_or(Refusal::Unavailable)?;
    mux.control_clients
        .agent_sessions
        .cloud_turn
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or(Refusal::Unavailable)
}

pub(super) fn prepare(attachment: &Attachment, request: Prepare) -> Result<Value, Refusal> {
    let config = configured(attachment)?;
    if !valid_prompt_id(&request.prompt_id)
        || request.workspace != config.workspace
        || request.machine != config.machine
        || !authorized(
            attachment,
            &config,
            &request.authorization,
            &request.prompt_id,
            request.generation,
            &request.attempt_id,
        )
    {
        return Err(Refusal::BadRequest);
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Refusal::Unavailable)?
        .as_millis() as u64;
    let deadline = request.deadline_ms.unwrap_or(now.saturating_add(DEFAULT_PREPARE_WINDOW_MS));
    let remaining = deadline
        .checked_sub(now)
        .filter(|ms| *ms > 0 && *ms <= MAX_PREPARE_WINDOW_MS)
        .ok_or(Refusal::BadRequest)?;
    // The daemon expires this exact reservation at the same deadline. The bounded worker
    // releases on deadline or attachment close; cancel remains responsive on another worker.
    attachment.link.call("agent-session-turn-prepare", json!({
        "sessionId": attachment.session, "prompt_id": request.prompt_id,
        "workspace": request.workspace, "machine": request.machine, "generation": request.generation,
        "attempt_id": request.attempt_id, "authorization": request.authorization,
        "deadline_ms": deadline,
    }), Duration::from_millis(remaining)).map_err(Refusal::of)
}

pub(super) fn abandon(attachment: &Attachment, request: Abandon) -> Result<Value, Refusal> {
    let config = configured(attachment)?;
    if !valid_prompt_id(&request.prompt_id)
        || request.workspace != config.workspace
        || request.machine != config.machine
        || !authorized(
            attachment,
            &config,
            &request.authorization,
            &request.prompt_id,
            request.generation,
            &request.attempt_id,
        )
    {
        return Err(Refusal::BadRequest);
    }
    attachment
        .link
        .call(
            "agent-session-turn-abandon",
            json!({
                "sessionId": attachment.session, "prompt_id": request.prompt_id,
                "workspace": request.workspace, "machine": request.machine, "generation": request.generation,
                "attempt_id": request.attempt_id, "authorization": request.authorization,
            }),
            CALL_TIMEOUT,
        )
        .map_err(Refusal::of)
}

pub(super) fn prompt_envelope(
    attachment: &Attachment,
    envelope: Option<Capability>,
) -> Result<Option<Value>, Refusal> {
    let config = attachment.mux.upgrade().and_then(|mux| {
        mux.control_clients
            .agent_sessions
            .cloud_turn
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    });
    match (config, envelope) {
        // Legacy and shared clients keep their existing prompt path. Only an explicit
        // envelope opts this request into the native capture/rewind protocol.
        (_, None) => Ok(None),
        (Some(config), Some(value))
            if attachment.author.is_none()
                && attachment.cloud_turn_supported
                && value.workspace == config.workspace
                && value.machine == config.machine
                && value.session == attachment.session
                && valid_id(&value.turn)
                && valid_id(&value.team)
                && valid_id(&value.user)
                && value.purpose.as_deref().is_none_or(|purpose| purpose == "execute")
                && value.attempt_id.as_deref().is_none_or(valid_id)
                && value.capability.starts_with("trc_")
                && value.capability.len() == 47 =>
        {
            serde_json::to_value(value).map(Some).map_err(|_| Refusal::BadRequest)
        }
        _ => Err(Refusal::BadRequest),
    }
}

impl Mux {
    pub fn set_cloud_turn_config(&self, config: Option<CloudTurnConfig>) {
        *self
            .control_clients
            .agent_sessions
            .cloud_turn
            .write()
            .unwrap_or_else(|e| e.into_inner()) = config;
    }
    pub(crate) fn serves_cloud_turns(&self) -> bool {
        self.serves_agent_session_attach()
            && self.control_clients.agent_sessions.lock().attachments.values().any(|attachment| {
                attachment.cloud_turn_supported && !attachment.ended.load(Ordering::Acquire)
            })
            && self
                .control_clients
                .agent_sessions
                .cloud_turn
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .is_some()
    }
}
