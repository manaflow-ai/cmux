//! The worker's view of upstream Cua Driver: one in-process runtime with an
//! immutable authorization ceiling, and one trusted, connection-bound session
//! per agent connection (`cua_driver_session_create_v1` on macOS;
//! `CuaDriver::create_trusted_session` here). Behind a trait so the protocol
//! tests run without a desktop.

use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

/// The upstream mode of one session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionMode {
    Standard,
    Bounded,
    Unrestricted,
}

/// The runtime's ceiling, fixed for the worker's life (a mode change restarts it).
#[derive(Clone, Debug)]
pub struct Ceiling {
    pub allowed: Vec<SessionMode>,
    pub compatibility: SessionMode,
    /// Required when `compatibility` is bounded: an empty manifest.
    pub compatibility_manifest: Option<PathBuf>,
    pub unrestricted_acknowledged: bool,
    pub max_session_ttl_seconds: u64,
    pub max_idle_ttl_seconds: u64,
}

#[derive(Clone, Debug)]
pub struct SessionSpec {
    pub public_session: String,
    pub mode: SessionMode,
    pub manifest: Option<PathBuf>,
    pub ttl_seconds: u64,
    pub idle_ttl_seconds: u64,
}

/// A failed call: upstream's message and machine code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CallError {
    pub message: String,
    pub code: Option<String>,
}

impl CallError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { message: message.into(), code: Some(code.to_owned()) }
    }
}

/// A residual boundary upstream asks the host about (standard mode).
#[derive(Clone, Debug)]
pub struct Residual {
    pub public_session: String,
    pub adapter: String,
    pub risk: String,
    pub resource: Value,
    pub digest: String,
}

/// The worker's answer to a residual boundary.
#[async_trait]
pub trait ResidualAuthority: Send + Sync {
    /// True to allow, false to deny; None cancels.
    async fn authorize(&self, residual: Residual) -> Option<bool>;
}

#[async_trait]
pub trait DriverSession: Send + Sync {
    /// The tool's MCP-shaped result (`content`, `isError`, `structuredContent`).
    async fn call(&self, tool: &str, arguments: Value) -> Result<Value, CallError>;
    fn close(&self);
}

#[async_trait]
pub trait Driver: Send + Sync {
    /// The inventory: an array of MCP tool descriptions.
    async fn tools(&self) -> Result<Value, String>;
    fn session(&self, spec: &SessionSpec) -> Result<Arc<dyn DriverSession>, String>;
}

/// Every call refused: the driver did not start (the reason is the error).
pub struct Unavailable(pub String);

#[async_trait]
impl Driver for Unavailable {
    async fn tools(&self) -> Result<Value, String> {
        Ok(json!([]))
    }
    fn session(&self, _spec: &SessionSpec) -> Result<Arc<dyn DriverSession>, String> {
        Err(self.0.clone())
    }
}

#[cfg(feature = "driver")]
pub use cua::CuaDriverRuntime;

#[cfg(feature = "driver")]
mod cua {
    use super::*;
    use cua_driver_sdk::{
        ConfiguredDriverOptions, CuaDriver, CuaDriverSession, DriverAuthorizationAction, DriverAuthorizationDecision,
        DriverAuthorizationHost, DriverAuthorizationHostError, DriverAuthorizationRequest, DriverError,
        RuntimeAuthorizationOptions, SessionPermissionMode, ToolResult, TrustedSessionOptions,
    };

    fn upstream(mode: SessionMode) -> SessionPermissionMode {
        match mode {
            SessionMode::Standard => SessionPermissionMode::Standard,
            SessionMode::Bounded => SessionPermissionMode::Bounded,
            SessionMode::Unrestricted => SessionPermissionMode::Unrestricted,
        }
    }

    struct Host(Arc<dyn ResidualAuthority>);

