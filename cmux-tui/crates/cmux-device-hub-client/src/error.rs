//! Device hub failures. Server errors carry the protocol's code
//! (`{error:{code, message}}`) and the HTTP status.

use std::fmt;

/// The protocol's error codes (PROTOCOL.md, "Errors"); `Other` keeps a code
/// this build does not know.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    BadRequest,
    Unauthorized,
    NotFound,
    BadSignature,
    StaleTimestamp,
    Replay,
    DeviceRemoved,
    DeviceKeyMismatch,
    NotShared,
    PermissionNone,
    ScopeExceedsPermission,
    HostOffline,
    NotHost,
    SessionNotPending,
    SessionNotActive,
    TicketInvalid,
    RoleTaken,
    RateLimited,
    HostScope,
    NotAnchored,
    NotSelf,
    DevicePlatformMismatch,
    DigestMismatch,
    ApprovalExists,
    SelfApproval,
    NotApprover,
    NotAsker,
    ApprovalNotPending,
    ApprovalExpired,
    AlwaysNotAllowed,
    BadDecisionSignature,
    Internal,
    Other(String),
}

const TABLE: &[(ErrorCode, &str)] = &[
    (ErrorCode::BadRequest, "bad_request"),
    (ErrorCode::Unauthorized, "unauthorized"),
    (ErrorCode::NotFound, "not_found"),
    (ErrorCode::BadSignature, "bad_signature"),
    (ErrorCode::StaleTimestamp, "stale_timestamp"),
    (ErrorCode::Replay, "replay"),
    (ErrorCode::DeviceRemoved, "device_removed"),
    (ErrorCode::DeviceKeyMismatch, "device_key_mismatch"),
    (ErrorCode::NotShared, "not_shared"),
    (ErrorCode::PermissionNone, "permission_none"),
    (ErrorCode::ScopeExceedsPermission, "scope_exceeds_permission"),
    (ErrorCode::HostOffline, "host_offline"),
    (ErrorCode::NotHost, "not_host"),
    (ErrorCode::SessionNotPending, "session_not_pending"),
    (ErrorCode::SessionNotActive, "session_not_active"),
    (ErrorCode::TicketInvalid, "ticket_invalid"),
    (ErrorCode::RoleTaken, "role_taken"),
    (ErrorCode::RateLimited, "rate_limited"),
    (ErrorCode::HostScope, "host_scope"),
    (ErrorCode::NotAnchored, "not_anchored"),
    (ErrorCode::NotSelf, "not_self"),
    (ErrorCode::DevicePlatformMismatch, "device_platform_mismatch"),
    (ErrorCode::DigestMismatch, "digest_mismatch"),
    (ErrorCode::ApprovalExists, "approval_exists"),
    (ErrorCode::SelfApproval, "self_approval"),
    (ErrorCode::NotApprover, "not_approver"),
    (ErrorCode::NotAsker, "not_asker"),
    (ErrorCode::ApprovalNotPending, "approval_not_pending"),
    (ErrorCode::ApprovalExpired, "approval_expired"),
    (ErrorCode::AlwaysNotAllowed, "always_not_allowed"),
    (ErrorCode::BadDecisionSignature, "bad_decision_signature"),
    (ErrorCode::Internal, "internal"),
];

impl ErrorCode {
    pub fn parse(raw: &str) -> ErrorCode {
        TABLE
            .iter()
            .find(|(_, name)| *name == raw)
            .map(|(code, _)| code.clone())
            .unwrap_or_else(|| ErrorCode::Other(raw.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        if let ErrorCode::Other(raw) = self {
            return raw;
        }
        TABLE.iter().find(|(code, _)| code == self).map(|(_, name)| *name).unwrap_or("")
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A device hub failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HubError {
    /// No usable hub address: the feature is off.
    NotConfigured(String),
    /// No account token (signed out), or the hub refused it.
    NotSignedIn(String),
    /// The hub's `{error:{code, message}}`.
    Server {
        status: u16,
        code: ErrorCode,
        message: String,
    },
    /// An HTTP error without the protocol's error body.
    Http {
        status: u16,
    },
    Transport(String),
    Decoding(String),
    Identity(String),
}

impl HubError {
    /// The protocol code of a server error.
    pub fn code(&self) -> Option<&ErrorCode> {
        match self {
            HubError::Server { code, .. } => Some(code),
            _ => None,
        }
    }

    /// The hub cannot be reached or used at all (not a refusal of this call).
    pub fn is_unavailable(&self) -> bool {
        matches!(
            self,
            HubError::NotConfigured(_) | HubError::NotSignedIn(_) | HubError::Transport(_)
        )
    }

    /// A 401 about the account session rather than the device signature.
    pub(crate) fn is_account_refusal(&self) -> bool {
        match self {
            HubError::NotSignedIn(_) => true,
            HubError::Server { status: 401, code: ErrorCode::Unauthorized, .. } => true,
            HubError::Server { status: 401, code: ErrorCode::Other(raw), .. } => raw.is_empty(),
            _ => false,
        }
    }

    /// The error for a non-2xx answer with `body`.
    pub(crate) fn from_response(status: u16, body: &[u8]) -> HubError {
        #[derive(serde::Deserialize)]
        struct Envelope {
            error: Inner,
        }
        #[derive(serde::Deserialize)]
        struct Inner {
            #[serde(default)]
            code: String,
            #[serde(default)]
            message: String,
        }
        match serde_json::from_slice::<Envelope>(body) {
            Ok(envelope) => HubError::Server {
                status,
                code: ErrorCode::parse(&envelope.error.code),
                message: envelope.error.message,
            },
            Err(_) => HubError::Http { status },
        }
    }
}

impl fmt::Display for HubError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HubError::NotConfigured(detail) => {
                write!(f, "the device hub is not configured: {detail}")
            }
            HubError::NotSignedIn(detail) => write!(f, "not signed in to the device hub: {detail}"),
            HubError::Server { status, code, message } => {
                write!(f, "device hub {status} {code}: {message}")
            }
            HubError::Http { status } => write!(f, "device hub HTTP {status}"),
            HubError::Transport(detail) => write!(f, "device hub transport: {detail}"),
            HubError::Decoding(detail) => write!(f, "device hub answer: {detail}"),
            HubError::Identity(detail) => write!(f, "device identity: {detail}"),
        }
    }
}

impl std::error::Error for HubError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_the_error_body() {
        let error =
            HubError::from_response(403, br#"{"error":{"code":"self_approval","message":"no"}}"#);
        assert_eq!(error.code(), Some(&ErrorCode::SelfApproval));
        assert_eq!(HubError::from_response(502, b"<html>"), HubError::Http { status: 502 });
        assert_eq!(ErrorCode::parse("future_code").as_str(), "future_code");
        assert_eq!(ErrorCode::parse("device_platform_mismatch"), ErrorCode::DevicePlatformMismatch);
    }
}
