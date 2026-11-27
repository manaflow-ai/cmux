//! The display-safe error vocabulary of the sign-in flows and its one-line failure detail
//! (AuthError.swift, AuthError+DisplaySafe.swift, AuthError+FailureDetail.swift). The localized
//! sentences stay in the app; this decides which case an error is and what the detail line says.

use crate::error::StackError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthError {
    /// No network connectivity; the flow failed fast.
    Offline,
    /// A transport-level failure.
    NetworkError,
    /// A bounded sign-in phase hit its deadline.
    TimedOut,
    /// The auth server failed: the status (0 when unknown) and a stable reason.
    ServerError(u16, String),
    /// The magic-link or OTP code was missing or rejected.
    InvalidCode,
    /// The hosted sign-in callback had no token payload or did not match the attempt.
    InvalidCallback,
    /// The browser auth session closed before a valid callback (a diagnostic reason).
    BrowserSignInFailed(String),
    /// The session is no longer valid: sign in again.
    Unauthorized,
    /// A credential failure (wrong email or password).
    AuthFailure,
    /// The person cancelled; nothing to show.
    Cancelled,
    /// Stack answered 429; the session is untouched and the flow retries on its own.
    RateLimited,
}

/// The Stack codes the sign-in screen renders by itself: the display-safe mapping leaves them.
/// Matched upper-cased, so the SDK's own lower-case `parse_error` and `invalid_url` count too.
const RENDERED_CODES: [&str; 26] = [
    "SCHEMA_ERROR",
    "USER_EMAIL_ALREADY_EXISTS",
    "VERIFICATION_CODE_ERROR",
    "INVALID_OTP",
    "OTP_EXPIRED",
    "RATE_LIMIT",
    "RATE_LIMITED",
    "EMAIL_PASSWORD_MISMATCH",
    "USER_NOT_FOUND",
    "PASSKEY_AUTHENTICATION_FAILED",
    "PASSKEY_WEBAUTHN_ERROR",
    "INVALID_TOTP_CODE",
    "REDIRECT_URL_NOT_WHITELISTED",
    "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN",
    "INVALID_APPLE_CREDENTIALS",
    "APPLE_SIGNIN_NOT_CONFIGURED",
    "APPLE_SIGNIN_NOT_HANDLED",
    "APPLE_SIGNIN_INVALID_RESPONSE",
    "APPLE_SIGNIN_FAILED",
    "APPLE_SIGNIN_NOT_INTERACTIVE",
    "APPLE_SIGNIN_ERROR",
    "OAUTH_ERROR",
    "MISSING_CODE",
    "PARSE_ERROR",
    "INVALID_RESPONSE",
    "INVALID_URL",
];

impl AuthError {
    /// The display-safe case of a Stack failure, or `None` when the screen renders its code
    /// itself (schema, OTP, rate limit, ...). Auth failures collapse to [`AuthError::Unauthorized`],
    /// a cancelled OAuth to [`AuthError::Cancelled`], everything else to a generic server error.
    ///
    /// As in Swift, a transport failure arrives here already wrapped by the Stack client
    /// (`network_error`), so it reads as the generic server error, not [`AuthError::NetworkError`].
    pub fn display_safe(error: &StackError) -> Option<AuthError> {
        let code = error.code().to_ascii_uppercase();
        if code == "OAUTH_CANCELLED" {
            return Some(AuthError::Cancelled);
        }
        if RENDERED_CODES.contains(&code.as_str()) {
            return None;
        }
        Some(match code.as_str() {
            "UNAUTHORIZED" | "INVALID_TOKEN" | "TOKEN_EXPIRED" => AuthError::Unauthorized,
            _ => AuthError::ServerError(0, "auth_failed".to_owned()),
        })
    }

    /// Whether a cached session that failed validation with this error is cleared: only a hard
    /// [`AuthError::Unauthorized`]; a transient failure keeps it.
    pub fn clears_cached_session(&self) -> bool {
        *self == AuthError::Unauthorized
    }

    /// The detail line an error screen shows and copies: the code, the HTTP status and Stack's
    /// request id, never a token, a URL or a message body.
    pub fn failure_detail_for(error: &StackError) -> String {
        let mut parts = vec![error.code().to_ascii_uppercase()];
        // The SDK attaches the status only to answers it read the Stack headers of.
        if !matches!(error, StackError::OAuth { .. })
            && let Some(status) = error.http_status()
        {
            parts.push(format!("HTTP {status}"));
        }
        if let Some(id) = error.request_id().filter(|id| !id.is_empty()) {
            parts.push(format!("Request ID {id}"));
        }
        parts.join(" · ")
    }

    /// The detail line of this display-safe error.
    pub fn failure_detail(&self) -> String {
        match self {
            AuthError::Offline => "OFFLINE".to_owned(),
            AuthError::NetworkError => "NETWORK_ERROR".to_owned(),
            AuthError::TimedOut => "TIMED_OUT".to_owned(),
            AuthError::ServerError(status, code) if *status > 0 => {
                format!("{} · HTTP {status}", code.to_ascii_uppercase())
            }
            AuthError::ServerError(_, code) => code.to_ascii_uppercase(),
            AuthError::InvalidCode => "INVALID_CODE".to_owned(),
            AuthError::InvalidCallback => "INVALID_CALLBACK".to_owned(),
            AuthError::BrowserSignInFailed(_) => "BROWSER_SIGN_IN_FAILED".to_owned(),
            AuthError::Unauthorized => "UNAUTHORIZED".to_owned(),
            AuthError::AuthFailure => "AUTH_FAILURE".to_owned(),
            AuthError::Cancelled => "CANCELLED".to_owned(),
            AuthError::RateLimited => "RATE_LIMITED".to_owned(),
        }
    }
}

#[cfg(test)]
#[path = "auth_error_tests.rs"]
mod tests;
