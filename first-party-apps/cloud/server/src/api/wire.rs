//! One op request as the app supervisor sends it (`apps-run`: op, args,
//! idempotency key; the origin is stamped by the supervisor).

use cmux_terminal_iface::OpenToken;
use serde::Deserialize;
use serde_json::Value;

/// Who started the request (OWNERSHIP-PRINCIPLES: absent = `cli`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// A person, with a gesture (palette, menu, native confirmation sheet).
    User,
    #[default]
    Cli,
    Mcp,
    Script,
    Remote,
    Agent,
}

impl Origin {
    /// The `cmux.wire/1` origin. `Agent` has none: the backend knows an
    /// agent by its token (`agt`), and the field stays out.
    pub fn wire_name(self) -> Option<&'static str> {
        Some(match self {
            Self::User => "user",
            Self::Cli => "cli",
            Self::Mcp => "mcp",
            Self::Script => "script",
            Self::Remote => "remote",
            Self::Agent => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Request {
    pub op: String,
    #[serde(default)]
    pub args: Value,
    #[serde(default)]
    pub origin: Origin,
    #[serde(default)]
    pub idempotency_key: Option<String>,
    /// Issued by the host after the user's gesture for one terminal open
    /// (`cloud.rescue.open`); stamped on the op line like `origin`. The
    /// server checks that it is there and passes it on; it never mints one.
    #[serde(default)]
    pub open_token: Option<OpenToken>,
}

impl Request {
    pub fn new(op: &str, args: Value) -> Self {
        Self {
            op: op.to_owned(),
            args,
            origin: Origin::Cli,
            idempotency_key: None,
            open_token: None,
        }
    }

    pub fn origin(mut self, origin: Origin) -> Self {
        self.origin = origin;
        self
    }

    pub fn key(mut self, key: &str) -> Self {
        self.idempotency_key = Some(key.to_owned());
        self
    }

    pub fn open_token(mut self, token: &str) -> Self {
        self.open_token = Some(OpenToken(token.to_owned()));
        self
    }
}
