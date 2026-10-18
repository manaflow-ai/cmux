//! The corpus is fake: every secret is assembled at run time, so no file in
//! the tree holds a string a secret scanner would flag.

use super::*;

/// A fake base62 body of `n` characters with the spread of a real token.
fn body(n: usize) -> String {
    "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(n).collect()
}

/// Masking `text` leaves none of `secrets` in the output, every mask is the
/// kind expected, and scanning the output again finds nothing (the source is
/// absent, not covered).
#[track_caller]
fn assert_masked(text: &str, secrets: &[&str], expected: &str) {
    let out = mask(text);
    assert_eq!(out, expected, "masking {text:?}");
    for secret in secrets {
        assert!(!out.contains(secret), "{secret:?} survives in {out:?}");
    }
    assert!(find(&out).is_empty(), "the masked text still has a secret: {out:?} {:?}", find(&out));
}

#[test]
fn provider_keys_become_their_kind() {
    let anthropic = format!("sk-ant-api03-{}", body(40));
    let openai = format!("sk-proj-{}", body(48));
    let stripe = format!("{}_live_{}", "sk", body(24));
    let github = format!("gh{}_{}", "p", body(36));
    let github_pat = format!("github_{}_{}", "pat", body(60).replace('Z', "_"));
    let slack = format!("xox{}-{}-{}", "b", "1234567890", body(24));
    let aws = format!("AKIA{}", "Q7ZJ4XK2MD9P3WRT");
    let google = format!("AIza{}", body(35));
    for (secret, mask) in [
        (&anthropic, "[anthropic key]"),
        (&openai, "[openai key]"),
        (&stripe, "[stripe key]"),
        (&github, "[github token]"),
        (&github_pat, "[github token]"),
        (&slack, "[slack token]"),
        (&aws, "[aws key]"),
        (&google, "[google key]"),
    ] {
        assert_masked(
            &format!("use {secret} for the deploy"),
            &[secret],
            &format!("use {mask} for the deploy"),
        );
    }
}

#[test]
fn headers_urls_jwts_and_private_keys_keep_their_frame() {
    let jwt = format!("eyJ{}.eyJ{}.{}", body(20), body(30), body(43));
    assert_masked(&format!("token {jwt} expired"), &[&jwt], "token [jwt] expired");

    let bearer = body(40);
    assert_masked(
        &format!("curl -H 'Authorization: Bearer {bearer}' https://api.example.com"),
        &[&bearer],
        "curl -H 'Authorization: Bearer [auth token]' https://api.example.com",
    );
    let basic = "dXNlcjpodW50ZXIy";
    assert_masked(
        &format!("Authorization: Basic {basic}"),
        &[basic],
        "Authorization: Basic [auth token]",
    );
    let api_key = format!("k{}", body(20));
    assert_masked(
        &format!("-H \"x-api-key: {api_key}\""),
        &[&api_key],
        "-H \"x-api-key: [auth token]\"",
    );

    let password = "hunter2hunter2";
    assert_masked(
        &format!("clone https://leo:{password}@git.example.com/repo.git"),
        &[password],
        "clone https://[credentials]@git.example.com/repo.git",
    );

    let pem = format!(
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n{}\n-----END OPENSSH PRIVATE KEY-----",
        body(64),
        body(64)
    );
    assert_masked(
        &format!("here is the key:\n{pem}\nthanks"),
        &[&body(64)],
        "here is the key:\n[private key]\nthanks",
    );
    // A pasted key cut off before its END line is still masked to the end of the text.
    assert_masked(
        &format!("-----BEGIN RSA PRIVATE KEY-----\n{}", body(64)),
        &[&body(64)],
        "[private key]",
    );
}

#[test]
fn secret_assignments_mask_the_value_and_keep_the_name() {
    let value = "s3cr3t-Value-77";
    assert_masked(&format!("export API_KEY={value}"), &[value], "export API_KEY=[secret]");
    assert_masked(&format!("DB_PASSWORD=\"{value}\""), &[value], "DB_PASSWORD=[secret]");
    assert_masked(
        &format!(r#"{{"client_secret": "{value}"}}"#),
        &[value],
        r#"{"client_secret": [secret]}"#,
    );
    // A known shape names its kind even inside an assignment.
    let github = format!("gh{}_{}", "p", body(36));
    assert_masked(&format!("GITHUB_TOKEN={github}"), &[&github], "GITHUB_TOKEN=[github token]");
    // Placeholders are not values.
    for text in [
        "GITHUB_TOKEN=$GITHUB_TOKEN",
        "API_KEY=${{ secrets.API_KEY }}",
        "password: <your password>",
        "TOKEN=********",
    ] {
        assert_eq!(mask(text), text);
    }
}

#[test]
fn a_long_random_run_is_masked_without_a_known_shape() {
    let token = body(40);
    assert_masked(&format!("the value is {token} ok"), &[&token], "the value is [secret] ok");
}

/// What must not be masked: the masked line would hide what an agent is doing.
#[test]
fn ordinary_text_is_left_alone() {
    for text in [
        // Git SHAs and other hex: one case only.
        "merge 774a92d8f81238a678ce294dd3228fe55aa2b7b2 into feat-cmux-next",
        "sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        // UUIDs, upper and lower.
        "session 550e8400-e29b-41d4-a716-446655440000 and 6F9619FF-8B86-D011-B42D-00C04FC964FF",
        // Paths, branches, identifiers and package names.
        "/Users/leoli/Projects/cmux-21189-rebase-20261018-isolated/Sources/AgentActivityLane.swift",
        "feat/chief-view-lane-step-and-the-sanitizer-for-secrets",
        "theLanesItemCountsOnlyThisMacsOwnSessionsUnlessTheFleetToggleIsOn",
        "pip install sk-learn-preprocessing-pipelines",
        // Prose that names keys and tokens.
        "rotate the API key and check the token: it expired",
        "the author: Leo",
        // A PR, an issue and a short id.
        "Opened manaflow-ai/cmux#21727; CI is green on 774a92d8f8.",
        // Code and config that only name tokens and secrets.
        "call crate::secret_scan::mask(text) on it",
        "max_tokens: 100000, inputTokens: 123456",
        "tokenizer: sentencepiece",
        "the token: expired",
    ] {
        assert_eq!(mask(text), text, "{text:?} was masked: {:?}", find(text));
    }
}

/// An inline image's base64 is long, mixed-case and random, but it is not a
/// secret, and masking it would replace the whole payload.
#[test]
fn a_data_uri_payload_is_not_a_secret() {
    let png = format!("data:image/png;base64,iVBORw0KGgo{}/{}=", body(48), body(48));
    let text = format!("![shot]({png})");
    assert_eq!(mask(&text), text);
}

#[test]
fn several_secrets_in_one_text_are_each_masked_once() {
    let github = format!("gh{}_{}", "p", body(36));
    let anthropic = format!("sk-ant-api03-{}", body(40));
    assert_masked(
        &format!("set {github} then {anthropic}, Bearer {anthropic}"),
        &[&github, &anthropic],
        "set [github token] then [anthropic key], Bearer [anthropic key]",
    );
}
