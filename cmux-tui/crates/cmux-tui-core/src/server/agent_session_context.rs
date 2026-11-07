//! Owner-only context access through an already attached tab. The daemon's
//! local acpmux link retains local origin policy; remote clients cannot name
//! an arbitrary session or project directory.
use super::*;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
pub(super) enum Params {
    Get {
        surface: SurfaceId,
    },
    Set {
        surface: SurfaceId,
        scope: Scope,
        #[serde(default)]
        text: Option<String>,
        #[serde(default, rename = "partId")]
        part_id: Option<Part>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Scope {
    User,
    Project,
}

#[derive(Deserialize)]
pub(super) enum Part {
    #[serde(rename = "cmux-system-prompt")]
    SystemPrompt,
}

impl Params {
    pub(super) fn surface(&self) -> SurfaceId {
        match self {
            Self::Get { surface } | Self::Set { surface, .. } => *surface,
        }
    }
}

pub(super) fn call(attachment: &Attachment, params: Params) -> Result<Value, Refusal> {
    let session = &attachment.session;
    let (method, params) = match params {
        Params::Get { .. } => ("_acpmux/context", json!({"sessionId": session})),
        Params::Set { scope, text, part_id, .. } => {
            let scope = match scope {
                Scope::User => "user",
                Scope::Project => "project",
            };
            // acpmux derives the project directory from this session's metadata.
            let mut params = json!({"sessionId": session, "scope": scope, "text": text});
            if let Some(Part::SystemPrompt) = part_id {
                params["partId"] = json!("cmux-system-prompt");
            }
            ("_acpmux/context_override", params)
        }
    };
    attachment.link.call(method, params, CALL_TIMEOUT).map_err(Refusal::of)
}
