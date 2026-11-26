use std::collections::{BTreeMap, HashMap};

use serde::Deserialize;

use super::*;
use crate::config::{Inputs, Selection, from_selection, sign_in_url};

/// Whether the development auth project trusts `https://cmux-staging.vercel.app`, the sign-in page
/// of every dev build on the development backend. Today it trusts only loopback, so every such
/// build's Google and email sign-in fails with REDIRECT_URL_NOT_WHITELISTED (probed 2026-11-19,
/// `scripts/stack-trusted-domains-probe.py`). Pending: the development project's dashboard entry
/// `https://cmux-staging.vercel.app` (handler path `/handler`). Once it lands, add it to
/// `fixtures/stack-trusted-domains.json` from a probe run and flip this to `true`.
const DEV_PROJECT_TRUSTS_STAGING: bool = false;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    projects: HashMap<String, Project>,
    probes: Vec<Probe>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Project {
    project_id: String,
    #[serde(flatten)]
    trusted: TrustedDomains,
}

#[derive(Deserialize)]
struct Probe {
    project: String,
    origin: String,
    accepted: bool,
}

fn fixture() -> Fixture {
    serde_json::from_str(include_str!("../fixtures/stack-trusted-domains.json")).expect("fixture")
}

fn project_for(fixture: &Fixture, project_id: &str) -> TrustedDomains {
    fixture
        .projects
        .values()
        .find(|project| project.project_id == project_id)
        .unwrap_or_else(|| panic!("no recorded allowlist for auth project {project_id}"))
        .trusted
        .clone()
}

/// The configuration a fresh build of `bundle_id` makes from `environment`'s selection.
fn fresh_build(
    environment: &str,
    bundle_id: &str,
    tag: Option<&str>,
) -> crate::config::Configuration {
    let env = cmux_cloud_environment::Environment::parse(environment).expect("environment");
    let resolved = env.configuration();
    let selection = Selection {
        name: resolved.name.clone(),
        api_origin: resolved.api_origin,
        auth_web_origin: resolved.auth_web_origin,
        stack_origin: resolved.stack_origin,
        stack_project_id: resolved.stack_project_id,
        stack_client_key: resolved.stack_client_key,
        bundle_id: bundle_id.to_owned(),
        auth_namespace: resolved.name,
        auth_storage_namespace: None,
        legacy_storage: false,
    };
    let mut bundled = BTreeMap::new();
    if let Some(tag) = tag {
        bundled.insert("CMUX_TAG".to_owned(), tag.to_owned());
    }
    from_selection(&Inputs {
        selection,
        bundle_id: Some(bundle_id.to_owned()),
        bundled,
        process: BTreeMap::new(),
        is_debug_build: tag.is_some(),
    })
}

#[test]
fn the_matcher_agrees_with_every_live_probe() {
    let fixture = fixture();
    for probe in &fixture.probes {
        let trusted = &fixture.projects[&probe.project].trusted;
        for url in hosted_page_redirect_urls(&probe.origin) {
            assert_eq!(
                redirect_url_trusted(&url, trusted),
                probe.accepted,
                "{} on the {} project: the live project answered accepted={}",
                url,
                probe.project,
                probe.accepted
            );
        }
    }
}

#[test]
fn every_fresh_build_signs_in_on_a_trusted_address() {
    let fixture = fixture();
    let tag = "next-cloud-dogfood-1d8c1c7";
    let tagged_bundle = format!("com.cmuxterm.app.debug.{tag}");
    // (what, backend, bundle, tag, whether its sign-in passes today)
    let builds = [
        (
            "tagged dev build, default backend",
            "dev",
            tagged_bundle.as_str(),
            Some(tag),
            DEV_PROJECT_TRUSTS_STAGING,
        ),
        (
            "tagged dev build pinned to its tag's backend",
            "https://cmux-dev-backend-1.tail137216.ts.net:4123",
            tagged_bundle.as_str(),
            Some(tag),
            DEV_PROJECT_TRUSTS_STAGING,
        ),
        (
            "signed NEXT DEV",
            "dev",
            crate::config::NEXT_DEV_BUNDLE_ID,
            None,
            DEV_PROJECT_TRUSTS_STAGING,
        ),
        ("cmux NIGHTLY", "prod", crate::config::NIGHTLY_BUNDLE_ID, None, true),
        ("tagged dev build on production", "prod", tagged_bundle.as_str(), Some(tag), true),
    ];
    for (what, backend, bundle, tag, passes) in builds {
        let configuration = fresh_build(backend, bundle, tag);
        let trusted = project_for(&fixture, &configuration.stack_project_id);
        for url in hosted_page_redirect_urls(&configuration.auth_web_origin) {
            assert_eq!(
                redirect_url_trusted(&url, &trusted),
                passes,
                "{what}: Stack checks {url} against project {}",
                configuration.stack_project_id
            );
        }
    }
}

