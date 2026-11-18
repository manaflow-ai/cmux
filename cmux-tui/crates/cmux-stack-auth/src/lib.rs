//! The Stack Auth REST calls the app's `CmuxAuthRuntime` makes today, and the cmux account calls
//! beside them, as one Rust client. Step 1 of the CmuxAuthRuntime port: nothing calls it yet.
//!
//! What it owns (the Swift it ports):
//! - [`StackClient`]: the Stack API at `<base>/api/v1` (the vendored Stack Swift SDK's
//!   `APIClient` and `StackClientApp`, as `StackAuthClient.swift` drives them): the refresh-token
//!   exchange and its 429 cooldown, the likely-valid access token, the OAuth code, OTP (magic
//!   link) and password sign-ins, `/users/me`, the team list, team selection and creation, and
//!   the session revoke.
//! - [`CmuxApi`]: cmux's own backend: `DELETE /api/account` (`AccountDeletionClient.swift`), the
//!   email-verification and billing recovery posts (`EmailVerificationRecoveryClient.swift`) and
//!   `GET /api/teams` (`CmuxTeamsAPI.swift`'s membership list).
//! - The pure rules: the sign-in 429 retry policy (`AuthRateLimit.swift`), the phase deadlines
//!   (`AuthTimeouts.swift`), and the display-safe error mapping and failure line
//!   (`AuthError+DisplaySafe.swift`, `AuthError+FailureDetail.swift`).
//!
//! What it does not own: the Keychain (the caller stores a [`Session`] and hands it in; a call
//! that refreshed returns the new access token in the same `Session`) and the browser sign-in
//! sheet (the caller opens [`StackClient::oauth_authorize_url`] and hands back the callback).
//!
//! Headers: Stack requests carry only the `x-hexclave-*` names. Stack answers 429 to a request
//! with the legacy `x-stack-*` aliases (since 2026-10-13); responses are read under either.
//! cmux API requests carry `Authorization: Bearer <access>` and `X-Stack-Refresh-Token`.
//!
//! Tokens are never logged and never in an error or a `Debug` line: [`Session`] and
//! [`OAuthStart`] print redacted, and transport errors are reduced to fixed words (reqwest's own
//! text names the URL, which can hold a code).

mod auth_error;
mod calls;
mod client;
mod cmux_api;
mod config;
mod error;
mod jwt;
mod policy;
mod refresh;
mod wire;

pub use auth_error::AuthError;
pub use calls::{CurrentUser, OAuthCallback, OAuthStart, Team};
pub use client::{StackClient, TokenResolution};
pub use cmux_api::{
    AccountDeletionError, AccountDeletionResult, CmuxApi, RecoveryError, TeamError, TeamMembership,
    TeamMemberships, TeamPermissions, TeamRole,
};
pub use config::{CmuxApiConfig, DEFAULT_REFRESH_LEAD, DEFAULT_STACK_BASE_URL, StackConfig};
pub use error::{RateLimit, StackError};
pub use jwt::{is_token_expired, is_token_fresh_enough};
pub use policy::{AuthTimeouts, SignInRateLimit};
pub use refresh::{RefreshFailure, RefreshOutcome, RefreshRateLimiter};
pub use wire::{BodyKind, Session, redacted_endpoint, retry_after_seconds};
