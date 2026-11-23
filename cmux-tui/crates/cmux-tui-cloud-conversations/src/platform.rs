//! Platform deployments shared by the room resolver and credential-bearing environment calls.

pub use cmux_cloud_environment::DEVELOPMENT_PLATFORM as DEVELOPMENT;
pub use cmux_cloud_environment::PRODUCTION_PLATFORM as PRODUCTION;
pub use cmux_cloud_environment::STAGING_PLATFORM as STAGING;

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

/// The cmux API whose install tokens each deployment's share room verifies (its `CMUX_AUTH_JWKS_URL`):
/// an owner token for a link in `room` (an origin) must come from this API. Nil for any other room
/// (a local platform, or one named by `CMUX_SHARE_ROOM_URL` that is not declared here).
pub fn share_owner_api(room: &str) -> Option<&'static str> {
    match share_deployment(room)? {
        DEVELOPMENT => Some(cmux_cloud_environment::DEVELOPMENT_API),
        STAGING => Some(cmux_cloud_environment::STAGING_API),
        _ => Some(cmux_cloud_environment::PRODUCTION_API),
    }
}

/// The platform deployment a share room or share link origin belongs to (its platform origin), whether it
/// is the platform's own origin or its short share host; nil for any other origin.
pub fn share_deployment(origin: &str) -> Option<&'static str> {
    use cmux_cloud_environment::{DEVELOPMENT_SHARE, PRODUCTION_SHARE, STAGING_SHARE};
    match origin {
        DEVELOPMENT | DEVELOPMENT_SHARE => Some(DEVELOPMENT),
        STAGING | STAGING_SHARE => Some(STAGING),
        PRODUCTION | PRODUCTION_SHARE => Some(PRODUCTION),
        _ => None,
    }
}

/// The short share host of the deployment a room origin belongs to (`https://share.cmux.dev` for production's
/// either origin), so links are made there; nil for any other origin, which stays as configured.
pub fn share_host(origin: &str) -> Option<&'static str> {
    use cmux_cloud_environment::{DEVELOPMENT_SHARE, PRODUCTION_SHARE, STAGING_SHARE};
    match share_deployment(origin)? {
        DEVELOPMENT => Some(DEVELOPMENT_SHARE),
        STAGING => Some(STAGING_SHARE),
        _ => Some(PRODUCTION_SHARE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_room_names_the_api_of_its_environment() {
        assert_eq!(
            share_owner_api(DEVELOPMENT),
            Some("https://cmux-api-development.debussy.workers.dev")
        );
        assert_eq!(share_owner_api(STAGING), Some("https://cloud-api-staging.cmux.dev"));
        assert_eq!(share_owner_api(PRODUCTION), Some("https://cloud-api.cmux.dev"));
        // The short share host is the same deployment as its platform origin.
        assert_eq!(
            share_owner_api("https://share-dev.cmux.dev"),
            Some("https://cmux-api-development.debussy.workers.dev")
        );
        assert_eq!(
            share_owner_api("https://share-staging.cmux.dev"),
            Some("https://cloud-api-staging.cmux.dev")
        );
        assert_eq!(share_owner_api("https://share.cmux.dev"), Some("https://cloud-api.cmux.dev"));
        assert_eq!(share_owner_api("https://share.example.com"), None);
        assert_eq!(share_deployment("https://share.cmux.dev"), Some(PRODUCTION));
        assert_eq!(share_deployment(PRODUCTION), Some(PRODUCTION));
        assert_eq!(share_owner_api("http://localhost:8787"), None);
        assert_eq!(share_owner_api(""), None);
    }

    #[test]
    fn each_room_is_made_on_its_share_host() {
        assert_eq!(share_host(DEVELOPMENT), Some("https://share-dev.cmux.dev"));
        assert_eq!(share_host(STAGING), Some("https://share-staging.cmux.dev"));
        assert_eq!(share_host(PRODUCTION), Some("https://share.cmux.dev"));
        assert_eq!(share_host("https://share.cmux.dev"), Some("https://share.cmux.dev"));
        assert_eq!(share_host("http://localhost:8788"), None);
        assert_eq!(share_host("https://links.example.com"), None);
    }
}
