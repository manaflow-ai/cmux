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

/// A hub the person names in `CMUX_PLATFORM_ORIGIN` passes the egress gate in enforce
/// mode; a host nobody named is still refused.
#[test]
fn the_named_platform_origin_passes_the_gate() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let host = "hub-named-backend-test.org";
    assert!(cmux_egress::check(host, "test").is_err());
    let origin =
        platform_origin_from(|key| (key == PLATFORM_ORIGIN_ENV).then(|| format!("https://{host}")));
    assert_eq!(origin.as_deref(), Some("https://hub-named-backend-test.org"));
    assert!(cmux_egress::check(host, "test").is_ok());
    assert!(cmux_egress::check("unrelated-hub-backend-test.org", "test").is_err());
    // A plain-http hub, which every caller's origin check refuses, names nothing.
    let refused = "refused-hub-backend-test.org";
    let origin = platform_origin_from(|key| {
        (key == PLATFORM_ORIGIN_ENV).then(|| format!("http://{refused}"))
    });
    assert_eq!(origin.as_deref(), Some("http://refused-hub-backend-test.org"));
    assert!(cmux_egress::check(refused, "test").is_err());
}
