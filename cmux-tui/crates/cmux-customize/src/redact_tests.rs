use super::*;

#[test]
fn a_value_named_like_a_credential_reads_as_the_mark() {
    let before = "{\n  \"apiKey\": \"abc123\", \"name\": \"mine\",\n  \"auth\": { \"refresh_token\" : \"r-1\" }\n}\n";
    let after = text(before);
    assert_eq!(
        after,
        "{\n  \"apiKey\": \"[redacted]\", \"name\": \"mine\",\n  \"auth\": { \"refresh_token\" : \"[redacted]\" }\n}\n"
    );
    // A value that merely follows a credential-named string is not one.
    assert_eq!(text("[\"token\", \"night\"]"), "[\"token\", \"night\"]");
    assert_eq!(text("\"maxTokens\": \"12\""), "\"maxTokens\": \"12\"");
}

#[test]
fn a_credential_on_the_line_after_its_name_reads_as_the_mark() {
    let file = "{\n  \"apiKey\":\n    // mine\n\n    \"private-value\",\n  \"name\":\n    \"mine\",\n  \"token\" :\n    [\"kept\"]\n}\n";
    let after = text(file);
    assert!(!after.contains("private-value"), "{after}");
    assert!(after.contains("    \"[redacted]\",\n"), "{after}");
    assert!(after.contains("\"mine\"") && after.contains("\"kept\""), "{after}");
    assert_eq!(after.lines().count(), file.lines().count());
    assert_eq!(find_secret(file), Some((5, "a value named like a password or token")));
    assert_eq!(find_secret("{\n  \"name\":\n    \"mine\"\n}\n"), None);
}

#[test]
fn a_credential_in_a_script_reads_as_the_mark_however_it_is_quoted() {
    for (line, masked) in [
        ("const config = {apiKey: 'private-value'};", "const config = {apiKey: '[redacted]'};"),
        (
            "  { 'api-key': \"private-value\", name: 'mine' }",
            "  { 'api-key': \"[redacted]\", name: 'mine' }",
        ),
        ("let password = `private-value`;", "let password = `[redacted]`;"),
        ("config.authToken = 'private-value'", "config.authToken = '[redacted]'"),
        (
            "headers: { Authorization: \"Bearer private-value\" }",
            "headers: { Authorization: \"[redacted]\" }",
        ),
        (
            "const tokenizer = 'kept'; let title = \"kept: too\";",
            "const tokenizer = 'kept'; let title = \"kept: too\";",
        ),
        ("// don't share: { apiKey: 'private-value' }", "// don't share: { apiKey: '[redacted]' }"),
    ] {
        assert_eq!(text(line), masked);
        assert_eq!(find_secret(line).is_some(), line != masked, "{line}");
    }
    let split =
        "const config = {\n  apiKey:\n    'private-value',\n  secret =\n    `private-value`\n};\n";
    assert!(!text(split).contains("private-value"), "{}", text(split));
    assert_eq!(find_secret(split), Some((3, "a value named like a password or token")));
}

#[test]
fn a_credential_in_a_template_literal_is_hidden_on_every_line_it_runs() {
    for script in [
        "const token = `\nprivate-value\n`;\nconst title = 'kept';\n",
        "const config = {\n  apiKey:\n    `\n    private-value\n    more-private-value`,\n};\nconst title = 'kept';\n",
        "let secret = `private-value\n  ${more}private-value\n`; const title = 'kept';\n",
    ] {
        let shown = text(script);
        assert!(!shown.contains("private-value"), "{shown}");
        assert!(shown.contains("const title = 'kept';"), "{shown}");
        assert_eq!(shown.lines().count(), script.lines().count(), "{shown}");
        assert!(find_secret(script).is_some(), "{script}");
    }
    assert_eq!(
        find_secret("const token = `\nprivate-value\n`;\n"),
        Some((2, "a value named like a password or token"))
    );
}

#[test]
fn a_url_keeps_its_host_and_loses_its_user_and_password() {
    assert_eq!(
        text("open https://alice:credential@example.com/page now"),
        "open https://[redacted]@example.com/page now"
    );
    assert_eq!(text("mail me@example.com"), "mail me@example.com");
    assert!(sensitive_url("https://alice:credential@example.com", true));
    assert!(sensitive_url("example.com/page?key=1", true));
    assert!(!sensitive_url("example.com/page?key=1", false));
    assert!(sensitive_url("https://example.com/#access=1", false));
    assert!(!sensitive_url("https://example.com/page", true));
    assert!(!sensitive_url("a night theme", true));
}

#[test]
fn a_token_and_a_private_key_block_read_as_the_mark() {
    let token = format!("ghp_{}", "a1B2".repeat(9));
    assert_eq!(text(&format!("gh auth --with {token} now\n")), "gh auth --with [redacted] now\n");
    assert_eq!(
        text(
            "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\nb\n"
        ),
        "a\n[redacted]\n[redacted]\n[redacted]\n[redacted]\nb\n"
    );
    assert_eq!(find_secret(&format!("one\ntwo {token}\n")), Some((2, "a GitHub token")));
    assert_eq!(find_secret("the task-12345 and sk-short\n"), None);
    assert_eq!(
        find_secret("x\nfetch('https://u:p@host/x')\n"),
        Some((2, "a user and password in a URL"))
    );
}

#[test]
fn a_setting_with_a_credential_reads_as_the_mark_and_keeps_its_line() {
    let file = "{\n  // mine\n  \"browser\": { \"newTabPage\": \"https://alice:credential@example.com\" },\n  \"appearance\": { \"density\": \"compact\" },\n  \"updates\": { \"channel\": \"nightly\" }\n}\n";
    let person = settings(file, Reader::Person);
    assert!(!person.contains("credential"), "{person}");
    assert!(person.contains("\"newTabPage\": \"[redacted]\""), "{person}");
    assert!(person.contains("\"channel\": \"nightly\""), "{person}");
    assert!(person.contains("\"density\": \"compact\""), "{person}");
    assert_eq!(person.lines().count(), file.lines().count());
    // An agent does not read what only the person may change.
    let agent = settings(file, Reader::Agent);
    assert!(agent.contains("\"channel\": \"[redacted]\""), "{agent}");
    assert!(agent.contains("\"density\": \"compact\""), "{agent}");
}

#[test]
fn a_token_is_found_by_its_prefix_and_ordinary_text_is_not() {
    assert_eq!(
        find_secret("a\nkey = \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\"\n"),
        Some((2, "a GitHub token"))
    );
    assert_eq!(find_secret("-----BEGIN OPENSSH PRIVATE KEY-----"), Some((1, "a private key")));
    assert_eq!(find_secret("task-sk-ip and risk-free and AKIA"), None);
    assert_eq!(find_secret("color: #abcdef; /* sk-short */"), None);
}
