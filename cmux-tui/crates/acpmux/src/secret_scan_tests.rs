//! The corpus is fake: every secret here is assembled at run time, and Nosey
//! Parker's examples are stored XORed and base64-encoded, so no file in the
//! tree holds a string a secret scanner (or GitHub push protection) would flag.

use base64::Engine as _;
use serde::Deserialize;

use super::*;

/// A fake base62 body of `n` characters with the spread of a real token.
fn body(n: usize) -> String {
    "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(n).collect()
}

/// Masking `text` leaves none of `secrets` in the output, every mask is the
/// one expected, and scanning the output again finds nothing (the source is
/// absent, not covered).
#[track_caller]
fn assert_masked(text: &str, secrets: &[&str], expected: &str) {
    let out = mask(text);
    assert_eq!(out, expected, "masking {text:?}: {:?}", find(text));
    for secret in secrets {
        assert!(!out.contains(secret), "{secret:?} survives in {out:?}");
    }
    assert!(find(&out).is_empty(), "the masked text still has a secret: {out:?} {:?}", find(&out));
}

#[test]
fn every_vendored_gitleaks_rule_compiles() {
    let config: Config = toml::from_str(GITLEAKS).expect("gitleaks.toml parses");
    let compiled: Vec<&str> = RULES.rules.iter().map(|r| r.id.as_str()).collect();
    let dropped: Vec<&str> = config
        .rules
        .iter()
        .filter(|r| r.regex.is_some() && r.path.is_none() && !compiled.contains(&r.id.as_str()))
        .map(|r| r.id.as_str())
        .collect();
    assert!(dropped.is_empty(), "rules the regex crate rejects: {dropped:?}");
    let labels: LabelsConfig = toml::from_str(LABELS).expect("labels.toml parses");
    let unlabelled: Vec<&str> = config
        .rules
        .iter()
        .filter(|r| !labels.labels.contains_key(&r.id))
        .map(|r| r.id.as_str())
        .collect();
    assert!(unlabelled.is_empty(), "run refresh.ts: no label for {unlabelled:?}");
}

#[test]
fn provider_keys_become_what_they_are() {
    let anthropic = format!("sk-ant-api03-{}AA", body(93));
    let stripe = format!("{}_live_{}", "sk", body(24));
    let github = format!("gh{}_{}", "p", body(36));
    let slack = format!("xox{}-{}-{}-{}", "b", "1234567890", "1234567890", body(24));
    let aws = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let google = format!("AIza{}", body(35));
    for (secret, rule, mask) in [
        (&anthropic, "anthropic-api-key", "[Anthropic API Key]"),
        (&stripe, "stripe-access-token", "[Stripe Access Token]"),
        (&github, "github-pat", "[GitHub Personal Access Token]"),
        (&slack, "slack-bot-token", "[Slack Bot token]"),
        (&aws, "aws-access-token", "[AWS access key]"),
        (&google, "gcp-api-key", "[GCP API key]"),
    ] {
        let text = format!("use {secret} for the deploy");
        assert_eq!(find(&text).first().map(|f| f.rule), Some(rule), "{text}");
        assert_masked(&text, &[secret], &format!("use {mask} for the deploy"));
    }
}

#[test]
fn headers_urls_jwts_and_private_keys_keep_their_frame() {
    let jwt = format!("eyJ{}.eyJ{}.{}", body(20), body(30), body(43));
    assert_masked(&format!("token {jwt} expired"), &[&jwt], "token [JSON Web Token] expired");

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
        "here is the key:\n[Private Key]\nthanks",
    );
    // A pasted key cut off before its END line is still masked to the end of the text.
    assert_masked(
        &format!("-----BEGIN RSA PRIVATE KEY-----\n{}", body(64)),
        &[&body(64)],
        "[Private Key]",
    );
}

