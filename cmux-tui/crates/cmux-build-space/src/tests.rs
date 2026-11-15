use super::*;

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let pairs: Vec<(String, String)> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    move |name| pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
}

fn dev(value: &str) -> Resolved {
    Ok(Some(BuildSpace::parse(value).expect("valid")))
}

#[test]
fn a_dev_value_is_the_space() {
    assert_eq!(resolve(env(&[(ENV, "dev:my-tag-2")])), dev("dev:my-tag-2"));
    assert_eq!(resolve(env(&[(MOBILE_ENV, "dev:a")])), dev("dev:a"));
    assert_eq!(resolve(env(&[(ENV, "dev:a"), (MOBILE_ENV, "dev:a")])), dev("dev:a"));
}

#[test]
fn unset_is_no_space_for_nightly_stable_and_standalone() {
    assert_eq!(resolve(env(&[])), Ok(None));
    for bundle in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.debug",
    ] {
        assert_eq!(resolve(env(&[("CMUX_BUNDLE_ID", bundle)])), Ok(None), "{bundle}");
    }
    // NIGHTLY's terminals carry CMUX_TAG=cmux-next: still no space.
    let nightly =
        env(&[("CMUX_BUNDLE_ID", "com.cmuxterm.app.nightly.cmux-next"), ("CMUX_TAG", "cmux-next")]);
    assert_eq!(resolve(nightly), Ok(None));
}

#[test]
fn unset_under_a_tagged_dev_launcher_is_refused() {
    for pairs in [
        vec![("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.my-tag")],
        vec![("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug"), ("CMUX_TAG", "my-tag")],
        vec![("CMUX_BUNDLE_ID", "com.cmuxterm.app.staging.x")],
    ] {
        let error = resolve(env(&pairs)).expect_err("a dev launcher without a space");
        assert!(error.to_string().contains(ENV), "{error}");
    }
}

#[test]
fn a_malformed_or_blank_value_is_refused_never_dropped() {
    for value in ["", " ", "dev:", "dev:UPPER", "dev:-a", "dev:a-", "prod", "dev:a b", "nightly"] {
        let error = resolve(env(&[(ENV, value)])).expect_err(value);
        assert!(error.to_string().contains("refusing to call cmux Cloud"), "{error}");
        assert!(resolve(env(&[(MOBILE_ENV, value)])).is_err(), "{value:?}");
    }
    let too_long = format!("dev:{}", "a".repeat(65));
    assert!(resolve(env(&[(ENV, &too_long)])).is_err());
    assert!(resolve(env(&[(ENV, &format!("dev:{}", "a".repeat(64)))])).is_ok());
}

#[test]
fn two_names_that_disagree_are_refused() {
    assert!(resolve(env(&[(ENV, "dev:a"), (MOBILE_ENV, "dev:b")])).is_err());
}

#[test]
fn headers_carry_the_space_only_for_a_dev_build() {
    let space = BuildSpace::parse("dev:x-1").expect("valid");
    let map = headers_for(Some(&space));
    assert_eq!(map.get(HEADER).and_then(|v| v.to_str().ok()), Some("dev:x-1"));
    assert!(headers_for(None).is_empty());
    let mut stale = headers_for(Some(&space));
    insert_space(&mut stale, None);
    assert!(stale.get(HEADER).is_none());
}

#[test]
fn parse_optional_drops_what_resolve_refuses() {
    assert_eq!(
        BuildSpace::parse_optional(Some(" dev:a ")).map(|s| s.to_string()),
        Some("dev:a".into())
    );
    assert_eq!(BuildSpace::parse_optional(Some("bad")), None);
    assert_eq!(BuildSpace::parse_optional(None), None);
}
