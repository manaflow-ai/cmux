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
    match room {
        DEVELOPMENT => Some(cmux_cloud_environment::DEVELOPMENT_API),
        STAGING => Some(cmux_cloud_environment::STAGING_API),
        PRODUCTION => Some(cmux_cloud_environment::PRODUCTION_API),
        _ => None,
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
        assert_eq!(share_owner_api("http://localhost:8787"), None);
        assert_eq!(share_owner_api(""), None);
    }
}
