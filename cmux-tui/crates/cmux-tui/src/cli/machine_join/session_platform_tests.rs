use super::platform_of_api;
use cmux_cloud_environment as e;

#[test]
fn the_app_sessions_api_maps_to_its_own_platform_never_the_api_itself() {
    assert_eq!(platform_of_api(e::PRODUCTION_API).as_deref(), Some(e::PRODUCTION_PLATFORM));
    assert_eq!(
        platform_of_api(&format!("{}/", e::PRODUCTION_API)).as_deref(),
        Some(e::PRODUCTION_PLATFORM)
    );
    assert_eq!(platform_of_api(e::STAGING_API).as_deref(), Some(e::STAGING_PLATFORM));
    assert_eq!(platform_of_api(e::DEVELOPMENT_API).as_deref(), Some(e::DEVELOPMENT_PLATFORM));
    assert_eq!(
        platform_of_api(e::LOCAL_DEPLOYMENT.api_origin).as_deref(),
        Some(e::LOCAL_DEPLOYMENT.platform_origin)
    );
    assert_eq!(platform_of_api("https://preview-1.example"), None);
}