#[test]
fn the_callback_scheme_never_reaches_stack() {
    let configuration = fresh_build("dev", "com.cmuxterm.app.debug.abc", Some("abc"));
    assert_eq!(configuration.callback_scheme, "cmux-dev-abc");
    let entry =
        sign_in_url(&configuration.auth_web_origin, &configuration.callback_scheme, Some("s"));
    // The page's own address is what Stack checks; the scheme is a percent-encoded query value.
    assert!(
        entry.starts_with(&format!("{}/handler/native-sign-in?", configuration.auth_web_origin))
    );
    assert!(!entry.contains("cmux-dev-abc://"));
    assert!(entry.contains("cmux-dev-abc%253A%252F%252Fauth-callback"));
}

#[test]
fn stack_compares_scheme_host_and_port_only() {
    let trusted = TrustedDomains {
        allow_localhost: false,
        trusted_domains: vec![
            "https://cmux.com".to_owned(),
            "https://*.preview.cmux.dev".to_owned(),
            "https://**.deep.cmux.dev".to_owned(),
            "https://host.ts.net:*".to_owned(),
            "http://lan.test:8080".to_owned(),
        ],
    };
    let cases = [
        ("https://cmux.com/handler/oauth-callback?after_auth_return_to=x", true),
        ("https://cmux.com:443/handler/sign-in", true),
        ("https://cmux.com:8443/handler/sign-in", false),
        ("http://cmux.com/handler/sign-in", false),
        ("https://www.cmux.com/handler/sign-in", false),
        ("https://pr-1.preview.cmux.dev/handler/sign-in", true),
        ("https://a.b.preview.cmux.dev/handler/sign-in", false),
        ("https://pr-1.preview.cmux.dev:8443/handler/sign-in", false),
        ("https://a.b.deep.cmux.dev/x", true),
        ("https://host.ts.net:4123/handler/sign-in", true),
        ("https://host.ts.net/handler/sign-in", true),
        ("https://other.ts.net:4123/handler/sign-in", false),
        ("http://lan.test:8080/x", true),
        ("http://lan.test/x", false),
        ("http://127.0.0.1:5000/callback", false),
        ("not a url", false),
    ];
    for (url, expected) in cases {
        assert_eq!(redirect_url_trusted(url, &trusted), expected, "{url}");
    }
}

#[test]
fn allow_localhost_admits_every_loopback_address() {
    let trusted = TrustedDomains { allow_localhost: true, trusted_domains: Vec::new() };
    for url in [
        "http://127.0.0.1:53111/callback",
        "http://127.10.0.2/x",
        "http://localhost:3777/handler/sign-in",
        "http://app.localhost/x",
        "http://[::1]:9000/x",
    ] {
        assert!(redirect_url_trusted(url, &trusted), "{url}");
    }
    for url in ["http://127.0.0.1.example.com/x", "https://cmux-staging.vercel.app/handler/sign-in"]
    {
        assert!(!redirect_url_trusted(url, &trusted), "{url}");
    }
}

#[test]
fn a_refused_url_reads_as_its_origin() {
    assert_eq!(
        rejected_origin("https://cmux-staging.vercel.app/handler/sign-in?after_auth_return_to=x")
            .as_deref(),
        Some("https://cmux-staging.vercel.app")
    );
    assert_eq!(
        rejected_origin("https://cmux-dev-backend-1.tail137216.ts.net:4123/handler/sign-in")
            .as_deref(),
        Some("https://cmux-dev-backend-1.tail137216.ts.net:4123")
    );
    assert_eq!(rejected_origin("http://[::1]:9000/x").as_deref(), Some("http://[::1]:9000"));
    assert_eq!(rejected_origin("garbage"), None);
}
