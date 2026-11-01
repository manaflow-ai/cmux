//! Owner-only turn preparation on a configured new-platform workspace machine.
use super::*;
use serde::Serialize;

pub const CAPABILITY: &str = "agent-session-turn-rewind-v1";

#[derive(Clone)]
pub struct CloudTurnConfig {
    workspace: String,
    machine: String,
}

impl CloudTurnConfig {
    /// Startup configuration only; never read from a prompt or session environment.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let origin = url::Url::parse(&get("CMUX_PLATFORM_ORIGIN")?).ok()?;
        let workspace = get("CMUX_PLATFORM_WORKSPACE_ID")?;
        let machine = get("CMUX_PLATFORM_MACHINE_ID")?;
        (origin.scheme() == "https"
            && origin.host_str().is_some()
            && origin.username().is_empty()
            && origin.password().is_none()
            && origin.query().is_none()
            && origin.fragment().is_none()
            && valid_id(&workspace)
            && valid_id(&machine))
        .then_some(Self { workspace, machine })
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Prepare {
    pub surface: SurfaceId,
    prompt_id: String,
    workspace: String,
    machine: String,
    generation: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Abandon {
    pub surface: SurfaceId,
    prompt_id: String,
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
    let mux = attachment.mux.upgrade().ok_or(Refusal::Unavailable)?;
    let result = mux
        .control_clients
        .agent_sessions
        .cloud_turn
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or(Refusal::Unavailable);
    result
}

pub(super) fn prepare(attachment: &Attachment, request: Prepare) -> Result<Value, Refusal> {
    let config = configured(attachment)?;
    if !valid_prompt_id(&request.prompt_id)
        || request.workspace != config.workspace
        || request.machine != config.machine
    {
        return Err(Refusal::BadRequest);
    }
    // This waits on a bounded attachment worker; cancel and other frames stay responsive.
    // Closing the attachment closes its dedicated acpmux link and releases this wait.
    attachment.link.call_until_closed("agent-session-turn-prepare", json!({
        "sessionId": attachment.session, "prompt_id": request.prompt_id,
        "workspace": request.workspace, "machine": request.machine, "generation": request.generation,
    })).map_err(Refusal::of)
}

pub(super) fn abandon(attachment: &Attachment, request: Abandon) -> Result<Value, Refusal> {
    configured(attachment)?;
    if !valid_prompt_id(&request.prompt_id) {
        return Err(Refusal::BadRequest);
    }
    attachment
        .link
        .call(
            "agent-session-turn-abandon",
            json!({
                "sessionId": attachment.session, "prompt_id": request.prompt_id,
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
        (None, None) => Ok(None),
        (Some(config), Some(value))
            if attachment.author.is_none()
                && value.workspace == config.workspace
                && value.machine == config.machine
                && value.session == attachment.session
                && valid_id(&value.turn)
                && valid_id(&value.team)
                && valid_id(&value.user)
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
            && self
                .control_clients
                .agent_sessions
                .cloud_turn
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .is_some()
    }
}
