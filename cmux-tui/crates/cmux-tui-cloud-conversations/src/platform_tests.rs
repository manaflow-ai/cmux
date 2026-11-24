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
