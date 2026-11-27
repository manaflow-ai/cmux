//! A failed cloud proxy reply as the Home sees it (`CloudReplyError.swift`,
//! home-cloud-proxy.md section 6): the rejection the store acts on, and
//! whether the daemon held no usable lease.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `HomeRejection`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Rejection {
    OwnerUnreachable,
    NotAuthorized,
    Invalid {
        reason: String,
    },
    #[serde(rename_all = "camelCase")]
    RateLimited {
        retry_after: Option<f64>,
    },
    Indeterminate,
}

impl Rejection {
    /// `HomeRejection.isRetryable`.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Rejection::OwnerUnreachable | Rejection::RateLimited { .. } | Rejection::Indeterminate
        )
    }

    /// The source's `isFinal`: an op the owner refused for good.
    pub fn is_final(&self) -> bool {
        matches!(self, Rejection::Invalid { .. } | Rejection::NotAuthorized)
    }
}

/// The error a cloud call failed with, as Swift reads it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ReplyError {
    /// `DaemonError.command`.
    #[serde(rename_all = "camelCase")]
    Command {
        #[serde(default)]
        message: String,
        code: Option<String>,
        /// The command's `details` object (`reason` is the reject reason).
        #[serde(default)]
        details: Option<Value>,
        #[serde(default)]
        retryable: Option<bool>,
    },
    /// `DaemonError.notConnected`.
    NotConnected,
    /// `DaemonError.missingCapabilities`.
    MissingCapabilities,
    /// Another `DaemonError`.
    Daemon,
    /// A `HomeRejection` thrown as is.
    Rejection { rejection: Rejection },
    /// Anything else.
    Other,
}

/// `cloud.reply_classify` reply.
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Classified {
    pub rejection: Rejection,
    pub is_no_lease: bool,
    pub is_final: bool,
    pub is_retryable: bool,
}

/// `DaemonError.rejectReason`: `details.reason` when it is a string.
fn reject_reason(details: &Option<Value>) -> Option<String> {
    details.as_ref()?.get("reason")?.as_str().map(str::to_owned)
}

pub fn rejection(error: &ReplyError) -> Rejection {
    match error {
        ReplyError::Rejection { rejection } => rejection.clone(),
        ReplyError::Command { message, code, details, retryable } => {
            let reason = reject_reason(details).unwrap_or_else(|| message.clone());
            match code.as_deref() {
                Some("cloud_conversation_rejected") => {
                    if *retryable == Some(true) {
                        Rejection::RateLimited { retry_after: None }
                    } else if reason == "forbidden" {
                        Rejection::NotAuthorized
                    } else {
                        Rejection::Invalid { reason }
                    }
                }
                Some("cloud_signed_out" | "cloud_session_expired" | "cloud_unauthenticated") => {
                    Rejection::OwnerUnreachable
                }
                Some("cloud_unavailable") => Rejection::Indeterminate,
                _ => Rejection::Invalid { reason },
            }
        }
        ReplyError::NotConnected | ReplyError::MissingCapabilities => Rejection::OwnerUnreachable,
        ReplyError::Daemon | ReplyError::Other => Rejection::Indeterminate,
    }
}

/// The daemon holds no usable lease: none, or one that expired.
pub fn is_no_lease(error: &ReplyError) -> bool {
    matches!(error, ReplyError::Command { code: Some(code), .. }
        if code == "cloud_signed_out" || code == "cloud_session_expired")
}

pub fn classify(error: &ReplyError) -> Classified {
    let rejection = rejection(error);
    Classified {
        is_no_lease: is_no_lease(error),
        is_final: rejection.is_final(),
        is_retryable: rejection.is_retryable(),
        rejection,
    }
}
