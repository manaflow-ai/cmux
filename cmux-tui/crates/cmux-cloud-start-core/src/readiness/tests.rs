//! A failed Cloud start's readiness summary: each missing piece gets its own repair.

use super::*;

fn need(code: &str, message: &str) -> Option<(Need, Repair)> {
    classify(code, Some(message)).map(|r| (r.need, r.repair))
}

#[test]
fn missing_git_access_connects_github() {
    assert_eq!(need("seed.needs_github", ""), Some((Need::GitAccess, Repair::ConnectGithub)));
    assert_eq!(
        need("cloud_start_failed", "fatal: repository not found"),
        Some((Need::GitAccess, Repair::ConnectGithub))
    );
    assert_eq!(
        need("cloud_start_failed", "The cmux GitHub App is not installed on acme/api"),
        Some((Need::GitAccess, Repair::ConnectGithub))
    );
}

#[test]
fn a_missing_secret_opens_secrets_and_names_it() {
    let readiness = classify(
        "cloud_start_failed",
        Some("setup: secret NPM_TOKEN is not set for this environment"),
    )
    .unwrap();
    assert_eq!(readiness.need, Need::PersonalSecret);
    assert_eq!(readiness.repair, Repair::EnvironmentSecrets);
    assert_eq!(readiness.secret.as_deref(), Some("NPM_TOKEN"));
    // A code alone, with no name in the words: no name is made up.
    let bare = classify("environment.secret_missing", None).unwrap();
    assert_eq!(bare.need, Need::PersonalSecret);
    assert_eq!(bare.secret, None);
}

#[test]
fn a_secret_name_is_never_a_plain_word() {
    assert_eq!(secret_name("HTTP 401: missing secret OK"), None);
    assert_eq!(secret_name("missing secret GITHUB_TOKEN"), Some("GITHUB_TOKEN".into()));
    assert_eq!(secret_name("missing secret APIKEY"), Some("APIKEY".into()));
    assert_eq!(secret_name(&format!("missing secret A_{}", "B".repeat(80))), None);
}

#[test]
fn a_failed_setup_opens_the_setup_script() {
    for words in [
        "Setup script failed (exit 1)",
        "setup exited with status 127",
        "npm ERR! code E404",
        "ERROR: Could not find a version that satisfies the requirement torch==9",
        "E: Unable to locate package libfoo-dev",
    ] {
        assert_eq!(
            need("cloud_start_failed", words),
            Some((Need::Dependency, Repair::EnvironmentScript)),
            "{words}"
        );
    }
    assert_eq!(
        need("environment.setup_failed", ""),
        Some((Need::Dependency, Repair::EnvironmentScript))
    );
}

#[test]
fn an_unsupported_image_opens_the_image_pick() {
    assert_eq!(
        need(
            "cloud_start_failed",
            "cmux-platform answered 409 cloud.carrier.image_unsupported: too old"
        ),
        Some((Need::UnsupportedImage, Repair::EnvironmentImage))
    );
    assert_eq!(
        need("cloud.image_unsupported", ""),
        Some((Need::UnsupportedImage, Repair::EnvironmentImage))
    );
    assert_eq!(
        need("cloud_start_failed", "image ubuntu-18 is not in the allowlist"),
        Some((Need::UnsupportedImage, Repair::EnvironmentImage))
    );
}

/// Anything else keeps the card's own words and ways on (Retry, This Mac).
#[test]
fn an_unknown_failure_says_nothing() {
    for (code, words) in [
        ("cloud_start_failed", "The machine did not answer in time."),
        ("cloud_plan_required", ""),
        ("cloud_folder_too_big", "~/Projects is too big to copy"),
        ("", ""),
    ] {
        assert_eq!(classify(code, Some(words)), None, "{code} {words}");
    }
    assert_eq!(classify("cloud_start_failed", None), None);
}

/// Only the first MAX_WORDS characters are read, so a log tail of any size costs the same.
#[test]
fn a_long_message_is_read_only_up_to_its_bound() {
    let late = format!("{} npm ERR! late", "x".repeat(MAX_WORDS + 10));
    assert_eq!(classify("cloud_start_failed", Some(&late)), None);
    let early = format!("npm ERR! early {}", "é".repeat(MAX_WORDS * 2));
    assert!(classify("cloud_start_failed", Some(&early)).is_some());
}

#[test]
fn the_wire_shape_is_camel_case_and_snake_case_words() {
    let readiness = classify("x", Some("missing secret NPM_TOKEN")).unwrap();
    assert_eq!(
        serde_json::to_value(&readiness).unwrap(),
        serde_json::json!({"need": "personal_secret", "repair": "environment_secrets", "secret": "NPM_TOKEN"})
    );
}
