//! C11: the API origin `bind.json` names is the guest's API base, within a vetted set per
//! environment ([`Env::allows_api_origin`]); everything else is refused.

use serde_json::json;

use super::wire::{Env, parse_bind_file};

const PREVIEW: &str = "https://cmux-api-preview-12.debussy.workers.dev";

fn bind(env: &str, origin: &str) -> String {
    json!({
        "team": "team_t0000000000000000001",
        "machine": "vm_m0000000000000000001",
        "bind_token": "bt_vector_one_time_token_000000000000000000",
        "api_origin": origin,
        "env": env,
    })
    .to_string()
}

#[test]
fn each_environment_allows_its_api_and_platform_origins() {
    for env in [Env::Dev, Env::Stg, Env::Prod] {
        assert!(env.allows_api_origin(env.api_origin()), "{env:?}");
        assert!(env.allows_api_origin(env.platform_origin()), "{env:?}");
    }
}

#[test]
fn only_dev_allows_a_numbered_api_preview() {
    assert!(Env::Dev.allows_api_origin(PREVIEW));
    assert!(Env::Dev.allows_api_origin("https://cmux-api-preview-1.debussy.workers.dev"));
    assert!(!Env::Stg.allows_api_origin(PREVIEW));
    assert!(!Env::Prod.allows_api_origin(PREVIEW));
}

#[test]
fn another_environments_origin_is_refused() {
    let all = [Env::Dev, Env::Stg, Env::Prod];
    for env in all {
        for other in all.into_iter().filter(|o| *o != env) {
            assert!(!env.allows_api_origin(other.api_origin()), "{env:?} took {other:?}'s API");
            assert!(
                !env.allows_api_origin(other.platform_origin()),
                "{env:?} took {other:?}'s platform"
            );
        }
    }
}

#[test]
fn lookalike_and_non_canonical_origins_are_refused() {
    let refused = [
        "",
        "cloud-api.cmux.dev",
        "http://cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev/",
        "https://cloud-api.cmux.dev/v1",
        "https://cloud-api.cmux.dev:8443",
        "https://user@cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev?x=1",
        "https://CLOUD-API.cmux.dev",
        "https://cloud-api.cmux.dev.evil.example",
        "https://evil.example/https://cloud-api.cmux.dev",
        " https://cloud-api.cmux.dev",
        "https://evil.cmux.dev",
    ];
    for origin in refused {
        assert!(!Env::Prod.allows_api_origin(origin), "prod took {origin:?}");
    }
    let bad_previews = [
        "https://cmux-api-preview-0.debussy.workers.dev",
        "https://cmux-api-preview-01.debussy.workers.dev",
        "https://cmux-api-preview-.debussy.workers.dev",
        "https://cmux-api-preview-1234567890.debussy.workers.dev",
        "https://cmux-api-preview-1.evil.debussy.workers.dev",
        "https://cmux-api-preview-1x.debussy.workers.dev",
        "https://cmux-api-preview-1.debussy.workers.dev/",
        "https://cmux-api-preview-1.debussy.workers.dev.evil.example",
        "http://cmux-api-preview-1.debussy.workers.dev",
        "https://cmux-api-preview-1.debussy.workers.dev:443",
    ];
    for origin in bad_previews {
        assert!(!Env::Dev.allows_api_origin(origin), "dev took {origin:?}");
    }
}

#[test]
fn the_bind_file_keeps_the_origin_it_names() {
    let file = parse_bind_file(&bind("dev", PREVIEW)).unwrap();
    assert_eq!(file.api_origin, PREVIEW);
    let platform = Env::Prod.platform_origin();
    assert_eq!(parse_bind_file(&bind("prod", platform)).unwrap().api_origin, platform);
    assert_eq!(
        parse_bind_file(&bind("stg", Env::Stg.api_origin())).unwrap().api_origin,
        Env::Stg.api_origin()
    );
}

#[test]
fn the_bind_file_refuses_an_origin_its_environment_does_not_allow() {
    for (env, origin) in [
        ("prod", Env::Stg.api_origin()),
        ("stg", PREVIEW),
        ("prod", "https://evil.example"),
        ("dev", "http://cmux-api-development.debussy.workers.dev"),
    ] {
        let why = parse_bind_file(&bind(env, origin)).unwrap_err();
        assert!(why.contains("api_origin is not a"), "{env} {origin}: {why}");
    }
}
