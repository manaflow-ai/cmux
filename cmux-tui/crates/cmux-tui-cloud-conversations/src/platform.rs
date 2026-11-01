//! Platform deployments shared by the room resolver and credential-bearing environment calls.

pub const DEVELOPMENT: &str = "https://cmux-platform-development.debussy.workers.dev";
pub const STAGING: &str = "https://cmux-platform-staging.debussy.workers.dev";
pub const PRODUCTION: &str = "https://cmux-platform-production.debussy.workers.dev";

/// Only a declared platform deployment or explicit local development may receive an install token.
pub(crate) fn accepts_environment_origin(base: &url::Url) -> bool {
    let deployment =
        [DEVELOPMENT, STAGING, PRODUCTION].contains(&base.origin().ascii_serialization().as_str());
    let local = base.scheme() == "http"
        && matches!(base.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    (deployment || local)
        && base.username().is_empty()
        && base.password().is_none()
        && base.query().is_none()
        && base.fragment().is_none()
        && base.path() == "/"
}
