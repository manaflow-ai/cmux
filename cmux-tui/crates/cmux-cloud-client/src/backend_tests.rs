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

/// One name, one alias, one precedence: `CMUX_PLATFORM_ORIGIN` wins, `CMUX_PLATFORM_URL`
/// counts only when it is unset or empty.
#[test]
fn the_platform_origin_is_one_variable_with_one_alias() {
    let read = |origin: Option<&str>, url: Option<&str>| {
        platform_origin_from(|key| match key {
            PLATFORM_ORIGIN_ENV => origin.map(str::to_owned),
            PLATFORM_ORIGIN_ALIAS_ENV => url.map(str::to_owned),
            _ => None,
        })
    };
    assert_eq!(read(Some("https://o.example"), None).as_deref(), Some("https://o.example"));
    assert_eq!(read(None, Some("https://u.example")).as_deref(), Some("https://u.example"));
    assert_eq!(
        read(Some(" https://o.example "), Some("https://u.example")).as_deref(),
        Some("https://o.example")
    );
    assert_eq!(read(Some(" "), Some("https://u.example")).as_deref(), Some("https://u.example"));
    assert_eq!(read(None, None), None);
}
