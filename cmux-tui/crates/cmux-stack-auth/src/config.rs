//! What a client is built from: the Stack project and its timeouts (the SDK's `APIClient`
//! defaults), and the cmux API origin.

use std::time::Duration;

/// Stack's production API origin (`StackAuthClient.init`'s default).
pub const DEFAULT_STACK_BASE_URL: &str = "https://api.stack-auth.com";

/// Default refresh lead: a token is refreshed once it expires within this window, plus a
/// per-client jitter of up to the same again (the SDK's `defaultTokenRefreshLeadMillis`).
pub const DEFAULT_REFRESH_LEAD: Duration = Duration::from_secs(60);

/// One Stack project and how its calls are bounded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StackConfig {
    /// The Stack origin, without a trailing `/`.
    pub base_url: String,
    pub project_id: String,
    /// Empty when the project needs no key: then no key header is sent, and OAuth uses Stack's
    /// public-client secret.
    pub publishable_client_key: String,
    /// One request's deadline (the SDK's 30 s `timeoutInterval`).
    pub request_timeout: Duration,
    /// The refresh exchange's own deadline (the SDK refresh coordinator's 30 s).
    pub refresh_timeout: Duration,
    /// Transport-failure retries of an idempotent request (GET, PUT, DELETE, ...); the SDK makes 5.
    pub transport_retries: u32,
    /// The first retry's wait; each next one doubles (the SDK's 1, 2, 4, 8, 16 s).
    pub transport_retry_base: Duration,
    /// The refresh lead for this client. [`StackConfig::new`] picks 60 s plus a random 0 to 60 s
    /// once, so many clients that signed in together do not refresh in the same second.
    pub refresh_lead: Duration,
}

impl StackConfig {
    /// The SDK's defaults for `project_id` at `base_url`.
    pub fn new(base_url: &str, project_id: &str, publishable_client_key: &str) -> Self {
        let extra = DEFAULT_REFRESH_LEAD.mul_f64(crate::refresh::random_unit());
        StackConfig {
            base_url: base_url.trim_end_matches('/').to_owned(),
            project_id: project_id.to_owned(),
            publishable_client_key: publishable_client_key.to_owned(),
            request_timeout: Duration::from_secs(30),
            refresh_timeout: Duration::from_secs(30),
            transport_retries: 5,
            transport_retry_base: Duration::from_secs(1),
            refresh_lead: DEFAULT_REFRESH_LEAD.saturating_add(extra),
        }
    }
}

/// The cmux backend (`AuthConfig.apiBaseURL`: `https://cmux.com`, or a DEV build's backend).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CmuxApiConfig {
    pub base_url: String,
    /// One request's deadline (the account and recovery clients' 60 s).
    pub request_timeout: Duration,
}

impl CmuxApiConfig {
    pub fn new(base_url: &str) -> Self {
        CmuxApiConfig {
            base_url: base_url.trim_end_matches('/').to_owned(),
            request_timeout: Duration::from_secs(60),
        }
    }
}