    #[async_trait]
    impl DriverAuthorizationHost for Host {
        async fn authorize(
            &self,
            request: DriverAuthorizationRequest,
        ) -> Result<DriverAuthorizationDecision, DriverAuthorizationHostError> {
            let residual = Residual {
                public_session: request.public_session.clone(),
                adapter: request.adapter_id.clone(),
                risk: request.risk_class.clone(),
                resource: serde_json::from_str(&request.resource_json).unwrap_or(Value::Null),
                digest: request.request_digest.clone(),
            };
            let action = match self.0.authorize(residual).await {
                Some(true) => DriverAuthorizationAction::Allow,
                Some(false) => DriverAuthorizationAction::Deny,
                None => DriverAuthorizationAction::Cancel,
            };
            Ok(DriverAuthorizationDecision { action, request_digest: request.request_digest })
        }
    }

    /// Upstream Cua Driver in this process.
    pub struct CuaDriverRuntime {
        driver: Arc<CuaDriver>,
    }

    impl CuaDriverRuntime {
        pub fn create(ceiling: &Ceiling, residual: Arc<dyn ResidualAuthority>) -> Result<Self, String> {
            let options = ConfiguredDriverOptions {
                claude_code_compatibility: false,
                authorization: RuntimeAuthorizationOptions {
                    allowed_modes: ceiling.allowed.iter().copied().map(upstream).collect(),
                    compatibility_mode: upstream(ceiling.compatibility),
                    compatibility_capability_manifest_path: ceiling
                        .compatibility_manifest
                        .as_ref()
                        .map(|path| path.display().to_string()),
                    compatibility_bounded_manifest_path: None,
                    unrestricted_acknowledged: ceiling.unrestricted_acknowledged,
                    max_session_ttl_seconds: ceiling.max_session_ttl_seconds,
                    max_idle_ttl_seconds: ceiling.max_idle_ttl_seconds,
                },
            };
            let driver = CuaDriver::create_configured_with_authorization_host(options, Arc::new(Host(residual)))
                .map_err(|error| error.to_string())?;
            Ok(Self { driver })
        }
    }

    #[async_trait]
    impl Driver for CuaDriverRuntime {
        async fn tools(&self) -> Result<Value, String> {
            let text = self.driver.list_tools_json().await.map_err(|error| error.to_string())?;
            let inventory: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
            Ok(match inventory {
                Value::Object(mut object) if object.contains_key("tools") => object.remove("tools").unwrap_or_default(),
                other => other,
            })
        }

        fn session(&self, spec: &SessionSpec) -> Result<Arc<dyn DriverSession>, String> {
            let session = self
                .driver
                .create_trusted_session(TrustedSessionOptions {
                    public_session: spec.public_session.clone(),
                    mode: upstream(spec.mode),
                    ttl_seconds: spec.ttl_seconds,
                    idle_ttl_seconds: spec.idle_ttl_seconds,
                    capability_manifest_path: spec.manifest.as_ref().map(|path| path.display().to_string()),
                    bounded_manifest_path: None,
                })
                .map_err(|error| error.to_string())?;
            Ok(Arc::new(Session(session)))
        }
    }

    struct Session(Arc<CuaDriverSession>);

    #[async_trait]
    impl DriverSession for Session {
        async fn call(&self, tool: &str, arguments: Value) -> Result<Value, CallError> {
            match self.0.call_tool(tool.to_owned(), arguments.to_string()).await {
                Ok(result) if result.is_error && result.error_code.is_some() => Err(CallError {
                    message: result.text.clone(),
                    code: result.error_code.clone(),
                }),
                Ok(result) => Ok(mcp_result(&result)),
                Err(DriverError::Tool { message, error_code, .. }) => {
                    Err(CallError { message, code: Some(error_code) })
                }
                Err(DriverError::Shutdown) => Err(CallError::new("session_closed", "the session was revoked")),
                Err(error) => Err(CallError { message: error.to_string(), code: None }),
            }
        }

        fn close(&self) {
            self.0.close();
        }
    }

    fn mcp_result(result: &ToolResult) -> Value {
        let mut content = Vec::new();
        if !result.text.is_empty() {
            content.push(json!({"type": "text", "text": result.text}));
        }
        for image in &result.images {
            content.push(json!({"type": "image", "data": image.data_base64, "mimeType": image.mime_type}));
        }
        let mut value = json!({"content": content, "isError": result.is_error});
        if let Some(structured) = result.structured_json.as_deref().and_then(|text| serde_json::from_str::<Value>(text).ok()) {
            value["structuredContent"] = structured;
        }
        value
    }
}
