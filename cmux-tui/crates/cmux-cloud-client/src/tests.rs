use super::*;

#[test]
fn fallback_keys_of_one_process_never_repeat() {
    let keys: std::collections::BTreeSet<_> = (0..1000).map(|_| fallback_key_bytes()).collect();
    assert_eq!(keys.len(), 1000);
}

/// `openapi.json` is the selection `tags.txt` names (scripts/update-spec.sh):
/// a tag added or dropped there without taking the spec again fails here.
#[test]
fn the_vendored_spec_is_the_selection_tags_txt_names() {
    let tags: std::collections::BTreeSet<String> = include_str!("../tags.txt")
        .lines()
        .map(|line| line.split('#').next().unwrap_or_default().trim().to_owned())
        .filter(|line| !line.is_empty())
        .collect();
    let spec: serde_json::Value =
        serde_json::from_str(include_str!("../openapi.json")).expect("openapi.json");
    let mut seen = std::collections::BTreeSet::new();
    for item in spec["paths"].as_object().expect("paths").values() {
        for op in item.as_object().expect("path item").values() {
            if let Some(tag) = op.pointer("/tags/0").and_then(serde_json::Value::as_str) {
                assert!(tags.contains(tag), "openapi.json has {tag}, which tags.txt does not name");
                seen.insert(tag.to_owned());
            }
        }
    }
    let missing: Vec<_> = tags.difference(&seen).collect();
    assert!(
        missing.is_empty(),
        "tags.txt names {missing:?}, which openapi.json lacks: run scripts/update-spec.sh"
    );
}

#[test]
fn client_keys_are_distinct_and_shaped() {
    let (a, b) = (client_key(), client_key());
    assert_ne!(a, b);
    assert_eq!(a.len(), 35);
    assert!(a.starts_with("ck_"));
    assert!(a[3..].chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn a_base_url_must_be_absolute_http() {
    test_tls();
    for bad in ["cloud-api.cmux.dev", "ftp://x", "/v1", ""] {
        assert!(matches!(anonymous_client(bad, "t"), Err(BuildError::InvalidBaseUrl(_))));
    }
    assert_eq!(
        anonymous_client("https://cloud-api.cmux.dev/", "t").unwrap().baseurl(),
        "https://cloud-api.cmux.dev"
    );
}

#[test]
fn a_bearer_with_a_newline_is_refused() {
    test_tls();
    assert!(matches!(
        client("https://x.example", "a\nb", None, "t"),
        Err(BuildError::InvalidBearer)
    ));
    assert!(matches!(
        client("https://x.example", "ok", Some("t\r"), "t"),
        Err(BuildError::InvalidTeam)
    ));
}