#[test]
fn secret_assignments_mask_the_value_and_keep_the_name() {
    let value = "s3cr3t-Value-77";
    assert_masked(&format!("export API_KEY={value}"), &[value], "export API_KEY=[secret]");
    assert_masked(&format!("DB_PASSWORD=\"{value}\""), &[value], "DB_PASSWORD=\"[secret]\"");
    assert_masked(
        &format!(r#"{{"client_secret": "{value}"}}"#),
        &[value],
        r#"{"client_secret": "[secret]"}"#,
    );
    // A known shape names its kind even inside an assignment.
    let github = format!("gh{}_{}", "p", body(36));
    assert_masked(
        &format!("GITHUB_TOKEN={github}"),
        &[&github],
        "GITHUB_TOKEN=[GitHub Personal Access Token]",
    );
    // A name that says secret or password makes its value one, even shaped like an id or a word.
    let hex = "37d02377a3e9d849e18704c3ec883f9c5787d857";
    assert_masked(&format!("GITHUB_SECRET={hex}"), &[hex], "GITHUB_SECRET=[secret]");
    assert_masked("password = open_sesame", &["open_sesame"], "password = [secret]");
    // Placeholders are not values.
    for text in [
        "GITHUB_TOKEN=$GITHUB_TOKEN",
        "API_KEY=${{ secrets.API_KEY }}",
        "password: <your password>",
        "TOKEN=********",
        "const password = process.env.DB_PASSWORD || \"not-set\"",
        r#"passwordLabel:"Password:","#,
        r#"text << "Password=#{password}, ""#,
    ] {
        assert_eq!(mask(text), text, "{:?}", find(text));
    }
}

/// Hex and UUIDs are ids in prose, but not behind a header or a key's name.
#[test]
fn hex_and_uuid_secrets_behind_a_header_or_a_name_are_masked() {
    let hex = "4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e";
    assert_masked(
        &format!("Authorization: Bearer {hex}"),
        &[hex],
        "Authorization: Bearer [auth token]",
    );
    let uuid = "6f9619ff-8b86-d011-b42d-00c04fc964ff";
    assert_masked(&format!("x-api-key: {uuid}"), &[uuid], "x-api-key: [auth token]");
    let short = "9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c";
    assert_masked(&format!("api_token = \"{short}\""), &[short], "api_token = \"[secret]\"");
}

/// Only a name that says it is an id lets hex through: a key that encrypts,
/// signs or authenticates is a secret, and hex never reads as random.
#[test]
fn hex_behind_a_key_name_that_is_not_an_id_is_masked() {
    let hex64 = "4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e";
    let hex40 = "774a92d8f81238a678ce294dd3228fe55aa2b7b2";
    for (name, value) in [
        ("encryption_key = \"", hex64),
        ("signing_key: ", hex40),
        ("hmac_key=", hex64),
        ("master_key: ", hex64),
        ("DD_APP_KEY=", hex40),
        ("client_key: ", hex64),
        ("the encryption key: ", hex64),
        ("access_key=", hex40),
        ("private_key: ", hex64),
    ] {
        let text = format!("{name}{value}");
        let out = mask(&text);
        assert!(!out.contains(value), "{text:?} was left: {out:?}");
    }
}

/// A value that only starts like a placeholder is still a value.
#[test]
fn a_secret_that_starts_with_a_sigil_is_masked() {
    assert_masked("password: $up3rS3cret9", &["$up3rS3cret9"], "password: [secret]");
    assert_masked("DB_PASSWORD=#h4sh-st4rt", &["#h4sh-st4rt"], "DB_PASSWORD=[secret]");
}

#[test]
fn every_vendored_allowlist_regex_compiles() {
    let config: Config = toml::from_str(GITLEAKS).expect("gitleaks.toml parses");
    let lists =
        std::iter::once(&config.allowlist).chain(config.rules.iter().flat_map(|r| &r.allowlists));
    let broken: Vec<&str> = lists
        .flat_map(|a| &a.regexes)
        .filter(|p| compile(p).is_none())
        .map(String::as_str)
        .collect();
    assert!(broken.is_empty(), "allowlist regexes the regex crate rejects: {broken:?}");
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
        "GIT_COMMIT=774a92d8f81238a678ce294dd3228fe55aa2b7b2",
        // A SHA or hash behind a plain "key" is an id: a cache or idempotency key.
        "key: 774a92d8f81238a678ce294dd3228fe55aa2b7b2",
        "cache key: 774a92d8f81238a678ce294dd3228fe55aa2b7b2",
        r#""key": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855""#,
        "restore_key=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        r#"{"cacheKey": "774a92d8f81238a678ce294dd3228fe55aa2b7b2"}"#,
        "idempotency key: 550e8400-e29b-41d4-a716-446655440000",
        // UUIDs, upper and lower.
        "session 550e8400-e29b-41d4-a716-446655440000 and 6F9619FF-8B86-D011-B42D-00C04FC964FF",
        r#""creating-a-strong-password":"/en/enterprise-server/authentication""#,
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
        // Code that names a password or secret without holding one.
        "struct Login { user: String, password: String, }",
        "let secret = compute_secret(input);",
        r#"passwordLabel: "Password","#,
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
    assert_eq!(mask(&text), text, "{:?}", find(&text));
}

#[test]
fn several_secrets_in_one_text_are_each_masked_once() {
    let github = format!("gh{}_{}", "p", body(36));
    let anthropic = format!("sk-ant-api03-{}AA", body(93));
    assert_masked(
        &format!("set {github} then {anthropic} , Bearer {anthropic}"),
        &[&github, &anthropic],
        "set [GitHub Personal Access Token] then [Anthropic API Key] , Bearer [Anthropic API Key]",
    );
}

#[test]
fn multibyte_text_around_a_secret_masks_on_character_boundaries() {
    let github = format!("gh{}_{}", "p", body(36));
    assert_masked(
        &format!("鍵は{github}です ✅"),
        &[&github],
        "鍵は[GitHub Personal Access Token]です ✅",
    );
}

#[derive(Deserialize)]
struct Corpus {
    xor: u8,
    rules: Vec<CorpusRule>,
}

#[derive(Deserialize)]
struct CorpusRule {
    id: String,
    examples: Vec<String>,
    negative: Vec<String>,
}

/// Nosey Parker's positive and negative examples (Apache-2.0): how many
/// secrets it catches and how many look-alikes it leaves alone. A refresh or a
/// rule change that loses either is caught here; the misses print.
#[test]
fn nosey_parker_examples_are_caught_and_its_negatives_left_alone() {
    let corpus: Corpus =
        serde_json::from_str(include_str!("../rules/secrets/noseyparker-examples.json"))
            .expect("noseyparker-examples.json parses");
    let decode = |s: &str| {
        let bytes = base64::engine::general_purpose::STANDARD.decode(s).expect("base64");
        String::from_utf8(bytes.into_iter().map(|b| b ^ corpus.xor).collect()).expect("utf-8")
    };
    let (mut caught, mut total, mut flagged, mut negatives) = (0, 0, 0, 0);
    let (mut missed, mut false_positives) = (Vec::new(), Vec::new());
    for rule in &corpus.rules {
        for example in rule.examples.iter().map(|e| decode(e)) {
            total += 1;
            if find(&example).is_empty() {
                missed.push(rule.id.as_str());
            } else {
                caught += 1;
                let out = mask(&example);
                assert!(find(&out).is_empty(), "{}: masking left a secret in {out:?}", rule.id);
            }
        }
        for example in rule.negative.iter().map(|e| decode(e)) {
            negatives += 1;
            if !find(&example).is_empty() {
                flagged += 1;
                false_positives.push(rule.id.as_str());
            }
        }
    }
    println!("caught {caught} of {total} Nosey Parker examples; missed: {missed:?}");
    println!("flagged {flagged} of {negatives} negative examples: {false_positives:?}");
    assert!(
        caught * 100 >= total * MIN_RECALL_PERCENT,
        "caught {caught} of {total}; missed {missed:?}"
    );
    assert!(
        flagged <= MAX_FLAGGED_NEGATIVES,
        "flagged {flagged} of {negatives}: {false_positives:?}"
    );
}

/// Measured on gitleaks v8.30.1 and Nosey Parker v0.24.0 (282 of 413 caught, 49 of 135 flagged);
/// move them when a change catches more. Most misses are not secrets a prompt holds (ARNs,
/// password hashes, Kerberos tickets) or hex and words with no name saying secret. Most
/// flagged negatives are secrets under another rule's name (a Slack user token among the bot
/// token's negatives) or values assigned to a password: masking them is right here.
const MIN_RECALL_PERCENT: usize = 68;
const MAX_FLAGGED_NEGATIVES: usize = 49;

/// The rule table and the cmux patterns are constants behind INVARIANT expects:
/// building each one here keeps a broken pattern a test failure, never a panic.
#[test]
fn the_constant_patterns_compile() {
    let rules = LazyLock::force(&RULES);
    assert!(rules.rules.iter().any(|rule| rule.id == "cmux-private-key"));
    assert!(rules.rules.iter().any(|rule| rule.id.starts_with("generic")));
    for pattern in [&ENTROPY_CANDIDATE, &DATA_URI, &PLACEHOLDER, &CODE_PATH] {
        assert!(!LazyLock::force(pattern).as_str().is_empty());
    }
}
