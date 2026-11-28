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

/// `/v1/machines/...` goes to the platform: an owner API maps to its own platform first (an
/// environment override never sends a prod owner's fork to another hub), an unknown origin
/// takes the environment's platform origin, and with neither it stays as given.
#[test]
fn machine_routes_go_to_the_owner_apis_platform() {
    let none = |_: &str| None;
    let staging =
        |key: &str| (key == PLATFORM_ORIGIN_ENV).then(|| Backend::Staging.platform().to_owned());
    for b in [Backend::Production, Backend::Staging, Backend::Development] {
        assert_eq!(Backend::of_owner_api(b.owner_api()), Some(b));
        assert_eq!(platform_for(b.owner_api(), none), b.platform());
        assert_eq!(platform_for(&format!("{}/", b.owner_api()), none), b.platform());
    }
    assert_eq!(
        platform_for(Backend::Production.owner_api(), staging),
        Backend::Production.platform()
    );
    assert_eq!(platform_for("http://127.0.0.1:8787", staging), Backend::Staging.platform());
    assert_eq!(platform_for("http://127.0.0.1:8787/", none), "http://127.0.0.1:8787");
    assert_eq!(platform_for(Backend::Staging.platform(), none), Backend::Staging.platform());
    assert_eq!(Backend::of_owner_api(Backend::Production.platform()), None);
}
