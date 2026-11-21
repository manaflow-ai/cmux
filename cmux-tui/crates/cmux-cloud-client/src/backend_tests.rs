use super::*;

#[test]
fn names_round_trip_and_origins_are_bare_https() {
    for b in [Backend::Production, Backend::Staging, Backend::Development] {
        assert_eq!(Backend::parse(b.name()), Some(b));
        assert_eq!(Backend::of_platform(b.platform()), Some(b));
        for origin in [b.platform(), b.owner_api()] {
            assert!(cmux_cloud_config::origin::is_bare_https_origin(origin), "{origin}");
        }
    }
    assert_eq!(Backend::parse("prod"), Some(Backend::Production));
    assert_eq!(Backend::parse("moon"), None);
}
