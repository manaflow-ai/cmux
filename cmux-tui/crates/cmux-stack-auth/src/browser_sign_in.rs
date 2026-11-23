//! Interactive browser enrollment, using Stack's existing email-code sign-in.
//!
//! The listener keeps one transaction per page in memory, behind its same-origin request
//! checks. Taking the transaction out of that store before `complete` makes it single-use.
//! Nothing reads a daemon session, environment credential, keychain or token file.

use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use reqwest::Url;
use tokio::time::Instant;

use crate::{StackClient, StackError};

const SIGN_IN_LIFETIME: Duration = Duration::from_secs(300);

/// A page's pending challenge. Deliberately neither serializable nor cloneable.
pub struct BrowserSignIn {
    origin: String,
    public_key: String,
    owner_user_id: String,
    nonce: String,
    expires_at: Instant,
}

impl std::fmt::Debug for BrowserSignIn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BrowserSignIn(<redacted>)")
    }
}

/// The browser's own short-lived credential for `setBrowserDeviceEnrollment`.
/// Keep it only in page memory. No refresh token crosses this boundary.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserEnrollment {
    pub access_token: String,
    pub public_key: String,
}

impl std::fmt::Debug for BrowserEnrollment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BrowserEnrollment(<redacted>)")
    }
}

/// Fixed reasons safe for a browser response or log. Stack response bodies stay private.
#[derive(Debug, PartialEq, Eq)]
pub enum BrowserSignInError {
    InvalidOrigin,
    InvalidPublicKey,
    InvalidInput,
    Expired,
    AccountMismatch,
    Unavailable,
    CodeRefused,
    RateLimited,
}

impl BrowserSignInError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidOrigin => "browser.sign_in.origin_mismatch",
            Self::InvalidPublicKey => "browser.sign_in.invalid_public_key",
            Self::InvalidInput => "browser.sign_in.invalid_input",
            Self::Expired => "browser.sign_in.expired",
            Self::AccountMismatch => "browser.sign_in.account_mismatch",
            Self::Unavailable => "browser.sign_in.unavailable",
            Self::CodeRefused => "browser.sign_in.code_refused",
            Self::RateLimited => "browser.sign_in.rate_limited",
        }
    }
}

impl std::fmt::Display for BrowserSignInError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}

impl std::error::Error for BrowserSignInError {}

impl BrowserSignIn {
    /// Start from an explicit email submission. `owner_user_id` is the listener's trusted
    /// account id, never a request field. `callback_url` is deployment configuration (the
    /// existing email-link callback); the person enters the email's code in this page.
    /// The caller must check the request Origin against its configured serving origin first,
    /// and bind this object to an unguessable page handle, never a process-global "last login".
    pub async fn start(
        stack: &StackClient,
        origin: &str,
        owner_user_id: &str,
        public_key: &str,
        email: &str,
        callback_url: &str,
    ) -> Result<Self, BrowserSignInError> {
        let origin = browser_origin(origin)?;
        let key = STANDARD.decode(public_key).map_err(|_| BrowserSignInError::InvalidPublicKey)?;
        if key.len() != 32 || STANDARD.encode(&key) != public_key {
            return Err(BrowserSignInError::InvalidPublicKey);
        }
        let email = email.trim();
        if owner_user_id.is_empty()
            || email.is_empty()
            || email.len() > 320
            || email.chars().any(char::is_control)
            || !email.contains('@')
        {
            return Err(BrowserSignInError::InvalidInput);
        }
        // Bound the whole attempt, including sending the email.
        let expires_at = Instant::now() + SIGN_IN_LIFETIME;
        let nonce =
            tokio::time::timeout_at(expires_at, stack.send_sign_in_code(email, callback_url))
                .await
                .map_err(|_| BrowserSignInError::Expired)?
                .map_err(stack_failure)?;
        if nonce.is_empty() {
            return Err(BrowserSignInError::Unavailable);
        }
        Ok(Self {
            origin,
            public_key: public_key.to_owned(),
            owner_user_id: owner_user_id.to_owned(),
            nonce,
            expires_at,
        })
    }

    /// Consume even a failed attempt. The caller takes it out of its page store before await;
    /// retries require a new explicit sign-in. Check the current owner again before enrollment
    /// if the daemon's account changed while this request was in flight.
    pub async fn complete(
        self,
        stack: &StackClient,
        origin: &str,
        code: &str,
    ) -> Result<BrowserEnrollment, BrowserSignInError> {
        if browser_origin(origin)? != self.origin {
            return Err(BrowserSignInError::InvalidOrigin);
        }
        if Instant::now() >= self.expires_at {
            return Err(BrowserSignInError::Expired);
        }
        let code = code.trim();
        if code.is_empty() || code.len() > 64 || !code.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return Err(BrowserSignInError::InvalidInput);
        }
        // Same composition as CMUXAuthMagicLinkCode: lowercase only the visible prefix.
        let code = code.to_ascii_lowercase() + &self.nonce;
        let (mut session, user) = tokio::time::timeout_at(self.expires_at, async {
            let mut session = stack.sign_in_with_code(&code).await.map_err(stack_failure)?;
            let user = stack.current_user(&mut session).await.map_err(stack_failure)?;
            Ok::<_, BrowserSignInError>((session, user))
        })
        .await
        .map_err(|_| BrowserSignInError::Expired)??;
        if user.is_none_or(|user| user.id != self.owner_user_id) {
            return Err(BrowserSignInError::AccountMismatch);
        }
        if Instant::now() >= self.expires_at {
            return Err(BrowserSignInError::Expired);
        }
        let access_token = session
            .access_token
            .take()
            .filter(|token| !token.is_empty())
            .ok_or(BrowserSignInError::Unavailable)?;
        Ok(BrowserEnrollment { access_token, public_key: self.public_key })
    }
}

fn stack_failure(error: StackError) -> BrowserSignInError {
    match error.http_status() {
        Some(429) => BrowserSignInError::RateLimited,
        Some(400 | 401 | 403) => BrowserSignInError::CodeRefused,
        _ => BrowserSignInError::Unavailable,
    }
}

fn browser_origin(value: &str) -> Result<String, BrowserSignInError> {
    let url = Url::parse(value).map_err(|_| BrowserSignInError::InvalidOrigin)?;
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(BrowserSignInError::InvalidOrigin);
    }
    Ok(url.origin().ascii_serialization())
}
